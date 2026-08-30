import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../providers.dart';
import '../widgets/contents_panel.dart';
import '../widgets/upload_action.dart';
import 'settings_screen.dart';

/// Table of contents shown after upload -- nothing plays until the user
/// taps a chapter. The same panel reappears as a Drawer on the reading
/// screen so chapters can be switched mid-listen.
class ContentsScreen extends ConsumerWidget {
  const ContentsScreen({super.key, required this.state});

  final Contents state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(readerNotifierProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text(state.book.title),
        actions: [
          const UploadFileButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: ContentsPanel(book: state.book, onChapterTap: notifier.selectChapter),
    );
  }
}
