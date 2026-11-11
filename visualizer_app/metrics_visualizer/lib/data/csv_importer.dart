// Imports `metric_events` exports (CSV, TSV or psql aligned text) into a
// [Dataset].
//
// Pure Dart (no Flutter imports) so parsing can run inside an isolate. Use
// [importCsvInBackground] from UI code; it hands the work to a background
// isolate on native platforms (on the web it runs inline).
//
// Performance notes: rows are scanned line by line without building an
// intermediate list of all rows, repeated strings (client, metric, action)
// are interned, and heartbeats (the vast majority of rows) are folded straight
// into per-client hourly counters. The cost is linear in the input size.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;

import 'models.dart';
import 'timestamp_parser.dart';

/// Thrown when a file cannot be imported at all. [message] says what went
/// wrong and [suggestion] how to fix it; both are safe to show to users.
class CsvImportException implements Exception {
  const CsvImportException(this.message, {this.suggestion});

  final String message;
  final String? suggestion;

  @override
  String toString() =>
      suggestion == null ? message : '$message $suggestion';
}

/// The psql command users can run on the server to produce a compatible
/// export of the last 90 days. Shown in the data source screen and docs.
const String recommendedExportCommand =
    r'''docker compose exec -T postgres psql -U metrics_user -d metrics -c "\copy (SELECT clientname, event_timestamp, metric, action, event_id, received_at FROM metric_events WHERE event_timestamp >= now() - interval '90 days' ORDER BY event_timestamp) TO STDOUT WITH (FORMAT csv, HEADER)" > avsm_export.csv''';

/// Columns the importer understands, with accepted header spellings
/// (compared case-insensitively, ignoring surrounding spaces and quotes).
const Map<String, List<String>> importColumnAliases = {
  'clientname': ['clientname', 'client_name', 'client', 'room'],
  'timestamp': ['event_timestamp', 'timestamp', 'event_time', 'time'],
  'metric': ['metric'],
  'action': ['action'],
  'event_id': ['event_id', 'eventid', 'uuid'],
  'received_at': ['received_at', 'receivedat'],
};

/// Decodes raw file bytes, honouring UTF-8 and UTF-16 byte order marks
/// (Windows PowerShell 5 redirection writes UTF-16LE). Invalid UTF-8
/// sequences are replaced rather than failing the whole import.
String decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true);
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final littleEndian = bytes[0] == 0xFF;
    final units = Uint16List((bytes.length - 2) ~/ 2);
    for (var i = 0, b = 2; i < units.length; i++, b += 2) {
      units[i] = littleEndian
          ? bytes[b] | (bytes[b + 1] << 8)
          : (bytes[b] << 8) | bytes[b + 1];
    }
    return String.fromCharCodes(units);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Parses an export already loaded into memory. Throws [CsvImportException]
/// when the file is empty, has no recognisable header or no usable rows.
Dataset importCsvBytes(Uint8List bytes, {required String sourceName}) =>
    importCsvString(decodeTextBytes(bytes), sourceName: sourceName);

/// Parses export text. See [importCsvBytes].
Dataset importCsvString(String text, {required String sourceName}) =>
    _Importer(text, sourceName).run();

/// Runs [importCsvBytes] off the UI thread.
Future<Dataset> importCsvInBackground(Uint8List bytes,
        {required String sourceName}) =>
    compute(_importEntry, _ImportJob(bytes, sourceName),
        debugLabel: 'csv-import');

class _ImportJob {
  const _ImportJob(this.bytes, this.sourceName);
  final Uint8List bytes;
  final String sourceName;
}

Dataset _importEntry(_ImportJob job) =>
    importCsvBytes(job.bytes, sourceName: job.sourceName);

enum _Format { csv, psqlAligned }

class _Importer {
  _Importer(this.text, this.sourceName);

  final String text;
  final String sourceName;

  int _pos = 0;
  final Map<String, String> _intern = {};
  final List<MetricEvent> _events = [];
  // client -> (hour index since epoch -> count)
  final Map<String, Map<int, int>> _heartbeats = {};
  int _skipped = 0;
  bool _dayFirst = false;
  final List<String> _warnings = [];
  // Nullable instead of int64 sentinels: dart2js cannot represent
  // 0x7FFFFFFFFFFFFFFF, and the web build must compile.
  int? _minMicros;
  int? _maxMicros;

  late _Format _format;
  late String _delimiter;
  late int _clientCol, _tsCol, _metricCol, _actionCol, _idCol, _receivedCol;
  late int _columnCount;

  static const int _microsPerHour = Duration.microsecondsPerHour;
  static final RegExp _ruleLine = RegExp(r'^[\s\-+|]+$');
  static final RegExp _footerLine = RegExp(r'^\(\d+ rows?\)$');

  String _i(String s) => _intern.putIfAbsent(s, () => s);

  Dataset run() {
    if (text.trim().isEmpty) {
      throw const CsvImportException('The file is empty.',
          suggestion: 'Export the metric_events table again and choose the new file.');
    }
    final header = _nextLogicalLine();
    if (header == null) {
      throw const CsvImportException('The file is empty.');
    }
    _detectFormat(header);
    final headerFields = _format == _Format.psqlAligned
        ? _splitAligned(header)
        : _splitCsvLine(header) ?? const <String>[];
    _mapColumns(headerFields);

    _detectSlashDateOrder();
    _forEachRow(_addRow, countUnreadable: true);

    if (_events.isEmpty && _heartbeats.isEmpty) {
      if (_skipped > 0) {
        throw CsvImportException(
            'None of the $_skipped data rows could be read.',
            suggestion:
                'Check that the timestamp column contains values such as '
                '2026-11-11 00:22:09+00 and that the file was not edited in '
                'a spreadsheet that changed the dates.');
      }
      throw const CsvImportException(
          'The file has column headers but no data rows.',
          suggestion: 'Widen the date range of the export and try again.');
    }

    final heartbeats = <HeartbeatBucket>[];
    final clients = _heartbeats.keys.toList()..sort();
    for (final client in clients) {
      final hours = _heartbeats[client]!;
      final keys = hours.keys.toList()..sort();
      for (final k in keys) {
        heartbeats.add(HeartbeatBucket(
          clientName: client,
          hourStart: DateTime.fromMicrosecondsSinceEpoch(k * _microsPerHour,
              isUtc: true),
          count: hours[k]!,
        ));
      }
    }

    // Cover whole UTC hours so heartbeat buckets fall inside the range.
    // At least one row was read (checked above), so both bounds are set.
    final startHour = _floorDiv(_minMicros!, _microsPerHour);
    final endHour = _floorDiv(_maxMicros!, _microsPerHour) + 1;
    return Dataset(
      events: _events,
      heartbeats: heartbeats,
      rangeStart: DateTime.fromMicrosecondsSinceEpoch(startHour * _microsPerHour,
          isUtc: true),
      rangeEnd: DateTime.fromMicrosecondsSinceEpoch(endHour * _microsPerHour,
          isUtc: true),
      origin: DatasetOrigin.csv,
      description: sourceName,
      skippedRows: _skipped,
      warnings: _warnings,
    );
  }

  /// When the timestamps are spreadsheet-style `N/N/YYYY` dates, scans the
  /// whole file once to decide between month-first and day-first, and
  /// records a warning when the order cannot be confirmed.
  void _detectSlashDateOrder() {
    final start = _pos;
    // Only files whose first data row has a slash date need the extra pass.
    var firstIsSlash = false;
    var checked = false;
    _forEachRow((f) {
      if (checked || f.length != _columnCount) return;
      checked = true;
      final order = SlashDateOrder()..add(f[_tsCol]);
      firstIsSlash = order.hasSlashDates;
    }, stopAfterFirst: true);
    _pos = start;
    if (!firstIsSlash) return;
    final order = SlashDateOrder();
    _forEachRow((f) {
      if (f.length != _columnCount) return;
      order.add(f[_tsCol]);
      if (_receivedCol >= 0) order.add(f[_receivedCol]);
    });
    _pos = start;
    _dayFirst = order.dayFirst;
    if (order.dayFirst) {
      _warnings.add(
          'Dates in this file are written day first (DD/MM/YYYY), as saved by '
          'a spreadsheet, and were read that way. Times were treated as UTC.');
    } else if (order.ambiguous) {
      _warnings.add(
          'Dates in this file are written as NN/NN/YYYY (re-saved by a '
          'spreadsheet) and no day is above 12, so the order could not be '
          'confirmed. They were read month first (MM/DD/YYYY) and as UTC. If '
          'the file uses day-first dates, export it again with the psql '
          'command instead of re-saving it in a spreadsheet.');
    }
  }

  static int _floorDiv(int a, int b) {
    final q = a ~/ b;
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
  }

  /// Next physical line without its terminator, or null at end of input.
  /// Handles LF, CRLF and lone CR line endings.
  String? _nextLine() {
    if (_pos >= text.length) return null;
    final start = _pos;
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    var line = text.substring(start, end);
    _pos = end + 1;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final cr = line.indexOf('\r');
    if (cr >= 0) {
      line = line.substring(0, cr);
      _pos = start + cr + 1;
    }
    return line;
  }

  /// First non-blank line (for the header).
  String? _nextLogicalLine() {
    String? line;
    do {
      line = _nextLine();
      if (line == null) return null;
      if (line.startsWith('﻿')) line = line.substring(1);
    } while (line.trim().isEmpty);
    return line;
  }

  void _detectFormat(String header) {
    final savedPos = _pos;
    if (header.contains('|')) {
      final rule = _nextLine();
      if (rule != null && rule.contains('-') && _ruleLine.hasMatch(rule)) {
        _format = _Format.psqlAligned;
        _delimiter = '|';
        return; // rule line consumed
      }
      _pos = savedPos;
    }
    _format = _Format.csv;
    final counts = {
      ',': ','.allMatches(header).length,
      ';': ';'.allMatches(header).length,
      '\t': '\t'.allMatches(header).length,
      '|': '|'.allMatches(header).length,
    };
    var best = ',';
    var bestCount = 0;
    counts.forEach((d, c) {
      if (c > bestCount) {
        best = d;
        bestCount = c;
      }
    });
    _delimiter = best;
  }

  void _mapColumns(List<String> fields) {
    final normalized = [
      for (final f in fields)
        f.trim().replaceAll('"', '').replaceAll('﻿', '').toLowerCase()
    ];
    int find(String key) {
      for (final alias in importColumnAliases[key]!) {
        final idx = normalized.indexOf(alias);
        if (idx >= 0) return idx;
      }
      return -1;
    }

    _clientCol = find('clientname');
    _tsCol = find('timestamp');
    _metricCol = find('metric');
    _actionCol = find('action');
    _idCol = find('event_id');
    _receivedCol = find('received_at');
    _columnCount = normalized.length;

    final missing = <String>[
      if (_clientCol < 0) 'clientname',
      if (_tsCol < 0) 'event_timestamp',
      if (_metricCol < 0) 'metric',
      if (_actionCol < 0) 'action',
    ];
    if (missing.isNotEmpty) {
      final shown = normalized.where((c) => c.isNotEmpty).take(12).join(', ');
      throw CsvImportException(
        'The file is missing the required column${missing.length == 1 ? '' : 's'} '
        '${missing.join(', ')}. Columns found: ${shown.isEmpty ? 'none' : shown}.',
        suggestion:
            'Export with a header row that includes clientname, '
            'event_timestamp, metric and action (see the export instructions).',
      );
    }
  }

  /// Reads data rows from the current position and passes their fields to
  /// [onRow]. Blank lines and the psql `(N rows)` footer (also written by
  /// `psql -A`, which is read as `|`-separated CSV) are skipped.
  void _forEachRow(
    void Function(List<String> fields) onRow, {
    bool countUnreadable = false,
    bool stopAfterFirst = false,
  }) {
    while (true) {
      final line = _nextLine();
      if (line == null) break;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (_footerLine.hasMatch(trimmed)) continue;
      if (_format == _Format.psqlAligned) {
        onRow(_splitAligned(line));
      } else {
        final fields =
            line.contains('"') ? _splitQuoted(line) : line.split(_delimiter);
        if (fields == null) {
          if (countUnreadable) _skipped++;
          continue;
        }
        onRow(fields);
      }
      if (stopAfterFirst) break;
    }
  }

  List<String> _splitAligned(String line) =>
      [for (final f in line.split('|')) f.trim()];

  /// Splits a header line. Returns null if quotes are unbalanced.
  List<String>? _splitCsvLine(String line) =>
      line.contains('"') ? _splitQuoted(line) : line.split(_delimiter);

  /// RFC 4180 field splitting for a line containing quotes. A quoted field
  /// may contain delimiters, doubled quotes and line breaks (in which case
  /// following physical lines are consumed). Returns null when the closing
  /// quote never arrives.
  List<String>? _splitQuoted(String firstLine) {
    final fields = <String>[];
    final sb = StringBuffer();
    var line = firstLine;
    var i = 0;
    var inQuotes = false;
    final delim = _delimiter.codeUnitAt(0);
    while (true) {
      if (i >= line.length) {
        if (inQuotes) {
          final next = _nextLine();
          if (next == null) return null;
          sb.write('\n');
          line = next;
          i = 0;
          continue;
        }
        fields.add(sb.toString());
        return fields;
      }
      final c = line.codeUnitAt(i);
      if (inQuotes) {
        if (c == _quoteChar) {
          if (i + 1 < line.length && line.codeUnitAt(i + 1) == _quoteChar) {
            sb.writeCharCode(_quoteChar);
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        sb.writeCharCode(c);
        i++;
      } else {
        if (c == _quoteChar) {
          inQuotes = true;
        } else if (c == delim) {
          fields.add(sb.toString());
          sb.clear();
        } else {
          sb.writeCharCode(c);
        }
        i++;
      }
    }
  }

  static const int _quoteChar = 0x22;

  void _addRow(List<String> f) {
    final n = f.length;
    // A different field count means an unquoted delimiter or a truncated
    // line; the columns cannot be trusted, so the row is skipped.
    if (n != _columnCount) {
      _skipped++;
      return;
    }
    final client = f[_clientCol].trim();
    final action = f[_actionCol].trim();
    final metric = f[_metricCol].trim();
    if (client.isEmpty || action.isEmpty) {
      _skipped++;
      return;
    }
    final ts = parseTimestamp(f[_tsCol], dayFirst: _dayFirst);
    if (ts == null) {
      _skipped++;
      return;
    }
    final micros = ts.microsecondsSinceEpoch;
    if (_minMicros == null || micros < _minMicros!) _minMicros = micros;
    if (_maxMicros == null || micros > _maxMicros!) _maxMicros = micros;

    if (_isHeartbeat(action)) {
      final hours = _heartbeats.putIfAbsent(_i(client), () => <int, int>{});
      final key = _floorDiv(micros, _microsPerHour);
      hours[key] = (hours[key] ?? 0) + 1;
      return;
    }

    String? eventId;
    if (_idCol >= 0) {
      final v = f[_idCol].trim();
      if (v.isNotEmpty) eventId = v;
    }
    DateTime? received;
    if (_receivedCol >= 0) {
      final v = f[_receivedCol];
      if (v.trim().isNotEmpty) received = parseTimestamp(v, dayFirst: _dayFirst);
    }
    _events.add(MetricEvent(
      clientName: _i(client),
      timestamp: ts,
      metric: _i(metric),
      action: _i(action),
      eventId: eventId,
      receivedAt: received,
    ));
  }

  static bool _isHeartbeat(String action) =>
      action == heartbeatAction ||
      (action.length == heartbeatAction.length &&
          action.toLowerCase() == 'heartbeat');
}
