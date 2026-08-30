import 'package:aireader/presentation/widgets/code_highlighting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The text of every span, so a test can assert the lexer never loses or
/// duplicates input -- the property that matters most for a listing shown
/// verbatim.
String _joined(List<InlineSpan> spans) => spans.map((s) => (s as TextSpan).text ?? '').join();

Color? _colorOf(List<InlineSpan> spans, String text) =>
    spans.whereType<TextSpan>().firstWhere((s) => s.text == text).style?.color;

void main() {
  const base = TextStyle();

  test('reproduces the source exactly', () {
    const code = 'def demo(x):\n    # halve it\n    return x / 2\n';

    expect(_joined(highlightCode(code, base)), code);
  });

  test('colours keywords, strings, numbers and comments differently', () {
    final spans = highlightCode('return "hi" # note\nx = 42', base);

    final colors = {_colorOf(spans, 'return'), _colorOf(spans, '"hi"'), _colorOf(spans, '42')};
    expect(colors.length, 3, reason: 'each category needs its own colour');
    expect(colors.contains(null), isFalse);
  });

  test('leaves unknown identifiers plain', () {
    // A book can print any language or pseudocode, so anything outside the
    // shared keyword set stays uncoloured rather than being guessed at.
    final spans = highlightCode('frobnicate(thing)', base);

    expect(_colorOf(spans, 'frobnicate'), isNull);
  });

  test('does not treat a # inside a string as a comment', () {
    final spans = highlightCode('x = "a # b"', base);

    expect(_colorOf(spans, '"a # b"'), isNotNull);
  });
}
