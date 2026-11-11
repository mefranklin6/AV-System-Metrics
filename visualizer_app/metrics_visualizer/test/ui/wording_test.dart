// Keeps the interface platform-neutral and written for AV professionals and
// analysts: no wording that assumes a particular control program, a support
// process (help desk, service desk, tickets) or what users were thinking.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Terms that must not appear in user-facing text. Matched case-insensitively.
final Map<String, RegExp> bannedTerms = {
  'help desk': RegExp(r'help[\s_-]?desk', caseSensitive: false),
  'service desk': RegExp(r'service[\s_-]?desk', caseSensitive: false),
  'ticket': RegExp(r'ticket', caseSensitive: false),
  'training': RegExp(r'training', caseSensitive: false),
  'confused / confusing': RegExp(r'confus', caseSensitive: false),
  'struggle': RegExp(r'struggl', caseSensitive: false),
  'ControlScript': RegExp(r'controlscript', caseSensitive: false),
  'GVE / GlobalViewer': RegExp(r'\bGVE\b|globalviewer', caseSensitive: false),
};

/// The code of [source] with comments removed, so only code and string
/// literals (the text users can see) are checked. Doc comments may name the
/// program the defaults also accept; the interface may not.
String withoutComments(String source) => [
      for (final line in source.split('\n'))
        if (!line.trimLeft().startsWith('//')) line.replaceFirst(RegExp(r'\s//\s.*$'), ''),
    ].join('\n');

/// Every Dart file whose strings can reach the screen or a CSV export.
List<File> userFacingSources() => [
      for (final dir in ['lib/ui', 'lib/state', 'lib/analytics'])
        ...Directory(dir)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];

void main() {
  test('the scanner finds banned wording in strings but ignores comments', () {
    expect(bannedTerms['help desk']!.hasMatch(withoutComments("final s = 'Call the Help Desk';")), isTrue);
    expect(bannedTerms['ticket']!.hasMatch(withoutComments('// tickets are not assumed\nfinal x = 1;')), isFalse);
    expect(bannedTerms['GVE / GlobalViewer']!.hasMatch("'GVE'"), isTrue);
    expect(bannedTerms['GVE / GlobalViewer']!.hasMatch("'Gven'"), isFalse);
  });

  test('UI, state and analytics strings use neutral wording', () {
    final sources = userFacingSources();
    expect(sources.length, greaterThan(20));
    final problems = <String>[];
    for (final f in sources) {
      final code = withoutComments(f.readAsStringSync().replaceAll('\r\n', '\n'));
      final lines = code.split('\n');
      for (var i = 0; i < lines.length; i++) {
        for (final e in bannedTerms.entries) {
          if (e.value.hasMatch(lines[i])) problems.add('${f.path}: "${e.key}" in: ${lines[i].trim()}');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the app README names the ControlScript template only as one accepted example', () {
    final readme = File('README.md').readAsStringSync();
    final mentions = RegExp('ControlScript').allMatches(readme).length;
    expect(mentions, 1);
    expect(readme, contains('That template is one implementation among many and is not'));
    for (final term in ['help desk', 'service desk', 'ticket', 'training', 'confus', 'struggl']) {
      expect(readme.toLowerCase(), isNot(contains(term)), reason: term);
    }
  });
}
