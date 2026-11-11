import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FlutterView, PlatformDispatcher, TextDirection;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../analytics/analytics.dart';
import '../data/api_client.dart';
import '../data/csv_importer.dart';
import '../data/demo_data.dart';
import '../data/token_store.dart';
import 'filters.dart';
import 'settings_state.dart';

export 'filters.dart';

/// Sends a screen reader announcement. [assertive] interrupts current
/// speech (use for errors only).
typedef Announcer = void Function(String message, {bool assertive});

/// Runs one analysis, normally in a background isolate.
typedef AnalysisRunner = Future<AnalysisOutcome> Function(AnalysisRequest request);

/// Parses a CSV export, normally in a background isolate.
typedef CsvImportRunner = Future<Dataset> Function(Uint8List bytes, String name);

/// Builds the demo dataset, normally in a background isolate.
typedef DemoRunner = Future<Dataset> Function();

/// Lets the user choose a file; returns null when cancelled.
typedef FilePickRunner = Future<PickedFile?> Function();

/// Creates an API client (injectable for tests).
typedef ApiClientFactory = AnalyticsApiClient Function(Uri baseUrl, String token);

/// A file chosen by the user.
class PickedFile {
  const PickedFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

/// Everything an analysis run needs. Sent to the background isolate, so it
/// holds only plain data.
class AnalysisRequest {
  const AnalysisRequest({
    required this.dataset,
    required this.window,
    required this.clients,
    required this.config,
    required this.excludeClients,
  });

  final Dataset dataset;
  final TimeWindow window;

  /// Clients to keep (null = all).
  final Set<String>? clients;
  final AnalysisConfig config;
  final Set<String> excludeClients;
}

/// The filtered dataset and its analysis.
class AnalysisOutcome {
  const AnalysisOutcome(this.filtered, this.result);
  final Dataset filtered;
  final AnalysisResult result;
}

/// Filters and analyses the dataset. This is the ONLY place the app calls
/// the analytics engine; it is pure and isolate-safe.
AnalysisOutcome runAnalysisRequest(AnalysisRequest r) {
  final filtered = r.dataset.filter(
    clients: r.clients,
    from: r.window.start,
    to: r.window.end,
  );
  return AnalysisOutcome(
    filtered,
    analyze(filtered, r.config, excludeClients: r.excludeClients),
  );
}

Future<AnalysisOutcome> _defaultAnalysisRunner(AnalysisRequest r) =>
    compute(runAnalysisRequest, r, debugLabel: 'analysis');

Future<Dataset> _defaultDemoRunner() => compute(
    generateDemoDatasetFromMicros,
    DateTime.now().toUtc().microsecondsSinceEpoch,
    debugLabel: 'demo-data');

Future<PickedFile?> _defaultFilePicker() async {
  final file = await FilePicker.pickFile(
    dialogTitle: 'Choose a metric_events export',
    type: FileType.custom,
    allowedExtensions: const ['csv', 'txt', 'tsv'],
  );
  if (file == null) return null;
  return PickedFile(file.name, await file.readAsBytes());
}

void _defaultAnnouncer(String message, {bool assertive = false}) {
  final dispatcher = PlatformDispatcher.instance;
  final FlutterView? view =
      dispatcher.implicitView ?? (dispatcher.views.isEmpty ? null : dispatcher.views.first);
  if (view == null) return;
  SemanticsService.sendAnnouncement(view, message, TextDirection.ltr,
      assertiveness: assertive ? Assertiveness.assertive : Assertiveness.polite);
}

/// A user-facing error with a suggested fix.
@immutable
class AppError {
  const AppError(this.title, this.message, {this.suggestion});

  final String title;
  final String message;
  final String? suggestion;

  @override
  String toString() => [title, message, ?suggestion].join(' ');
}

/// Application state: the loaded dataset, filters and the analysis result.
///
/// Screens read it with `context.watch<AppState>()`. The analysis is
/// recomputed in the background whenever the dataset, the filters, the
/// analysis settings or the excluded clients change. At most one analysis
/// runs at a time; changes made meanwhile are coalesced into one follow-up
/// run, and results for outdated inputs are discarded.
class AppState extends ChangeNotifier {
  AppState({
    required this.settings,
    AnalysisRunner? analysisRunner,
    CsvImportRunner? csvImporter,
    DemoRunner? demoRunner,
    FilePickRunner? filePicker,
    ApiClientFactory? apiClientFactory,
    TokenStore? tokenStore,
    Announcer? announcer,
  })  : _analysisRunner = analysisRunner ?? _defaultAnalysisRunner,
        _csvImporter = csvImporter ??
            ((bytes, name) => importCsvInBackground(bytes, sourceName: name)),
        _demoRunner = demoRunner ?? _defaultDemoRunner,
        _filePicker = filePicker ?? _defaultFilePicker,
        _apiClientFactory = apiClientFactory ??
            ((url, token) => AnalyticsApiClient(baseUrl: url, token: token)),
        tokenStore = tokenStore ?? SecureTokenStore(),
        _legacyTokenBaseUrl = _parseSavedBaseUrl(settings.apiBaseUrl),
        _announce = announcer ?? _defaultAnnouncer {
    _settingsSignature = _signature();
    settings.addListener(_onSettingsChanged);
  }

  final SettingsState settings;
  final TokenStore tokenStore;
  final AnalysisRunner _analysisRunner;
  final CsvImportRunner _csvImporter;
  final DemoRunner _demoRunner;
  final FilePickRunner _filePicker;
  final ApiClientFactory _apiClientFactory;
  final Announcer _announce;

  static final NumberFormat _count = NumberFormat.decimalPattern();

  // ---------------------------------------------------------------- data
  Dataset? _dataset;
  bool _isLoading = false;
  double? _loadProgress;
  String? _loadMessage;
  AppError? _error;
  CancellationToken? _apiCancel;

  /// The full loaded dataset (before filters), or null.
  Dataset? get dataset => _dataset;
  bool get hasData => _dataset != null;

  /// True while a file, the API or the demo is loading.
  bool get isLoading => _isLoading;

  /// 0..1 when known, null for indeterminate.
  double? get loadProgress => _loadProgress;
  String? get loadMessage => _loadMessage;

  /// Whether the current load can be cancelled (API downloads).
  bool get canCancelLoad => _isLoading && _apiCancel != null;

  /// The most recent load or analysis error, cleared by [dismissError] or
  /// the next successful load.
  AppError? get error => _error;

  // ------------------------------------------------------------- filters
  DashboardFilters _filters = const DashboardFilters();
  BuildingClassifier _buildings = BuildingClassifier(ClassifierConfig.defaultBuildingPattern);
  List<String> _rooms = const [];
  Map<String, List<String>> _roomsByBuilding = const {};

  DashboardFilters get filters => _filters;

  /// The time window currently analysed, or null without data.
  TimeWindow? get window => _dataset == null ? null : _filters.windowFor(_dataset!);

  /// All rooms in the dataset, excluding [SettingsState.excludeClients].
  List<String> get rooms => _rooms;

  /// All buildings, sorted.
  List<String> get buildings => _roomsByBuilding.keys.toList()..sort();

  /// Rooms in [building].
  List<String> roomsIn(String building) => _roomsByBuilding[building] ?? const [];

  /// The building a client belongs to (per the configured pattern).
  String buildingOf(String client) => _buildings.buildingOf(client);

  /// Rooms offered in the room picker: those in the selected buildings, or
  /// all rooms when no building is selected.
  List<String> get selectableRooms => _filters.buildings.isEmpty
      ? _rooms
      : [for (final r in _rooms) if (_filters.buildings.contains(buildingOf(r))) r];

  /// The clients analysed after building/room filters (null = all).
  Set<String>? get selectedClients {
    if (_filters.rooms.isNotEmpty) return _filters.rooms;
    if (_filters.buildings.isNotEmpty) return selectableRooms.toSet();
    return null;
  }

  // ------------------------------------------------------------ analysis
  Dataset? _filtered;
  AnalysisResult? _analysis;
  bool _isAnalyzing = false;
  bool _analysisDirty = false;
  int _generation = 0;
  late String _settingsSignature;

  /// The dataset after filters (what [analysis] describes).
  Dataset? get filteredDataset => _filtered;

  /// The latest analysis, or null before the first one finishes. While a
  /// newer analysis runs, the previous result stays available.
  AnalysisResult? get analysis => _analysis;
  bool get isAnalyzing => _isAnalyzing;

  // ------------------------------------------------------------- loading

  /// Opens the file picker and imports the chosen export.
  Future<void> pickAndLoadCsv() async {
    if (_isLoading) return;
    PickedFile? file;
    try {
      file = await _filePicker();
    } catch (e) {
      _setError(const AppError('Could not open the file picker',
          'The system file dialog failed to open.',
          suggestion: 'Try again, or drag the file into a different folder and retry.'));
      return;
    }
    if (file == null) return;
    await loadCsvBytes(file.bytes, file.name);
  }

  /// Imports a CSV / psql text export.
  Future<void> loadCsvBytes(Uint8List bytes, String name) async {
    _beginLoad('Reading $name');
    try {
      final ds = await _csvImporter(bytes, name);
      _finishLoad(ds);
    } on CsvImportException catch (e) {
      _failLoad(AppError('Could not import $name', e.message, suggestion: e.suggestion));
    } catch (e) {
      _failLoad(AppError('Could not import $name',
          'The file could not be read as a metric_events export.',
          suggestion: 'Check that it is the CSV produced by the export command.'));
    }
  }

  /// Loads the deterministic demo campus.
  Future<void> loadDemo() async {
    _beginLoad('Generating demo data');
    try {
      _finishLoad(await _demoRunner());
    } catch (e) {
      _failLoad(const AppError('Could not create demo data',
          'Something went wrong while generating the demo campus.'));
    }
  }

  /// Downloads [from, to) from the Analytics API. When [rememberToken] is
  /// true the token is saved in the system credential store (this browser
  /// tab's session on the web) for [baseUrl]'s origin, otherwise any saved
  /// token is deleted.
  ///
  /// The remembered token is never sent to an origin other than the one it
  /// was saved for: such a request fails before anything is sent.
  Future<void> loadFromApi({
    required Uri baseUrl,
    required String token,
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
    bool rememberToken = false,
  }) async {
    if (_isLoading) return;
    if (!await _tokenMayBeSentTo(token, baseUrl)) {
      final e = withheldTokenError(baseUrl);
      _setError(AppError('Could not load data from the Analytics API', e.message, suggestion: e.suggestion));
      return;
    }
    await _rememberToken(token, rememberToken, baseUrl);
    final cancel = CancellationToken();
    _apiCancel = cancel;
    _beginLoad('Connecting to ${baseUrl.host}');
    AnalyticsApiClient? client;
    try {
      client = _apiClientFactory(baseUrl, token);
      final ds = await client.loadDataset(
        from: from,
        to: to,
        clients: clients,
        cancel: cancel,
        onProgress: (p) {
          if (cancel.isCancelled) return;
          _loadProgress = p.fraction;
          _loadMessage = p.message;
          notifyListeners();
        },
      );
      if (cancel.isCancelled) throw const ApiException(ApiErrorKind.cancelled, 'Loading was cancelled.');
      _finishLoad(ds);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.cancelled) {
        _cancelledLoad();
      } else {
        _failLoad(AppError('Could not load data from the Analytics API', e.message,
            suggestion: e.suggestion));
      }
    } on ArgumentError catch (e) {
      _failLoad(AppError('Could not load data from the Analytics API', '${e.message}'));
    } catch (e) {
      _failLoad(const AppError('Could not load data from the Analytics API',
          'An unexpected error occurred while reading the server response.'));
    } finally {
      client?.close();
      if (identical(_apiCancel, cancel)) _apiCancel = null;
    }
  }

  /// How many events (not heartbeats) [loadFromApi] with the same
  /// arguments would download, from `GET /api/v1/clients`, so the UI can
  /// ask before a very large download (see
  /// [AnalyticsApiClient.largeDownloadEvents]).
  ///
  /// Shows progress like a load and can be cancelled with [cancelLoad].
  /// Returns null when the check was cancelled or failed; a failure is
  /// reported in [error] exactly like a failed load, so the caller should
  /// not start the download.
  Future<int?> estimateApiDownload({
    required Uri baseUrl,
    required String token,
    required DateTime from,
    required DateTime to,
    Set<String>? clients,
  }) async {
    if (_isLoading) return null;
    if (!await _tokenMayBeSentTo(token, baseUrl)) {
      final e = withheldTokenError(baseUrl);
      _setError(AppError('Could not load data from the Analytics API', e.message, suggestion: e.suggestion));
      return null;
    }
    final cancel = CancellationToken();
    _apiCancel = cancel;
    _beginLoad('Checking the size of the download from ${baseUrl.host}');
    AnalyticsApiClient? client;
    try {
      client = _apiClientFactory(baseUrl, token);
      final count = await client.estimateEventCount(from: from, to: to, clients: clients, cancel: cancel);
      cancel.throwIfCancelled();
      _isLoading = false;
      _loadProgress = null;
      _loadMessage = null;
      _apiCancel = null;
      notifyListeners();
      return count;
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.cancelled) {
        _cancelledLoad();
      } else {
        _failLoad(AppError('Could not load data from the Analytics API', e.message,
            suggestion: e.suggestion));
      }
    } on ArgumentError catch (e) {
      _failLoad(AppError('Could not load data from the Analytics API', '${e.message}'));
    } catch (e) {
      _failLoad(const AppError('Could not load data from the Analytics API',
          'An unexpected error occurred while reading the server response.'));
    } finally {
      client?.close();
      if (identical(_apiCancel, cancel)) _apiCancel = null;
    }
    return null;
  }

  void _cancelledLoad() {
    _isLoading = false;
    _apiCancel = null;
    _loadProgress = null;
    _loadMessage = null;
    notifyListeners();
    _announce('Loading cancelled.');
  }

  /// Checks a connection without loading data. Returns server info and the
  /// client list; throws [ApiException] / [ArgumentError] on failure.
  Future<(ApiInfo, List<ApiClientSummary>)> testApiConnection({
    required Uri baseUrl,
    required String token,
    DateTime? from,
    DateTime? to,
  }) async {
    if (!await _tokenMayBeSentTo(token, baseUrl)) throw withheldTokenError(baseUrl);
    final client = _apiClientFactory(baseUrl, token);
    try {
      final info = await client.info();
      final clients = await client.clients(from: from, to: to);
      return (info, clients);
    } finally {
      client.close();
    }
  }

  /// Cancels an API download in progress.
  void cancelLoad() => _apiCancel?.cancel();

  Future<void> _rememberToken(String token, bool remember, Uri baseUrl) async {
    try {
      if (remember) {
        await tokenStore.write(token, baseUrl: baseUrl);
      } else {
        await tokenStore.delete();
      }
    } catch (_) {
      // Failing to store a token must not block loading; the user simply
      // has to enter it again next time.
    }
  }

  /// The API address saved when the app started. A token remembered by an
  /// older version (without an origin) was saved together with it, so it
  /// is bound to that address (see [TokenStore.readFor]); it is captured
  /// once so that later edits of the address cannot re-bind such a token.
  final Uri? _legacyTokenBaseUrl;

  static Uri? _parseSavedBaseUrl(String url) {
    try {
      return AnalyticsApiClient.parseBaseUrl(url);
    } on FormatException {
      return null;
    }
  }

  /// The remembered token when it was saved for [baseUrl]'s origin, else
  /// null. Never returns a token saved for another server.
  Future<String?> rememberedTokenFor(Uri baseUrl) async {
    try {
      return await tokenStore.readFor(baseUrl, legacyBaseUrl: _legacyTokenBaseUrl);
    } catch (_) {
      return null;
    }
  }

  /// The origin ("https://host:port") the remembered token belongs to, or
  /// null when no token is remembered.
  Future<String?> rememberedTokenOrigin() async {
    try {
      return await tokenStore.rememberedOrigin(legacyBaseUrl: _legacyTokenBaseUrl);
    } catch (_) {
      return null;
    }
  }

  /// Deletes the remembered token.
  Future<void> forgetRememberedToken() => tokenStore.delete();

  Future<bool> _tokenMayBeSentTo(String token, Uri baseUrl) async {
    try {
      return await tokenStore.mayBeSentTo(token, baseUrl, legacyBaseUrl: _legacyTokenBaseUrl);
    } catch (_) {
      // The store could not be read, so it cannot have handed this token
      // out either.
      return true;
    }
  }

  /// The error for a remembered token about to be sent to another server.
  static ApiException withheldTokenError(Uri baseUrl) => ApiException(
        ApiErrorKind.unauthorized,
        'The remembered token belongs to a different server, so it was not sent to ${baseUrl.host}.',
        suggestion: 'Enter the token for this server. If this server really uses the same token, '
            'untick "Remember token" (this forgets the saved token) and try again.',
      );

  /// Forgets the loaded data and filters.
  void clearData() {
    _generation++;
    _dataset = null;
    _filtered = null;
    _analysis = null;
    _isAnalyzing = false;
    _analysisDirty = false;
    _filters = const DashboardFilters();
    _rooms = const [];
    _roomsByBuilding = const {};
    _error = null;
    notifyListeners();
    _announce('Data cleared.');
  }

  void dismissError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void _beginLoad(String message) {
    _isLoading = true;
    _loadProgress = null;
    _loadMessage = message;
    _error = null;
    notifyListeners();
    _announce('$message…');
  }

  void _finishLoad(Dataset ds) {
    _isLoading = false;
    _loadProgress = null;
    _loadMessage = null;
    _apiCancel = null;
    _dataset = ds;
    _filters = const DashboardFilters();
    _analysis = null;
    _filtered = null;
    _rebuildRoomIndex();
    notifyListeners();
    final skipped = ds.skippedRows > 0
        ? ' ${_count.format(ds.skippedRows)} rows could not be read and were skipped.'
        : '';
    final warnings = ds.warnings.isEmpty ? '' : ' ${ds.warnings.join(' ')}';
    _announce('Loaded ${_count.format(ds.events.length)} events from '
        '${_count.format(_rooms.length)} rooms.$skipped$warnings');
    _scheduleAnalysis();
  }

  void _failLoad(AppError error) {
    _isLoading = false;
    _loadProgress = null;
    _loadMessage = null;
    _apiCancel = null;
    _setError(error);
  }

  void _setError(AppError error) {
    _error = error;
    notifyListeners();
    _announce('Error: ${error.title}. ${error.message}', assertive: true);
  }

  void _rebuildRoomIndex() {
    _buildings = BuildingClassifier(settings.analysisConfig.classifier.buildingPattern);
    final ds = _dataset;
    if (ds == null) {
      _rooms = const [];
      _roomsByBuilding = const {};
      return;
    }
    // Case-insensitive, like the analytics engine.
    final excluded = {for (final c in settings.excludeClients) c.toLowerCase()};
    _rooms = [for (final c in ds.clientNames) if (!excluded.contains(c.toLowerCase())) c];
    final byBuilding = <String, List<String>>{};
    for (final r in _rooms) {
      byBuilding.putIfAbsent(buildingOf(r), () => []).add(r);
    }
    _roomsByBuilding = byBuilding;
    // Drop selections that no longer exist.
    final validBuildings = _filters.buildings.where(byBuilding.containsKey).toSet();
    final validRooms = _filters.rooms.where(_rooms.contains).toSet();
    if (validBuildings.length != _filters.buildings.length ||
        validRooms.length != _filters.rooms.length) {
      _filters = _filters.copyWith(buildings: validBuildings, rooms: validRooms);
    }
  }

  // ------------------------------------------------------------- filters

  void setDatePreset(DatePreset preset) {
    if (preset == DatePreset.custom && _filters.customWindow == null) {
      final ds = _dataset;
      if (ds == null) return;
      _filters = _filters.copyWith(
          preset: preset, customWindow: TimeWindow(ds.rangeStart, ds.rangeEnd));
    } else {
      if (preset == _filters.preset) return;
      _filters = _filters.copyWith(preset: preset);
    }
    _filtersChanged();
  }

  /// Sets a custom window (UTC, half-open). [end] is exclusive.
  void setCustomWindow(DateTime start, DateTime end) {
    if (!start.isBefore(end)) {
      throw ArgumentError('The start date must be before the end date.');
    }
    _filters = _filters.copyWith(
        preset: DatePreset.custom, customWindow: TimeWindow(start.toUtc(), end.toUtc()));
    _filtersChanged();
  }

  void setBuildings(Set<String> buildings) {
    final rooms = _filters.rooms
        .where((r) => buildings.isEmpty || buildings.contains(buildingOf(r)))
        .toSet();
    _filters = _filters.copyWith(buildings: Set.unmodifiable(buildings), rooms: Set.unmodifiable(rooms));
    _filtersChanged();
  }

  void setRooms(Set<String> rooms) {
    _filters = _filters.copyWith(rooms: Set.unmodifiable(rooms));
    _filtersChanged();
  }

  void clearFilters() {
    if (_filters.isDefault) return;
    _filters = const DashboardFilters();
    _filtersChanged();
  }

  void _filtersChanged() {
    notifyListeners();
    _scheduleAnalysis();
  }

  // ------------------------------------------------------------ analysis

  String _signature() => jsonEncode({
        'config': settings.analysisConfig.toJson(),
        'exclude': settings.excludeClients.toList()..sort(),
      });

  void _onSettingsChanged() {
    final sig = _signature();
    if (sig == _settingsSignature) return;
    _settingsSignature = sig;
    if (_dataset != null) {
      _rebuildRoomIndex();
      notifyListeners();
      _scheduleAnalysis();
    }
  }

  void _scheduleAnalysis() {
    if (_dataset == null) return;
    _generation++;
    if (_isAnalyzing) {
      _analysisDirty = true;
      return;
    }
    unawaited(_runAnalysis());
  }

  /// Re-runs the analysis now (e.g. from a Retry button).
  void reanalyze() => _scheduleAnalysis();

  Future<void> _runAnalysis() async {
    final ds = _dataset;
    if (ds == null) return;
    final generation = _generation;
    _isAnalyzing = true;
    _analysisDirty = false;
    notifyListeners();
    final request = AnalysisRequest(
      dataset: ds,
      window: _filters.windowFor(ds),
      clients: selectedClients,
      config: settings.analysisConfig,
      excludeClients: settings.excludeClients,
    );
    AnalysisOutcome? outcome;
    AppError? failure;
    try {
      outcome = await _analysisRunner(request);
    } catch (e, st) {
      debugPrint('Analysis failed: $e\n$st');
      failure = const AppError('Analysis failed',
          'The data could not be analysed with the current settings.',
          suggestion: 'Check the analysis settings (for example the regular expressions) '
              'or reset them to defaults, then try again.');
    }
    if (_disposed) return;
    _isAnalyzing = false;
    if (!identical(_dataset, ds)) {
      // Data was replaced or cleared meanwhile; a new run was scheduled.
      if (_dataset != null && _analysisDirty) unawaited(_runAnalysis());
      return;
    }
    if (_analysisDirty || generation != _generation) {
      unawaited(_runAnalysis());
      return;
    }
    if (outcome != null) {
      _filtered = outcome.filtered;
      _analysis = outcome.result;
      notifyListeners();
      final n = outcome.filtered.events.length;
      _announce('Analysis updated: ${_count.format(n)} events in the selected range.');
    } else {
      _setError(failure!);
    }
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_onSettingsChanged);
    _apiCancel?.cancel();
    super.dispose();
  }
}
