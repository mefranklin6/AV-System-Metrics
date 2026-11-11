import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/data/timestamp_parser.dart';

void main() {
  final expected = DateTime.utc(2026, 11, 11, 0, 22, 9, 709, 41);

  group('parseTimestamp', () {
    test('psql timestamptz forms', () {
      expect(parseTimestamp('2026-11-11 00:22:09.709041+00'), expected);
      expect(parseTimestamp('2026-11-11 00:22:09.709041+00:00'), expected);
      expect(parseTimestamp('2026-11-11 00:22:09.709041+0000'), expected);
      expect(parseTimestamp('  2026-11-11 00:22:09.709041+00  '), expected);
      expect(parseTimestamp('"2026-11-11 00:22:09.709041+00"'), expected);
    });

    test('ISO 8601 / RFC 3339 forms', () {
      expect(parseTimestamp('2026-11-11T00:22:09.709041Z'), expected);
      expect(parseTimestamp('2026-11-11t00:22:09.709041z'), expected);
      expect(parseTimestamp('2026-11-11T00:22:09.709041000Z'), expected,
          reason: 'nanoseconds are truncated to microseconds');
      expect(parseTimestamp('2026-11-11T00:22:09,709041Z'), expected);
      expect(parseTimestamp('2026-11-11 00:22:09.709041 UTC'), expected);
    });

    test('offsets are converted to UTC', () {
      expect(parseTimestamp('2026-11-10 16:22:09.709041-08'), expected);
      expect(parseTimestamp('2026-11-10T16:22:09.709041-08:00'), expected);
      expect(parseTimestamp('2026-11-11 05:52:09.709041+05:30'), expected);
    });

    test('missing offset means UTC; partial precision is accepted', () {
      expect(parseTimestamp('2026-11-11 00:22:09.709041'), expected);
      expect(parseTimestamp('2026-11-11 00:22:09'), DateTime.utc(2026, 11, 11, 0, 22, 9));
      expect(parseTimestamp('2026-11-11 00:22'), DateTime.utc(2026, 11, 11, 0, 22));
      expect(parseTimestamp('2026-11-11'), DateTime.utc(2026, 11, 11));
      expect(parseTimestamp('2026-11-11 00:22:09.7+00'), DateTime.utc(2026, 11, 11, 0, 22, 9, 700));
      expect(parseTimestamp('2026/11/11 00:22:09'), DateTime.utc(2026, 11, 11, 0, 22, 9));
    });

    test('US spreadsheet re-saves', () {
      expect(parseTimestamp('11/10/2026 23:31'), DateTime.utc(2026, 11, 10, 23, 31));
      expect(parseTimestamp('11/10/2026 11:31:46 PM'), DateTime.utc(2026, 11, 10, 23, 31, 46));
      expect(parseTimestamp('1/2/2026 12:05 AM'), DateTime.utc(2026, 1, 2, 0, 5));
      expect(parseTimestamp('11/10/2026'), DateTime.utc(2026, 11, 10));
    });

    test('day-first spreadsheet re-saves', () {
      expect(parseTimestamp('10/11/2026 23:31', dayFirst: true), DateTime.utc(2026, 11, 10, 23, 31));
      expect(parseTimestamp('25/12/2026', dayFirst: true), DateTime.utc(2026, 12, 25));
      expect(parseTimestamp('12/25/2026', dayFirst: true), isNull);
      // ISO timestamps are unaffected.
      expect(parseTimestamp('2026-11-11T00:22:09.709041Z', dayFirst: true), expected);
    });

    test('SlashDateOrder decides the order for a file', () {
      SlashDateOrder of(List<String> values) {
        final o = SlashDateOrder();
        values.forEach(o.add);
        return o;
      }

      final dayFirst = of(['10/11/2026 23:31', '25/11/2026 08:00']);
      expect(dayFirst.dayFirst, isTrue);
      expect(dayFirst.ambiguous, isFalse);
      final us = of(['11/10/2026 23:31', '11/25/2026 08:00']);
      expect(us.dayFirst, isFalse);
      expect(us.ambiguous, isFalse);
      final unsure = of(['"03/04/2026 10:00"', '05/06/2026']);
      expect(unsure.ambiguous, isTrue);
      expect(unsure.dayFirst, isFalse);
      final iso = of(['2026-11-11 00:22:09+00']);
      expect(iso.hasSlashDates, isFalse);
      expect(iso.ambiguous, isFalse);
    });

    test('leap second and 24:00 are normalised', () {
      expect(parseTimestamp('2016-12-31 23:59:60Z'), DateTime.utc(2017, 1, 1));
      expect(parseTimestamp('2026-11-10 24:00:00Z'), DateTime.utc(2026, 11, 11));
    });

    test('rejects garbage and impossible values', () {
      for (final bad in [
        '',
        'not a date',
        'Ok',
        '2026-13-01 00:00:00',
        '2026-02-30 00:00:00',
        '2026-11-11 25:00:00',
        '2026-11-11 00:61:00',
        '2026-11-11 00:22:09+99',
        '2026-11-11 00:22:09 PST',
        '2026-11-11X00:22:09',
        '2026-11-11 00:22:09.Z',
        '13/45/2026 10:00',
        '11/10/2026 13:00 PM',
        '2026-11-11 00:22:09+00 trailing',
      ]) {
        expect(parseTimestamp(bad), isNull, reason: bad);
      }
    });
  });

  test('formatRfc3339Utc matches the API format', () {
    expect(formatRfc3339Utc(expected), '2026-11-11T00:22:09.709041Z');
    expect(formatRfc3339Utc(DateTime.utc(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05.000000Z');
    expect(parseTimestamp(formatRfc3339Utc(expected)), expected);
  });
}
