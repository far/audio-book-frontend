import 'package:flutter/material.dart';

import '../../domain/entities.dart';

/// Chapter list. Reusable body shown two ways: full-screen right after
/// upload (ContentsScreen, nothing is playing yet), and as a Drawer on the
/// reading screen (so the user can switch chapters while listening,
/// without leaving the reading view).
///
/// No voice/provider picker here -- removed after landing, since only one
/// provider is registered by default and a dropdown with one option is
/// just clutter (CLAUDE.md degrade-gracefully guardrail cuts both ways:
/// don't build a choice that isn't actually a choice yet).
class ContentsPanel extends StatelessWidget {
  const ContentsPanel({super.key, required this.book, required this.onChapterTap, this.currentChapterId});

  final Book book;
  final ValueChanged<Chapter> onChapterTap;

  /// Highlights the chapter currently open in the reading screen, if any.
  final String? currentChapterId;

  @override
  Widget build(BuildContext context) {
    final sortedChapters = [...book.chapters]..sort((a, b) => a.order.compareTo(b.order));

    if (sortedChapters.isEmpty) {
      return const Center(child: Text('No chapters found in this book.'));
    }

    return ListView.builder(
      itemCount: sortedChapters.length,
      itemBuilder: (context, index) {
        final chapter = sortedChapters[index];
        final isCurrent = chapter.id == currentChapterId;
        return ListTile(
          selected: isCurrent,
          title: Text(chapter.title),
          subtitle: Text('${chapter.chunks.length} parts'),
          trailing: Icon(isCurrent ? Icons.volume_up : Icons.play_arrow),
          onTap: () => onChapterTap(chapter),
        );
      },
    );
  }
}
