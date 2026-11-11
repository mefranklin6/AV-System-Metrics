import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'status_widgets.dart';

/// Where the Implementation Guide is published: the platform-neutral
/// description of which events a control program logs and how they are
/// named. The app's event recognition defaults follow it.
const String implementationGuideUrl =
    'https://github.com/mefranklin6/AV-System-Metrics/blob/main/Implementation_Guide.md';

/// The Implementation Guide's address as text with a copy
/// button. The app opens no browser itself, so the address is shown in full
/// and can be copied (WCAG 2.4.4: the purpose is in the visible text).
class GuideLink extends StatelessWidget {
  const GuideLink({
    super.key,
    this.intro = 'The Implementation Guide describes which events to log and how to name them:',
  });

  /// Sentence shown before the address.
  final String intro;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(intro, style: body),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(implementationGuideUrl, style: body?.copyWith(fontWeight: FontWeight.w600)),
            IconButton(
              tooltip: 'Copy the Implementation Guide address',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: implementationGuideUrl));
                if (context.mounted) announce(context, 'Implementation Guide address copied to the clipboard.');
              },
            ),
          ],
        ),
      ],
    );
  }
}
