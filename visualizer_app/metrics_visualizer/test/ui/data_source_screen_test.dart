import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/models.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/about_screen.dart' show aboutTokenStorage;
import 'package:metrics_visualizer/ui/screens/data_source_screen.dart';

import 'ui_test_helpers.dart';

const token = 'test-token-0123456789abcdefghijklmnopqrstuv';

Finder field(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextFormField));

Finder button(String label) =>
    find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));

MockClient fakeServer({int status = 200, int eventCount = 3, List<Uri>? requests}) => MockClient((req) async {
      requests?.add(req.url);
      if (status != 200) {
        return http.Response(jsonEncode({'error': {'code': 'forbidden', 'message': 'invalid token'}}), status);
      }
      final body = switch (req.url.pathSegments.last) {
        'info' => {
            'api_version': '1',
            'server_time': '2026-11-11T00:00:00.000000Z',
            'activity_range': {'first_event': '2026-09-01T00:00:00.000000Z', 'last_event': '2026-11-10T00:00:00.000000Z'},
            'heartbeat_purge': {'enabled_status': 'succeeded', 'retention_days': 30, 'cutoff': null, 'finished_at': null},
          },
        'clients' => {
            'clients': [
              {'clientname': 'BSS_245', 'event_count': eventCount, 'heartbeat_count': 9, 'first_event': null, 'last_event': null, 'last_heartbeat': null},
            ]
          },
        'events' => {'events': [], 'next_cursor': null},
        _ => {'truncated': false, 'series': []},
      };
      return http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
    });

void main() {
  testWidgets('shows export instructions with a copyable command', (tester) async {
    final t = await pumpApp(tester, size: tallSize);
    expect(find.text('Import a CSV export'), findsOneWidget);
    expect(find.text(recommendedExportCommand), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.byTooltip('Copy export command'));
    await pumpFrames(tester, 2);
    expect(copied, recommendedExportCommand);
    expect(find.text('Export command copied.'), findsOneWidget);

    await tester.tap(button('Choose CSV file… (Ctrl+O)'));
    await pumpFrames(tester, 2);
    expect(t.filePicks, 1);
  });

  testWidgets('API form validates input and explains errors in text', (tester) async {
    await pumpApp(tester, size: tallSize);
    await tester.tap(button('Load data'));
    await pumpFrames(tester, 2);
    expect(find.text('Enter the Analytics API address.'), findsOneWidget);
    expect(find.text('Enter the API token.'), findsOneWidget);

    await tester.enterText(field('API address'), 'avsm.example.edu');
    await tester.enterText(field('API token'), 'has space');
    await tester.tap(button('Load data'));
    await pumpFrames(tester, 2);
    expect(find.textContaining('starts with https://'), findsOneWidget);
    expect(find.textContaining('contains spaces'), findsOneWidget);
  });

  group('period chips keep keyboard focus when chosen (WCAG 2.4.3 / 3.2.2)', () {
    ChoiceChip chip(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    for (final key in [LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
      testWidgets('an unselected chip stays focused after ${key.keyLabel}', (tester) async {
        await pumpApp(tester, size: tallSize);
        expect(chip(tester, '30 days').selected, isTrue);
        // Tab forward from the 30 days chip to the 90 days chip.
        chip(tester, '30 days').focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final node = chip(tester, '90 days').focusNode!;
        expect(node.hasPrimaryFocus, isTrue);
        await tester.sendKeyEvent(key);
        await pumpFrames(tester, 2);
        expect(chip(tester, '90 days').selected, isTrue);
        expect(chip(tester, '30 days').selected, isFalse);
        expect(FocusManager.instance.primaryFocus, same(node), reason: 'focus stays on the chosen chip');
      });
    }

    testWidgets('the first chip keeps focus instead of returning to the checkbox', (tester) async {
      await pumpApp(tester, size: tallSize);
      final node = chip(tester, '7 days').focusNode!;
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpFrames(tester, 2);
      expect(chip(tester, '7 days').selected, isTrue);
      expect(FocusManager.instance.primaryFocus, same(node));
      // Each chip has its own node, whichever is selected.
      final nodes = {for (final label in ['7 days', '30 days', '90 days', '180 days', '365 days']) chip(tester, label).focusNode};
      expect(nodes.length, 5);
      expect(nodes, isNot(contains(null)));
    });
  });

  for (final size in [narrowSize, const Size(700, 900)]) {
    testWidgets('API field errors are not cut off at 200% text (${size.width.toInt()} px)', (tester) async {
      await pumpApp(tester, size: size, textScale: 2.0);
      // Helper text first (it is replaced by the error once validated).
      for (final helper in ['Kept in memory only', 'The address your administrator gave you']) {
        expect(tester.renderObject<RenderParagraph>(find.textContaining(helper)).didExceedMaxLines, isFalse,
            reason: helper);
      }
      await tester.enterText(field('API address'), 'avsm.example.edu');
      await tester.enterText(field('API token'), '$token!');
      await tester.pump();
      // Load data is off-screen at this size: validate the form directly.
      final form = tester.state<FormState>(find.ancestor(of: field('API token'), matching: find.byType(Form)).first);
      expect(form.validate(), isFalse);
      await pumpFrames(tester, 3);
      final address = find.textContaining('Enter a full address');
      final tokenError = find.textContaining('The token contains a character');
      expect(address, findsOneWidget);
      expect(tokenError, findsOneWidget);
      for (final f in [address, tokenError]) {
        final paragraph = tester.renderObject<RenderParagraph>(f);
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'text of $f must wrap, not be cut off');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('warns about unencrypted http to a remote host only', (tester) async {
    await pumpApp(tester, size: tallSize);
    await tester.enterText(field('API address'), 'http://10.20.30.40:8081');
    await tester.pump();
    expect(find.byType(InsecureConnectionWarning), findsOneWidget);
    expect(find.textContaining('Not encrypted'), findsOneWidget);
    await tester.enterText(field('API address'), 'http://localhost:8081');
    await tester.pump();
    expect(find.byType(InsecureConnectionWarning), findsNothing);
    await tester.enterText(field('API address'), 'https://avsm.example.edu');
    await tester.pump();
    expect(find.byType(InsecureConnectionWarning), findsNothing);
  });

  testWidgets('token can be shown and hidden', (tester) async {
    await pumpApp(tester, size: tallSize);
    EditableText token() => tester.widget<EditableText>(
        find.descendant(of: field('API token'), matching: find.byType(EditableText)));
    expect(token().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show token'));
    await tester.pump();
    expect(token().obscureText, isFalse);
    await tester.tap(find.byTooltip('Hide token'));
    await tester.pump();
    expect(token().obscureText, isTrue);
  });

  testWidgets('test connection reports success and enables room choice', (tester) async {
    final t = await pumpApp(tester, size: tallSize, httpClient: fakeServer());
    await tester.enterText(field('API address'), 'https://avsm.example.edu:8081/');
    await tester.enterText(field('API token'), token);
    await tester.tap(button('Test connection'));
    await pumpFrames(tester, 5);
    expect(find.textContaining('Connected. 1 clients'), findsOneWidget);
    expect(t.settings.apiBaseUrl, 'https://avsm.example.edu:8081');
    final choose = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Choose rooms…'));
    expect(choose.onPressed, isNotNull);
  });

  testWidgets('connection failures are shown with the reason', (tester) async {
    await pumpApp(tester, size: tallSize, httpClient: fakeServer(status: 403));
    await tester.enterText(field('API address'), 'https://avsm.example.edu');
    await tester.enterText(field('API token'), token);
    await tester.tap(button('Test connection'));
    await pumpFrames(tester, 5);
    final message = tester.widget<Text>(find.textContaining('Access was denied'));
    expect(message.data, isNot(contains(token)));
  });

  testWidgets('loading from the API remembers the token only when asked', (tester) async {
    final t = await pumpApp(tester, size: tallSize, httpClient: fakeServer());
    await tester.enterText(field('API address'), 'https://avsm.example.edu');
    await tester.enterText(field('API token'), token);
    await tester.tap(find.text('Remember token on this computer'));
    await pumpFrames(tester, 2);
    expect(t.settings.rememberApiToken, isTrue);
    await tester.tap(button('Load data'));
    await settleWork(tester, t);
    expect(t.tokens.entry!.token, token);
    expect(t.tokens.entry!.origin, 'https://avsm.example.edu:443');
    expect(t.app.hasData, isTrue);
    expect(t.navigation.current, AppDestination.overview);
  });

  testWidgets('a remembered token (saved by an older version) is only filled in for its address',
      (tester) async {
    final requests = <Uri>[];
    final server = MockClient((req) async {
      requests.add(req.url);
      return http.Response('{}', 500);
    });
    await pumpApp(
      tester,
      size: tallSize,
      httpClient: server,
      savedToken: token,
      prefs: const {'v1.apiBaseUrl': 'https://avsm.example.edu:8081', 'v1.rememberApiToken': true},
    );
    await pumpFrames(tester, 2);
    TextFormField tokenField() => tester.widget<TextFormField>(field('API token'));
    expect(tokenField().controller!.text, token);

    // Another host (a typo or a look-alike link): the token is withheld.
    await tester.enterText(field('API address'), 'https://avsm.example.com:8081');
    await tester.pump();
    expect(tokenField().controller!.text, isEmpty);
    expect(find.textContaining('The remembered token is for https://avsm.example.edu:8081'), findsOneWidget);
    await tester.tap(button('Test connection'));
    await pumpFrames(tester, 3);
    expect(requests, isEmpty, reason: 'nothing is sent without a token');

    // Back to the saved address: the token returns.
    await tester.enterText(field('API address'), 'https://AVSM.example.edu:8081/');
    await pumpFrames(tester, 2);
    expect(tokenField().controller!.text, token);
    expect(find.textContaining('The remembered token is for'), findsNothing);
  });

  testWidgets('a loaded dataset is summarised and can be cleared', (tester) async {
    final t = await pumpApp(tester, size: tallSize, loadDemo: true);
    expect(find.text('Data loaded'), findsOneWidget);
    expect(find.textContaining('Demo data: Demo campus'), findsOneWidget);
    await tester.tap(button('Clear data'));
    await pumpFrames(tester, 2);
    expect(t.app.hasData, isFalse);
    expect(find.text('Data loaded'), findsNothing);
  });

  testWidgets('import errors are displayed on the page', (tester) async {
    final t = await pumpApp(tester, size: tallSize);
    await t.app.loadCsvBytes(Uint8List.fromList(utf8.encode('a,b\n1,2')), 'broken.csv');
    await settleWork(tester, t);
    expect(find.text('Could not import broken.csv'), findsOneWidget);
    expect(find.textContaining('Suggestion:'), findsOneWidget);
    await expectMeetsA11yGuidelines(tester);
    await tester.tap(button('Dismiss'));
    await tester.pump();
    expect(find.text('Could not import broken.csv'), findsNothing);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('data source with an insecure warning meets guidelines (${mode.name})', (tester) async {
      await pumpApp(tester, size: tallSize, themeMode: mode, loadDemo: true);
      await tester.enterText(field('API address'), 'http://10.20.30.40:8081');
      await tester.pump();
      await expectMeetsA11yGuidelines(tester);
    });
  }

  testWidgets('a token remembered for another server is not filled in', (tester) async {
    final tokens = <String>[];
    final server = MockClient((req) async {
      tokens.add(req.headers['Authorization'] ?? '');
      return http.Response('{}', 500);
    });
    final t = await pumpApp(
      tester,
      size: tallSize,
      httpClient: server,
      prefs: const {'v1.apiBaseUrl': 'https://avsm.example.com:8081', 'v1.rememberApiToken': true},
    );
    await t.tokens.write(token, baseUrl: Uri.parse('https://avsm.example.edu:8081'));
    // Rebuild the card so it reads the store again.
    t.navigation.goTo(AppDestination.overview);
    await pumpFrames(tester, 2);
    t.navigation.goTo(AppDestination.dataSource);
    await pumpFrames(tester, 3);
    expect(tester.widget<TextFormField>(field('API token')).controller!.text, isEmpty);
    expect(find.textContaining('The remembered token is for https://avsm.example.edu:8081'), findsOneWidget);
    expect(tokens, isEmpty);
  });

  testWidgets('the insecure warning names only the supported TLS setup', (tester) async {
    await pumpApp(tester, size: tallSize);
    await tester.enterText(field('API address'), 'http://10.20.30.40:8081');
    await tester.pump();
    expect(find.textContaining('TLS reverse proxy'), findsOneWidget);
    expect(find.textContaining('ANALYTICS_TLS_CERT_FILE'), findsNothing);
  });

  test('remember-token wording matches where the token is kept', () {
    final (webTitle, webDetail) = rememberTokenWording(isWeb: true);
    expect(webTitle, contains('browser tab'));
    expect(webDetail, contains('Kept for this browser tab session'));
    expect(webDetail, isNot(contains('profile')));
    final (desktopTitle, desktopDetail) = rememberTokenWording(isWeb: false);
    expect(desktopTitle, 'Remember token on this computer');
    expect(desktopDetail, contains('credential store'));
  });

  test('settings token status matches where the token is kept', () {
    expect(rememberedTokenStatus(remember: false, isWeb: true), 'API tokens are not saved.');
    expect(rememberedTokenStatus(remember: false, isWeb: false), 'API tokens are not saved.');
    final web = rememberedTokenStatus(remember: true, isWeb: true);
    expect(web, contains('browser tab session'));
    expect(web, isNot(contains('credential store')));
    expect(rememberedTokenStatus(remember: true, isWeb: false), contains('credential store'));
    expect(aboutTokenStorage(isWeb: true), contains("tab's session storage"));
    expect(aboutTokenStorage(isWeb: true), isNot(contains('credential store')));
    expect(aboutTokenStorage(isWeb: false), contains('credential store'));
  });

  group('large downloads', () {
    Future<TestApp> fillForm(WidgetTester tester, MockClient server) async {
      final t = await pumpApp(tester, size: tallSize, httpClient: server);
      await tester.enterText(field('API address'), 'https://avsm.example.edu');
      await tester.enterText(field('API token'), token);
      return t;
    }

    testWidgets('asks first, suggests narrowing and returns focus to the period', (tester) async {
      final requests = <Uri>[];
      final t = await fillForm(tester, fakeServer(eventCount: 2500000, requests: requests));
      await tester.tap(button('Load data'));
      await settleWork(tester, t);
      expect(find.text('Large download'), findsOneWidget);
      expect(find.textContaining('about 2,500,000 events'), findsOneWidget);
      expect(find.textContaining('shorter period or fewer rooms'), findsOneWidget);
      expect(requests.map((u) => u.pathSegments.last), ['clients'], reason: 'nothing downloaded yet');
      // The safe choice has focus.
      final cancel = find.ancestor(of: find.text('Change period or rooms'), matching: find.byType(TextButton));
      expect(Focus.of(tester.element(find.text('Change period or rooms'))).hasFocus, isTrue);
      await expectMeetsA11yGuidelines(tester);

      await tester.tap(cancel);
      await pumpFrames(tester, 3);
      expect(find.text('Large download'), findsNothing);
      expect(t.app.hasData, isFalse);
      expect(t.app.isLoading, isFalse);
      expect(requests.map((u) => u.pathSegments.last), ['clients']);
      final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '30 days'));
      expect(chip.focusNode?.hasFocus, isTrue, reason: 'focus returns to the selected period');
    });

    testWidgets('the dialog fits a narrow window at 200% text', (tester) async {
      await pumpApp(tester, size: narrowSize, textScale: 2.0);
      final context = tester.element(find.byType(DataSourceScreen));
      final result = showLargeDownloadDialog(context: context, events: 2500000, period: '365 days', rooms: 12);
      await pumpFrames(tester, 3);
      expect(find.text('Large download'), findsOneWidget);
      expect(find.textContaining('12 selected rooms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(button('Download anyway'));
      await pumpFrames(tester, 2);
      final rect = tester.getRect(button('Download anyway'));
      expect(rect.right, lessThanOrEqualTo(narrowSize.width));
      expect(rect.bottom, lessThanOrEqualTo(narrowSize.height));
      await tester.tap(button('Download anyway'));
      await pumpFrames(tester, 2);
      expect(await result, isTrue);
    });

    testWidgets('Escape cancels the dialog', (tester) async {
      final t = await fillForm(tester, fakeServer(eventCount: 2500000));
      await tester.tap(button('Load data'));
      await settleWork(tester, t);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester, 3);
      expect(find.text('Large download'), findsNothing);
      expect(t.app.hasData, isFalse);
    });

    testWidgets('Download anyway loads the data', (tester) async {
      final t = await fillForm(tester, fakeServer(eventCount: 2500000));
      await tester.tap(button('Load data'));
      await settleWork(tester, t);
      await tester.tap(button('Download anyway'));
      await settleWork(tester, t);
      expect(t.app.hasData, isTrue);
    });

    testWidgets('small downloads start without asking', (tester) async {
      final requests = <Uri>[];
      final t = await fillForm(tester, fakeServer(requests: requests));
      await tester.tap(button('Load data'));
      await settleWork(tester, t);
      expect(find.text('Large download'), findsNothing);
      expect(t.app.hasData, isTrue);
      expect(requests.first.pathSegments.last, 'clients');
    });

    testWidgets('counts from Test connection are reused', (tester) async {
      final requests = <Uri>[];
      final t = await fillForm(tester, fakeServer(eventCount: 2500000, requests: requests));
      await tester.tap(button('Test connection'));
      await pumpFrames(tester, 5);
      expect(find.textContaining('2,500,000 events'), findsOneWidget);
      requests.clear();
      await tester.tap(button('Load data'));
      await pumpFrames(tester, 3);
      expect(find.text('Large download'), findsOneWidget);
      expect(requests, isEmpty, reason: 'no second size check');
      await tester.tap(button('Change period or rooms'));
      await pumpFrames(tester, 3);
      expect(t.app.hasData, isFalse);
    });
  });

  testWidgets('import notes such as ambiguous dates are shown on the page', (tester) async {
    final t = await pumpApp(tester, size: tallSize);
    await t.app.loadCsvBytes(
        Uint8List.fromList(utf8.encode('clientname,event_timestamp,metric,action\n'
            'A_1,10/11/2026 23:31,pc,Started\n'
            'A_1,03/04/2026 08:00,hdmi,Started\n')),
        'resaved.csv');
    await settleWork(tester, t);
    t.navigation.goTo(AppDestination.dataSource);
    await settleWork(tester, t);
    expect(find.text('Notes about this data'), findsOneWidget);
    expect(find.textContaining('NN/NN/YYYY'), findsOneWidget);
    final handle = tester.ensureSemantics();
    final heading = tester.getSemantics(find.text('Notes about this data')).getSemanticsData();
    expect(heading.flagsCollection.isHeader, isTrue);
    expect(heading.headingLevel, 3);
    handle.dispose();
    await expectMeetsA11yGuidelines(tester);
  });

  test('data notes list import warnings first, without duplicates', () {
    final ds = Dataset(
      events: const [],
      heartbeats: const [],
      rangeStart: DateTime.utc(2026),
      rangeEnd: DateTime.utc(2026, 2),
      origin: DatasetOrigin.csv,
      description: 'x.csv',
      warnings: const ['Dates were read day first.'],
    );
    expect(dataNotes(ds, null), ['Dates were read day first.']);
    expect(dataNotes(ds, ['Dates were read day first.', 'Invalid pattern.']),
        ['Dates were read day first.', 'Invalid pattern.']);
  });
}
