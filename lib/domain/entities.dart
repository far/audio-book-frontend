/// Domain entities -- pure Dart, no Flutter import (dependency rule, CLAUDE.md).
library;

class Chunk {
  const Chunk({required this.id, required this.index, required this.text});

  final String id;
  final int index;
  final String text;
}

/// One renderable element of a chapter, in document order.
///
/// The reader shows the book as an EPUB reader would -- headings and
/// images in place -- while only prose is selectable for synthesis. Sealed
/// so a renderer must handle every kind explicitly. "Renderable" and
/// "readable" are separate: [chunkIds] is what makes a block selectable
/// for synthesis, and it's empty for images and code listings.
/// Mirrors `Block` in backend/app/domain/entities.py.
sealed class Block {
  const Block();

  /// Chunks this block is read from; empty for blocks that are shown but
  /// never voiced. Kept on the base class so callers don't have to know
  /// which kinds are readable -- that set has already changed once.
  List<String> get chunkIds => const [];
}

/// A run of a paragraph, and the chunk that voices it -- or null.
///
/// Text is shown whether or not it can be read aloud, so display and
/// playback stay separate: a formula or inline snippet mid-paragraph is
/// rendered in place and skipped by the voice, as is anything truncation
/// dropped for budget. Without the split, making something unreadable
/// would delete it from the page.
class Segment {
  const Segment({required this.text, this.chunkId});

  final String text;
  final String? chunkId;
}

/// A paragraph, in reading order. Its voiced segments are its chunks; the
/// rest is shown but never spoken.
class TextBlock extends Block {
  const TextBlock(this.segments);

  final List<Segment> segments;

  @override
  List<String> get chunkIds => [for (final segment in segments) ?segment.chunkId];
}

/// Read aloud like prose, but rendered as a heading -- a listener expects
/// to hear "Chapter One" before the chapter starts.
class HeadingBlock extends Block {
  const HeadingBlock({required this.text, required this.level, required this.chunkIds});

  final String text;
  final int level;

  @override
  final List<String> chunkIds;
}

/// Shown verbatim, never read aloud: a synthesized listing is minutes of
/// unintelligible punctuation.
class CodeBlock extends Block {
  const CodeBlock(this.text);

  final String text;
}

class ImageBlock extends Block {
  const ImageBlock({required this.src, required this.alt});

  /// Path *within the EPUB archive*, normalised to archive-root relative
  /// by the backend parser. Not a URL: images are read straight out of the
  /// uploaded file the client still holds, so this is a lookup key (see
  /// [BookAssets]).
  final String src;
  final String alt;
}

class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    required this.order,
    required this.chunks,
    required this.blocks,
  });

  final String id;
  final String title;
  final int order;
  final List<Chunk> chunks;
  final List<Block> blocks;

  /// Playback position of [chunkId], or -1. The player's playlist is built
  /// from [chunks] in order, so this is the one place that converts the
  /// chunk IDs the document carries into the indices the player speaks.
  int indexOfChunk(String chunkId) => chunks.indexWhere((c) => c.id == chunkId);
}

class Book {
  const Book({required this.id, required this.title, required this.chapters, required this.firstChapterId});

  final String id;
  final String title;
  final List<Chapter> chapters;
  final String? firstChapterId;

  Chapter? get firstChapter {
    if (firstChapterId == null) return null;
    for (final chapter in chapters) {
      if (chapter.id == firstChapterId) return chapter;
    }
    return null;
  }
}

/// A provider the backend has actually registered, with the voices it can
/// use. Built from `GET /tts/providers` -- a provider missing its API key
/// is never registered, so it can't be offered and then fail.
class TtsProviderInfo {
  const TtsProviderInfo({required this.name, required this.voices});

  final String name;
  final List<TtsVoice> voices;
}

class TtsVoice {
  const TtsVoice({required this.id, required this.name});

  /// What the provider's API takes.
  final String id;

  /// What a person picks from. For ElevenLabs these differ entirely.
  final String name;
}

/// The provider and voice to synthesize with, sent as query parameters on
/// every chunk request.
class TtsSelection {
  const TtsSelection({required this.provider, required this.voiceId});

  /// Piper is the only provider registered by default -- it needs no API
  /// key -- so it is what the app starts on.
  static const piperDefault = TtsSelection(provider: 'piper', voiceId: 'en_US-lessac-medium');

  final String provider;
  final String voiceId;

  @override
  bool operator ==(Object other) =>
      other is TtsSelection && other.provider == provider && other.voiceId == voiceId;

  @override
  int get hashCode => Object.hash(provider, voiceId);
}
