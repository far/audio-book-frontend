import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import '../providers.dart';
import '../widgets/chapter_blocks_view.dart';
import '../widgets/contents_panel.dart';
import '../widgets/upload_action.dart';
import '../widgets/playback_controls.dart';
import 'settings_screen.dart';

class ReadingScreen extends ConsumerWidget {
  const ReadingScreen({super.key, required this.state});

  final Reading state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(readerNotifierProvider.notifier);
    final isLastChunk = state.currentChunkIndex >= state.chapter.chunks.length - 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(state.chapter.title),
        // Scaffold auto-adds the drawer-toggle icon since `leading` is left
        // unset -- lets the user switch chapters mid-listen without leaving
        // the reading view.
        actions: [
          const UploadFileButton(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ContentsPanel(
            book: state.book,
            currentChapterId: state.chapter.id,
            onChapterTap: (chapter) {
              Navigator.of(context).pop(); // close the drawer
              notifier.selectChapter(chapter);
            },
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ChapterBlocksView(
              chapter: state.chapter,
              state: state,
              assets: ref.watch(bookAssetsProvider),
              onChunkTap: notifier.seekToChunkId,
            ),
          ),
          if (isLastChunk && !state.isPlaying)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('End of chapter'),
            ),
          PlaybackControls(
            state: state,
            onTogglePlayPause: notifier.togglePlayPause,
            onSpeedChanged: notifier.setSpeed,
            onPrevious: notifier.previousChunk,
            onNext: notifier.nextChunk,
          ),
        ],
      ),
    );
  }
}
