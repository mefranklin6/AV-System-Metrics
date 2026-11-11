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

  test('default navigation pattern matches whole parts only', () {
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
      'Btn_Start_Page',
      'Camera Page',
      'Main-Menu',
      'Navigation',
    ]) {
      expect(nav.hasMatch(yes), isTrue, reason: yes);
    }
    for (final no in [
      'Btn_Backlight',
      'Btn_Std_Backlight',
      'Btn_Volume_Up',
      'Btn_Exit',
      'Tablet',
    ]) {
      expect(nav.hasMatch(no), isFalse, reason: no);
    }
  });

  test('saved copies of earlier default patterns are upgraded', () {
    for (final old in ClassifierConfig.previousNavigationButtonPatterns) {
      final json = const AnalysisConfig().toJson();
      (json['classifier'] as Map<String, Object?>)['navigationButtonPattern'] =
          old;
      final back = AnalysisConfig.fromJson(
        (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>(),
      );
      expect(
        back.classifier.navigationButtonPattern,
        ClassifierConfig.defaultNavigationButtonPattern,
      );
    }
    final dev = ClassifierConfig.fromJson({
      'devicePattern': ClassifierConfig.previousDevicePatterns.single,
    });
    expect(dev.devicePattern, ClassifierConfig.defaultDevicePattern);
    final custom = ClassifierConfig.fromJson({
      'navigationButtonPattern': 'X',
      'devicePattern': r'^(Amp)_\d+$',
    });
    expect(custom.navigationButtonPattern, 'X');
    expect(custom.devicePattern, r'^(Amp)_\d+$');
  });

  test('settings saved by the previous version load with new defaults', () {
    // The classifier keys an earlier version saved, nothing else.
    final old = <String, Object?>{
      'classifier': {
        'inputNames': ['pc', 'hdmi'],
        'devicePattern': ClassifierConfig.previousDevicePatterns.single,
        'navigationButtonPattern':
            ClassifierConfig.previousNavigationButtonPatterns.last,
        'buildingPattern': r'^([A-Za-z]+)[_\- ]?',
      },
      'thresholds': const IssueThresholds(buttonMashCount: 9).toJson(),
    };
    final back = AnalysisConfig.fromJson(
      (jsonDecode(jsonEncode(old)) as Map).cast<String, Object?>(),
    );
    final c = back.classifier;
    expect(c.inputNames, ['pc', 'hdmi']);
    expect(c.systemPowerNames, ClassifierConfig.defaultSystemPowerNames);
    expect(c.powerReasonSynonyms, ClassifierConfig.defaultPowerReasonSynonyms);
    expect(c.sourcePrefixes, ClassifierConfig.defaultSourcePrefixes);
    expect(c.programStartNames, ClassifierConfig.defaultProgramStartNames);
    expect(c.startupCompleteNames, ClassifierConfig.defaultStartupCompleteNames);
    expect(
      c.shutdownCompleteNames,
      ClassifierConfig.defaultShutdownCompleteNames,
    );
    expect(
      c.repeatableControlPattern,
      ClassifierConfig.defaultRepeatableControlPattern,
    );
    expect(c.helpPattern, ClassifierConfig.defaultHelpPattern);
    expect(c.devicePattern, ClassifierConfig.defaultDevicePattern);
    expect(back.thresholds.buttonMashCount, 9);
  });

  test('every classifier field round-trips through JSON and copyWith', () {
    const c = ClassifierConfig(
      systemPowerNames: ['Room Power'],
      powerReasonSynonyms: {
        'user': ['Panel'],
      },
      sourcePrefixes: ['Route >'],
      inputNames: ['apple_tv'],
      devicePattern: r'^(Amp)_\d+$',
      programStartNames: ['Boot'],
      startupCompleteNames: ['Ready'],
      shutdownCompleteNames: ['Asleep'],
      navigationButtonPattern: 'Go',
      repeatableControlPattern: 'Spin',
      helpPattern: 'assist',
      buildingPattern: r'^([A-Z]+)',
    );
    final back = ClassifierConfig.fromJson(
      (jsonDecode(jsonEncode(c.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.toJson(), c.toJson());
    final d = const ClassifierConfig().copyWith(
      systemPowerNames: c.systemPowerNames,
      powerReasonSynonyms: c.powerReasonSynonyms,
      sourcePrefixes: c.sourcePrefixes,
      inputNames: c.inputNames,
      devicePattern: c.devicePattern,
      programStartNames: c.programStartNames,
      startupCompleteNames: c.startupCompleteNames,
      shutdownCompleteNames: c.shutdownCompleteNames,
      navigationButtonPattern: c.navigationButtonPattern,
      repeatableControlPattern: c.repeatableControlPattern,
      helpPattern: c.helpPattern,
      buildingPattern: c.buildingPattern,
    );
    expect(d.toJson(), c.toJson());
    expect(const ClassifierConfig().copyWith().toJson(), const ClassifierConfig().toJson());
  });

  test('list problems: sources and reason groups', () {
    expect(const ClassifierConfig().listProblem(), isNull);
    expect(const ClassifierConfig(inputNames: []).listProblem(), isNull);
    expect(
      const ClassifierConfig(inputNames: [], sourcePrefixes: [' ']).listProblem(),
      isNotNull,
    );
    expect(
      const ClassifierConfig(powerReasonSynonyms: {'gve': ['GVE']}).listProblem(),
      isNotNull,
    );
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
