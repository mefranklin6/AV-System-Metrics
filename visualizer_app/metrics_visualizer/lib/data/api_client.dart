// Client for the optional, read-only AV System Metrics Analytics API
// (Self_Hosted/analytics_api). See that folder's README.md and openapi.yaml
// for the server contract.
//
// Security notes:
// * The bearer token is only ever sent in the Authorization header, never in
//   URLs, and is never included in exception messages or toString output.
// * Redirects are not followed, so the token can never be forwarded to a
//   different host.
// * Responses are validated before use; malformed JSON becomes an
//   [ApiException] with kind [ApiErrorKind.invalidResponse].

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'timestamp_parser.dart';

/// Broad categories of failures, mapped from the API's error codes plus
/// client-side conditions.
enum ApiErrorKind {
  badRequest,
  unauthorized,
  forbidden,
  notFound,
  methodNotAllowed,
  tooManyRequests,
  internal,
  unavailable,
  network,
  timeout,
  invalidResponse,
  redirect,
  cancelled,
  unknown,
}

/// A failed API call. [message] and [suggestion] are written for end users.
class ApiException implements Exception {
  const ApiException(
    this.kind,
    this.message, {
    this.statusCode,
    this.code,
    this.suggestion,
    this.retryAfter,
  });

  final ApiErrorKind kind;
  final String message;

  /// HTTP status, when a response was received.
  final int? statusCode;

  /// The server's snake_case error code, when present.
  final String? code;
  final String? suggestion;

  /// From the `Retry-After` header on 429 / 503 responses.
  final Duration? retryAfter;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' (HTTP $statusCode)';
    return suggestion == null
        ? '$message$status'
        : '$message$status $suggestion';
  }
}

/// Lets callers stop a long-running download. Pass the same token to
/// [AnalyticsApiClient] methods and call [cancel] from the UI.
class CancellationToken {
  bool _cancelled = false;
  final Completer<void> _completer = Completer<void>();
  bool get isCancelled => _cancelled;

  /// Completes (never with an error) when [cancel] is called. Used to abort
  /// the request in flight.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer.complete();
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const ApiException(
          ApiErrorKind.cancelled, 'Loading was cancelled.');
    }
  }
}

/// Progress of a multi-request download.
class ApiProgress {
  const ApiProgress({
    required this.message,
    this.fraction,
    this.eventsLoaded = 0,
  });

  /// Human-readable phase, e.g. "Downloading events (12,000 so far)".
  final String message;

  /// 0..1 overall estimate, or null when unknown.
  final double? fraction;
  final int eventsLoaded;
}

typedef ApiProgressCallback = void Function(ApiProgress progress);

/// Response of `GET /api/v1/info`.
class ApiInfo {
  const ApiInfo({
    required this.apiVersion,
    required this.serverTime,
    this.firstEvent,
    this.lastEvent,
    this.purgeStatus,
    this.retentionDays,
    this.purgeCutoff,
    this.purgeFinishedAt,
  });

  final String apiVersion;
  final DateTime serverTime;
  final DateTime? firstEvent;
  final DateTime? lastEvent;

  /// `running`, `succeeded`, `failed` or null when the server has no status.
  final String? purgeStatus;

  /// Heartbeat retention (days), when the purge job has reported it.
  final int? retentionDays;
  final DateTime? purgeCutoff;
  final DateTime? purgeFinishedAt;
}

/// One row of `GET /api/v1/clients`.
class ApiClientSummary {
  const ApiClientSummary({
    required this.clientName,
    required this.eventCount,
    required this.heartbeatCount,
    this.firstEvent,
    this.lastEvent,
    this.lastHeartbeat,
  });

  final String clientName;
  final int eventCount;
  final int heartbeatCount;
  final DateTime? firstEvent;
  final DateTime? lastEvent;
  final DateTime? lastHeartbeat;
}

/// Typed access to the Analytics API.
class AnalyticsApiClient {
  /// [baseUrl] is the server root: normally the TLS reverse proxy in front
  /// of the service (e.g. `https://avsm.example.edu`, or a path prefix such
  /// as `https://av.example.edu/analytics`). `http://<server>:8081` only
  /// suits trusted networks. Use
  /// [parseBaseUrl] to validate user input first.
  ///
  /// [sleep] waits before a rate-limit retry (injectable for tests).
  AnalyticsApiClient({
    required this.baseUrl,
    required String token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 45),
    this.maxEvents = defaultMaxEvents,
    Future<void> Function(Duration delay)? sleep,
  })  : _token = token,
        _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _sleep = sleep ?? Future<void>.delayed {
    final problem = validateToken(token);
    if (problem != null) throw ArgumentError(problem);
  }

  final Uri baseUrl;
  final String _token;
  final http.Client _http;
  final bool _ownsClient;
  final Future<void> Function(Duration delay) _sleep;

  /// Per-request timeout, covering sending the request and reading the
  /// whole response.
  final Duration timeout;

  /// [fetchAllEvents] stops with an error rather than holding more than
  /// this many events in memory.
  final int maxEvents;

  /// Default for [maxEvents]: well above a typical term of data for a
  /// large campus, but low enough to keep a browser tab alive.
  static const int defaultMaxEvents = 5000000;

  /// Above this many events ([estimateEventCount]) the app asks before
  /// downloading and suggests a shorter period or fewer rooms.
  static const int largeDownloadEvents = 2000000;

  /// A `429` whose `Retry-After` is at most this long is a short rate limit:
  /// the client waits and retries (up to [maxRateLimitRetries] times).
  /// Longer waits (the failed sign-in lockout) are reported instead.
  static const Duration maxAutomaticRetryAfter = Duration(seconds: 60);
  static const int maxRateLimitRetries = 3;

  /// Encoded query-string budget per request. Long client lists are split
  /// so a URL stays well under common proxy limits (nginx: 8 KiB request
  /// line) and the server's 16 KiB header limit.
  static const int maxQueryBytes = 6 * 1024;

  /// Server limits on tokens (Self_Hosted/analytics_api/config.go).
  static const int minTokenLength = 32;
  static const int maxTokenLength = 512;

  /// Largest page the server accepts.
  static const int maxPageSize = 5000;

  /// Longest span the server accepts for hourly heartbeat buckets.
  static const Duration maxHourlyHeartbeatSpan = Duration(days: 92);

  /// Longest span for any query.
  static const Duration maxQuerySpan = Duration(days: 400);

  /// Most `client` filter values allowed per request.
  static const int maxClientsPerRequest = 200;

  /// Validates and normalises a user-entered base URL. Throws
  /// [FormatException] with a user-facing message when it is unusable.
  static Uri parseBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('Enter the Analytics API address.');
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException(
          'Enter a full address that starts with https:// such as '
          'https://avsm.example.edu');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('The address must start with https:// or http://');
    }
    if (uri.userInfo.isNotEmpty) {
      throw const FormatException(
          'Do not put a user name or password in the address. Enter the token in the token field.');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const FormatException(
          'Remove the ? or # part from the address; enter only the server root.');
    }
    // Normalise: drop trailing slashes from the path prefix.
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: segments.isEmpty ? null : segments,
    );
  }

  /// True when [uri] would send the token unencrypted over a network, that
  /// is plain `http` to anything other than this computer.
  static bool isInsecure(Uri uri) {
    if (uri.scheme != 'http') return false;
    return !isLoopbackHost(uri.host);
  }

  static final RegExp _ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');

  /// True only for `localhost` and loopback IP literals (127.0.0.0/8 and
  /// ::1). Any other name, such as `127.0.0.1.example.org`, may resolve to
  /// a remote host and is not loopback.
  static bool isLoopbackHost(String host) {
    var h = host.toLowerCase();
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h == 'localhost') return true;
    if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
    final v4 = _ipv4.firstMatch(h);
    if (v4 != null) {
      for (var i = 1; i <= 4; i++) {
        final part = v4.group(i)!;
        // Leading zeros can mean octal to some resolvers: not loopback.
        if (part.length > 1 && part.startsWith('0')) return false;
        if (int.parse(part) > 255) return false;
      }
      return v4.group(1) == '127';
    }
    if (h.contains(':')) {
      try {
        final bytes = Uri.parseIPv6Address(h);
        for (var i = 0; i < 15; i++) {
          if (bytes[i] != 0) return false;
        }
        return bytes[15] == 1;
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  /// Returns a user-facing problem with [token], or null when acceptable.
  /// Tokens must be printable ASCII without whitespace so they cannot
  /// inject extra HTTP headers, and follow the server's rules (32-512
  /// letters, digits or `. _ ~ + / = -`, one token only).
  static String? validateToken(String token) {
    if (token.isEmpty) return 'Enter the API token.';
    for (final c in token.codeUnits) {
      if (c <= 0x20 || c >= 0x7F) {
        return 'The token contains spaces or unsupported characters. '
            'Paste it again without extra spaces or line breaks.';
      }
    }
    if (token.contains(',')) {
      return 'Enter only one token, not the comma-separated list from the '
          'server settings.';
    }
    if (token.length > maxTokenLength) {
      return 'The token is too long (at most $maxTokenLength characters). '
          'Check that you copied only the token.';
    }
    if (token.length < minTokenLength) {
      return 'The token is too short (at least $minTokenLength characters). '
          'Check that you copied all of it.';
    }
    for (final c in token.codeUnits) {
      final ok = (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          '._~+/=-'.codeUnits.contains(c);
      if (!ok) {
        return 'The token contains a character the server never uses in '
            'tokens (only letters, digits and . _ ~ + / = - are allowed). '
            'Check that you copied only the token.';
      }
    }
    return null;
  }

  void close() {
    if (_ownsClient) _http.close();
  }

  // ---------------------------------------------------------------- calls

  /// `GET /health` (unauthenticated). True when the server reports OK.
  Future<bool> health({CancellationToken? cancel}) async {
    try {
      final body = await _getJson(['health'], const {},
          authenticated: false, cancel: cancel);
      return body['ok'] == true;
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.unavailable) return false;
      rethrow;
    }
  }

  /// `GET /api/v1/info`.
  Future<ApiInfo> info({CancellationToken? cancel}) async {
    final j = await _getJson(['api', 'v1', 'info'], const {}, cancel: cancel);
    final range = _map(j['activity_range']);
    final purge = _map(j['heartbeat_purge']);
    return ApiInfo(
      apiVersion: _string(j, 'api_version'),
      serverTime: _time(j, 'server_time'),
      firstEvent: _timeOrNull(range, 'first_event'),
      lastEvent: _timeOrNull(range, 'last_event'),
      purgeStatus: purge['enabled_status'] as String?,
      retentionDays: (purge['retention_days'] as num?)?.toInt(),
      purgeCutoff: _timeOrNull(purge, 'cutoff'),
      purgeFinishedAt: _timeOrNull(purge, 'finished_at'),
    );
  }

  /// `GET /api/v1/clients`.
  Future<List<ApiClientSummary>> clients({
    DateTime? from,
    DateTime? to,
    CancellationToken? cancel,
  }) async {
    final j = await _getJson(['api', 'v1', 'clients'], {
      if (from != null) 'from': formatRfc3339Utc(from),
      if (to != null) 'to': formatRfc3339Utc(to),
    }, cancel: cancel);
    final list = _list(j, 'clients');
    return [
      for (final raw in list)
        () {
          final c = _map(raw);
          return ApiClientSummary(
            clientName: _string(c, 'clientname'),
            eventCount: _int(c, 'event_count'),
            heartbeatCount: _int(c, 'heartbeat_count'),
            firstEvent: _timeOrNull(c, 'first_event'),
            lastEvent: _timeOrNull(c, 'last_event'),
            lastHeartbeat: _timeOrNull(c, 'last_heartbeat'),
          );
        }()
    ];
  }

  /// Number of non-heartbeat events the server holds for [clients] (null or
  /// empty = all) in [from, to), from `GET /api/v1/clients`. Lets the UI
  /// warn before a very large download.
  Future<int> estimateEventCount({
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
    CancellationToken? cancel,
  }) async {
    final all = await this.clients(from: from, to: to, cancel: cancel);
    var total = 0;
    for (final c in all) {
      if (clients == null ||
          clients.isEmpty ||
          clients.contains(c.clientName)) {
        total += c.eventCount;
      }
    }
    return total;
  }

  /// Downloads every non-heartbeat event in [from, to) by following
  /// `next_cursor` until the server reports no more rows.
  ///
  /// [clients] (null or empty = all) is split into groups of
  /// [maxClientsPerRequest]. [onProgress] receives an estimate based on how
  /// far through the time range the latest page reached.
  Future<List<MetricEvent>> fetchAllEvents({
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
    int pageSize = maxPageSize,
    ApiProgressCallback? onProgress,
    CancellationToken? cancel,
  }) async {
    _checkRange(from, to, maxQuerySpan);
    final size = pageSize.clamp(1, maxPageSize);
    final groups = _clientGroups(clients);
    final events = <MetricEvent>[];
    final spanMicros = to.difference(from).inMicroseconds;
    groupLoop:
    for (var g = 0; g < groups.length; g++) {
      String? cursor;
      final seenCursors = <String>{};
      do {
        cancel?.throwIfCancelled();
        final Map<String, Object?> j;
        try {
          j = await _getJson(['api', 'v1', 'events'], {
            'from': formatRfc3339Utc(from),
            'to': formatRfc3339Utc(to),
            'limit': '$size',
            if (groups[g].isNotEmpty) 'client': groups[g],
            'cursor': ?cursor,
          }, cancel: cancel);
        } on ApiException catch (e) {
          // The address was too long for the server or a proxy: retry the
          // group in two halves (only before any of its pages was kept).
          if (_isTooLong(e) && cursor == null && groups[g].length > 1) {
            final half = groups[g].length ~/ 2;
            groups.replaceRange(g, g + 1, [
              groups[g].sublist(0, half),
              groups[g].sublist(half),
            ]);
            g--; // run the first half next
            continue groupLoop;
          }
          rethrow;
        }
        final page = _list(j, 'events');
        DateTime? last;
        for (final raw in page) {
          final e = _map(raw);
          final action = _string(e, 'action');
          if (action == heartbeatAction) continue;
          final ts = _time(e, 'event_timestamp');
          last = ts;
          events.add(MetricEvent(
            clientName: _string(e, 'clientname'),
            timestamp: ts,
            metric: _string(e, 'metric'),
            action: action,
            eventId: e['event_id'] as String?,
            receivedAt: _timeOrNull(e, 'received_at'),
          ));
        }
        if (events.length > maxEvents) throw _tooManyEvents();
        final next = j['next_cursor'];
        if (next != null && next is! String) {
          throw _invalid('next_cursor is not a string');
        }
        cursor = next as String?;
        if (cursor != null && !seenCursors.add(cursor)) {
          throw _invalid('the server repeated a page cursor');
        }
        if (cursor != null && page.isEmpty) {
          throw _invalid('an empty page had a next cursor');
        }
        if (onProgress != null) {
          final within = last == null || spanMicros <= 0
              ? (cursor == null ? 1.0 : 0.0)
              : (last.difference(from).inMicroseconds / spanMicros)
                  .clamp(0.0, 1.0);
          final done = cursor == null ? 1.0 : within;
          onProgress(ApiProgress(
            message: 'Downloading events (${events.length} so far)',
            fraction: (g + done) / groups.length,
            eventsLoaded: events.length,
          ));
        }
      } while (cursor != null);
    }
    return events;
  }

  /// Downloads hourly heartbeat counts for [from, to), splitting the range
  /// into chunks no longer than [maxHourlyHeartbeatSpan] and the client list
  /// into groups small enough that one request cannot exceed the server's
  /// bucket limit ([heartbeatRoomsPerRequest]).
  ///
  /// The server returns at most [maxHeartbeatBucketsPerResponse] buckets per
  /// request and sets `truncated` when more exist. A truncated response is
  /// never used: the request is repeated in smaller parts until every part
  /// is complete. "All rooms" is replaced by the explicit room list from
  /// `GET /api/v1/clients`, room groups are halved, and a single room is
  /// split into halves of its time range (on hour boundaries). If even one
  /// room for one hour is truncated, an [ApiException] is thrown rather than
  /// keeping partial coverage.
  Future<List<HeartbeatBucket>> fetchHourlyHeartbeats({
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
    ApiProgressCallback? onProgress,
    CancellationToken? cancel,
  }) async {
    _checkRange(from, to, maxQuerySpan);
    final chunks = splitRange(from, to, maxHourlyHeartbeatSpan);
    // The first chunk is the longest, so its group size suits every chunk.
    final roomsPerRequest = chunks.isEmpty
        ? maxClientsPerRequest
        : heartbeatRoomsPerRequest(chunks.first.$1, chunks.first.$2);
    final groups = clientGroups(clients, maxPerGroup: roomsPerRequest);
    final out = <HeartbeatBucket>[];
    var done = 0;
    for (var c = 0; c < chunks.length; c++) {
      final (start, end) = chunks[c];
      for (var g = 0; g < groups.length; g++) {
        final group = groups[g];
        cancel?.throwIfCancelled();
        final _HeartbeatPage page;
        try {
          page = await _heartbeatPage(start, end, group, cancel);
        } on ApiException catch (e) {
          // Address too long: split the group (for this and later chunks).
          if (_isTooLong(e) && group.length > 1) {
            final half = group.length ~/ 2;
            groups.replaceRange(g, g + 1, [
              group.sublist(0, half),
              group.sublist(half),
            ]);
            g--;
            continue;
          }
          rethrow;
        }
        if (page.truncated) {
          if (group.isEmpty) {
            // "All rooms" was too much: ask for the room names in the rest
            // of the range and request them in groups instead (for this and
            // later chunks). A room whose first event arrives after this
            // list was read is not included, as if the download had
            // started a moment earlier.
            final named = await this.clients(from: start, to: to.toUtc(), cancel: cancel);
            final resolved = clientGroups({for (final s in named) s.clientName},
                maxPerGroup: roomsPerRequest);
            if (resolved.length == 1 && resolved.single.isEmpty) {
              throw _heartbeatsTruncated();
            }
            groups.replaceRange(g, g + 1, resolved);
            g--;
            continue;
          }
          if (group.length > 1) {
            // Too many rooms in one request (not expected with
            // roomsPerRequest, but the server decides): halve the group, for
            // this and later chunks.
            final half = group.length ~/ 2;
            groups.replaceRange(g, g + 1, [
              group.sublist(0, half),
              group.sublist(half),
            ]);
            g--;
            continue;
          }
          // One room: split its time range until every part is complete.
          out.addAll(await _heartbeatsByTimeHalves(start, end, group, cancel));
        } else {
          out.addAll(page.buckets);
        }
        // Requests made so far plus those still to come (groups can split).
        final total =
            done + (groups.length - g) + (chunks.length - c - 1) * groups.length;
        done++;
        onProgress?.call(ApiProgress(
          message: 'Downloading heartbeat coverage ($done of $total)',
          fraction: done / total,
        ));
      }
    }
    return out;
  }

  /// Most buckets the server returns from one `/api/v1/heartbeats` request
  /// (Self_Hosted/analytics_api/store.go `maxHeartbeatBuckets`).
  static const int maxHeartbeatBucketsPerResponse = 200000;

  /// One `/api/v1/heartbeats` request, parsed. `truncated` is required by
  /// the API contract; a response without it is rejected, because the app
  /// could not tell complete coverage from partial coverage.
  Future<_HeartbeatPage> _heartbeatPage(
      DateTime start, DateTime end, List<String> group, CancellationToken? cancel) async {
    final j = await _getJson(['api', 'v1', 'heartbeats'], {
      'from': formatRfc3339Utc(start),
      'to': formatRfc3339Utc(end),
      'bucket': 'hour',
      if (group.isNotEmpty) 'client': group,
    }, cancel: cancel);
    final truncated = j['truncated'];
    if (truncated is! bool) throw _invalid('missing "truncated"');
    final buckets = <HeartbeatBucket>[];
    for (final rawSeries in _list(j, 'series')) {
      final s = _map(rawSeries);
      final client = _string(s, 'clientname');
      for (final rawBucket in _list(s, 'buckets')) {
        final b = _map(rawBucket);
        buckets.add(HeartbeatBucket(
          clientName: client,
          hourStart: _time(b, 'start'),
          count: _int(b, 'count'),
        ));
      }
    }
    return _HeartbeatPage(buckets, truncated);
  }

  /// Fetches [start, end) for one room [group] in two halves split on an
  /// hour boundary, recursing while a half is still truncated.
  Future<List<HeartbeatBucket>> _heartbeatsByTimeHalves(
      DateTime start, DateTime end, List<String> group, CancellationToken? cancel) async {
    final mid = hourBoundaryNear(start, end);
    if (mid == null) throw _heartbeatsTruncated();
    final out = <HeartbeatBucket>[];
    for (final (s, e) in [(start, mid), (mid, end)]) {
      cancel?.throwIfCancelled();
      final page = await _heartbeatPage(s, e, group, cancel);
      out.addAll(page.truncated ? await _heartbeatsByTimeHalves(s, e, group, cancel) : page.buckets);
    }
    return out;
  }

  /// A whole UTC hour strictly inside (start, end), as close to the middle
  /// as possible, or null when there is none. Splitting on hour boundaries
  /// keeps every hourly bucket in exactly one half.
  static DateTime? hourBoundaryNear(DateTime start, DateTime end) {
    const hour = Duration.microsecondsPerHour;
    final s = start.toUtc().microsecondsSinceEpoch, e = end.toUtc().microsecondsSinceEpoch;
    final middle = s + (e - s) ~/ 2;
    var m = middle - middle % hour; // floor (times after 1970 are positive)
    if (m <= s) m += hour;
    if (m >= e) return null;
    return DateTime.fromMicrosecondsSinceEpoch(m, isUtc: true);
  }

  static ApiException _heartbeatsTruncated() => const ApiException(
        ApiErrorKind.badRequest,
        'The server returned only part of the room online coverage (it sends '
        'at most 200,000 hourly values per request) and the request could not '
        'be split into complete parts.',
        suggestion: 'Choose a shorter date range or fewer rooms. Room online '
            'coverage was not loaded rather than shown incomplete.',
      );

  /// Loads everything the visualizer needs for [from, to) into a [Dataset].
  Future<Dataset> loadDataset({
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
    ApiProgressCallback? onProgress,
    CancellationToken? cancel,
  }) async {
    onProgress?.call(const ApiProgress(
        message: 'Contacting the Analytics API', fraction: 0));
    final serverInfo = await info(cancel: cancel);
    final events = await fetchAllEvents(
      from: from,
      to: to,
      clients: clients,
      cancel: cancel,
      onProgress: onProgress == null
          ? null
          : (p) => onProgress(ApiProgress(
                message: p.message,
                fraction: (p.fraction ?? 0) * 0.8,
                eventsLoaded: p.eventsLoaded,
              )),
    );
    final heartbeats = await fetchHourlyHeartbeats(
      from: from,
      to: to,
      clients: clients,
      cancel: cancel,
      onProgress: onProgress == null
          ? null
          : (p) => onProgress(ApiProgress(
                message: p.message,
                fraction: 0.8 + (p.fraction ?? 0) * 0.2,
                eventsLoaded: events.length,
              )),
    );
    cancel?.throwIfCancelled();
    return Dataset(
      events: events,
      heartbeats: heartbeats,
      rangeStart: from.toUtc(),
      rangeEnd: to.toUtc(),
      origin: DatasetOrigin.api,
      description: baseUrl.host,
      heartbeatRetentionDays: serverInfo.retentionDays,
    );
  }

  /// Splits [from, to) into consecutive half-open chunks no longer than
  /// [maxSpan].
  static List<(DateTime, DateTime)> splitRange(
      DateTime from, DateTime to, Duration maxSpan) {
    final chunks = <(DateTime, DateTime)>[];
    var start = from.toUtc();
    final end = to.toUtc();
    while (start.isBefore(end)) {
      var chunkEnd = start.add(maxSpan);
      if (chunkEnd.isAfter(end)) chunkEnd = end;
      chunks.add((start, chunkEnd));
      start = chunkEnd;
    }
    return chunks;
  }

  // ------------------------------------------------------------ internals

  void _checkRange(DateTime from, DateTime to, Duration maxSpan) {
    if (!from.isBefore(to)) {
      throw ArgumentError('The start date must be before the end date.');
    }
    if (to.difference(from) > maxSpan) {
      throw ArgumentError(
          'The date range can be at most ${maxSpan.inDays} days.');
    }
  }

  /// Splits [clients] into groups of at most [maxPerGroup] (and never more
  /// than [maxClientsPerRequest]) names whose encoded `client=` parameters
  /// fit in [maxQueryBytes]. Returns a growable list (groups may be split
  /// again on a 414 / 431 response).
  static List<List<String>> clientGroups(Set<String>? clients,
      {int maxPerGroup = maxClientsPerRequest}) {
    if (clients == null || clients.isEmpty) return [<String>[]];
    final limit = maxPerGroup.clamp(1, maxClientsPerRequest);
    final sorted = clients.toList()..sort();
    final groups = <List<String>>[];
    var current = <String>[];
    var bytes = 0;
    for (final name in sorted) {
      // "&client=" plus the percent-encoded name.
      final cost = 8 + Uri.encodeQueryComponent(name).length;
      if (current.isNotEmpty &&
          (current.length >= limit ||
              bytes + cost > maxQueryBytes)) {
        groups.add(current);
        current = <String>[];
        bytes = 0;
      }
      current.add(name);
      bytes += cost;
    }
    if (current.isNotEmpty) groups.add(current);
    return groups;
  }

  static List<List<String>> _clientGroups(Set<String>? clients) =>
      clientGroups(clients);

  /// Rooms per heartbeat request so that one request for [start, end) can
  /// never exceed [maxHeartbeatBucketsPerResponse] (a room has at most one
  /// bucket per hour the range touches).
  static int heartbeatRoomsPerRequest(DateTime start, DateTime end) {
    final hours = (end.difference(start).inMicroseconds / Duration.microsecondsPerHour).ceil() + 1;
    return (maxHeartbeatBucketsPerResponse ~/ hours).clamp(1, maxClientsPerRequest);
  }

  static bool _isTooLong(ApiException e) =>
      e.statusCode == 414 || e.statusCode == 431;

  ApiException _tooManyEvents() => ApiException(
        ApiErrorKind.badRequest,
        'This period has more than $maxEvents events, more than the app can '
        'safely hold in memory.',
        suggestion: 'Choose a shorter date range or fewer rooms.',
      );

  Uri _uri(List<String> path, Map<String, Object> query) => Uri(
        scheme: baseUrl.scheme,
        host: baseUrl.host,
        port: baseUrl.hasPort ? baseUrl.port : null,
        pathSegments: [...baseUrl.pathSegments.where((s) => s.isNotEmpty), ...path],
        queryParameters: query.isEmpty ? null : query,
      );

  /// GET with automatic retries for short rate limits: a `429` with a
  /// `Retry-After` of at most [maxAutomaticRetryAfter] is waited out (the
  /// wait ends early on cancel) and retried up to [maxRateLimitRetries]
  /// times, so a long download does not fail on a brief limit.
  Future<Map<String, Object?>> _getJson(
    List<String> path,
    Map<String, Object> query, {
    bool authenticated = true,
    CancellationToken? cancel,
  }) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _getJsonOnce(path, query,
            authenticated: authenticated, cancel: cancel);
      } on ApiException catch (e) {
        final wait = e.retryAfter;
        if (e.kind != ApiErrorKind.tooManyRequests ||
            wait == null ||
            wait > maxAutomaticRetryAfter ||
            attempt >= maxRateLimitRetries) {
          rethrow;
        }
        cancel?.throwIfCancelled();
        final sleeping = _sleep(wait);
        if (cancel == null) {
          await sleeping;
        } else {
          await Future.any([sleeping, cancel.whenCancelled]);
          cancel.throwIfCancelled();
        }
      }
    }
  }

  /// One GET. [timeout] covers sending and reading the whole response, and
  /// both the timeout and [cancel] abort the request in flight.
  Future<Map<String, Object?>> _getJsonOnce(
    List<String> path,
    Map<String, Object> query, {
    required bool authenticated,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final abort = Completer<void>();
    void triggerAbort() {
      if (!abort.isCompleted) abort.complete();
    }

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      triggerAbort();
    });
    unawaited(cancel?.whenCancelled.then((_) => triggerAbort()));
    final request = http.AbortableRequest('GET', _uri(path, query),
        abortTrigger: abort.future)
      ..followRedirects = false
      ..headers['Accept'] = 'application/json';
    if (authenticated) request.headers['Authorization'] = 'Bearer $_token';

    http.Response response;
    try {
      final work = () async {
        final streamed = await _http.send(request);
        return http.Response.fromStream(streamed);
      }();
      // Do not depend on the client honouring the abort trigger: stop
      // waiting as soon as it fires.
      final aborted =
          abort.future.then<http.Response>((_) => throw const _Aborted());
      work.ignore();
      aborted.ignore();
      response = await Future.any([work, aborted]);
    } catch (e) {
      if (cancel != null && cancel.isCancelled) {
        throw const ApiException(
            ApiErrorKind.cancelled, 'Loading was cancelled.');
      }
      if (timedOut || e is TimeoutException) {
        throw ApiException(ApiErrorKind.timeout,
            'The Analytics API did not respond within ${timeout.inSeconds} seconds.',
            suggestion:
                'Check that the server is running and reachable, or choose a shorter date range.');
      }
      if (e is ApiException) rethrow;
      if (e is http.ClientException) {
        throw ApiException(ApiErrorKind.network,
            'Could not connect to the Analytics API.',
            suggestion: networkSuggestion(baseUrl));
      }
      throw const ApiException(ApiErrorKind.network,
          'Could not connect to the Analytics API.',
          suggestion:
              'Check the address and port and that the server is reachable.');
    } finally {
      timer.cancel();
    }
    cancel?.throwIfCancelled();

    final status = response.statusCode;
    if (status >= 300 && status < 400) {
      throw ApiException(ApiErrorKind.redirect,
          'The server answered with a redirect instead of data.',
          statusCode: status,
          suggestion:
              'Enter the final address of the Analytics API (for example '
              'https:// instead of http://). Redirects are not followed so the '
              'token is never sent to another server.');
    }
    if (status < 200 || status >= 300) {
      throw _errorFromResponse(response);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw _invalid('the response was not JSON');
    }
    if (decoded is! Map) throw _invalid('the response was not a JSON object');
    return decoded.cast<String, Object?>();
  }

  static const bool _isWeb = bool.fromEnvironment('dart.library.js_interop');

  /// Suggestion for a failed connection to [baseUrl]. On the web, a
  /// redirect, a CORS refusal and a blocked http:// request all look the
  /// same to the app, so an http:// address also gets an HTTPS hint.
  static String networkSuggestion(Uri baseUrl, {bool isWeb = _isWeb}) {
    const base = 'Check the address and port, your network or VPN connection '
        'and any firewall.';
    if (!isWeb) return base;
    final https = baseUrl.scheme == 'http'
        ? ' If the server uses HTTPS or redirects to https://, enter the '
            'https:// address instead.'
        : '';
    return "$base In a web browser the server must also list this app's "
        'address in ANALYTICS_CORS_ORIGINS.$https';
  }

  static ApiException _errorFromResponse(http.Response response) {
    final status = response.statusCode;
    if (status == 414 || status == 431) {
      // Plain-text answer from Go or from a proxy such as nginx.
      return ApiException(
        ApiErrorKind.badRequest,
        'The request address was too long for the server or a proxy in '
        'front of it.',
        statusCode: status,
        suggestion: 'Select fewer rooms, or all rooms, and try again. The '
            'administrator can also raise the proxy header size limit.',
      );
    }
    String? code;
    String? serverMessage;
    try {
      final j = jsonDecode(utf8.decode(response.bodyBytes));
      if (j is Map && j['error'] is Map) {
        final err = j['error'] as Map;
        code = err['code'] as String?;
        serverMessage = err['message'] as String?;
      }
    } catch (_) {
      // Not a JSON error body (for example a proxy error page): fall back
      // to the status code.
    }
    final kind = _kindFor(code, status);
    Duration? retryAfter;
    final ra = int.tryParse(response.headers['retry-after']?.trim() ?? '');
    if (ra != null && ra >= 0) retryAfter = Duration(seconds: ra);
    final (message, suggestion) = _describe(kind, retryAfter);
    final detail = serverMessage == null || serverMessage.isEmpty
        ? ''
        : ' Server says: "${_sanitize(serverMessage)}".';
    return ApiException(kind, '$message$detail',
        statusCode: status,
        code: code,
        suggestion: suggestion,
        retryAfter: retryAfter);
  }

  static String _sanitize(String s) {
    final cleaned = s.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ');
    return cleaned.length > 200 ? '${cleaned.substring(0, 200)}…' : cleaned;
  }

  static ApiErrorKind _kindFor(String? code, int status) {
    switch (code) {
      case 'bad_request':
        return ApiErrorKind.badRequest;
      case 'unauthorized':
        return ApiErrorKind.unauthorized;
      case 'forbidden':
        return ApiErrorKind.forbidden;
      case 'not_found':
        return ApiErrorKind.notFound;
      case 'method_not_allowed':
        return ApiErrorKind.methodNotAllowed;
      case 'too_many_requests':
        return ApiErrorKind.tooManyRequests;
      case 'internal':
        return ApiErrorKind.internal;
      case 'unavailable':
        return ApiErrorKind.unavailable;
    }
    switch (status) {
      case 400:
        return ApiErrorKind.badRequest;
      case 401:
        return ApiErrorKind.unauthorized;
      case 403:
        return ApiErrorKind.forbidden;
      case 404:
        return ApiErrorKind.notFound;
      case 405:
        return ApiErrorKind.methodNotAllowed;
      case 429:
        return ApiErrorKind.tooManyRequests;
      case 502:
      case 503:
      case 504:
        return ApiErrorKind.unavailable;
    }
    return status >= 500 ? ApiErrorKind.internal : ApiErrorKind.unknown;
  }

  static (String, String?) _describe(ApiErrorKind kind, Duration? retryAfter) {
    switch (kind) {
      case ApiErrorKind.badRequest:
        return (
          'The Analytics API rejected the request.',
          'Check the date range (at most 400 days, start before end) and room names.'
        );
      case ApiErrorKind.unauthorized:
        return (
          'The token was missing or not in the expected format.',
          'Enter the API token your server administrator gave you: one '
              'token, without spaces or line breaks.'
        );
      case ApiErrorKind.forbidden:
        return (
          'Access was denied.',
          'Check that the token is correct and current, and that this '
              "computer's network is allowed by ANALYTICS_ALLOWED_NET."
        );
      case ApiErrorKind.notFound:
        return (
          'The Analytics API was not found at this address.',
          'Check the address. It should be the server root, without /api/v1.'
        );
      case ApiErrorKind.methodNotAllowed:
        return ('The server does not allow this request.', null);
      case ApiErrorKind.tooManyRequests:
        final wait = retryAfter == null ? 'a few minutes' : waitText(retryAfter);
        if (retryAfter != null && retryAfter <= maxAutomaticRetryAfter) {
          return (
            'The Analytics API is limiting how fast requests can be made.',
            'Wait $wait and try again. If it keeps happening, choose a '
                'shorter date range or fewer rooms.'
          );
        }
        return (
          'Too many requests or failed sign-in attempts.',
          'Wait $wait and try again. Repeated wrong tokens temporarily block your address.'
        );
      case ApiErrorKind.internal:
        return (
          'The Analytics API had an internal error.',
          'Try again later. If it keeps happening, ask the administrator to check the analytics-api logs.'
        );
      case ApiErrorKind.unavailable:
        return (
          'The Analytics API is temporarily unavailable.',
          'The database may be restarting or under maintenance. Try again in a few minutes.'
        );
      default:
        return ('The Analytics API returned an unexpected response.', null);
    }
  }

  /// `1 second`, `30 seconds`, `1 minute`, `15 minutes` (rounded up).
  static String waitText(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    if (s < 60) return s == 1 ? '1 second' : '$s seconds';
    final m = (s + 59) ~/ 60;
    return m == 1 ? '1 minute' : '$m minutes';
  }

  static ApiException _invalid(String why) => ApiException(
        ApiErrorKind.invalidResponse,
        'The server sent data the app could not read ($why).',
        suggestion:
            'Check that the address points to the AV System Metrics Analytics API.',
      );

  static Map<String, Object?> _map(Object? v) {
    if (v == null) return const {};
    if (v is! Map) throw _invalid('expected an object');
    return v.cast<String, Object?>();
  }

  static List<Object?> _list(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v is! List) throw _invalid('missing "$key" list');
    return v;
  }

  static String _string(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v is! String) throw _invalid('missing "$key"');
    return v;
  }

  static int _int(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v is! num) throw _invalid('missing "$key"');
    return v.toInt();
  }

  static DateTime _time(Map<String, Object?> j, String key) {
    final t = _timeOrNull(j, key);
    if (t == null) throw _invalid('missing "$key"');
    return t;
  }

  static DateTime? _timeOrNull(Map<String, Object?> j, String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is! String) throw _invalid('"$key" is not a timestamp');
    final t = parseTimestamp(v);
    if (t == null) throw _invalid('"$key" is not a timestamp');
    return t;
  }
}

/// One parsed `/api/v1/heartbeats` response.
class _HeartbeatPage {
  const _HeartbeatPage(this.buckets, this.truncated);
  final List<HeartbeatBucket> buckets;
  final bool truncated;
}

/// Internal marker: the abort trigger fired before a response arrived.
class _Aborted implements Exception {
  const _Aborted();
}
