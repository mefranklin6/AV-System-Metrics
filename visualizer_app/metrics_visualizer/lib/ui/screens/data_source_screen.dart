import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/api_client.dart';
import '../../data/csv_importer.dart';
import '../../data/models.dart';
import '../../data/token_store.dart';
import '../../state/app_state.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';

/// Start page: load a CSV export, connect to the Analytics API or explore
/// the demo campus.
class DataSourceScreen extends StatelessWidget {
  const DataSourceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return LayoutBuilder(builder: (context, constraints) {
      final horizontal = constraints.maxWidth < 600 ? 16.0 : 24.0;
      return ListView(
        padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 32),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    title: 'Data source',
                    subtitle:
                        'Choose where the room and device usage data comes from. Nothing is uploaded anywhere: '
                        'files are read on this computer and API data stays in memory.',
                    level: HeadingLevel.page,
                  ),
                  if (app.error != null) ...[
                    ErrorBanner(
                      title: app.error!.title,
                      message: app.error!.message,
                      suggestion: app.error!.suggestion,
                      onDismiss: app.dismissError,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (app.dataset != null) ...[
                    _CurrentDataCard(
                      dataset: app.dataset!,
                      notes: dataNotes(app.dataset!, app.analysis?.dataQuality.warnings),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const ResponsiveGrid(
                    minChildWidth: 380,
                    maxColumns: 3,
                    children: [
                      _CsvCard(),
                      _ApiCard(),
                      _DemoCard(),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// Notes about the loaded data that users should see: the importer's
/// warnings (such as how day-first or ambiguous spreadsheet dates were
/// read) followed by any other analysis data-quality warnings, without
/// duplicates.
List<String> dataNotes(Dataset dataset, List<String>? analysisWarnings) =>
    {...dataset.warnings, ...?analysisWarnings}.toList();

class _CurrentDataCard extends StatelessWidget {
  const _CurrentDataCard({required this.dataset, required this.notes});

  final Dataset dataset;

  /// From [dataNotes]; shown as visible text, not only announced.
  final List<String> notes;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final fmt = Fmt.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final heartbeatCount = dataset.heartbeats.fold<int>(0, (a, b) => a + b.count);
    final origin = switch (dataset.origin) {
      DatasetOrigin.csv => 'CSV file',
      DatasetOrigin.api => 'Analytics API',
      DatasetOrigin.demo => 'Demo data',
    };
    final facts = <(String, String)>[
      ('Source', '$origin: ${dataset.description}'),
      ('Events', fmt.count(dataset.events.length)),
      ('Heartbeats', fmt.count(heartbeatCount)),
      ('Rooms', fmt.count(app.rooms.length)),
      ('Period', '${fmt.date(dataset.rangeStart)} – ${fmt.date(dataset.rangeEnd.subtract(const Duration(microseconds: 1)))}'),
      if (dataset.skippedRows > 0) ('Skipped rows', fmt.count(dataset.skippedRows)),
    ];
    return Card(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_outline, color: cs.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Heading('Data loaded',
                      level: HeadingLevel.section,
                      style: theme.textTheme.titleLarge?.copyWith(color: cs.onSecondaryContainer)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 32,
              runSpacing: 12,
              children: [
                for (final (label, value) in facts)
                  Semantics(
                    label: '$label: $value',
                    excludeSemantics: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(label,
                            style: theme.textTheme.labelLarge?.copyWith(color: cs.onSecondaryContainer)),
                        Text(value,
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: cs.onSecondaryContainer, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
              ],
            ),
            if (dataset.skippedRows > 0) ...[
              const SizedBox(height: 12),
              Text(
                '${fmt.count(dataset.skippedRows)} rows could not be read (for example a missing or invalid timestamp) and were left out.',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
              ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Heading('Notes about this data',
                  level: HeadingLevel.subsection,
                  style: HeadingLevel.subsection.styleOf(theme)?.copyWith(color: cs.onSecondaryContainer)),
              const SizedBox(height: 8),
              for (final note in notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Icon(Icons.info_outline, size: 20, color: cs.onSecondaryContainer, semanticLabel: 'Note'),
                      ),
                      Expanded(
                        child: Text(note,
                            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSecondaryContainer)),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => context.read<NavigationState>().goTo(AppDestination.overview),
                  icon: const Icon(Icons.dashboard_outlined),
                  label: const Text('Go to overview'),
                ),
                OutlinedButton.icon(
                  onPressed: app.clearData,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Clear data'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.icon, required this.title, required this.children});

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: cs.onPrimaryContainer),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Heading(title, level: HeadingLevel.section),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CsvCard extends StatelessWidget {
  const _CsvCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    return _SourceCard(
      icon: Icons.upload_file_outlined,
      title: 'Import a CSV export',
      children: [
        Text('1. On the AV System Metrics server, in the stack directory, run:', style: body),
        const SizedBox(height: 8),
        const CodeBlock(code: recommendedExportCommand, label: 'Export command'),
        const SizedBox(height: 8),
        Text(
          'Change 90 days to the period you need. The export includes heartbeats (most of the rows); '
          'the app summarises them per hour to show when each room was online. On Windows PowerShell 5, '
          'files redirected with > are UTF-16, which the app also reads.',
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Text('2. Copy avsm_export.csv to this computer, for example with scp or WinSCP.', style: body),
        const SizedBox(height: 12),
        Text('3. Choose the file below.', style: body),
        const SizedBox(height: 8),
        Text(
          'Also accepted: CSV from pgAdmin or DBeaver, and psql table output saved as .txt. '
          'Columns needed: clientname, event_timestamp, metric and action.',
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.icon(
            onPressed: app.isLoading ? null : app.pickAndLoadCsv,
            icon: const Icon(Icons.folder_open_outlined),
            label: const Text('Choose CSV file… (Ctrl+O)'),
          ),
        ),
      ],
    );
  }
}

/// Monospaced, selectable command text with a Copy button.
class CodeBlock extends StatelessWidget {
  const CodeBlock({super.key, required this.code, required this.label});

  final String code;

  /// Names the block for screen readers, e.g. "Export command".
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Semantics(
              label: label,
              child: SelectableText(
                code,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  fontFamilyFallback: const ['Consolas', 'Menlo', 'Courier New'],
                  color: cs.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy ${label.toLowerCase()}',
            icon: const Icon(Icons.copy_outlined),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)
                ?..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text('$label copied.')));
              announce(context, '$label copied to the clipboard.');
            },
          ),
        ],
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _SourceCard(
      icon: Icons.auto_awesome_outlined,
      title: 'Explore demo data',
      children: [
        Text(
          'A synthetic campus of 24 rooms in 6 buildings over 10 weeks, with realistic class schedules '
          'and a few planted patterns (repeated power cycling, repeated presses of one control, a room '
          'with a heartbeat gap and more) so you can see what every page shows. No real data is used.',
          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: app.isLoading ? null : app.loadDemo,
            icon: const Icon(Icons.play_circle_outline),
            label: const Text('Explore demo data'),
          ),
        ),
      ],
    );
  }
}

enum _ApiRange {
  d7('7 days', 7),
  d30('30 days', 30),
  d90('90 days', 90),
  d180('180 days', 180),
  d365('365 days', 365);

  const _ApiRange(this.label, this.days);
  final String label;
  final int days;
}

class _ApiCard extends StatefulWidget {
  const _ApiCard();

  @override
  State<_ApiCard> createState() => _ApiCardState();
}

class _ApiCardState extends State<_ApiCard> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _url;
  final _token = TextEditingController();
  /// One stable focus node per period chip. Activating a chip with the
  /// keyboard must leave focus on that chip (WCAG 2.4.3 / 3.2.2), so the
  /// nodes never move between chips when the selection changes.
  late final Map<_ApiRange, FocusNode> _rangeFocus = {
    for (final r in _ApiRange.values) r: FocusNode(debugLabel: 'Period ${r.label}'),
  };
  bool _showToken = false;
  bool _remember = false;
  _ApiRange _range = _ApiRange.d30;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  List<ApiClientSummary>? _serverClients;
  Set<String> _chosenClients = {};

  /// Address and period the last successful Test connection counted
  /// events for, so Load data can reuse [_serverClients]' counts.
  String? _testedUrl;
  _ApiRange? _testedRange;

  /// The remembered token as the store handed it out, and the origin it
  /// was handed out for. The store only returns a remembered token for its
  /// own origin (TokenStore.readFor); this lets the field be cleared at
  /// once when the address moves to another origin, so a typo or a
  /// look-alike address never receives it.
  String? _filledToken;
  String? _filledOrigin;

  /// Origin the remembered token belongs to, or null when none is saved.
  String? _rememberedOrigin;

  /// Shown when the saved token was withheld because the address changed.
  String? _tokenNotice;

  /// Drops answers from the token store that a newer lookup replaced.
  int _lookup = 0;

  @override
  void initState() {
    super.initState();
    final settings = context.read<SettingsState>();
    _url = TextEditingController(text: settings.apiBaseUrl);
    _url.addListener(_onUrlChanged);
    _remember = settings.rememberApiToken;
    if (_remember) _refreshSavedToken();
  }

  /// "scheme://host:port" of [url], or null when it is not a valid API
  /// address.
  static String? originOf(String url) {
    try {
      return TokenStore.originOf(AnalyticsApiClient.parseBaseUrl(url));
    } on FormatException {
      return null;
    }
  }

  String _withheldNotice(String origin) =>
      'The remembered token is for $origin, so it is not sent to this address. '
      'Enter the token for this server.';

  /// Asks the store for the remembered token for the current address and
  /// fills it in when the field is empty.
  Future<void> _refreshSavedToken() async {
    final app = context.read<AppState>();
    final lookup = ++_lookup;
    final url = _parsedUrl;
    final origin = await app.rememberedTokenOrigin();
    final saved = url == null ? null : await app.rememberedTokenFor(url);
    if (!mounted || lookup != _lookup) return;
    _rememberedOrigin = origin;
    setState(() {
      if (saved != null) {
        _filledToken = saved;
        _filledOrigin = TokenStore.originOf(url!);
        if (_token.text.isEmpty) _token.text = saved;
        _tokenNotice = null;
      } else {
        _tokenNotice = origin != null && _token.text.isEmpty ? _withheldNotice(origin) : null;
      }
    });
  }

  void _onUrlChanged() {
    final filled = _filledToken;
    if (filled != null && _token.text == filled && originOf(_url.text) != _filledOrigin) {
      _token.clear();
      _filledToken = null;
      _filledOrigin = null;
      setState(() => _tokenNotice = _withheldNotice(_rememberedOrigin ?? 'another address'));
      announce(context, 'Address changed: the remembered token was removed from the token field.');
    } else {
      setState(() {});
    }
    if (_remember && _rememberedOrigin != null) _refreshSavedToken();
  }

  @override
  void dispose() {
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _token.dispose();
    for (final node in _rangeFocus.values) {
      node.dispose();
    }
    super.dispose();
  }

  Uri? get _parsedUrl {
    try {
      return AnalyticsApiClient.parseBaseUrl(_url.text);
    } on FormatException {
      return null;
    }
  }

  (DateTime, DateTime) get _window {
    final now = DateTime.now().toUtc();
    final end = DateTime.utc(now.year, now.month, now.day, now.hour + 1);
    return (end.subtract(Duration(days: _range.days)), end);
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    final url = _parsedUrl!;
    final app = context.read<AppState>();
    // The remembered token is bound to its own origin in the token store,
    // so the address can be saved freely.
    await context.read<SettingsState>().setApiBaseUrl(url.toString());
    if (!mounted) return;
    setState(() {
      _testing = true;
      _testResult = null;
    });
    String result;
    var ok = false;
    final range = _range;
    try {
      final (from, to) = _window;
      final (info, clients) = await app.testApiConnection(
          baseUrl: url, token: _token.text.trim(), from: from, to: to);
      if (!mounted) return;
      // Not Fmt.of: that subscribes to settings and is only valid in build.
      final fmt = Fmt(utc: context.read<SettingsState>().timeDisplay == TimeDisplay.utc);
      final activity = info.firstEvent == null
          ? 'no activity recorded yet'
          : 'activity from ${fmt.date(info.firstEvent!)} to ${fmt.date(info.lastEvent!)}';
      final events = clients.fold<int>(0, (a, c) => a + c.eventCount);
      result = 'Connected. ${fmt.count(clients.length)} clients and ${fmt.count(events)} events '
          'in the last ${range.label}; $activity.';
      _serverClients = clients;
      _testedUrl = url.toString();
      _testedRange = range;
      ok = true;
    } on ApiException catch (e) {
      result = e.toString();
    } on ArgumentError catch (e) {
      result = '${e.message}';
    } catch (_) {
      result = 'The connection test failed unexpectedly.';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = result;
      _testOk = ok;
    });
    announce(context, ok ? result : 'Connection failed. $result', assertive: !ok);
  }

  /// Events the download would contain, from the last Test connection when
  /// it counted the same address and period, else null.
  int? _knownEventCount(Uri url) {
    final clients = _serverClients;
    if (clients == null || _testedUrl != url.toString() || _testedRange != _range) return null;
    var total = 0;
    for (final c in clients) {
      if (_chosenClients.isEmpty || _chosenClients.contains(c.clientName)) total += c.eventCount;
    }
    return total;
  }

  Future<void> _load() async {
    if (!_formKey.currentState!.validate()) return;
    final url = _parsedUrl!;
    final settings = context.read<SettingsState>();
    final app = context.read<AppState>();
    final (from, to) = _window;
    final token = _token.text.trim();
    final clients = _chosenClients.isEmpty ? null : Set<String>.of(_chosenClients);

    // Very large downloads are slow and can exhaust a browser tab's memory:
    // check the size first and let the user narrow the request.
    final estimate = _knownEventCount(url) ??
        await app.estimateApiDownload(baseUrl: url, token: token, from: from, to: to, clients: clients);
    if (!mounted || estimate == null) return; // cancelled, or the error is shown
    if (estimate > AnalyticsApiClient.largeDownloadEvents) {
      final go = await showLargeDownloadDialog(
        context: context,
        events: estimate,
        period: _range.label,
        rooms: clients?.length,
      );
      if (!mounted) return;
      if (!go) {
        // Back to the period choice, which the dialog suggested changing.
        _rangeFocus[_range]!.requestFocus();
        announce(context, 'Download not started. Choose a shorter period or fewer rooms.');
        return;
      }
    }

    await settings.setApiBaseUrl(url.toString());
    await settings.setRememberApiToken(_remember);
    // The token is now saved (or deleted) for this address's origin.
    final origin = TokenStore.originOf(url);
    _rememberedOrigin = _remember ? origin : null;
    _filledToken = _remember ? token : null;
    _filledOrigin = _remember ? origin : null;
    _tokenNotice = null;
    // On success the shell switches to the Overview page.
    await app.loadFromApi(
      baseUrl: url,
      token: token,
      from: from,
      to: to,
      clients: clients,
      rememberToken: _remember,
    );
  }

  Future<void> _chooseClients() async {
    final names = [for (final c in _serverClients!) c.clientName];
    final result = await showMultiSelectDialog(
      context: context,
      title: 'Rooms to download',
      options: names,
      selected: _chosenClients,
    );
    if (result != null) setState(() => _chosenClients = result);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final url = _parsedUrl;
    final insecure = url != null && AnalyticsApiClient.isInsecure(url);
    final (rememberTitle, rememberDetail) = rememberTokenWording();
    return _SourceCard(
      icon: Icons.cloud_sync_outlined,
      title: 'Connect to the Analytics API',
      children: [
        Text(
          'Read-only access to the server database through the optional analytics-api service. '
          'Ask your server administrator for the address and a token.',
          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 16),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'API address',
                  hintText: 'https://avsm.example.edu',
                  helperText: 'The address your administrator gave you, without /api/v1.',
                  helperMaxLines: settingsTextMaxLines,
                  errorMaxLines: settingsTextMaxLines,
                  prefixIcon: Icon(Icons.link),
                ),
                validator: (v) {
                  try {
                    AnalyticsApiClient.parseBaseUrl(v ?? '');
                    return null;
                  } on FormatException catch (e) {
                    return e.message;
                  }
                },
              ),
              if (insecure) ...[
                const SizedBox(height: 8),
                InsecureConnectionWarning(host: url.host),
              ],
              const SizedBox(height: 16),
              TextFormField(
                controller: _token,
                obscureText: !_showToken,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.visiblePassword,
                decoration: InputDecoration(
                  labelText: 'API token',
                  helperText: 'Kept in memory only, unless you choose to remember it.',
                  helperMaxLines: settingsTextMaxLines,
                  errorMaxLines: settingsTextMaxLines,
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    tooltip: _showToken ? 'Hide token' : 'Show token',
                    icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showToken = !_showToken),
                  ),
                ),
                validator: (v) => AnalyticsApiClient.validateToken((v ?? '').trim()),
              ),
              if (_tokenNotice != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(_tokenNotice!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
                ),
              ],
              const SizedBox(height: 8),
              CheckboxListTile(
                value: _remember,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(rememberTitle),
                subtitle: Text(rememberDetail),
                onChanged: (v) async {
                  final remember = v ?? false;
                  setState(() => _remember = remember);
                  final settings = context.read<SettingsState>();
                  final app = context.read<AppState>();
                  await settings.setRememberApiToken(remember);
                  if (!remember) {
                    await app.forgetRememberedToken();
                    _lookup++;
                    _filledToken = null;
                    _filledOrigin = null;
                    _rememberedOrigin = null;
                    if (mounted) setState(() => _tokenNotice = null);
                  }
                },
              ),
              const SizedBox(height: 8),
              Text('Period to download (ending now)',
                  style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final r in _ApiRange.values)
                    ChoiceChip(
                      focusNode: _rangeFocus[r],
                      label: Text(r.label),
                      selected: r == _range,
                      onSelected: (_) => setState(() => _range = r),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Longer periods take longer to download. Room online coverage is limited to the '
                "server's heartbeat retention (30 days by default).",
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _chosenClients.isEmpty ? 'Rooms: all' : 'Rooms: ${_chosenClients.length} selected',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                  ),
                  TextButton(
                    onPressed: _serverClients == null ? null : _chooseClients,
                    child: const Text('Choose rooms…'),
                  ),
                ],
              ),
              if (_serverClients == null)
                Text('Test the connection to choose specific rooms.',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: _testResult == null
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(_testOk ? Icons.check_circle_outline : Icons.error_outline,
                                color: _testOk ? cs.primary : cs.error,
                                semanticLabel: _testOk ? 'Success' : 'Error'),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(_testResult!,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(color: _testOk ? cs.onSurface : cs.error)),
                            ),
                          ],
                        ),
                      ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing || app.isLoading ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.network_check),
                    label: Text(_testing ? 'Testing…' : 'Test connection'),
                  ),
                  FilledButton.icon(
                    onPressed: _testing || app.isLoading ? null : _load,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Load data'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Title and explanation of the "Remember token" checkbox. On the web the
/// token is kept in the tab's sessionStorage (see SecureTokenStore), so it
/// lasts only for this browser tab session.
(String, String) rememberTokenWording({bool isWeb = kIsWeb}) => isWeb
    ? (
        'Remember token in this browser tab',
        'Kept for this browser tab session only, for this API address: it is forgotten when the tab is '
            'closed. While the tab is open, any script running on this site could read it. Do not use on '
            'shared computers.',
      )
    : (
        'Remember token on this computer',
        'Stored in the operating system credential store, for this API address only.',
      );

/// Settings page summary of where a remembered token is kept, matching
/// [rememberTokenWording].
String rememberedTokenStatus({required bool remember, bool isWeb = kIsWeb}) {
  if (!remember) return 'API tokens are not saved.';
  return isWeb
      ? 'An API token may be kept for this browser tab session.'
      : 'An API token may be saved in the operating system credential store.';
}

/// Asks before downloading more than [AnalyticsApiClient.largeDownloadEvents]
/// events and suggests a shorter period or fewer rooms. Returns true to
/// download anyway. The safe choice has focus, Escape cancels, and the
/// dialog is announced by its title.
Future<bool> showLargeDownloadDialog({
  required BuildContext context,
  required int events,
  required String period,
  int? rooms,
}) async {
  final fmt = Fmt(utc: true);
  final scope = rooms == null ? 'all rooms' : '${fmt.count(rooms)} selected rooms';
  final go = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final body = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface);
      return AlertDialog(
        title: const Text('Large download'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The last $period for $scope has about ${fmt.count(events)} events. Downloading this much '
              'can take several minutes and use a lot of memory, and the app stops at '
              '${fmt.count(AnalyticsApiClient.defaultMaxEvents)} events.',
              style: body,
            ),
            const SizedBox(height: 12),
            Text(
              'Choose a shorter period or fewer rooms (Test connection, then Choose rooms) for a faster download.',
              style: body,
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Change period or rooms'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Download anyway'),
          ),
        ],
      );
    },
  );
  return go ?? false;
}

/// Warns that the token and data would cross the network unencrypted.
class InsecureConnectionWarning extends StatelessWidget {
  const InsecureConnectionWarning({super.key, required this.host});

  final String host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        decoration: BoxDecoration(
          color: cs.tertiaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.tertiary, width: 1.5),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_outlined, color: cs.onTertiaryContainer, semanticLabel: 'Warning'),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Not encrypted: the token and data would travel to $host in plain text. '
                'Use an https:// address (on Docker Compose installs, a TLS reverse proxy in front of the '
                'Analytics API) unless this is a trusted, isolated network.',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onTertiaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
