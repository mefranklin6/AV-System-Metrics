import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/data/api_client.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/data/token_store.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const token = 'test-token-0123456789abcdefghijklmnopqrstuv';

class Harness {
  Harness(this.settings, {AnalysisRunner? runner, http.Client? httpClient})
      : tokens = MemoryTokenStore() {
    app = AppState(
      settings: settings,
      analysisRunner: runner ??
          (r) async {
            runs.add(r);
            return runAnalysisRequest(r);
          },
      csvImporter: (bytes, name) async => importCsvBytes(bytes, sourceName: name),
      demoRunner: () async => generateDemoDataset(end: DateTime.utc(2026, 11, 10), weeks: 3),
      filePicker: () async => picked,
      apiClientFactory: (url, t) => AnalyticsApiClient(baseUrl: url, token: t, httpClient: httpClient),
      tokenStore: tokens,
      announcer: (m, {assertive = false}) => announcements.add((m, assertive)),
    );
  }

  final SettingsState settings;
  final MemoryTokenStore tokens;
  late final AppState app;
  final runs = <AnalysisRequest>[];
  final announcements = <(String, bool)>[];
  PickedFile? picked;

  /// Waits until no analysis is pending.
  Future<void> settle() async {
    for (var i = 0; i < 100 && (app.isAnalyzing || app.isLoading); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(Duration.zero);
  }
}

Uint8List csvBytes(List<String> rows) => Uint8List.fromList(
    utf8.encode(['clientname,event_timestamp,metric,action', ...rows].join('\n')));

void main() {
  late SettingsState settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsState.load();
  });

  test('loading a CSV builds the room index and analyses in the background', () async {
    final h = Harness(settings);
    final bytes = File('test/fixtures/production_sample.csv').readAsBytesSync();
    await h.app.loadCsvBytes(bytes, 'sample.csv');
    await h.settle();
    final app = h.app;
    expect(app.hasData, isTrue);
    expect(app.error, isNull);
    expect(app.analysis, isNotNull);
    expect(app.filteredDataset!.events, hasLength(83));
    expect(app.buildings, containsAll(['BSS', 'HOLT', 'AJH', 'YOLO']));
    expect(app.roomsIn('HOLT'), containsAll(['Holt_171', 'HOLT_155', 'HOLT_185']));
    expect(app.buildingOf('Holt_171'), 'HOLT');
    expect(h.announcements.map((a) => a.$1), contains(startsWith('Loaded 83 events from 19 rooms')));
    expect(h.announcements.map((a) => a.$1), contains(startsWith('Analysis updated')));
  });

  test('import errors are reported in text and announced assertively', () async {
    final h = Harness(settings);
    await h.app.loadCsvBytes(Uint8List.fromList(utf8.encode('just,some,columns\n1,2,3')), 'bad.csv');
    expect(h.app.hasData, isFalse);
    expect(h.app.isLoading, isFalse);
    expect(h.app.error!.title, contains('bad.csv'));
    expect(h.app.error!.message, contains('clientname'));
    expect(h.app.error!.suggestion, isNotNull);
    expect(h.announcements.last.$2, isTrue);
    h.app.dismissError();
    expect(h.app.error, isNull);
  });

  test('file picker: cancel does nothing, a pick loads', () async {
    final h = Harness(settings);
    await h.app.pickAndLoadCsv();
    expect(h.app.hasData, isFalse);
    h.picked = PickedFile('x.csv', csvBytes(['BSS_245,2026-11-10 10:00:00+00,pc,Started']));
    await h.app.pickAndLoadCsv();
    expect(h.app.dataset!.description, 'x.csv');
  });

  test('excluded clients are not rooms; settings changes re-run the analysis', () async {
    final h = Harness(settings);
    await h.app.loadCsvBytes(
        csvBytes([
          'BSS_245,2026-11-10 10:00:00+00,pc,Started',
          'avsm-system,2026-11-10 10:00:00+00,Update started,Trace',
          'HOLT_155,2026-11-10 11:00:00+00,hdmi,Started',
        ]),
        'x.csv');
    await h.settle();
    expect(h.app.rooms, ['BSS_245', 'HOLT_155'], reason: 'exclusion is case-insensitive');
    final before = h.runs.length;

    await settings.setExcludeClients({'AVSM-System', 'HOLT_155'});
    await h.settle();
    expect(h.app.rooms, ['BSS_245']);
    expect(h.runs.length, before + 1);
    expect(h.runs.last.excludeClients, contains('HOLT_155'));

    await settings.setThemeMode(ThemeMode.dark);
    await h.settle();
    expect(h.runs.length, before + 1, reason: 'appearance changes do not re-analyse');

    await settings.setTimeDisplay(TimeDisplay.utc);
    await h.settle();
    expect(h.runs.length, before + 2);
    expect(h.runs.last.config.useLocalTime, isFalse);
  });

  group('filters', () {
    late Harness h;
    setUp(() async {
      h = Harness(settings);
      await h.app.loadDemo();
      await h.settle();
    });

    test('date presets end at the end of the data', () async {
      final ds = h.app.dataset!;
      expect(h.app.window, TimeWindow(ds.rangeStart, ds.rangeEnd));
      h.app.setDatePreset(DatePreset.last7);
      await h.settle();
      expect(h.app.window!.end, ds.rangeEnd);
      expect(h.app.window!.duration, const Duration(days: 7));
      expect(h.runs.last.window, h.app.window);
      expect(h.app.filteredDataset!.events.every((e) => !e.timestamp.isBefore(h.app.window!.start)), isTrue);

      h.app.setDatePreset(DatePreset.last90);
      expect(h.app.window!.start, ds.rangeStart, reason: 'clamped to the data');
      h.app.setDatePreset(DatePreset.semester);
      expect(h.app.window!.start, ds.rangeStart);
    });

    test('custom windows validate their bounds', () async {
      final start = DateTime.utc(2026, 10, 25), end = DateTime.utc(2026, 10, 28);
      h.app.setCustomWindow(start, end);
      await h.settle();
      expect(h.app.filters.preset, DatePreset.custom);
      expect(h.app.window, TimeWindow(start, end));
      expect(() => h.app.setCustomWindow(end, start), throwsArgumentError);
    });

    test('buildings and rooms narrow the analysed clients', () async {
      expect(h.app.buildings, ['AJH', 'ARTS', 'BSS', 'HOLT', 'LIB', 'SCI']);
      expect(h.app.selectedClients, isNull);
      h.app.setBuildings({'HOLT'});
      await h.settle();
      expect(h.app.selectableRooms, ['HOLT_155', 'HOLT_185', 'Holt_171', 'Holt_210']);
      expect(h.app.selectedClients, h.app.selectableRooms.toSet());
      expect(h.app.filteredDataset!.clientNames.toSet().difference(h.app.selectableRooms.toSet()), isEmpty);

      h.app.setRooms({'HOLT_155'});
      await h.settle();
      expect(h.runs.last.clients, {'HOLT_155'});
      // Changing buildings drops rooms outside them.
      h.app.setBuildings({'BSS'});
      expect(h.app.filters.rooms, isEmpty);
      h.app.clearFilters();
      expect(h.app.filters.isDefault, isTrue);
    });

    test('changing the building pattern re-derives buildings', () async {
      await settings.setAnalysisConfig(settings.analysisConfig.copyWith(
          classifier: settings.analysisConfig.classifier.copyWith(buildingPattern: r'^([A-Za-z])')));
      await h.settle();
      expect(h.app.buildings, ['A', 'B', 'H', 'L', 'S']);
    });

    test('clearing data resets everything', () async {
      h.app.setDatePreset(DatePreset.last7);
      h.app.clearData();
      expect(h.app.hasData, isFalse);
      expect(h.app.analysis, isNull);
      expect(h.app.filters.isDefault, isTrue);
      expect(h.app.rooms, isEmpty);
    });
  });

  test('analysis runs are coalesced and stale results discarded', () async {
    final pending = <Completer<AnalysisOutcome>>[];
    final requests = <AnalysisRequest>[];
    final h = Harness(settings, runner: (r) {
      requests.add(r);
      final c = Completer<AnalysisOutcome>();
      pending.add(c);
      return c.future;
    });
    await h.app.loadCsvBytes(
        csvBytes([
          'BSS_245,2026-11-01 10:00:00+00,pc,Started',
          'BSS_245,2026-11-10 10:00:00+00,hdmi,Started',
        ]),
        'x.csv');
    expect(requests, hasLength(1));
    expect(h.app.isAnalyzing, isTrue);

    // Three changes while the first run is busy...
    h.app.setDatePreset(DatePreset.last7);
    h.app.setRooms({'BSS_245'});
    h.app.setDatePreset(DatePreset.all);
    expect(requests, hasLength(1), reason: 'never more than one run at a time');

    // ...the first result is stale and a single follow-up run starts.
    pending[0].complete(runAnalysisRequest(requests[0]));
    await Future<void>.delayed(Duration.zero);
    expect(h.app.analysis, isNull);
    expect(requests, hasLength(2));
    expect(requests[1].clients, {'BSS_245'});
    expect(requests[1].window.start, h.app.dataset!.rangeStart);

    pending[1].complete(runAnalysisRequest(requests[1]));
    await Future<void>.delayed(Duration.zero);
    expect(h.app.analysis, isNotNull);
    expect(h.app.isAnalyzing, isFalse);
  });

  test('analysis failures surface as an error with a suggestion', () async {
    final h = Harness(settings, runner: (r) async => throw StateError('boom'));
    await h.app.loadCsvBytes(csvBytes(['BSS_245,2026-11-01 10:00:00+00,pc,Started']), 'x.csv');
    await h.settle();
    expect(h.app.analysis, isNull);
    expect(h.app.error!.title, 'Analysis failed');
    expect(h.app.error!.suggestion, isNotNull);
  });

  group('Analytics API', () {
    http.Response json(Object body, [int status = 200]) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    MockClient server({int eventStatus = 200, void Function()? onEvents}) => MockClient((req) async {
          expect(req.headers['Authorization'], 'Bearer $token');
          switch (req.url.pathSegments.last) {
            case 'info':
              return json({
                'api_version': '1',
                'server_time': '2026-11-11T00:00:00.000000Z',
                'activity_range': {'first_event': null, 'last_event': null},
                'heartbeat_purge': {'enabled_status': 'succeeded', 'retention_days': 30, 'cutoff': null, 'finished_at': null},
              });
            case 'clients':
              return json({'clients': [
                {'clientname': 'BSS_245', 'event_count': 1, 'heartbeat_count': 0, 'first_event': null, 'last_event': null, 'last_heartbeat': null}
              ]});
            case 'events':
              onEvents?.call();
              if (eventStatus != 200) {
                return json({'error': {'code': 'forbidden', 'message': 'invalid token'}}, eventStatus);
              }
              return json({
                'events': [
                  {
                    'id': 1,
                    'clientname': 'BSS_245',
                    'event_timestamp': '2026-11-10T10:00:00.000000Z',
                    'metric': 'pc',
                    'action': 'Started',
                    'event_id': 'e1',
                    'received_at': '2026-11-10T10:00:01.000000Z'
                  }
                ],
                'next_cursor': null
              });
            case 'heartbeats':
              return json({'truncated': false, 'series': []});
          }
          return http.Response('', 404);
        });

    test('loads, remembers the token only when asked', () async {
      final h = Harness(settings, httpClient: server());
      await h.app.loadFromApi(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
        rememberToken: true,
      );
      await h.settle();
      expect(h.app.error, isNull);
      expect(h.app.dataset!.origin, DatasetOrigin.api);
      expect(h.app.dataset!.heartbeatRetentionDays, 30);
      expect(h.tokens.entry!.token, token);
      expect(h.tokens.entry!.origin, 'https://avsm.example.edu:443');

      await h.app.loadFromApi(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(h.tokens.entry, isNull);
    });

    test('server errors keep the previous data and explain the problem', () async {
      final h = Harness(settings, httpClient: server(eventStatus: 403));
      await h.app.loadFromApi(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(h.app.hasData, isFalse);
      expect(h.app.error!.message, contains('Access was denied'));
      expect(h.app.error!.message, isNot(contains(token)));
    });

    test('a load can be cancelled', () async {
      late Harness h;
      h = Harness(settings, httpClient: server(onEvents: () => h.app.cancelLoad()));
      await h.app.loadFromApi(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(h.app.hasData, isFalse);
      expect(h.app.error, isNull);
      expect(h.app.isLoading, isFalse);
      expect(h.announcements.last.$1, 'Loading cancelled.');
    });

    test('test connection returns info and clients', () async {
      final h = Harness(settings, httpClient: server());
      final (info, clients) =
          await h.app.testApiConnection(baseUrl: Uri.parse('https://avsm.example.edu'), token: token);
      expect(info.retentionDays, 30);
      expect(clients.single.clientName, 'BSS_245');
    });

    test('a remembered token is bound to its origin', () async {
      final h = Harness(settings, httpClient: server());
      await h.app.loadFromApi(
        baseUrl: Uri.parse('https://avsm.example.edu/analytics'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
        rememberToken: true,
      );
      expect(h.tokens.entry!.origin, 'https://avsm.example.edu:443');
      expect(await h.app.rememberedTokenOrigin(), 'https://avsm.example.edu:443');
      expect(await h.app.rememberedTokenFor(Uri.parse('https://AVSM.example.edu')), token);
      expect(await h.app.rememberedTokenFor(Uri.parse('https://avsm.example.com')), isNull);
      await h.app.forgetRememberedToken();
      expect(h.tokens.entry, isNull);
    });

    test('the remembered token is never sent to another origin', () async {
      var requests = 0;
      final h = Harness(settings, httpClient: MockClient((req) async {
        requests++;
        return http.Response('{}', 500);
      }));
      await h.tokens.write(token, baseUrl: Uri.parse('https://avsm.example.edu'));
      final other = Uri.parse('https://avsm.example.com');
      await expectLater(h.app.testApiConnection(baseUrl: other, token: token),
          throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('different server'))));
      await h.app.loadFromApi(
        baseUrl: other,
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
        rememberToken: true,
      );
      expect(h.app.error!.message, contains('different server'));
      expect(h.app.error!.message, isNot(contains(token)));
      expect(await h.app.estimateApiDownload(
          baseUrl: other, token: token, from: DateTime.utc(2026, 11, 1), to: DateTime.utc(2026, 11, 11)), isNull);
      expect(requests, 0, reason: 'nothing was sent');
      expect(h.tokens.entry!.origin, 'https://avsm.example.edu:443', reason: 'not re-bound');
      // Another token for that server is fine.
      await expectLater(h.app.testApiConnection(baseUrl: other, token: 'x$token'), throwsA(isA<ApiException>()));
      expect(requests, 1);
    });

    test('a token saved by an older version is bound to the address saved at startup', () async {
      await settings.setApiBaseUrl('https://avsm.example.edu:8081');
      // An entry without an origin, as older versions wrote it.
      final legacy = MemoryTokenStore(token);
      final app = AppState(settings: settings, tokenStore: legacy, announcer: (m, {assertive = false}) {});
      addTearDown(app.dispose);
      // Editing the address later must not re-bind the token.
      await settings.setApiBaseUrl('https://avsm.example.com:8081');
      expect(await app.rememberedTokenFor(Uri.parse('https://avsm.example.com:8081')), isNull);
      expect(await app.rememberedTokenFor(Uri.parse('https://avsm.example.edu:8081')), token);
      expect(legacy.entry!.origin, 'https://avsm.example.edu:8081');
    });

    test('estimateApiDownload counts the events of the selected rooms', () async {
      final h = Harness(settings, httpClient: server());
      final n = await h.app.estimateApiDownload(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(n, 1);
      expect(h.app.isLoading, isFalse);
      expect(h.app.error, isNull);
    });

    test('a failed size check is reported like a failed load', () async {
      final h = Harness(settings, httpClient: MockClient((req) async => http.Response(
          jsonEncode({'error': {'code': 'forbidden', 'message': 'invalid token'}}), 403,
          headers: {'content-type': 'application/json'})));
      final n = await h.app.estimateApiDownload(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(n, isNull);
      expect(h.app.isLoading, isFalse);
      expect(h.app.error!.message, contains('Access was denied'));
      expect(h.announcements.last.$2, isTrue, reason: 'errors are announced assertively');
    });

    test('a size check can be cancelled', () async {
      late Harness h;
      h = Harness(settings, httpClient: MockClient((req) async {
        h.app.cancelLoad();
        return http.Response(jsonEncode({'clients': []}), 200, headers: {'content-type': 'application/json'});
      }));
      final n = await h.app.estimateApiDownload(
        baseUrl: Uri.parse('https://avsm.example.edu'),
        token: token,
        from: DateTime.utc(2026, 11, 1),
        to: DateTime.utc(2026, 11, 11),
      );
      expect(n, isNull);
      expect(h.app.error, isNull);
      expect(h.app.isLoading, isFalse);
      expect(h.announcements.last.$1, 'Loading cancelled.');
    });
  });
}
