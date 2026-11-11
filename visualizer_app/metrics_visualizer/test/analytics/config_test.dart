import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

void main() {
  test('BusinessHours defaults and membership', () {
    const b = BusinessHours();
    expect(b.contains(DateTime.monday, 7), isTrue);
    expect(b.contains(DateTime.monday, 21), isTrue);
    expect(b.contains(DateTime.monday, 22), isFalse);
    expect(b.contains(DateTime.monday, 6), isFalse);
    expect(b.contains(DateTime.saturday, 12), isFalse);
    expect(b.hoursPerWeek, 75);
    expect(const BusinessHours(startHour: 10, endHour: 9).hoursPerWeek, 0);
  });

  test('AnalysisConfig JSON round trip keeps business hours', () {
    const cfg = AnalysisConfig(
      useLocalTime: false,
      businessHours: BusinessHours(
        weekdays: [1, 2, 3],
        startHour: 8,
        endHour: 18,
      ),
    );
    final back = AnalysisConfig.fromJson(
      (jsonDecode(jsonEncode(cfg.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.useLocalTime, isFalse);
    expect(back.businessHours.weekdays, [1, 2, 3]);
    expect(back.businessHours.startHour, 8);
    expect(back.businessHours.endHour, 18);
    expect(back.thresholds.buttonMashCount, cfg.thresholds.buttonMashCount);
  });

  test('older JSON without business hours still loads', () {
    final old = const AnalysisConfig().toJson()..remove('businessHours');
    final back = AnalysisConfig.fromJson(old);
    expect(back.businessHours.hoursPerWeek, 75);
  });

  test('copyWith replaces business hours only', () {
    final c = const AnalysisConfig().copyWith(
      businessHours: const BusinessHours(startHour: 9),
    );
    expect(c.businessHours.startHour, 9);
    expect(c.maxSessionLength, const Duration(hours: 16));
  });

  test('navigation pattern skips the power-on and backlight buttons', () {
    final nav = RegExp(
      ClassifierConfig.defaultNavigationButtonPattern,
      caseSensitive: false,
    );
    for (final yes in [
      'Btn_Audio_Nav',
      'Btn_Home_Page',
      'Btn_Back',
      'Btn_Back_Main',
      'Btn_Settings_Menu',
      'Btn_Help_Tab',
      'Btn_Home',
      'Btn_Exit',
    ]) {
      expect(nav.hasMatch(yes), isTrue, reason: yes);
    }
    for (final no in [
      'Btn_Start_Page',
      'Btn_Backlight',
      'Btn_Std_Backlight',
      'Btn_Volume_Up',
    ]) {
      expect(nav.hasMatch(no), isFalse, reason: no);
    }
  });

  test('a saved copy of the old navigation default is upgraded', () {
    final json = const AnalysisConfig().toJson();
    (json['classifier'] as Map<String, Object?>)['navigationButtonPattern'] =
        ClassifierConfig.previousNavigationButtonPattern;
    final back = AnalysisConfig.fromJson(
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>(),
    );
    expect(
      back.classifier.navigationButtonPattern,
      ClassifierConfig.defaultNavigationButtonPattern,
    );
    final custom = ClassifierConfig.fromJson({'navigationButtonPattern': 'X'});
    expect(custom.navigationButtonPattern, 'X');
  });

  test('device type overrides round-trip and apply case-insensitively', () {
    const cfg = AnalysisConfig(
      deviceTypeOverrides: {'BSS_112/Projector_1': 'display'},
    );
    final back = AnalysisConfig.fromJson(
      (jsonDecode(jsonEncode(cfg.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.deviceTypeOverrides, {'BSS_112/Projector_1': 'display'});
    expect(back.deviceTypeFor('bss_112', 'projector_1', 'PROJECTOR'), 'DISPLAY');
    expect(back.deviceTypeFor('BSS_112', 'Projector_2', 'PROJECTOR'),
        'PROJECTOR');
    expect(
      AnalysisConfig.fromJson(const AnalysisConfig().toJson()
            ..remove('deviceTypeOverrides'))
          .deviceTypeOverrides,
      isEmpty,
    );
  });
}
