import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/app_state.dart';
import 'presentation/providers.dart';
import 'presentation/screens/buffering_screen.dart';
import 'presentation/screens/contents_screen.dart';
import 'presentation/screens/reading_screen.dart';
import 'presentation/screens/upload_screen.dart';

void main() {
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const AppRoot(),
    );
  }
}

class AppRoot extends ConsumerWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);

    return switch (state) {
      Idle() => const UploadScreen(statusText: 'Pick an EPUB file to begin.'),
      Uploading() => const UploadScreen(statusText: 'Uploading file…'),
      Contents() => ContentsScreen(state: state),
      Buffering() => BufferingScreen(state: state),
      Reading() => ReadingScreen(state: state),
      Failed(:final message) => UploadScreen(statusText: 'Pick an EPUB file to begin.', errorMessage: message),
    };
  }
}
