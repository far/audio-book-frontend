import 'package:flutter/material.dart';

/// Minimal, language-agnostic syntax colouring for code blocks.
///
/// Deliberately a lexer over four categories -- comment, string, number,
/// keyword -- and not a parser. A book can print any language (and often
/// pseudocode), so there is no grammar to target, and a wrong guess costs
/// only a colour. The keyword set is the intersection of what shows up
/// across mainstream languages; unknown words simply stay plain.
///
/// Code is never read aloud (it carries no chunk IDs), so this is purely
/// presentation and does not affect playback.
const _keywords = {
  'abstract', 'and', 'as', 'async', 'await', 'bool', 'break', 'case', 'catch', 'char', 'class',
  'const', 'continue', 'def', 'default', 'do', 'double', 'elif', 'else', 'end', 'enum', 'except',
  'extends', 'false', 'final', 'finally', 'float', 'fn', 'for', 'from', 'func', 'function', 'if',
  'implements', 'import', 'in', 'int', 'interface', 'is', 'lambda', 'let', 'match', 'mut', 'new',
  'nil', 'none', 'not', 'null', 'or', 'package', 'pass', 'private', 'protected', 'public', 'raise',
  'return', 'self', 'static', 'struct', 'super', 'switch', 'then', 'this', 'throw', 'trait', 'true',
  'try', 'type', 'typedef', 'use', 'var', 'void', 'while', 'with', 'yield',
};

const _commentColor = Color(0xFF6A737D);
const _stringColor = Color(0xFF0A7B44);
const _numberColor = Color(0xFF9A4B00);
const _keywordColor = Color(0xFF7B1FA2);

/// Line comments (`//`, `#`, `--`), quoted strings, numbers, then words.
/// Strings come before comments in the alternation so a `#` inside a
/// string isn't mistaken for one.
///
/// Quotes are written as `\x27` (') and `\x22` (") because a Dart raw
/// string can't escape its own delimiter, and raw is what keeps the
/// backslashes in the rest of the pattern readable.
final _token = RegExp(
  r'(?<string>\x27\x27\x27[\s\S]*?\x27\x27\x27|\x22\x22\x22[\s\S]*?\x22\x22\x22'
  r'|\x27[^\x27\n]*\x27|\x22[^\x22\n]*\x22)'
  r'|(?<comment>//[^\n]*|#[^\n]*|--[^\n]*)'
  r'|(?<number>\b\d+(\.\d+)?\b)'
  r'|(?<word>[A-Za-z_][A-Za-z0-9_]*)',
);

/// Splits [code] into coloured spans over [base].
List<InlineSpan> highlightCode(String code, TextStyle? base) {
  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final match in _token.allMatches(code)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: code.substring(cursor, match.start)));
    }

    final color = switch (match) {
      _ when match.namedGroup('comment') != null => _commentColor,
      _ when match.namedGroup('string') != null => _stringColor,
      _ when match.namedGroup('number') != null => _numberColor,
      _ when _keywords.contains(match.namedGroup('word')) => _keywordColor,
      _ => null,
    };

    spans.add(TextSpan(text: match[0], style: color == null ? null : base?.copyWith(color: color)));
    cursor = match.end;
  }

  if (cursor < code.length) {
    spans.add(TextSpan(text: code.substring(cursor)));
  }
  return spans;
}
