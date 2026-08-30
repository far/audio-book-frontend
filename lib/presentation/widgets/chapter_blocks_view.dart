import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/entities.dart';
import '../../domain/repositories.dart';
import '../app_state.dart';
import 'code_highlighting.dart';

/// Green: currently being read aloud. Comes from the player's own index,
/// so it needs nothing from the server.
///
/// There used to be a blue "being synthesized" highlight and a dimmed
/// "not yet synthesized" style too, both fed by the WebSocket control
/// plane. With that removed the client has no view of what the server is
/// working on, and inventing one would mean guessing.
const _playingBackground = Color(0xFFB9F0C4);

/// Renders a chapter as the document it came from -- headings and images in
/// place, prose as tappable parts.
///
/// One widget per block, built lazily: a chapter can run to hundreds of
/// blocks, and the per-block [GlobalKey]s are what let playback scroll to
/// the block holding the current part.
///
/// Prose is drawn as a single [Text.rich] per paragraph with one span per
/// chunk, rather than a box per chunk. Chunks are sentence-sized, so
/// boxing each one broke paragraphs into a stack of unrelated slabs; spans
/// keep the paragraph reading as a paragraph while still letting each
/// sentence carry its own highlight and tap target.
class ChapterBlocksView extends StatefulWidget {
  const ChapterBlocksView({
    super.key,
    required this.chapter,
    required this.state,
    required this.assets,
    required this.onChunkTap,
  });

  final Chapter chapter;
  final Reading state;

  /// Null when the picked file couldn't be opened as a zip -- images then
  /// render as their alt text rather than failing the chapter.
  final BookAssets? assets;
  final ValueChanged<String> onChunkTap;

  @override
  State<ChapterBlocksView> createState() => _ChapterBlocksViewState();
}

class _ChapterBlocksViewState extends State<ChapterBlocksView> {
  final _scrollController = ScrollController();
  Map<int, GlobalKey> _blockKeys = {};

  // Chapter-scoped lookups, built once per chapter rather than per frame.
  // The view rebuilds on every playback tick, and both of these are
  // O(chunks) to construct -- doing it inside build() made the cost scale
  // with chapter length on each tick.
  Map<String, Chunk> _chunksById = const {};
  Map<String, int> _blockIndexByChunkId = const {};

  @override
  void initState() {
    super.initState();
    _indexChapter();
  }

  @override
  void didUpdateWidget(covariant ChapterBlocksView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter.id != widget.chapter.id) {
      // GlobalKeys track ONE element as it moves within the tree; reusing
      // them across a chapter swap makes Flutter treat block N of the old
      // chapter and block N of the new one as the same widget, which can
      // leave stale content on screen.
      _blockKeys = {};
      _indexChapter();
    }
    if (oldWidget.state.currentChunkIndex != widget.state.currentChunkIndex) {
      _scrollToCurrent();
    }
  }

  void _indexChapter() {
    _chunksById = {for (final chunk in widget.chapter.chunks) chunk.id: chunk};
    _blockIndexByChunkId = {
      for (final (index, block) in widget.chapter.blocks.indexed)
        for (final chunkId in block.chunkIds) chunkId: index,
    };
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  String? get _currentChunkId {
    final chunks = widget.chapter.chunks;
    final index = widget.state.currentChunkIndex;
    return index >= 0 && index < chunks.length ? chunks[index].id : null;
  }

  void _scrollToCurrent() {
    final chunkId = _currentChunkId;
    if (chunkId == null) return;
    final context = _blockKeys[_blockIndexByChunkId[chunkId]]?.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 300), alignment: 0.3);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final blocks = widget.chapter.blocks;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: blocks.length,
      itemBuilder: (context, index) {
        final key = _blockKeys.putIfAbsent(index, GlobalKey.new);
        return Padding(
          key: key,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: switch (blocks[index]) {
            TextBlock(:final segments) => _buildProse(theme, segments),
            HeadingBlock(:final text, :final level, :final chunkIds) => _buildHeading(theme, text, level, chunkIds),
            CodeBlock(:final text) => _buildCode(theme, text),
            ImageBlock(:final src, :final alt) => _buildImage(theme, src, alt),
          },
        );
      },
    );
  }

  Widget _buildProse(ThemeData theme, List<Segment> segments, {TextStyle? baseStyle}) {
    return _ProseText(
      segments: segments,
      style: baseStyle ?? theme.textTheme.bodyLarge,
      currentChunkId: _currentChunkId,
      onChunkTap: widget.onChunkTap,
    );
  }

  /// Headings are read aloud like prose -- same spans, same highlighting,
  /// same tap-to-seek -- just rendered at heading weight.
  Widget _buildHeading(ThemeData theme, String text, int level, List<String> chunkIds) {
    final style = switch (level) {
      1 => theme.textTheme.headlineSmall,
      2 => theme.textTheme.titleLarge,
      _ => theme.textTheme.titleMedium,
    };
    final bold = style?.copyWith(fontWeight: FontWeight.bold);
    // A heading whose chunks were dropped by truncation still shows its
    // own text -- it just can't be played.
    final segments = chunkIds.isEmpty
        ? [Segment(text: text)]
        : [
            for (final id in chunkIds)
              if (_chunksById[id] case final chunk?) Segment(text: chunk.text, chunkId: id),
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: _buildProse(theme, segments, baseStyle: bold),
    );
  }

  /// Shown verbatim and never tappable -- a code listing carries no chunk
  /// IDs, so there is nothing to seek to. Scrolls horizontally rather than
  /// wrapping, since wrapped code is unreadable.
  Widget _buildCode(ThemeData theme, String text) {
    final base = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(TextSpan(children: highlightCode(text, base)), style: base),
      ),
    );
  }

  Widget _buildImage(ThemeData theme, String src, String alt) {
    final bytes = widget.assets?.read(src);
    if (bytes == null) {
      // The book references an image the archive doesn't ship, or the file
      // wasn't readable as a zip. Alt text beats a broken-image box.
      return alt.isEmpty
          ? const SizedBox.shrink()
          : Text(alt, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic));
    }
    return Center(
      child: Image.memory(
        Uint8List.fromList(bytes),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stack) =>
            Text(alt, style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
      ),
    );
  }
}

/// Prose (or a heading) as one paragraph of tappable spans.
///
/// Its own widget so that the tap recognizers -- which own resources and
/// must be disposed -- live and die with the block. Held on the list's
/// State instead, they accumulated one per chunk for the whole chapter and
/// were only released on a chapter change; here `ListView.builder`
/// reclaims them as blocks scroll out of view.
class _ProseText extends StatefulWidget {
  const _ProseText({
    required this.segments,
    required this.style,
    required this.currentChunkId,
    required this.onChunkTap,
  });

  final List<Segment> segments;
  final TextStyle? style;
  final String? currentChunkId;
  final ValueChanged<String> onChunkTap;

  @override
  State<_ProseText> createState() => _ProseTextState();
}

class _ProseTextState extends State<_ProseText> {
  final Map<String, TapGestureRecognizer> _recognizers = {};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  // Reads `widget` at tap time rather than capturing it, so a recognizer
  // cached across a rebuild still calls the current callback.
  TapGestureRecognizer _recognizerFor(String chunkId) => _recognizers.putIfAbsent(
    chunkId,
    () => TapGestureRecognizer()..onTap = () => widget.onChunkTap(chunkId),
  );

  TextStyle? _chunkStyle(String chunkId) {
    if (chunkId != widget.currentChunkId) return widget.style;
    return widget.style?.copyWith(backgroundColor: _playingBackground);
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in widget.segments)
            if (segment.chunkId case final chunkId?)
              TextSpan(
                text: '${segment.text} ',
                recognizer: _recognizerFor(chunkId),
                style: _chunkStyle(chunkId),
              )
            else
              // Shown but never voiced -- a formula, an inline snippet, or
              // text past the synthesis budget. Rendered plainly and left
              // untappable: there is nothing to seek to.
              TextSpan(text: '${segment.text} ', style: widget.style),
        ],
      ),
      style: widget.style,
    );
  }
}
