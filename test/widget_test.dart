import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aireader/main.dart';

void main() {
  testWidgets('Idle state shows the upload prompt and button', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: MyApp()));

    expect(find.text('Pick an EPUB file to begin.'), findsOneWidget);
    expect(find.text('Upload EPUB'), findsOneWidget);
  });
}
