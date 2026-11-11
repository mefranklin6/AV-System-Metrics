import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:metrics_visualizer/data/api_client.dart';
import 'package:metrics_visualizer/data/models.dart';

const token = 'test-token-0123456789abcdefghijklmnopqrstuv';

http.Response jsonResponse(Object body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json; charset=utf-8', ...headers});

Map<String, Object?> event(int i, {String client = 'BSS_245', String action = 'Started'}) => {
      'id': i,
      'clientname': client,
      'event_timestamp': '2026-11-10T10:${i.toString().padLeft(2, '0')}:00.000001Z',
      'metric': 'pc',
      'action': action,
      'event_id': '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
      'received_at': '2026-11-10T10:${i.toString().padLeft(2, '0')}:05.000000Z',
    };

AnalyticsApiClient clientWith(MockClientHandler handler, {String base = 'https://avsm.example.edu:8081'}) =>
    AnalyticsApiClient(
        baseUrl: AnalyticsApiClient.parseBaseUrl(base), token: token, httpClient: MockClient(handler));

final from = DateTime.utc(2026, 11, 1);
final to = DateTime.utc(2026, 11, 11);

void main() {
  group('base URL, token and transport security helpers', () {
    test('parseBaseUrl normalises valid addresses', () {
      expect(AnalyticsApiClient.parseBaseUrl(' https://avsm.example.edu:8081/ ').toString(),
          'https://avsm.example.edu:8081');
      expect(AnalyticsApiClient.parseBaseUrl('https://av.example.edu/analytics//').toString(),
          'https://av.example.edu/analytics');
      expect(AnalyticsApiClient.parseBaseUrl('http://127.0.0.1:8081').port, 8081);
    });

    test('parseBaseUrl rejects unusable input with a message', () {
      for (final bad in [
        '',
        'avsm.example.edu',
        'ftp://avsm.example.edu',
        'https://user:pw@avsm.example.edu',
        'https://avsm.example.edu/?token=x',
        'https://avsm.example.edu/#x',
      ]) {
        expect(() => AnalyticsApiClient.parseBaseUrl(bad), throwsFormatException, reason: bad);
      }
    });

    test('isInsecure flags plain http except loopback', () {
      bool insecure(String u) => AnalyticsApiClient.isInsecure(Uri.parse(u));
      expect(insecure('http://10.1.2.3:8081'), isTrue);
      expect(insecure('http://avsm.example.edu'), isTrue);
      expect(insecure('https://avsm.example.edu'), isFalse);
      expect(insecure('http://localhost:8081'), isFalse);
      expect(insecure('http://127.0.0.1:8081'), isFalse);
      expect(insecure('http://[::1]:8081'), isFalse);
      expect(insecure('http://127.5.6.7'), isFalse);
      expect(insecure('http://[0:0:0:0:0:0:0:1]'), isFalse);
    });

    test('isInsecure treats look-alike host names as remote', () {
      bool insecure(String u) => AnalyticsApiClient.isInsecure(Uri.parse(u));
      expect(insecure('http://127.0.0.1.example.org'), isTrue);
      expect(insecure('http://127.reports.example.edu'), isTrue);
      expect(insecure('http://127.0.0.256'), isTrue);
      expect(insecure('http://0127.0.0.1'), isTrue);
      expect(insecure('http://localhost.example.edu'), isTrue);
      expect(insecure('http://[::2]'), isTrue);
    });

    test('validateToken blocks header injection and blanks', () {
      expect(AnalyticsApiClient.validateToken(token), isNull);
      expect(AnalyticsApiClient.validateToken(''), isNotNull);
      expect(AnalyticsApiClient.validateToken('abc def'), isNotNull);
      expect(AnalyticsApiClient.validateToken('abc\r\nX-Evil: 1'), isNotNull);
      expect(AnalyticsApiClient.validateToken('tökén'), isNotNull);
      expect(() => AnalyticsApiClient(baseUrl: Uri.parse('https://x'), token: 'a b'), throwsArgumentError);
    });

    test('validateToken follows the server token rules', () {
      final other = 'Z' * 40;
      expect(AnalyticsApiClient.validateToken('$token,$other'), contains('only one token'));
      expect(AnalyticsApiClient.validateToken('a' * 513), contains('too long'));
      expect(AnalyticsApiClient.validateToken('a' * 512), isNull);
      expect(AnalyticsApiClient.validateToken('a' * 31), contains('too short'));
      expect(AnalyticsApiClient.validateToken('${'a' * 32}\$'), isNotNull);
      expect(AnalyticsApiClient.validateToken('aZ09._~+/=-${'b' * 30}'), isNull);
    });

    test('network suggestion hints at https on the web only for http', () {
      final plain = Uri.parse('http://avsm.example.edu');
      final secure = Uri.parse('https://avsm.example.edu');
      expect(AnalyticsApiClient.networkSuggestion(plain, isWeb: true), contains('https://'));
      expect(AnalyticsApiClient.networkSuggestion(plain, isWeb: true), contains('ANALYTICS_CORS_ORIGINS'));
      expect(AnalyticsApiClient.networkSuggestion(secure, isWeb: true), isNot(contains('enter the https')));
      expect(AnalyticsApiClient.networkSuggestion(plain, isWeb: false), isNot(contains('CORS')));
    });

    test('client groups respect both the name count and the URL size', () {
      final short = {for (var i = 0; i < 450; i++) 'R_${i.toString().padLeft(3, '0')}'};
      expect(AnalyticsApiClient.clientGroups(short).map((g) => g.length), [200, 200, 50]);
      final long = {for (var i = 0; i < 200; i++) '${'Room ü ' * 8}$i'};
      final groups = AnalyticsApiClient.clientGroups(long);
      expect(groups.length, greaterThan(1));
      expect(groups.expand((g) => g).toSet(), long);
      for (final g in groups) {
        final bytes = g.fold<int>(0, (a, n) => a + 8 + Uri.encodeQueryComponent(n).length);
        expect(bytes, lessThanOrEqualTo(AnalyticsApiClient.maxQueryBytes));
      }
      expect(AnalyticsApiClient.clientGroups(null), [<String>[]]);
    });

    test('splitRange makes contiguous chunks no longer than the limit', () {
      final chunks = AnalyticsApiClient.splitRange(
          DateTime.utc(2026, 1, 1), DateTime.utc(2026, 7, 20), const Duration(days: 92));
      expect(chunks, hasLength(3));
      expect(chunks.first.$1, DateTime.utc(2026, 1, 1));
      expect(chunks.last.$2, DateTime.utc(2026, 7, 20));
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].$2.difference(chunks[i].$1) <= const Duration(days: 92), isTrue);
        if (i > 0) expect(chunks[i].$1, chunks[i - 1].$2);
      }
    });
  });

  group('requests', () {
    test('info: bearer header, never a token in the URL, nulls handled', () async {
      late http.BaseRequest seen;
      final api = clientWith((req) async {
        seen = req;
        return jsonResponse({
          'api_version': '1',
          'server_time': '2026-11-11T00:22:09.709041Z',
          'activity_range': {'first_event': '2026-09-01T00:00:00.000000Z', 'last_event': null},
          'heartbeat_purge': {
            'enabled_status': 'succeeded',
            'retention_days': 30,
            'cutoff': null,
            'finished_at': '2026-11-11T00:00:00.000000Z'
          },
        });
      });
      final info = await api.info();
      expect(seen.url.toString(), 'https://avsm.example.edu:8081/api/v1/info');
      expect(seen.headers['Authorization'], 'Bearer $token');
      expect(seen.url.toString(), isNot(contains(token)));
      expect(info.apiVersion, '1');
      expect(info.serverTime, DateTime.utc(2026, 11, 11, 0, 22, 9, 709, 41));
      expect(info.firstEvent, DateTime.utc(2026, 9, 1));
      expect(info.lastEvent, isNull);
      expect(info.retentionDays, 30);
      expect(info.purgeStatus, 'succeeded');
      expect(info.purgeCutoff, isNull);
    });

    test('path prefix behind a reverse proxy is kept', () async {
      late Uri seen;
      final api = clientWith((req) async {
        seen = req.url;
        return jsonResponse({'from': '2026-11-01T00:00:00.000000Z', 'to': '2026-11-11T00:00:00.000000Z', 'clients': []});
      }, base: 'https://av.example.edu/analytics');
      await api.clients(from: from, to: to);
      expect(seen.path, '/analytics/api/v1/clients');
      expect(seen.queryParameters['from'], '2026-11-01T00:00:00.000000Z');
      expect(seen.queryParameters['to'], '2026-11-11T00:00:00.000000Z');
    });

    test('clients are parsed', () async {
      final api = clientWith((req) async => jsonResponse({
            'from': '2026-11-01T00:00:00.000000Z',
            'to': '2026-11-11T00:00:00.000000Z',
            'clients': [
              {
                'clientname': 'BSS_245',
                'event_count': 12,
                'heartbeat_count': 400,
                'first_event': '2026-11-02T00:00:00.000000Z',
                'last_event': '2026-11-03T00:00:00.000000Z',
                'last_heartbeat': '2026-11-10T23:59:00.000000Z'
              },
              {
                'clientname': 'HOLT_155',
                'event_count': 0,
                'heartbeat_count': 5,
                'first_event': null,
                'last_event': null,
                'last_heartbeat': null
              },
            ]
          }));
      final clients = await api.clients(from: from, to: to);
      expect(clients.map((c) => c.clientName), ['BSS_245', 'HOLT_155']);
      expect(clients.first.heartbeatCount, 400);
      expect(clients.last.firstEvent, isNull);
    });

    test('health is unauthenticated and maps 503 to false', () async {
      var authSeen = false;
      final ok = clientWith((req) async {
        authSeen = req.headers.containsKey('Authorization');
        return jsonResponse({'ok': true});
      });
      expect(await ok.health(), isTrue);
      expect(authSeen, isFalse);
      final down = clientWith((req) async => jsonResponse({'ok': false}, status: 503));
      expect(await down.health(), isFalse);
    });
  });

  group('event pagination', () {
    test('follows next_cursor, sends filters and reports progress', () async {
      final requests = <Uri>[];
      final api = clientWith((req) async {
        requests.add(req.url);
        final cursor = req.url.queryParameters['cursor'];
        return switch (cursor) {
          null => jsonResponse({
              'from': 'x',
              'to': 'y',
              'events': [event(1), event(2)],
              'next_cursor': 'c1'
            }),
          'c1' => jsonResponse({
              'events': [event(3), event(4, action: 'Heartbeat')],
              'next_cursor': 'c2'
            }),
          'c2' => jsonResponse({
              'events': [event(5)],
              'next_cursor': null
            }),
          _ => jsonResponse({'error': {'code': 'bad_request', 'message': 'bad cursor'}}, status: 400),
        };
      });
      final progress = <ApiProgress>[];
      final events = await api.fetchAllEvents(
        from: from,
        to: to,
        clients: {'HOLT_155', 'BSS_245'},
        pageSize: 2,
        onProgress: progress.add,
      );
      expect(requests, hasLength(3));
      expect(requests.first.queryParametersAll['client'], ['BSS_245', 'HOLT_155']);
      expect(requests.first.queryParameters['limit'], '2');
      expect(requests.first.queryParameters.containsKey('cursor'), isFalse);
      expect(requests[1].queryParameters['cursor'], 'c1');
      expect(events.map((e) => e.metric), everyElement('pc'));
      expect(events, hasLength(4), reason: 'a heartbeat row is never kept as an event');
      expect(events.first.eventId, '00000000-0000-4000-8000-000000000001');
      expect(events.first.receivedAt, DateTime.utc(2026, 11, 10, 10, 1, 5));
      expect(progress.last.fraction, 1.0);
      expect(progress.last.eventsLoaded, 4);
      expect(progress.map((p) => p.fraction!), orderedEquals([...progress.map((p) => p.fraction!)]..sort()));
    });

    test('page size is clamped to the server maximum', () async {
      late Uri seen;
      final api = clientWith((req) async {
        seen = req.url;
        return jsonResponse({'events': [], 'next_cursor': null});
      });
      await api.fetchAllEvents(from: from, to: to, pageSize: 999999);
      expect(seen.queryParameters['limit'], '5000');
    });

    test('more than 200 clients are split into several requests', () async {
      final groups = <List<String>>[];
      final api = clientWith((req) async {
        groups.add(req.url.queryParametersAll['client']!);
        return jsonResponse({'events': [], 'next_cursor': null});
      });
      final clients = {for (var i = 0; i < 450; i++) 'R_${i.toString().padLeft(3, '0')}'};
      await api.fetchAllEvents(from: from, to: to, clients: clients);
      expect(groups.map((g) => g.length), [200, 200, 50]);
      expect(groups.expand((g) => g).toSet(), clients);
    });

    test('a repeated cursor is rejected instead of looping forever', () async {
      final api = clientWith((req) async => jsonResponse({'events': [event(1)], 'next_cursor': 'same'}));
      await expectLater(api.fetchAllEvents(from: from, to: to),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.invalidResponse)));
    });

    test('cancellation stops between pages', () async {
      final cancel = CancellationToken();
      var calls = 0;
      final api = clientWith((req) async {
        calls++;
        cancel.cancel();
        return jsonResponse({'events': [event(calls)], 'next_cursor': 'c$calls'});
      });
      await expectLater(api.fetchAllEvents(from: from, to: to, cancel: cancel),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.cancelled)));
      expect(calls, 1);
    });

    test('a short rate limit is waited out and the download continues', () async {
      final waits = <Duration>[];
      var calls = 0;
      final api = AnalyticsApiClient(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        sleep: (d) async => waits.add(d),
        httpClient: MockClient((req) async {
          calls++;
          if (calls == 2) {
            return jsonResponse({'error': {'code': 'too_many_requests', 'message': 'slow'}},
                status: 429, headers: {'retry-after': '1'});
          }
          final cursor = req.url.queryParameters['cursor'];
          return cursor == null
              ? jsonResponse({'events': [event(1)], 'next_cursor': 'c1'})
              : jsonResponse({'events': [event(2)], 'next_cursor': null});
        }),
      );
      final events = await api.fetchAllEvents(from: from, to: to);
      expect(events, hasLength(2));
      expect(waits, [const Duration(seconds: 1)]);
      expect(calls, 3);
    });

    test('rate limits give up after a few retries with a clear message', () async {
      var calls = 0;
      final api = AnalyticsApiClient(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        sleep: (d) async {},
        httpClient: MockClient((req) async {
          calls++;
          return jsonResponse({'error': {'code': 'too_many_requests', 'message': 'slow'}},
              status: 429, headers: {'retry-after': '1'});
        }),
      );
      final e = await api.fetchAllEvents(from: from, to: to).then<ApiException?>((_) => null,
          onError: (Object e) => e as ApiException);
      expect(e!.kind, ApiErrorKind.tooManyRequests);
      expect(calls, 1 + AnalyticsApiClient.maxRateLimitRetries);
      expect(e.message, isNot(contains('sign-in')));
      expect(e.suggestion, contains('1 second '));
    });

    test('a sign-in lockout is not retried', () async {
      var calls = 0;
      final api = AnalyticsApiClient(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        sleep: (d) async => fail('must not wait for a lockout'),
        httpClient: MockClient((req) async {
          calls++;
          return jsonResponse({'error': {'code': 'too_many_requests', 'message': 'locked'}},
              status: 429, headers: {'retry-after': '899'});
        }),
      );
      await expectLater(api.info(),
          throwsA(isA<ApiException>().having((e) => e.suggestion, 'suggestion', contains('15 minutes'))));
      expect(calls, 1);
    });

    test('cancel aborts a request in flight', () async {
      final cancel = CancellationToken();
      final api = clientWith((req) {
        // The server never answers.
        scheduleMicrotask(cancel.cancel);
        return Completer<http.Response>().future;
      });
      await expectLater(api.fetchAllEvents(from: from, to: to, cancel: cancel),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.cancelled)));
    });

    test('a 414 splits the client list and retries', () async {
      final groups = <List<String>>[];
      final api = clientWith((req) async {
        final names = req.url.queryParametersAll['client']!;
        if (names.length > 2) return http.Response('URI Too Long', 414);
        groups.add(names);
        return jsonResponse({'events': [event(groups.length, client: names.first)], 'next_cursor': null});
      });
      final events = await api.fetchAllEvents(from: from, to: to, clients: {'A_1', 'A_2', 'A_3', 'A_4', 'A_5'});
      expect(groups.expand((g) => g).toList(), ['A_1', 'A_2', 'A_3', 'A_4', 'A_5']);
      expect(groups.every((g) => g.length <= 2), isTrue);
      expect(events, hasLength(groups.length));
    });

    test('a 431 for a single client is reported with a suggestion', () async {
      final api = clientWith((req) async => http.Response('Request Header Fields Too Large', 431));
      await expectLater(
          api.fetchAllEvents(from: from, to: to, clients: {'A_1'}),
          throwsA(isA<ApiException>()
              .having((e) => e.message, 'message', contains('too long'))
              .having((e) => e.suggestion, 'suggestion', contains('fewer rooms'))));
    });

    test('downloads stop at the event limit', () async {
      var page = 0;
      final api = AnalyticsApiClient(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        maxEvents: 3,
        httpClient: MockClient((req) async {
          page++;
          return jsonResponse({'events': [event(page * 2), event(page * 2 + 1)], 'next_cursor': 'c$page'});
        }),
      );
      await expectLater(api.fetchAllEvents(from: from, to: to),
          throwsA(isA<ApiException>().having((e) => e.suggestion, 'suggestion', contains('shorter'))));
      expect(page, 2);
    });

    test('estimateEventCount sums the selected rooms', () async {
      final api = clientWith((req) async => jsonResponse({
            'clients': [
              {'clientname': 'A_1', 'event_count': 10, 'heartbeat_count': 1},
              {'clientname': 'A_2', 'event_count': 5, 'heartbeat_count': 1},
            ]
          }));
      expect(await api.estimateEventCount(from: from, to: to), 15);
      expect(await api.estimateEventCount(from: from, to: to, clients: {'A_2'}), 5);
    });

    test('invalid ranges are rejected before any request', () async {
      final api = clientWith((req) async => fail('no request expected'));
      expect(() => api.fetchAllEvents(from: to, to: from), throwsArgumentError);
      expect(() => api.fetchAllEvents(from: DateTime.utc(2024), to: DateTime.utc(2026)), throwsArgumentError);
    });
  });

  group('heartbeats', () {
    test('long ranges are split into <= 92 day hourly requests', () async {
      final spans = <Duration>[];
      final api = clientWith((req) async {
        final q = req.url.queryParameters;
        expect(q['bucket'], 'hour');
        final f = DateTime.parse(q['from']!), t = DateTime.parse(q['to']!);
        spans.add(t.difference(f));
        return jsonResponse({
          'bucket': 'hour',
          'truncated': false,
          'series': [
            {
              'clientname': 'BSS_245',
              'buckets': [
                {'start': q['from'], 'count': 60}
              ]
            }
          ]
        });
      });
      final progress = <double>[];
      final buckets = await api.fetchHourlyHeartbeats(
        from: DateTime.utc(2026, 1, 1),
        to: DateTime.utc(2026, 7, 20),
        onProgress: (p) => progress.add(p.fraction!),
      );
      expect(spans, hasLength(3));
      expect(spans.every((s) => s <= const Duration(days: 92)), isTrue);
      expect(buckets, hasLength(3));
      expect(buckets.first.hourStart, DateTime.utc(2026, 1, 1));
      expect(buckets.first.count, 60);
      expect(progress.last, 1.0);
    });

    Map<String, Object?> series(String client, List<String> starts) => {
          'clientname': client,
          'buckets': [for (final s in starts) {'start': s, 'count': 12}]
        };

    Map<String, Object?> clientRow(String name) =>
        {'clientname': name, 'event_count': 1, 'heartbeat_count': 100};

    test('a response without "truncated" is rejected', () async {
      final api = clientWith((req) async => jsonResponse({'series': []}));
      await expectLater(api.fetchHourlyHeartbeats(from: from, to: to),
          throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.invalidResponse)));
    });

    test('truncated "all rooms" is re-requested by room list; partial data is dropped', () async {
      final requests = <Uri>[];
      final api = clientWith((req) async {
        requests.add(req.url);
        if (req.url.pathSegments.last == 'clients') {
          return jsonResponse({'clients': [clientRow('A_1'), clientRow('B_2'), clientRow('C_3')]});
        }
        final names = req.url.queryParametersAll['client'];
        if (names == null) {
          // The partial answer must never be kept.
          return jsonResponse({'truncated': true, 'series': [series('PARTIAL', ['2026-11-01T00:00:00.000000Z'])]});
        }
        return jsonResponse({
          'truncated': false,
          'series': [for (final n in names) series(n, ['2026-11-02T00:00:00.000000Z'])]
        });
      });
      final buckets = await api.fetchHourlyHeartbeats(from: from, to: to);
      expect(buckets.map((b) => b.clientName), ['A_1', 'B_2', 'C_3']);
      expect(requests.map((u) => u.pathSegments.last), ['heartbeats', 'clients', 'heartbeats']);
      expect(requests[1].queryParameters['from'], '2026-11-01T00:00:00.000000Z');
      expect(requests[1].queryParameters['to'], '2026-11-11T00:00:00.000000Z');
    });

    test('a truncated room group is halved until each part is complete', () async {
      final sizes = <int>[];
      final api = clientWith((req) async {
        final names = req.url.queryParametersAll['client']!;
        sizes.add(names.length);
        return jsonResponse({
          'truncated': names.length > 2,
          'series': [for (final n in names) series(n, ['2026-11-02T00:00:00.000000Z'])]
        });
      });
      final clients = {'A_1', 'A_2', 'A_3', 'A_4', 'A_5'};
      final buckets = await api.fetchHourlyHeartbeats(from: from, to: to, clients: clients);
      expect(sizes.first, 5);
      expect(buckets.map((b) => b.clientName).toSet(), clients);
      expect(buckets, hasLength(5), reason: 'no bucket from a truncated answer');
    });

    test('a single truncated room is split into time halves on hour boundaries', () async {
      final ranges = <(DateTime, DateTime)>[];
      final api = clientWith((req) async {
        final q = req.url.queryParameters;
        final f = DateTime.parse(q['from']!), t = DateTime.parse(q['to']!);
        ranges.add((f, t));
        final truncated = t.difference(f) > const Duration(days: 3);
        return jsonResponse({
          'truncated': truncated,
          'series': [series('A_1', [q['from']!])]
        });
      });
      final buckets = await api.fetchHourlyHeartbeats(from: from, to: to, clients: {'A_1'});
      final complete = ranges.where((r) => r.$2.difference(r.$1) <= const Duration(days: 3)).toList()
        ..sort((a, b) => a.$1.compareTo(b.$1));
      expect(complete.first.$1, from);
      expect(complete.last.$2, to);
      for (var i = 1; i < complete.length; i++) {
        expect(complete[i].$1, complete[i - 1].$2, reason: 'contiguous, no gaps or overlaps');
        expect(complete[i].$1.minute + complete[i].$1.second + complete[i].$1.microsecond, 0);
      }
      expect(buckets, hasLength(complete.length));
    });

    test('truncation that cannot be split further is an error, not partial data', () async {
      final api = clientWith((req) async => jsonResponse({
            'truncated': true,
            'series': [series('A_1', ['2026-11-01T00:00:00.000000Z'])]
          }));
      await expectLater(
          api.fetchHourlyHeartbeats(from: from, to: from.add(const Duration(hours: 1)), clients: {'A_1'}),
          throwsA(isA<ApiException>()
              .having((e) => e.message, 'message', contains('only part'))
              .having((e) => e.suggestion, 'suggestion', contains('fewer rooms'))));
    });

    test('truncated "all rooms" with an empty room list is an error', () async {
      final api = clientWith((req) async => req.url.pathSegments.last == 'clients'
          ? jsonResponse({'clients': []})
          : jsonResponse({'truncated': true, 'series': []}));
      await expectLater(api.fetchHourlyHeartbeats(from: from, to: to),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('only part'))));
    });

    test('room groups are sized so a request cannot reach the bucket limit', () async {
      expect(AnalyticsApiClient.heartbeatRoomsPerRequest(from, from.add(const Duration(days: 92))),
          AnalyticsApiClient.maxHeartbeatBucketsPerResponse ~/ (92 * 24 + 1));
      expect(AnalyticsApiClient.heartbeatRoomsPerRequest(from, from.add(const Duration(days: 7))),
          AnalyticsApiClient.maxClientsPerRequest);
      final sizes = <int>[];
      final api = clientWith((req) async {
        sizes.add(req.url.queryParametersAll['client']!.length);
        return jsonResponse({'truncated': false, 'series': []});
      });
      final clients = {for (var i = 0; i < 150; i++) 'R_${i.toString().padLeft(3, '0')}'};
      await api.fetchHourlyHeartbeats(from: from, to: from.add(const Duration(days: 90)), clients: clients);
      expect(sizes.every((n) => n * (90 * 24 + 1) <= AnalyticsApiClient.maxHeartbeatBucketsPerResponse), isTrue);
      expect(sizes.fold<int>(0, (a, b) => a + b), 150);
    });

    test('hour boundaries for splitting', () {
      final s = DateTime.utc(2026, 11, 1, 0, 30);
      expect(AnalyticsApiClient.hourBoundaryNear(s, DateTime.utc(2026, 11, 1, 4, 30)), DateTime.utc(2026, 11, 1, 2));
      expect(AnalyticsApiClient.hourBoundaryNear(s, DateTime.utc(2026, 11, 1, 1, 10)), DateTime.utc(2026, 11, 1, 1));
      expect(AnalyticsApiClient.hourBoundaryNear(DateTime.utc(2026, 11, 1), DateTime.utc(2026, 11, 1, 1)), isNull);
      expect(AnalyticsApiClient.hourBoundaryNear(s, DateTime.utc(2026, 11, 1, 0, 59)), isNull);
    });
  });

  test('loadDataset combines info, events and heartbeats', () async {
    final api = clientWith((req) async {
      switch (req.url.pathSegments.last) {
        case 'info':
          return jsonResponse({
            'api_version': '1',
            'server_time': '2026-11-11T00:00:00.000000Z',
            'activity_range': {'first_event': null, 'last_event': null},
            'heartbeat_purge': {'enabled_status': null, 'retention_days': 21, 'cutoff': null, 'finished_at': null},
          });
        case 'events':
          return jsonResponse({'events': [event(1), event(2)], 'next_cursor': null});
        case 'heartbeats':
          return jsonResponse({
            'truncated': false,
            'series': [
              {
                'clientname': 'HOLT_155',
                'buckets': [
                  {'start': '2026-11-10T10:00:00.000000Z', 'count': 59}
                ]
              }
            ]
          });
      }
      return http.Response('', 404);
    });
    final progress = <ApiProgress>[];
    final ds = await api.loadDataset(from: from, to: to, onProgress: progress.add);
    expect(ds.origin, DatasetOrigin.api);
    expect(ds.description, 'avsm.example.edu');
    expect(ds.events, hasLength(2));
    expect(ds.heartbeats.single.count, 59);
    expect(ds.heartbeatRetentionDays, 21);
    expect(ds.rangeStart, from);
    expect(ds.rangeEnd, to);
    expect(ds.clientNames, ['BSS_245', 'HOLT_155']);
    expect(progress.last.fraction, closeTo(1.0, 1e-9));
  });

  group('error mapping', () {
    Future<ApiException> errorFor(http.Response response) async {
      final api = clientWith((req) async => response);
      try {
        await api.info();
      } on ApiException catch (e) {
        return e;
      }
      fail('expected ApiException');
    }

    Map<String, Object> err(String code, String message) => {
          'error': {'code': code, 'message': message}
        };

    test('every documented code maps to its kind with a suggestion', () async {
      final cases = {
        'bad_request': (400, ApiErrorKind.badRequest),
        'unauthorized': (401, ApiErrorKind.unauthorized),
        'forbidden': (403, ApiErrorKind.forbidden),
        'not_found': (404, ApiErrorKind.notFound),
        'method_not_allowed': (405, ApiErrorKind.methodNotAllowed),
        'too_many_requests': (429, ApiErrorKind.tooManyRequests),
        'internal': (500, ApiErrorKind.internal),
        'unavailable': (503, ApiErrorKind.unavailable),
      };
      for (final MapEntry(key: code, value: (status, kind)) in cases.entries) {
        final e = await errorFor(jsonResponse(err(code, 'msg $code'), status: status));
        expect(e.kind, kind, reason: code);
        expect(e.statusCode, status);
        expect(e.code, code);
        expect(e.message, contains('msg $code'));
        expect(e.toString(), isNot(contains(token)));
      }
    });

    test('401 asks for a token; 429 honours Retry-After', () async {
      final unauth = await errorFor(jsonResponse(err('unauthorized', 'missing'),
          status: 401, headers: {'www-authenticate': 'Bearer realm="avsm-analytics"'}));
      expect(unauth.suggestion, contains('token'));
      final limited = await errorFor(
          jsonResponse(err('too_many_requests', 'slow down'), status: 429, headers: {'retry-after': '900'}));
      expect(limited.retryAfter, const Duration(minutes: 15));
      expect(limited.suggestion, contains('15 minutes'));
    });

    test('non-JSON error pages fall back to the status code', () async {
      final e = await errorFor(http.Response('<html>Bad gateway</html>', 502));
      expect(e.kind, ApiErrorKind.unavailable);
      expect(e.message, isNot(contains('<html>')));
      final teapot = await errorFor(http.Response('nope', 418));
      expect(teapot.kind, ApiErrorKind.unknown);
    });

    test('redirects are reported, not followed', () async {
      final e = await errorFor(http.Response('', 302, headers: {'location': 'https://evil.example/'}));
      expect(e.kind, ApiErrorKind.redirect);
    });

    test('malformed bodies become invalidResponse', () async {
      expect((await errorFor(http.Response('not json', 200))).kind, ApiErrorKind.invalidResponse);
      expect((await errorFor(http.Response('[1,2]', 200))).kind, ApiErrorKind.invalidResponse);
      expect((await errorFor(jsonResponse({'api_version': 1}))).kind, ApiErrorKind.invalidResponse);
    });

    test('control characters in server messages are sanitised', () async {
      final e = await errorFor(jsonResponse(err('bad_request', 'line1\nline2\u0007'), status: 400));
      expect(e.message, isNot(contains('\n')));
      expect(e.message, isNot(contains('\u0007')));
    });

    test('network failures and timeouts', () async {
      final down = clientWith((req) async => throw http.ClientException('connection refused'));
      await expectLater(
          down.info(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.network)));

      final slow = AnalyticsApiClient(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        timeout: const Duration(milliseconds: 20),
        httpClient: MockClient((req) => Completer<http.Response>().future),
      );
      await expectLater(
          slow.info(), throwsA(isA<ApiException>().having((e) => e.kind, 'kind', ApiErrorKind.timeout)));
    });
  });
}
