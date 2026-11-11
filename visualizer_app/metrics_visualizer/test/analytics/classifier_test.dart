import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

void main() {
  group('classifier on every metric form in the production sample', () {
    final classifier = MetricClassifier();
    final rows = readProductionSample();

    // Expected category of every distinct (metric, action) pair in the
    // fixture. A new form in the fixture fails the coverage test below.
    const expected = <String, EventCategory>{
      'Ok|Heartbeat': EventCategory.heartbeat,
      'System Shutdown Sequence Complete|Trace': EventCategory.lifecycle,
      'System Startup Sequence Complete|Trace': EventCategory.lifecycle,
      'Program Audio Volume|Level 50 (Device -20.0)': EventCategory.volume,
      'Program Audio Volume|Level 63 (Device -7.3)': EventCategory.volume,
      'Program Audio Volume|Level 55 (Device -23.5)': EventCategory.volume,
      'Program Audio Volume|Level 31 (Device -18.8)': EventCategory.volume,
      'Projector_1|Stopped': EventCategory.device,
      'Projector_1|Started': EventCategory.device,
      'Projector_2|Stopped': EventCategory.device,
      'Camera_1|Started': EventCategory.device,
      'Camera_2|Started': EventCategory.device,
      'Camera_2|Stopped': EventCategory.device,
      'Microphone Muted|Stopped': EventCategory.mute,
      'Microphone Muted|Started': EventCategory.mute,
      'Ceiling Microphones Muted|Stopped': EventCategory.mute,
      'Ceiling Microphones Muted|Started': EventCategory.mute,
      'Program Audio Muted|Stopped': EventCategory.mute,
      'Program Audio Muted|Started': EventCategory.mute,
      'System - User|Started': EventCategory.systemPower,
      'System - User|Stopped': EventCategory.systemPower,
      'System - Inactivity|Stopped': EventCategory.systemPower,
      'pc|Started': EventCategory.input,
      'Btn_Video_Mute Pressed|Trace': EventCategory.uiTrace,
      'Btn_Volume_Up Tapped|Trace': EventCategory.uiTrace,
      'Btn_Volume_Up Pressed|Trace': EventCategory.uiTrace,
      'Btn_Volume_Down Tapped|Trace': EventCategory.uiTrace,
      'Btn_Volume_Down Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Right Pressed|Trace': EventCategory.uiTrace,
      'Btn_Volume_Mute Pressed|Trace': EventCategory.uiTrace,
      'Btn_Inst_Power_On Pressed|Trace': EventCategory.uiTrace,
      'Btn_Inst_Cam_Nav Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Preset_1 Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Manual_Trk Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Left Pressed|Trace': EventCategory.uiTrace,
      'Sldr_Volume Released|Trace': EventCategory.uiTrace,
      'Sldr_Volume Pressed|Trace': EventCategory.uiTrace,
      'Btn_Start_Page Pressed|Trace': EventCategory.uiTrace,
      'Btn_Presenter_Mode Pressed|Trace': EventCategory.uiTrace,
      'Btn_Power_Down_Confirm Pressed|Trace': EventCategory.uiTrace,
      'Btn_Inst_Power_Offline Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Reset Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Preset_3 Pressed|Trace': EventCategory.uiTrace,
      'Btn_Cam_Presenter_Trk Pressed|Trace': EventCategory.uiTrace,
    };

    test('fixture is non-trivial', () {
      expect(rows.length, greaterThan(80));
    });

    test('every distinct form is covered and classified as expected', () {
      final seen = <String>{};
      for (final r in rows) {
        final key = '${r['metric']}|${r['action']}';
        seen.add(key);
        expect(
          expected.containsKey(key),
          isTrue,
          reason: 'unexpected form in fixture: $key',
        );
        expect(
          classifier.classify(r['metric']!, r['action']!).category,
          expected[key],
          reason: key,
        );
      }
      expect(seen, containsAll(expected.keys));
    });

    test('nothing in the fixture is unclassified', () {
      for (final r in rows) {
        expect(
          classifier.classify(r['metric']!, r['action']!).category,
          isNot(EventCategory.other),
          reason: '${r['metric']} ${r['action']}',
        );
      }
    });

    test('the psql fixture classifies the same way', () {
      final lines = readProductionPsqlRows();
      expect(lines, isNotEmpty);
      for (final (metric, action) in lines) {
        expect(
          classifier.classify(metric, action).category,
          isNot(EventCategory.other),
          reason: '$metric $action',
        );
      }
    });
  });

  // Every row of the "Event conventions" table in Implementation_Guide.md,
  // recommended and also-recognized forms.
  group('Implementation guide: event conventions', () {
    final c = MetricClassifier();
    ClassifiedMetric k(String metric, String action) =>
        c.classify(metric, action);

    test('room system powered on / off', () {
      for (final metric in [
        'System Power',
        'System',
        'System Power - User',
        'System - User',
        'system power - schedule',
        '  System -Inactivity ',
      ]) {
        for (final (action, start) in [('Started', true), ('Stopped', false)]) {
          final m = k(metric, action);
          expect(m.category, EventCategory.systemPower, reason: metric);
          expect(m.isStart, start, reason: '$metric $action');
          expect(m.isStop, !start, reason: '$metric $action');
        }
      }
      expect(k('System Power', 'Started').powerSource, PowerSource.unknown);
      expect(k('System Power', 'Started').powerReason, isNull);
      expect(k('System Power', 'Trace').category, EventCategory.other);
      expect(k('Systems - User', 'Started').category, isNot(EventCategory.systemPower));
    });

    test('power reasons: five groups with synonyms, others verbatim', () {
      PowerSource? src(String m) => k(m, 'Stopped').powerSource;
      expect(src('System Power - User'), PowerSource.user);
      expect(src('System Power - Manual'), PowerSource.user);
      expect(src('System Power - Schedule'), PowerSource.scheduled);
      expect(src('System - Scheduled'), PowerSource.scheduled);
      expect(src('System Power - Inactivity'), PowerSource.inactivity);
      expect(src('System Power - Idle'), PowerSource.inactivity);
      expect(src('System Power - Timeout'), PowerSource.inactivity);
      expect(src('System Power - Remote'), PowerSource.remote);
      expect(src('System Power - Restore'), PowerSource.restore);
      expect(src('System Power - Recovery'), PowerSource.restore);
      final gve = k('System - GVE', 'Started');
      expect(gve.powerSource, PowerSource.other);
      expect(gve.powerReason, 'GVE');
      final reset = k('System - User Reset', 'Started');
      expect(reset.powerSource, PowerSource.other);
      expect(reset.powerReason, 'User Reset');
    });

    test('source routed to the main display(s)', () {
      for (final (metric, name) in [
        ('Source - HDMI 1', 'HDMI 1'),
        ('Source: Lectern PC', 'Lectern PC'),
        ('Source Select: HDMI 1', 'HDMI 1'),
        ('Input - Document Camera', 'Document Camera'),
        ('Input: Wireless', 'Wireless'),
        ('source-hdmi 1', 'hdmi 1'),
        ('Source - Display 2 - HDMI 1', 'Display 2 - HDMI 1'),
      ]) {
        for (final action in ['Started', 'Trace']) {
          final m = k(metric, action);
          expect(m.category, EventCategory.input, reason: '$metric $action');
          expect(m.isSourceSelection, isTrue, reason: '$metric $action');
          expect(m.inputLabel, name, reason: metric);
          expect(m.inputKey, name.toLowerCase(), reason: metric);
        }
        final stop = k(metric, 'Stopped');
        expect(stop.category, EventCategory.input);
        expect(stop.isSourceSelection, isFalse);
        expect(stop.isStop, isTrue);
      }
      final bare = k('hdmi', 'Started');
      expect(bare.category, EventCategory.input);
      expect(bare.inputLabel, 'HDMI');
      expect(k('doc_cam', 'Started').inputLabel, 'Document Camera');
      // The same source name merges across naming styles.
      expect(
        k('doc_cam', 'Started').inputKey,
        k('Source - Document Camera', 'Started').inputKey,
      );
    });

    test('device powered on / off', () {
      for (final (metric, type, n) in [
        ('Projector 1', 'PROJECTOR', 1),
        ('Projector_1', 'PROJECTOR', 1),
        ('Display 1 Power', 'DISPLAY', 1),
        ('Projector Power', 'PROJECTOR', null),
        ('Laser Projector 2', 'LASER PROJECTOR', 2),
        ('Camera_12', 'CAMERA', 12),
      ]) {
        final on = k(metric, 'Started');
        expect(on.category, EventCategory.device, reason: metric);
        expect(on.deviceType, type, reason: metric);
        expect(on.deviceNumber, n, reason: metric);
        expect(on.deviceId, metric);
        expect(k(metric, 'Stopped').isStop, isTrue);
      }
      expect(k('Projector 1', 'Trace').category, EventCategory.other);
    });

    test('device communication up / down', () {
      final up = k('Projector 1', 'Connected');
      expect(up.category, EventCategory.connection);
      expect(up.connected, isTrue);
      expect(up.connectionTarget, 'Projector 1');
      expect(k('Any metric at all', 'Disconnected').connected, isFalse);
    });

    test('control program started', () {
      for (final metric in [
        'Program Start',
        'Initialize',
        'Program Started',
        'Processor Boot',
      ]) {
        for (final action in ['Started', 'Trace']) {
          final m = k(metric, action);
          expect(m.category, EventCategory.lifecycle, reason: '$metric $action');
          expect(m.lifecycle, LifecycleKind.programStart, reason: metric);
        }
      }
      expect(
        k('Initialize', 'Stopped').lifecycle,
        LifecycleKind.programStartStopped,
      );
    });

    test('startup / shutdown complete (optional)', () {
      for (final m in ['System Startup Complete', 'System Startup Sequence Complete']) {
        expect(k(m, 'Trace').lifecycle, LifecycleKind.startupComplete);
      }
      for (final m in ['System Shutdown Complete', 'System Shutdown Sequence Complete']) {
        expect(k(m, 'Trace').lifecycle, LifecycleKind.shutdownComplete);
      }
    });

    test('touch-panel or keypad control used; only Pressed is a press', () {
      for (final (word, kind) in [
        ('Pressed', UiEventKind.pressed),
        ('Released', UiEventKind.released),
        ('Tapped', UiEventKind.tapped),
        ('Held', UiEventKind.held),
        ('Repeated', UiEventKind.repeated),
      ]) {
        final m = k('Camera Preset 2 $word', 'Trace');
        expect(m.category, EventCategory.uiTrace);
        expect(m.controlName, 'Camera Preset 2');
        expect(m.uiEvent, kind);
        expect(m.isPress, kind == UiEventKind.pressed);
      }
      expect(k('Hello World!', 'Trace').category, EventCategory.other);
    });

    test('audio muted / unmuted', () {
      for (final (metric, action, start) in [
        ('Program Audio Mute', 'Started', true),
        ('Program Audio Mute', 'Stopped', false),
        ('Program Audio Muted', 'Started', true),
        ('Program Audio', 'Muted', true),
        ('Program Audio', 'Unmuted', false),
      ]) {
        final m = k(metric, action);
        expect(m.category, EventCategory.mute, reason: '$metric $action');
        expect(m.muteName, 'Program Audio', reason: '$metric $action');
        expect(m.isStart, start);
      }
    });

    test('volume set', () {
      final v = k('Program Audio Volume', 'Level 40');
      expect(v.category, EventCategory.volume);
      expect(v.volumeLevel, 40);
      expect(v.volumeDb, isNull);
      final legacy = k('Program Audio Volume', 'Level 31 (Device -18.8)');
      expect(legacy.volumeLevel, 31);
      expect(legacy.volumeDb, -18.8);
      expect(k('Mic Volume', 'Level 12 any text').volumeLevel, 12);
    });

    test('wireless share keeps the metric verbatim', () {
      final s = k('NAV Share - Station 4', 'Share');
      expect(s.category, EventCategory.share);
      expect(s.shareStation, 'NAV Share - Station 4');
      expect(k('Room 101 Wireless', 'Share').shareStation, 'Room 101 Wireless');
    });

    test('heartbeat', () {
      expect(k('Ok', 'Heartbeat').category, EventCategory.heartbeat);
    });

    test('anything else is kept as other', () {
      expect(k('Lights Scene 3', 'Trace').category, EventCategory.other);
      expect(k('Anything', 'SomeCustomAction').category, EventCategory.other);
    });
  });

  group('Developer Guide examples', () {
    final c = MetricClassifier();

    test('System Power, Source Select, Display Power, Microphone Mute', () {
      expect(c.classify('System Power', 'Started').category, EventCategory.systemPower);
      final src = c.classify('Source Select: HDMI 1', 'Started');
      expect(src.category, EventCategory.input);
      expect(src.inputLabel, 'HDMI 1');
      final disp = c.classify('Display 1 Power', 'Started');
      expect(disp.category, EventCategory.device);
      expect(disp.deviceType, 'DISPLAY');
      final mic = c.classify('Microphone 1 Mute', 'Started');
      expect(mic.category, EventCategory.mute);
      expect(mic.muteName, 'Microphone 1');
      // custom("Muted", "Microphone 1"): action Muted, metric Microphone 1.
      final custom = c.classify('Microphone 1', 'Muted');
      expect(custom.category, EventCategory.mute);
      expect(custom.muteName, 'Microphone 1');
      expect(custom.isStart, isTrue);
    });
  });

  group('help-labelled events', () {
    final c = MetricClassifier();

    test('any action, word "help" anywhere in the metric', () {
      for (final (metric, action) in [
        ('Help', 'Started'),
        ('Help', 'Stopped'),
        ('Help Pressed', 'Trace'),
        ('Btn_Help Pressed', 'Trace'),
        ('Call For Help', 'Requested'),
        ('HELP-Button', 'Connected'),
      ]) {
        expect(
          c.classify(metric, action).category,
          EventCategory.help,
          reason: '$metric $action',
        );
      }
      final press = c.classify('Help Pressed', 'Trace');
      expect(press.controlName, 'Help');
      expect(press.isPress, isTrue);
      expect(c.classify('Helper Display', 'Trace').category, EventCategory.other);
      expect(c.classify('Btn_Helpful Pressed', 'Trace').category, EventCategory.uiTrace);
    });
  });

  group('control name patterns', () {
    final c = MetricClassifier();

    test('navigation: Nav, Navigation, Page, Menu, Tab, Back, Home parts', () {
      for (final name in [
        'Btn_Inst_Cam_Nav',
        'Btn_Nav_Display',
        'Navigation',
        'Camera Page',
        'Btn_Start_Page',
        'Main Menu',
        'Settings-Tab',
        'Back',
        'Btn_Back',
        'Home',
      ]) {
        expect(c.classify('$name Pressed', 'Trace').isNavigation, isTrue, reason: name);
      }
      for (final name in ['Btn_Backlight', 'Table Lights', 'Homeroom', 'Volume Up']) {
        expect(c.classify('$name Pressed', 'Trace').isNavigation, isFalse, reason: name);
      }
    });

    test('repeatable and slider controls by generic words', () {
      for (final name in [
        'Volume Up',
        'Btn_Volume_Down',
        'Vol Up',
        'Camera Zoom In',
        'Cam Pan Left',
        'Tilt',
        'Focus Out',
        'Btn_Cam_Right',
      ]) {
        expect(c.classify('$name Pressed', 'Trace').isRepeatable, isTrue, reason: name);
      }
      for (final name in ['Sldr_Volume', 'Mic Fader', 'Volume Slider']) {
        final m = c.classify('$name Pressed', 'Trace');
        expect(m.isSlider, isTrue, reason: name);
        expect(m.isRepeatable, isTrue, reason: name);
      }
      expect(c.classify('Video Mute Pressed', 'Trace').isRepeatable, isFalse);
      expect(c.classify('Btn_Upload Pressed', 'Trace').isRepeatable, isFalse);
    });
  });

  group('other parsed fields', () {
    final c = MetricClassifier();

    test('bare source names are normalised with display labels', () {
      final pc = c.classify('pc', 'Started');
      expect(pc.inputKey, 'pc');
      expect(pc.inputLabel, 'PC');
      expect(c.classify('VGA', 'Started').inputKey, 'vga');
      expect(c.classify('Custom_Input', 'Started').inputLabel, 'Custom Input');
      expect(c.classify('station_2_laptop', 'Started').inputLabel, 'Station 2 Laptop');
      expect(c.classify('blu_ray', 'Started').inputLabel, 'Blu-ray');
      expect(MetricClassifier.inputLabelFor('my_new_input'), 'My New Input');
    });

    test('buildings are upper-cased prefixes', () {
      expect(c.buildingOf('BSS_245'), 'BSS');
      expect(c.buildingOf('Holt_171'), 'HOLT');
      expect(c.buildingOf('SCI-101'), 'SCI');
      expect(c.buildingOf('AJH_125A'), 'AJH');
      expect(c.buildingOf('123'), '123');
    });

    test('AVSM-System events are admin lifecycle', () {
      final e = MetricEvent(
        clientName: 'AVSM-System',
        timestamp: monday,
        metric: 'Update Started',
        action: 'Trace',
      );
      expect(c.classifyEvent(e).category, EventCategory.adminLifecycle);
      expect(MetricClassifier.isAdminClient('avsm-system'), isTrue);
    });

    test('results are cached per distinct pair', () {
      expect(
        identical(c.classify('pc', 'Started'), c.classify('pc', 'Started')),
        isTrue,
      );
    });
  });

  test('invalid configured patterns fall back to defaults with a warning', () {
    final c = MetricClassifier(
      const ClassifierConfig(
        devicePattern: '(unclosed',
        navigationButtonPattern: '[bad',
        helpPattern: '(',
      ),
    );
    expect(c.warnings, hasLength(3));
    expect(c.classify('Projector_1', 'Started').category, EventCategory.device);
    expect(c.classify('Btn_Back Pressed', 'Trace').isNavigation, isTrue);
    expect(c.classify('Help', 'Started').category, EventCategory.help);
  });

  test('every name list and pattern is configurable', () {
    final c = MetricClassifier(
      const ClassifierConfig(
        systemPowerNames: ['Room Power'],
        powerReasonSynonyms: {
          'user': ['Panel'],
          'scheduled': ['Nightly'],
        },
        sourcePrefixes: ['Route >'],
        inputNames: ['apple_tv'],
        devicePattern: r'^(Amp)_(\d+)$',
        programStartNames: ['Boot'],
        startupCompleteNames: ['Ready'],
        shutdownCompleteNames: ['Asleep'],
        navigationButtonPattern: r'^Go ',
        repeatableControlPattern: r'Spin',
        helpPattern: r'assist',
      ),
    );
    expect(c.classify('Room Power - Panel', 'Started').powerSource, PowerSource.user);
    expect(c.classify('Room Power - Nightly', 'Stopped').powerSource, PowerSource.scheduled);
    expect(c.classify('Room Power - User', 'Stopped').powerSource, PowerSource.other);
    expect(c.classify('System Power', 'Started').category, isNot(EventCategory.systemPower));
    expect(c.classify('Route > Laptop', 'Started').inputLabel, 'Laptop');
    expect(c.classify('Source - HDMI', 'Started').category, isNot(EventCategory.input));
    expect(c.classify('Apple_TV', 'Started').inputKey, 'apple tv');
    expect(c.classify('pc', 'Started').category, EventCategory.other);
    final amp = c.classify('Amp_3', 'Started');
    expect(amp.deviceType, 'AMP');
    expect(amp.deviceNumber, 3);
    expect(c.classify('Projector 1', 'Started').category, EventCategory.other);
    expect(c.classify('Boot', 'Trace').lifecycle, LifecycleKind.programStart);
    expect(c.classify('Ready', 'Trace').lifecycle, LifecycleKind.startupComplete);
    expect(c.classify('Asleep', 'Trace').lifecycle, LifecycleKind.shutdownComplete);
    expect(c.classify('Go Home Pressed', 'Trace').isNavigation, isTrue);
    expect(c.classify('Back Pressed', 'Trace').isNavigation, isFalse);
    expect(c.classify('Spin Pressed', 'Trace').isRepeatable, isTrue);
    expect(c.classify('Assist Pressed', 'Trace').category, EventCategory.help);
    expect(c.classify('Help', 'Started').category, isNot(EventCategory.help));
  });
}
