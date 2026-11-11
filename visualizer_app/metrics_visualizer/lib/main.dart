import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app.dart';
import 'state/settings_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Flutter web builds the accessibility tree lazily; keep it always on so
    // screen readers work without the user first finding the hidden
    // "Enable accessibility" button.
    SemanticsBinding.instance.ensureSemantics();
  }
  final settings = await SettingsState.load();
  runApp(MetricsVisualizerApp(settings: settings));
}
