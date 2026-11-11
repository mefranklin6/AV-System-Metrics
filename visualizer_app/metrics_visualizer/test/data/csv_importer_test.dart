import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/models.dart';

const header = 'id,clientname,sort_key,event_timestamp,metric,action,event_id,received_at,source_ip';

String row(String client, String ts, String metric, String action, {String id = 'e'}) =>
    '1,$client,k,$ts,$metric,$action,$id,$ts,192.0.2.1';

int heartbeatTotal(Dataset ds) => ds.heartbeats.fold(0, (a, b) => a + b.count);

void main() {
  group('production sample', () {
    late Dataset ds;
    setUpAll(() {
      final bytes = File('test/fixtures/production_sample.csv').readAsBytesSync();
      ds = importCsvBytes(bytes, sourceName: 'production_sample.csv');
    });

    test('imports every row, heartbeats folded into hourly buckets', () {
      expect(ds.skippedRows, 0);
      expect(ds.events.length, 83);
      expect(heartbeatTotal(ds), 10);
      expect(ds.events.any((e) => e.action == heartbeatAction), isFalse);
      expect(ds.origin, DatasetOrigin.csv);
      expect(ds.description, 'production_sample.csv');
    });

    test('keeps fields, ids and timestamps exactly', () {
      final first = ds.events.first;
      expect(first.clientName, 'BSS_112');
      expect(first.metric, 'System Shutdown Sequence Complete');
      expect(first.action, 'Trace');
      expect(first.timestamp, DateTime.utc(2026, 11, 10, 23, 31, 46, 654, 474));
      expect(first.eventId, '99c70179-fe4e-4d67-974d-5ab820635daa');
      expect(first.receivedAt, DateTime.utc(2026, 11, 10, 23, 31, 55, 883, 161));
      expect(ds.events.where((e) => e.action.startsWith('Level ')), isNotEmpty);
    });

    test('range covers whole hours around the data and buckets are aligned', () {
      expect(ds.rangeStart, DateTime.utc(2026, 11, 10, 23));
      expect(ds.rangeEnd.minute, 0);
      for (final e in ds.events) {
        expect(e.timestamp.isBefore(ds.rangeStart), isFalse);
        expect(e.timestamp.isBefore(ds.rangeEnd), isTrue);
      }
      for (final h in ds.heartbeats) {
        expect(h.hourStart.minute, 0);
        expect(h.hourStart.second, 0);
        expect(h.hourStart.isUtc, isTrue);
      }
      // Case differences are preserved (Holt_171 vs HOLT_155).
      expect(ds.clientNames, containsAll(['Holt_171', 'HOLT_155', 'AJH_125A']));
    });

    test('psql aligned text export gives the same rows', () {
      final text = File('test/fixtures/production_sample_psql.txt').readAsStringSync();
      final psql = importCsvString(text, sourceName: 'psql.txt');
      expect(psql.skippedRows, 0);
      expect(psql.events.length, 40);
      for (var i = 0; i < 40; i++) {
        final a = psql.events[i], b = ds.events.firstWhere((e) => e.eventId == a.eventId);
        expect(a.clientName, b.clientName);
        expect(a.timestamp, b.timestamp);
        expect(a.metric, b.metric);
        expect(a.action, b.action);
        expect(a.receivedAt, b.receivedAt);
      }
    });
  });

  group('formats and encodings', () {
    const minimal = 'clientname,event_timestamp,metric,action\n'
        'BSS_245,2026-11-10 10:00:00+00,pc,Started\n';

    test('minimal required columns, case-insensitive aliases, extra columns ignored', () {
      final ds = importCsvString(
          'Room,"Timestamp",METRIC,Action,Extra\nBSS_245,2026-11-10T10:00:00Z,pc,Started,x\n',
          sourceName: 'x');
      expect(ds.events.single.clientName, 'BSS_245');
      expect(ds.events.single.eventId, isNull);
      expect(ds.events.single.receivedAt, isNull);
    });

    test('UTF-8 BOM, UTF-16LE BOM and UTF-16BE BOM', () {
      final utf8Bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(minimal)]);
      expect(importCsvBytes(utf8Bom, sourceName: 'a').events, hasLength(1));

      Uint8List utf16(bool le) {
        final b = <int>[le ? 0xFF : 0xFE, le ? 0xFE : 0xFF];
        for (final c in minimal.codeUnits) {
          b.addAll(le ? [c & 0xFF, c >> 8] : [c >> 8, c & 0xFF]);
        }
        return Uint8List.fromList(b);
      }

      expect(importCsvBytes(utf16(true), sourceName: 'b').events.single.metric, 'pc');
      expect(importCsvBytes(utf16(false), sourceName: 'c').events.single.metric, 'pc');
    });

    test('CRLF, lone CR, semicolon and tab delimiters, blank lines', () {
      expect(importCsvString(minimal.replaceAll('\n', '\r\n'), sourceName: 'x').events, hasLength(1));
      expect(importCsvString(minimal.replaceAll('\n', '\r'), sourceName: 'x').events, hasLength(1));
      expect(importCsvString('\n\n${minimal.replaceAll(',', ';')}\n\n', sourceName: 'x').events,
          hasLength(1));
      expect(importCsvString(minimal.replaceAll(',', '\t'), sourceName: 'x').events, hasLength(1));
    });

    test('quoted fields with delimiters, doubled quotes and line breaks', () {
      final ds = importCsvString(
        'clientname,event_timestamp,metric,action\n'
        'BSS_245,2026-11-10 10:00:00+00,"NAV Share - Station, 3",Share\n'
        'BSS_245,2026-11-10 10:00:01+00,"Say ""hi""",Trace\n'
        'BSS_245,2026-11-10 10:00:02+00,"two\nlines",Trace\n'
        'BSS_245,2026-11-10 10:00:03+00,pc,Started\n',
        sourceName: 'x',
      );
      expect(ds.skippedRows, 0);
      expect(ds.events.map((e) => e.metric),
          ['NAV Share - Station, 3', 'Say "hi"', 'two\nlines', 'pc']);
    });

    test('mixed timestamp variants in one file', () {
      final ds = importCsvString(
        [
          'clientname,event_timestamp,metric,action',
          'A_1,2026-11-10 10:00:00.5+00,pc,Started',
          'A_1,2026-11-10T10:00:01Z,hdmi,Started',
          'A_1,2026-11-10 02:00:02-08:00,usb,Started',
          'A_1,2026-11-10 10:00:03,vga,Started',
          'A_1,11/10/2026 10:00:04 AM,dvd,Started',
        ].join('\n'),
        sourceName: 'x',
      );
      expect(ds.skippedRows, 0);
      expect(ds.events.map((e) => e.timestamp.second), [0, 1, 2, 3, 4]);
    });
  });

  group('malformed input', () {
    test('bad rows are skipped and counted', () {
      final ds = importCsvString(
        [
          header,
          row('BSS_245', '2026-11-10 10:00:00+00', 'pc', 'Started'),
          row('BSS_245', 'yesterday', 'pc', 'Started'), // bad timestamp
          row('', '2026-11-10 10:00:01+00', 'pc', 'Started'), // empty client
          row('BSS_245', '2026-11-10 10:00:02+00', 'pc', ''), // empty action
          '1,BSS_245,k,2026-11-10 10:00:03+00,pc', // too few columns
          '${row('BSS_245', '2026-11-10 10:00:04+00', 'pc', 'Started')},extra', // too many
          '1,BSS_245,k,2026-11-10 10:00:05+00,"unterminated,Started,e,x,y', // open quote to EOF
        ].join('\n'),
        sourceName: 'x',
      );
      expect(ds.events, hasLength(1));
      expect(ds.skippedRows, 6);
    });

    test('psql footer, wrapped lines and blank lines are tolerated', () {
      final ds = importCsvString(
        ' clientname | event_timestamp | metric | action\n'
        '------------+-----------------+--------+--------\n'
        ' BSS_245    | 2026-11-10 10:00:00+00 | pc | Started\n'
        '\n'
        ' BSS_245    | 2026-11-10 10:00:01+00 | Ok | Heartbeat\n'
        '(2 rows)\n',
        sourceName: 'x',
      );
      expect(ds.events, hasLength(1));
      expect(heartbeatTotal(ds), 1);
      expect(ds.skippedRows, 0);
    });

    test('psql unaligned (-A) output and its footer', () {
      final ds = importCsvString(
        'clientname|event_timestamp|metric|action\n'
        'BSS_245|2026-11-10 10:00:00+00|pc|Started\n'
        'BSS_245|2026-11-10 10:00:01+00|hdmi|Started\n'
        '(2 rows)\n',
        sourceName: 'x',
      );
      expect(ds.events, hasLength(2));
      expect(ds.skippedRows, 0);
    });

    test('day-first spreadsheet dates are detected and read correctly', () {
      final ds = importCsvString(
        [
          'clientname,event_timestamp,metric,action',
          'A_1,10/11/2026 23:31,pc,Started',
          'A_1,25/11/2026 08:00,hdmi,Started',
        ].join('\n'),
        sourceName: 'x',
      );
      expect(ds.skippedRows, 0);
      expect(ds.events.map((e) => e.timestamp),
          [DateTime.utc(2026, 11, 10, 23, 31), DateTime.utc(2026, 11, 25, 8)]);
      expect(ds.warnings.single, contains('day first'));
    });

    test('ambiguous slash dates are read month first with a warning', () {
      final ds = importCsvString(
        [
          'clientname,event_timestamp,metric,action',
          'A_1,10/11/2026 23:31,pc,Started',
          'A_1,03/04/2026 08:00,hdmi,Started',
        ].join('\n'),
        sourceName: 'x',
      );
      expect(ds.events.first.timestamp, DateTime.utc(2026, 3, 4, 8));
      expect(ds.warnings.single, contains('could not be confirmed'));
      // Filtering keeps the warning for the analysis.
      expect(ds.filter().warnings, ds.warnings);
    });

    test('US dates with a day above 12 need no warning', () {
      final ds = importCsvString(
        [
          'clientname,event_timestamp,metric,action',
          'A_1,11/25/2026 23:31,pc,Started',
          'A_1,03/04/2026 08:00,hdmi,Started',
        ].join('\n'),
        sourceName: 'x',
      );
      expect(ds.events.last.timestamp, DateTime.utc(2026, 11, 25, 23, 31));
      expect(ds.warnings, isEmpty);
    });

    test('clear errors for unusable files', () {
      expect(() => importCsvString('', sourceName: 'x'),
          throwsA(isA<CsvImportException>().having((e) => e.message, 'message', contains('empty'))));
      expect(
          () => importCsvString('clientname,metric,action\nA,pc,Started\n', sourceName: 'x'),
          throwsA(isA<CsvImportException>()
              .having((e) => e.message, 'message', contains('event_timestamp'))
              .having((e) => e.suggestion, 'suggestion', isNotNull)));
      expect(() => importCsvString('$header\n', sourceName: 'x'),
          throwsA(isA<CsvImportException>().having((e) => e.message, 'message', contains('no data rows'))));
      expect(
          () => importCsvString('$header\n${row('A_1', 'bad', 'pc', 'Started')}\n', sourceName: 'x'),
          throwsA(isA<CsvImportException>().having((e) => e.message, 'message', contains('None of the 1'))));
    });
  });

  test('heartbeats are counted per client per UTC hour', () {
    final ds = importCsvString(
      [
        header,
        row('A_1', '2026-11-10 10:00:00+00', 'Ok', 'Heartbeat'),
        row('A_1', '2026-11-10 10:59:59.999999+00', 'Ok', 'Heartbeat'),
        row('A_1', '2026-11-10 11:00:00+00', 'Ok', 'heartbeat'),
        row('B_2', '2026-11-10 10:30:00+00', 'Ok', 'Heartbeat'),
        row('B_2', '2026-11-10 03:30:00-07', 'Ok', 'Heartbeat'), // 10:30 UTC
      ].join('\n'),
      sourceName: 'x',
    );
    expect(ds.events, isEmpty);
    final byKey = {
      for (final h in ds.heartbeats) '${h.clientName}@${h.hourStart.toIso8601String()}': h.count
    };
    expect(byKey, {
      'A_1@2026-11-10T10:00:00.000Z': 2,
      'A_1@2026-11-10T11:00:00.000Z': 1,
      'B_2@2026-11-10T10:00:00.000Z': 2,
    });
    expect(ds.rangeStart, DateTime.utc(2026, 11, 10, 10));
    expect(ds.rangeEnd, DateTime.utc(2026, 11, 10, 12));
  });

  test('background import returns the same dataset', () async {
    final bytes = File('test/fixtures/production_sample.csv').readAsBytesSync();
    final ds = await importCsvInBackground(bytes, sourceName: 'bg.csv');
    expect(ds.events, hasLength(83));
  });

  test('performance: 200,000 rows import within a few seconds', () {
    final sb = StringBuffer('$header\n');
    final start = DateTime.utc(2026, 9, 1);
    const clients = ['BSS_245', 'HOLT_155', 'ARTS_107', 'AJH_125A', 'Holt_171'];
    for (var i = 0; i < 200000; i++) {
      final t = start.add(Duration(seconds: i * 13));
      final ts = '${t.toIso8601String().replaceFirst('T', ' ').replaceFirst('Z', '')}+00';
      final heartbeat = i % 10 != 0;
      sb.writeln('$i,${clients[i % clients.length]},k,$ts,'
          '${heartbeat ? 'Ok' : 'pc'},${heartbeat ? 'Heartbeat' : 'Started'},'
          '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')},$ts,192.0.2.1');
    }
    final bytes = Uint8List.fromList(utf8.encode(sb.toString()));
    final watch = Stopwatch()..start();
    final ds = importCsvBytes(bytes, sourceName: 'big.csv');
    watch.stop();
    expect(ds.events, hasLength(20000));
    expect(heartbeatTotal(ds), 180000);
    expect(ds.skippedRows, 0);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)),
        reason: 'took ${watch.elapsedMilliseconds} ms');
  });
}
