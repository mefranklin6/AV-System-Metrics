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
  });

  group('parsed fields', () {
    final c = MetricClassifier();

    test('devices', () {
      final p = c.classify('Projector_2', 'Stopped');
      expect(p.deviceType, 'PROJECTOR');
      expect(p.deviceNumber, 2);
      expect(p.deviceId, 'Projector_2');
      expect(p.isStop, isTrue);
      final cam = c.classify('Camera_1', 'Started');
      expect(cam.deviceType, 'CAMERA');
      expect(cam.isStart, isTrue);
      expect(c.classify('Display_3', 'Started').deviceType, 'DISPLAY');
      expect(c.classify('Projector_1', 'Trace').category, EventCategory.other);
    });

    test('volume', () {
      final v = c.classify('Program Audio Volume', 'Level 50 (Device -20.0)');
      expect(v.volumeLevel, 50);
      expect(v.volumeDb, -20.0);
      expect(v.volumeName, 'Program Audio Volume');
      final m = c.classify('Microphone Volume', 'Level 7');
      expect(m.category, EventCategory.volume);
      expect(m.volumeLevel, 7);
      expect(m.volumeDb, isNull);
    });

    test('ui traces', () {
      final nav = c.classify('Btn_Inst_Cam_Nav Pressed', 'Trace');
      expect(nav.controlName, 'Btn_Inst_Cam_Nav');
      expect(nav.uiEvent, UiEventKind.pressed);
      expect(nav.isNavigation, isTrue);
      expect(nav.isPress, isTrue);
      final tap = c.classify('Btn_Volume_Up Tapped', 'Trace');
      expect(tap.uiEvent, UiEventKind.tapped);
      expect(tap.isPress, isFalse);
      expect(tap.isRepeatable, isTrue);
      expect(tap.isNavigation, isFalse);
      final mute = c.classify('Btn_Volume_Mute Pressed', 'Trace');
      expect(mute.isRepeatable, isFalse);
      final sl = c.classify('Sldr_Volume Released', 'Trace');
      expect(sl.isSlider, isTrue);
      expect(sl.uiEvent, UiEventKind.released);
      expect(c.classify('Btn_Back Held', 'Trace').uiEvent, UiEventKind.held);
      expect(c.classify('Btn_Back Repeated', 'Trace').isNavigation, isTrue);
      expect(c.classify('Btn_Home_Page Pressed', 'Trace').isNavigation, isTrue);
      expect(c.classify('Hello World!', 'Trace').category, EventCategory.other);
    });

    test('system power and lifecycle', () {
      PowerSource? src(String m, String a) => c.classify(m, a).powerSource;
      expect(src('System - User', 'Started'), PowerSource.user);
      expect(src('System - Inactivity', 'Stopped'), PowerSource.inactivity);
      expect(src('System - Scheduled', 'Stopped'), PowerSource.scheduled);
      expect(src('System - Restore', 'Started'), PowerSource.restore);
      expect(src('System - GVE', 'Stopped'), PowerSource.remote);
      expect(src('System - User Reset', 'Started'), PowerSource.userReset);
      expect(src('System - Something', 'Started'), PowerSource.unknown);
      LifecycleKind? lc(String m, String a) => c.classify(m, a).lifecycle;
      expect(lc('Initialize', 'Started'), LifecycleKind.initializeStarted);
      expect(lc('Initialize', 'Stopped'), LifecycleKind.initializeStopped);
      expect(
        lc('System Startup Sequence Complete', 'Trace'),
        LifecycleKind.startupComplete,
      );
      expect(
        lc('System Shutdown Sequence Complete', 'Trace'),
        LifecycleKind.shutdownComplete,
      );
      expect(lc('System Restored', 'Trace'), LifecycleKind.restored);
    });

    test('inputs are normalised with display labels', () {
      final pc = c.classify('pc', 'Started');
      expect(pc.inputKey, 'pc');
      expect(pc.inputLabel, 'PC');
      expect(c.classify('VGA', 'Started').inputKey, 'vga');
      expect(c.classify('doc_cam', 'Started').inputLabel, 'Document Camera');
      expect(c.classify('Custom_Input', 'Started').inputLabel, 'Custom Input');
      final st = c.classify('station_12_laptop', 'Started');
      expect(st.category, EventCategory.input);
      expect(st.inputLabel, 'Station 12 Laptop');
      expect(c.classify('blu_ray', 'Started').inputLabel, 'Blu-ray');
      expect(c.classify('pc', 'Stopped').isStop, isTrue);
      expect(
        c.classify('not_an_input', 'Started').category,
        EventCategory.other,
      );
      expect(MetricClassifier.inputLabelFor('my_new_input'), 'My New Input');
    });

    test('help, mutes, share, connections, custom', () {
      expect(c.classify('Help', 'Started').category, EventCategory.help);
      final mute = c.classify('VoiceLift In-Room Muted', 'Started');
      expect(mute.category, EventCategory.mute);
      expect(mute.muteName, 'VoiceLift In-Room Muted');
      final share = c.classify('NAV Share - Station 4', 'Share');
      expect(share.category, EventCategory.share);
      expect(share.shareStation, 'Station 4');
      final conn = c.classify('Projector_1', 'Connected');
      expect(conn.category, EventCategory.connection);
      expect(conn.connected, isTrue);
      expect(conn.connectionTarget, 'Projector_1');
      expect(c.classify('Switcher', 'Disconnected').connected, isFalse);
      expect(
        c.classify('Anything', 'SomeCustomAction').category,
        EventCategory.other,
      );
    });

    test('buildings are upper-cased prefixes', () {
      expect(c.buildingOf('BSS_245'), 'BSS');
      expect(c.buildingOf('Holt_171'), 'HOLT');
      expect(c.buildingOf('HOLT_155'), 'HOLT');
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
      ),
    );
    expect(c.warnings, hasLength(2));
    expect(c.classify('Projector_1', 'Started').category, EventCategory.device);
    expect(c.classify('Btn_Back Pressed', 'Trace').isNavigation, isTrue);
  });

  test('custom input names and device pattern are honoured', () {
    final c = MetricClassifier(
      const ClassifierConfig(
        inputNames: ['apple_tv'],
        devicePattern: r'^(Amp)_(\d+)$',
      ),
    );
    expect(c.classify('Apple_TV', 'Started').inputKey, 'apple_tv');
    expect(c.classify('pc', 'Started').category, EventCategory.other);
    final amp = c.classify('Amp_3', 'Started');
    expect(amp.deviceType, 'AMP');
    expect(amp.deviceNumber, 3);
  });
}
