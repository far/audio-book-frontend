/// Repository interfaces. Presentation depends on these, never on `dio`,
/// or `just_audio` directly (dependency rule, CLAUDE.md).
library;

import 'entities.dart';

abstract class BookRepository {
  /// Providers the backend actually has configured. Anything needing an
  /// API key it wasn't given simply isn't in the list.
  Future<List<TtsProviderInfo>> listTtsProviders();

  /// Uploads an EPUB file and returns the parsed Book. Throws [UploadFailure]
  /// on rejection (wrong format, bad magic bytes, too large, empty book).
  Future<Book> uploadBook({required List<int> bytes, required String filename});
}

/// Non-text assets of the open book, read from the EPUB the client still
/// holds rather than fetched from the backend -- the upload already
/// contained them, and the backend is busy synthesizing (see plan.md
/// decisions, "On images").
abstract class BookAssets {
  /// Bytes for an archive-relative path (`ImageBlock.src`), or null if the
  /// archive has no such entry. Null is normal, not exceptional: a book
  /// can reference an image it doesn't ship.
  List<int>? read(String href);
}

