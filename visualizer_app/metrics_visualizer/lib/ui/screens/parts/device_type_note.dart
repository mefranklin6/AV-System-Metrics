// The "device types come from metric names" note shown on the Devices and
// Forecast screens, with a link to the device type overrides in Settings.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../state/navigation_state.dart';
import '../../../state/settings_state.dart';
import 'b_common.dart' show InfoCallout;

/// Explains that each device's type is read from its metric name, so a
/// device whose name does not say what it is (a flat panel logged as a
/// projector, for example) is grouped and forecast as the logged type unless
/// a device type override says otherwise.
class DeviceTypeNote extends StatelessWidget {
  const DeviceTypeNote({super.key});

  /// Visible title, also the callout's heading.
  static const String title = 'Device types come from metric names';

  /// Label of the button that opens the overrides in Settings.
  static const String buttonLabel = 'Set device types in Settings';

  @override
  Widget build(BuildContext context) {
    final overrides = context.select<SettingsState, int>((s) => s.analysisConfig.deviceTypeOverrides.length);
    final applied = overrides == 0
        ? 'No device type overrides are set.'
        : '${overrides == 1 ? '1 device type override is' : '$overrides device type overrides are'} applied.';
    return InfoCallout(
      icon: Icons.tv_outlined,
      title: title,
      message: 'Each device is grouped by the type in its metric name (the text before the device number, so '
          '"Projector 1" is a projector) and forecast with that type\'s rated life. If a program logs a '
          'device under a name that does not say what it is, set its real type under Device type '
          'overrides in Settings. $applied',
      actions: [
        OutlinedButton.icon(
          onPressed: () => context.read<NavigationState>().openSettings(SettingsSection.deviceTypeOverrides),
          icon: const Icon(Icons.tune),
          label: const Text(buttonLabel),
        ),
      ],
    );
  }
}
