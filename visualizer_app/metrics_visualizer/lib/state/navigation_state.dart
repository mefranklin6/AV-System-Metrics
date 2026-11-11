import 'package:flutter/material.dart';

/// Every top-level page. The shell builds its navigation from this list, in
/// this order, so it is also the keyboard shortcut order (Ctrl+1 ...).
enum AppDestination {
  overview('Overview', 'Campus-wide summary', Icons.dashboard_outlined, Icons.dashboard),
  rooms('Rooms', 'Room list and per-room detail', Icons.meeting_room_outlined, Icons.meeting_room),
  inputs('Sources', 'Which sources are selected and for how long', Icons.input_outlined, Icons.input),
  devices('Devices', 'Device on-hours from power events', Icons.videocam_outlined, Icons.videocam),
  systemUsage('System usage', 'Power-on times, sessions and utilisation', Icons.power_settings_new_outlined, Icons.power_settings_new),
  connectivity('Connectivity', 'Device communication, heartbeats and heartbeat gaps', Icons.lan_outlined, Icons.lan),
  issues('Issues', 'Patterns in the data worth reviewing', Icons.report_problem_outlined, Icons.report_problem),
  forecast('Forecast', 'Usage trends and replacement planning', Icons.trending_up_outlined, Icons.trending_up),
  dataSource('Data source', 'Load a CSV export, connect to the API or try demo data', Icons.storage_outlined, Icons.storage),
  settings('Settings', 'Appearance, accessibility and analysis options', Icons.settings_outlined, Icons.settings),
  about('About', 'Version, accessibility and privacy', Icons.info_outlined, Icons.info);

  const AppDestination(this.label, this.description, this.icon, this.selectedIcon);

  final String label;
  final String description;
  final IconData icon;
  final IconData selectedIcon;

  /// Analysis pages show the filter bar and need a loaded dataset.
  bool get isAnalysis => index <= AppDestination.forecast.index;
}

/// Which page is showing, plus cross-page selections (e.g. the room a user
/// drilled into). Screens navigate with
/// `context.read<NavigationState>().goTo(AppDestination.rooms, room: 'BSS_245')`.
class NavigationState extends ChangeNotifier {
  NavigationState({AppDestination initial = AppDestination.dataSource})
      : _current = initial;

  AppDestination _current;
  String? _selectedRoom;

  AppDestination get current => _current;

  /// The room shown in the Rooms detail view, or null for the room list.
  String? get selectedRoom => _selectedRoom;

  /// Shows [destination]. When [room] is given it becomes the selected room
  /// (used for drill-down into the Rooms page).
  void goTo(AppDestination destination, {String? room}) {
    final changed = destination != _current || (room != null && room != _selectedRoom);
    _current = destination;
    if (room != null) _selectedRoom = room;
    if (changed) notifyListeners();
  }

  /// Selects a room (null returns to the room list) without changing page.
  void selectRoom(String? room) {
    if (room == _selectedRoom) return;
    _selectedRoom = room;
    notifyListeners();
  }

  SettingsSection? _settingsSection;

  /// The Settings section to scroll to and focus when the Settings page
  /// next builds, set by [openSettings]. Read it with
  /// [takeSettingsSection], which clears it.
  SettingsSection? get pendingSettingsSection => _settingsSection;

  /// Shows Settings scrolled to [section] (for links such as "Open Event
  /// recognition settings" on other pages).
  void openSettings(SettingsSection section) {
    _settingsSection = section;
    _current = AppDestination.settings;
    notifyListeners();
  }

  /// Returns and clears the pending Settings section.
  SettingsSection? takeSettingsSection() {
    final s = _settingsSection;
    _settingsSection = null;
    return s;
  }
}

/// Settings sections that other pages link to.
enum SettingsSection {
  eventRecognition('Event recognition'),
  deviceTypeOverrides('Device type overrides'),
  thresholds('Issue detection thresholds');

  const SettingsSection(this.title);

  /// The section's visible heading.
  final String title;
}
