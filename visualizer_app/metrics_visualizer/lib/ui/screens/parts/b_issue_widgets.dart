// The expandable issue card used by the Issues screen.

import 'package:flutter/material.dart';

import '../../../analytics/analytics.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'b_common.dart';
import 'b_table.dart';

/// One issue: a summary row (severity icon + word, title, room, time,
/// data area) that expands to what the data shows, what is worth
/// checking, the facts, the evidence events and a link to the room.
///
/// While keyboard focus is anywhere inside the card, the card gets the
/// theme's 3 px focus ring, because the built-in list tile focus highlight
/// is only a faint tint (WCAG 2.4.7 / 2.4.13).
class IssueTile extends StatefulWidget {
  const IssueTile({
    super.key,
    required this.issue,
    required this.expanded,
    required this.onExpansionChanged,
    required this.onOpenRoom,
  });

  final Issue issue;
  final bool expanded;
  final ValueChanged<bool> onExpansionChanged;
  final ValueChanged<String> onOpenRoom;

  /// Heading of the factual explanation in an expanded issue.
  static const String dataShowsHeading = 'What the data shows';

  /// Heading of the neutral follow-ups in an expanded issue.
  static const String worthCheckingHeading = 'Worth checking';

  /// Whether [IssueType] counts hours rather than events.
  static bool countsHours(IssueType t) => t == IssueType.heartbeatGap || t == IssueType.longDeviceSession;

  @override
  State<IssueTile> createState() => _IssueTileState();
}

class _IssueTileState extends State<IssueTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final motion = Motion.of(context);
    final i = widget.issue;
    final where = i.subject == null ? i.room : '${i.room} · ${i.subject}';
    final card = Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: _focused ? BorderSide(color: AppTheme.focusRing(cs), width: 3) : BorderSide.none,
      ),
      child: ExpansionTile(
        key: ValueKey<String>('issue-expansion-${i.id}'),
        initiallyExpanded: widget.expanded,
        onExpansionChanged: widget.onExpansionChanged,
        expansionAnimationStyle: motion.reduced
            ? AnimationStyle.noAnimation
            : AnimationStyle(duration: motion.short, curve: motion.curve),
        maintainState: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: ExcludeSemantics(
          child: Icon(severityIcon(i.severity), color: cs.onSurface),
        ),
        title: Text(i.title, style: theme.textTheme.titleMedium?.copyWith(color: cs.onSurface)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SeverityBadge(i.severity),
              Text(
                '$where · ${fmt.dateTime(i.start)} · ${i.area.label}',
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        children: [_IssueDetail(issue: i, onOpenRoom: widget.onOpenRoom)],
      ),
    );
    // The card draws its own ring, so the app-wide one is not added on top.
    return NoFocusRing(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) {
          if (f != _focused) setState(() => _focused = f);
        },
        child: card,
      ),
    );
  }
}

class _IssueDetail extends StatelessWidget {
  const _IssueDetail({required this.issue, required this.onOpenRoom});

  final Issue issue;
  final ValueChanged<String> onOpenRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final i = issue;
    final body = theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface);

    Widget heading(String text) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Heading(text, level: HeadingLevel.detail),
        );

    final facts = <(String, String)>[
      ('Type', i.type.label),
      ('Severity', i.severity.label),
      ('Data area', i.area.label),
      ('Building', i.building),
      ('Room', i.room),
      if (i.subject != null) ('Device or control', i.subject!),
      ('Started', fmt.dateTime(i.start)),
      ('Ended', fmt.dateTime(i.end)),
      ('Duration', fmt.duration(i.duration)),
      (IssueTile.countsHours(i.type) ? 'Hours' : 'Events', fmt.count(i.count)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading(IssueTile.dataShowsHeading),
        Text(i.explanation, style: body),
        heading(IssueTile.worthCheckingHeading),
        Text(i.suggestedAction, style: body),
        heading('Details'),
        Wrap(
          spacing: 24,
          runSpacing: 4,
          children: [
            for (final (label, value) in facts)
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: value),
                ]),
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
              ),
          ],
        ),
        heading('Evidence'),
        if (i.evidence.isEmpty)
          Text(
            i.type == IssueType.heartbeatGap
                ? 'This issue is based on missing heartbeats, so there are no individual events to show.'
                : 'No individual events were kept for this issue.',
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
          )
        else ...[
          Text(
            i.evidence.length >= Issue.maxEvidence
                ? 'The first ${Issue.maxEvidence} supporting events (more were recorded).'
                : '${fmt.count(i.evidence.length)} supporting ${i.evidence.length == 1 ? 'event' : 'events'}.',
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          SortableTable(
            label: 'Evidence for ${i.title}',
            pageSize: 20,
            columns: const [ChartColumn('Time'), ChartColumn('Metric'), ChartColumn('Action')],
            rows: [
              for (final e in i.evidence) [instantWithSeconds(fmt, e.timestamp), e.metric, e.action],
            ],
            sortKeys: [
              for (final e in i.evidence) [e.timestamp, e.metric, e.action],
            ],
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton.tonalIcon(
            onPressed: () => onOpenRoom(i.room),
            icon: const Icon(Icons.meeting_room_outlined),
            label: Text('Open room ${i.room}'),
          ),
        ),
      ],
    );
  }
}
