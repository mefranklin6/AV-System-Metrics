import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/data/api_client.dart';
import 'package:metrics_visualizer/data/csv_importer.dart' show recommendedExportCommand;

/// Checks platform files that tests cannot exercise at run time, so a
/// supported platform does not silently lose a data source.
void main() {
  group('macOS sandbox entitlements', () {
    for (final name in ['DebugProfile', 'Release']) {
      test('$name allows the API, CSV import and nothing more than needed', () {
        final plist = File('macos/Runner/$name.entitlements').readAsStringSync();
        bool enabled(String key) => RegExp('<key>${RegExp.escape(key)}</key>' r'\s*<true/>').hasMatch(plist);
        expect(enabled('com.apple.security.app-sandbox'), isTrue);
        // Outbound HTTPS to the Analytics API.
        expect(enabled('com.apple.security.network.client'), isTrue);
        // The file picker returns null without this.
        expect(enabled('com.apple.security.files.user-selected.read-only'), isTrue);
        // The app never writes user-chosen files.
        expect(plist, isNot(contains('files.user-selected.read-write')));
        // Not needed: the token store uses the login keychain (see SecureTokenStore.macOsOptions).
        expect(plist, isNot(contains('keychain-access-groups')));
      });
    }
  });

  group('web build stays on its own site', () {
    test('the bootstrap loads CanvasKit and fallback fonts from the hosting site', () {
      final js = File('web/flutter_bootstrap.js').readAsStringSync();
      expect(js, contains('{{flutter_js}}'));
      expect(js, contains('{{flutter_build_config}}'));
      expect(js, contains("canvasKitBaseUrl: 'canvaskit/'"));
      expect(js, contains("fontFallbackBaseUrl: 'fonts/fallback/'"));
      expect(js, isNot(contains('https://')));
    });

    test('Roboto is bundled, so CanvasKit does not download it from Google', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- family: Roboto'));
      for (final file in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Italic.ttf']) {
        expect(pubspec, contains('fonts/Roboto/$file'));
        expect(File('fonts/Roboto/$file').existsSync(), isTrue, reason: file);
      }
      expect(File('fonts/Roboto/LICENSE.txt').existsSync(), isTrue);
    });

    test('documented and CI web builds turn off the CDN', () {
      final readme = File('README.md').readAsStringSync();
      final ci = File('../../.github/workflows/visualizer-app.yml').readAsStringSync();
      final release = File('../../.github/workflows/visualizer-app-release.yml').readAsStringSync();
      for (final text in [readme, ci, release]) {
        expect(text, contains('flutter build web --release --no-web-resources-cdn'));
        expect(RegExp(r'flutter build web(?! --release --no-web-resources-cdn)').hasMatch(text), isFalse);
      }
    });
  });

  test('the API client limits match the Analytics API specification', () {
    final spec = File('../../Self_Hosted/analytics_api/openapi.yaml').readAsStringSync();
    final flat = spec.split(RegExp(r'\s+')).join(' ');
    expect(flat, contains('the range may span at most ${AnalyticsApiClient.maxQuerySpan.inDays} days'));
    expect(flat,
        contains('With `bucket=hour` the range may span at most ${AnalyticsApiClient.maxHourlyHeartbeatSpan.inDays} days'));
  });

  test('the operator and Visualizer READMEs show the same export command as the app', () {
    for (final path in ['README.md', '../../Self_Hosted/README.md']) {
      expect(File(path).readAsStringSync(), contains(recommendedExportCommand), reason: path);
    }
  });
}
