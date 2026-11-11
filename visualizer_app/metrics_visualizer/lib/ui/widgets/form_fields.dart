import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart' show fieldTextMaxLines;
import 'status_widgets.dart';

/// Line limit for helper and error text of every text field (the theme
/// default too). Generous, so long instructions wrap instead of being cut
/// off with an ellipsis in narrow fields at 200% text size (WCAG 1.4.4 /
/// 3.3.1 / 3.3.2 / 3.3.3).
const int settingsTextMaxLines = fieldTextMaxLines;

/// Speaks a field's new validation error. Flutter marks the error text as
/// a live region only on platforms without announcements; on desktop and
/// the web (where announcements are supported) nothing would be read when
/// the error appears, so it is announced explicitly (WCAG 4.1.3 / 3.3.1).
void announceFieldError(BuildContext context, String label, String error) {
  if (!MediaQuery.supportsAnnounceOf(context)) return;
  announce(context, '$label: $error', assertive: true);
}

/// A labelled whole-number field with range validation. Calls [onChanged]
/// only with valid values, shows the error in text otherwise (WCAG 3.3.1),
/// and follows external changes to [value] (e.g. "Reset to defaults").
class IntSettingField extends StatefulWidget {
  const IntSettingField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.suffix,
    this.helper,
    this.width = 220,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Unit shown after the number, e.g. "seconds".
  final String? suffix;
  final String? helper;
  final double width;

  @override
  State<IntSettingField> createState() => _IntSettingFieldState();
}

class _IntSettingFieldState extends State<IntSettingField> {
  late final TextEditingController _controller = TextEditingController(text: '${widget.value}');
  String? _error;

  @override
  void didUpdateWidget(IntSettingField old) {
    super.didUpdateWidget(old);
    if (int.tryParse(_controller.text) != widget.value && old.value != widget.value) {
      _controller.text = '${widget.value}';
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _validate(String text) {
    final v = int.tryParse(text.trim());
    if (v == null) return 'Enter a whole number from ${widget.min} to ${widget.max}.';
    if (v < widget.min || v > widget.max) {
      return 'Must be from ${widget.min} to ${widget.max}.';
    }
    return null;
  }

  void _changed(String text) {
    final error = _validate(text);
    if (error != null && error != _error) announceFieldError(context, widget.label, error);
    setState(() => _error = error);
    if (error == null) {
      final v = int.parse(text.trim());
      if (v != widget.value) widget.onChanged(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: TextField(
        controller: _controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: widget.label,
          suffixText: widget.suffix,
          helperText: widget.helper ?? '${widget.min}–${widget.max}',
          helperMaxLines: settingsTextMaxLines,
          errorText: _error,
          errorMaxLines: settingsTextMaxLines,
        ),
        onChanged: _changed,
      ),
    );
  }
}

/// A regular-expression field with live validation and an explanation of
/// what the pattern is for. [validator] returns null when valid.
class PatternSettingField extends StatefulWidget {
  const PatternSettingField({
    super.key,
    required this.label,
    required this.value,
    required this.helper,
    required this.validator,
    required this.onChanged,
    this.defaultValue,
  });

  final String label;
  final String value;
  final String helper;
  final String? Function(String) validator;
  final ValueChanged<String> onChanged;

  /// When given, the default is shown under the field and a "Reset to
  /// default" button restores it.
  final String? defaultValue;

  @override
  State<PatternSettingField> createState() => _PatternSettingFieldState();
}

class _PatternSettingFieldState extends State<PatternSettingField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  String? _error;

  @override
  void didUpdateWidget(PatternSettingField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && _controller.text != widget.value) {
      _controller.text = widget.value;
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    final error = widget.validator(text);
    if (error != null && error != _error) announceFieldError(context, widget.label, error);
    setState(() => _error = error);
    if (error == null && text != widget.value) widget.onChanged(text);
  }

  @override
  Widget build(BuildContext context) {
    final def = widget.defaultValue;
    return TextField(
      controller: _controller,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: ['Consolas', 'Menlo']),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: def == null ? widget.helper : '${widget.helper}\nDefault: $def',
        helperMaxLines: settingsTextMaxLines,
        errorText: _error,
        errorMaxLines: settingsTextMaxLines,
        suffixIcon: def == null
            ? null
            : IconButton(
                tooltip: 'Reset ${widget.label} to default',
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  _controller.text = def;
                  _changed(def);
                },
              ),
      ),
      onChanged: _changed,
    );
  }
}

/// Editable list of short strings shown as deletable chips, with an add
/// field. Used for the event recognition name lists and excluded clients.
class StringListEditor extends StatefulWidget {
  const StringListEditor({
    super.key,
    required this.label,
    required this.values,
    required this.onChanged,
    this.addHint = 'Add',
    this.helper,
    this.normalize,
    this.emptyMessage = 'None.',
    this.allowEmpty = true,
    this.validate,
    this.defaultValues,
  });

  final String label;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;
  final String addHint;
  final String? helper;

  /// Optional normaliser applied to new entries (e.g. lower-casing).
  final String Function(String)? normalize;
  final String emptyMessage;

  /// When false, the last entry cannot be removed.
  final bool allowEmpty;

  /// Checks a proposed list before [onChanged] is called. Returns a
  /// user-facing error (shown under the add field and announced) to keep
  /// the list unchanged, or null to accept it.
  final String? Function(List<String>)? validate;

  /// When given, the defaults are listed under the editor and a "Reset to
  /// default" button restores them.
  final List<String>? defaultValues;

  @override
  State<StringListEditor> createState() => _StringListEditorState();
}

class _StringListEditorState extends State<StringListEditor> {
  final _controller = TextEditingController();
  final _addFocus = FocusNode(debugLabel: 'Add entry');

  /// One focus group per chip (the chip's delete button is its only tab
  /// stop), so focus can move to a neighbour when a chip is removed instead
  /// of dropping to the top of the app.
  final Map<String, FocusNode> _chipFocus = {};
  String? _error;

  @override
  void didUpdateWidget(StringListEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final gone = _chipFocus.keys.where((k) => !widget.values.contains(k)).toList();
    for (final k in gone) {
      _chipFocus.remove(k)!.dispose();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _addFocus.dispose();
    for (final n in _chipFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  FocusNode _focusFor(String v) =>
      _chipFocus.putIfAbsent(v, () => FocusNode(debugLabel: 'Chip $v', skipTraversal: true, canRequestFocus: false));

  void _fail(String error) {
    if (error != _error) announceFieldError(context, widget.addHint, error);
    setState(() => _error = error);
  }

  void _add() {
    var v = _controller.text.trim();
    if (widget.normalize != null) v = widget.normalize!(v);
    if (v.isEmpty) {
      _fail('Type a value first.');
      return;
    }
    if (v.length > 128) {
      _fail('Keep entries under 128 characters.');
      return;
    }
    if (widget.values.contains(v)) {
      _fail('"$v" is already in the list.');
      return;
    }
    final next = [...widget.values, v];
    final problem = widget.validate?.call(next);
    if (problem != null) {
      _fail(problem);
      return;
    }
    setState(() => _error = null);
    _controller.clear();
    widget.onChanged(next);
    announce(context, '$v added.');
  }

  /// Removes [v], then focuses the chip that took its place (or the one
  /// before it, or the Add field when the list is empty) and confirms.
  void _remove(String v) {
    final values = widget.values;
    final index = values.indexOf(v);
    final rest = [...values]..remove(v);
    final hadFocus = _chipFocus[v]?.hasFocus ?? false;
    final problem = widget.validate?.call(rest);
    if (problem != null) {
      _fail(problem);
      return;
    }
    if (_error != null) setState(() => _error = null);
    widget.onChanged(rest);
    announce(context, '$v removed.');
    if (!hadFocus) return;
    final next = rest.isEmpty ? null : rest[index.clamp(0, rest.length - 1)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final group = next != null && widget.values.contains(next) ? _chipFocus[next] : null;
      final target = group?.traversalDescendants.firstOrNull ?? _addFocus;
      target.requestFocus();
    });
  }

  void _reset(List<String> defaults) {
    final problem = widget.validate?.call(defaults);
    if (problem != null) {
      _fail(problem);
      return;
    }
    setState(() => _error = null);
    widget.onChanged([...defaults]);
    announce(context, '${widget.label} reset to the default.');
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final defaults = widget.defaultValues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
        if (widget.helper != null) ...[
          const SizedBox(height: 4),
          Text(widget.helper!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
        if (defaults != null) ...[
          const SizedBox(height: 4),
          Text(
            defaults.isEmpty ? 'Default: none.' : 'Default: ${defaults.join(', ')}',
            style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        if (widget.values.isEmpty)
          Text(widget.emptyMessage, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in widget.values)
                Focus(
                  focusNode: _focusFor(v),
                  child: InputChip(
                    label: Text(v),
                    onDeleted: !widget.allowEmpty && widget.values.length == 1 ? null : () => _remove(v),
                    deleteButtonTooltipMessage: 'Remove $v',
                  ),
                ),
            ],
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            SizedBox(
              width: 260,
              child: TextField(
                controller: _controller,
                focusNode: _addFocus,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: widget.addHint,
                  errorText: _error,
                  errorMaxLines: settingsTextMaxLines,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add),
                label: const Text('Add'),
              ),
            ),
            if (defaults != null && !_sameList(defaults, widget.values))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                // Names the list, so every reset button on a page has a
                // distinct accessible name (WCAG 2.4.6 / 2.5.3).
                child: TextButton.icon(
                  onPressed: () => _reset(defaults),
                  icon: const Icon(Icons.restart_alt),
                  label: Text('Reset ${widget.label.toLowerCase()} to default'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
