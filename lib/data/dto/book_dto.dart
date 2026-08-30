/// DTOs mirroring backend/app/api/dto.py. Hand-parsed rather than generated
/// (see pubspec/CLAUDE.md note: build_runner's analyzer requirement and
/// freezed's stable-release support don't currently overlap on this Dart
/// SDK version -- dropped the codegen toolchain rather than fight it).
library;

import '../../domain/entities.dart';

class ChunkDto {
  const ChunkDto({required this.id, required this.index, required this.text});

  factory ChunkDto.fromJson(Map<String, dynamic> json) =>
      ChunkDto(id: json['id'] as String, index: json['index'] as int, text: json['text'] as String);

  final String id;
  final int index;
  final String text;

  Chunk toDomain() => Chunk(id: id, index: index, text: text);
}

/// Tagged union mirroring `BlockDTO` in backend/app/api/dto.py -- `kind`
/// selects which fields carry meaning. Unknown kinds map to null and are
/// dropped rather than throwing: a backend that learns a new block type
/// shouldn't break rendering of the ones this client understands.
class SegmentDto {
  const SegmentDto({required this.text, required this.chunkId});

  factory SegmentDto.fromJson(Map<String, dynamic> json) =>
      SegmentDto(text: json['text'] as String, chunkId: json['chunk_id'] as String?);

  final String text;
  final String? chunkId;

  Segment toDomain() => Segment(text: text, chunkId: chunkId);
}

class BlockDto {
  const BlockDto({
    required this.kind,
    required this.segments,
    required this.chunkIds,
    required this.text,
    required this.level,
    required this.src,
    required this.alt,
  });

  factory BlockDto.fromJson(Map<String, dynamic> json) => BlockDto(
    kind: json['kind'] as String,
    segments: (json['segments'] as List<dynamic>? ?? const [])
        .map((s) => SegmentDto.fromJson(s as Map<String, dynamic>))
        .toList(),
    chunkIds: (json['chunk_ids'] as List<dynamic>? ?? const []).cast<String>(),
    text: json['text'] as String? ?? '',
    level: json['level'] as int? ?? 0,
    src: json['src'] as String? ?? '',
    alt: json['alt'] as String? ?? '',
  );

  final String kind;
  final List<SegmentDto> segments;
  final List<String> chunkIds;
  final String text;
  final int level;
  final String src;
  final String alt;

  Block? toDomain() => switch (kind) {
    'text' => TextBlock(segments.map((s) => s.toDomain()).toList()),
    'heading' => HeadingBlock(text: text, level: level, chunkIds: chunkIds),
    'image' => ImageBlock(src: src, alt: alt),
    'code' => CodeBlock(text),
    _ => null,
  };
}

class ChapterDto {
  const ChapterDto({
    required this.id,
    required this.title,
    required this.order,
    required this.chunks,
    required this.blocks,
  });

  factory ChapterDto.fromJson(Map<String, dynamic> json) => ChapterDto(
    id: json['id'] as String,
    title: json['title'] as String,
    order: json['order'] as int,
    chunks: (json['chunks'] as List<dynamic>)
        .map((c) => ChunkDto.fromJson(c as Map<String, dynamic>))
        .toList(),
    blocks: (json['blocks'] as List<dynamic>? ?? const [])
        .map((b) => BlockDto.fromJson(b as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String title;
  final int order;
  final List<ChunkDto> chunks;
  final List<BlockDto> blocks;

  Chapter toDomain() => Chapter(
    id: id,
    title: title,
    order: order,
    chunks: chunks.map((c) => c.toDomain()).toList(),
    blocks: blocks.map((b) => b.toDomain()).nonNulls.toList(),
  );
}

class BookDto {
  const BookDto({required this.id, required this.title, required this.chapters, required this.firstChapterId});

  factory BookDto.fromJson(Map<String, dynamic> json) => BookDto(
    id: json['id'] as String,
    title: json['title'] as String,
    chapters: (json['chapters'] as List<dynamic>)
        .map((c) => ChapterDto.fromJson(c as Map<String, dynamic>))
        .toList(),
    firstChapterId: json['first_chapter_id'] as String?,
  );

  final String id;
  final String title;
  final List<ChapterDto> chapters;
  final String? firstChapterId;

  Book toDomain() => Book(
    id: id,
    title: title,
    chapters: chapters.map((c) => c.toDomain()).toList(),
    firstChapterId: firstChapterId,
  );
}


/// Mirrors `ProviderInfoDTO` / `VoiceDTO` in backend/app/api/routers/tts.py.
class ProviderInfoDto {
  const ProviderInfoDto({required this.name, required this.voices});

  factory ProviderInfoDto.fromJson(Map<String, dynamic> json) => ProviderInfoDto(
    name: json['name'] as String,
    voices: (json['voices'] as List<dynamic>)
        .map((v) => VoiceDto.fromJson(v as Map<String, dynamic>))
        .toList(),
  );

  final String name;
  final List<VoiceDto> voices;

  TtsProviderInfo toDomain() =>
      TtsProviderInfo(name: name, voices: voices.map((v) => v.toDomain()).toList());
}

class VoiceDto {
  const VoiceDto({required this.id, required this.name});

  factory VoiceDto.fromJson(Map<String, dynamic> json) =>
      VoiceDto(id: json['id'] as String, name: json['name'] as String);

  final String id;
  final String name;

  TtsVoice toDomain() => TtsVoice(id: id, name: name);
}
