import '../domain/entities.dart';

/// App state machine: Idle -> Uploading -> Contents -> Buffering -> Reading | Failed.
/// Native Dart sealed class (no freezed -- see data/dto note) so callers get
/// exhaustive `switch` checking for free.
///
/// `Extracting` was dropped: EPUB parsing happens synchronously within the
/// upload response, so there was never actually a separate "extracting"
/// phase to show -- it was a UI-only placeholder for work that doesn't
/// exist as a distinct step. Removed per the YAGNI guardrail rather than
/// keeping dead state around.
sealed class AppState {
  const AppState();
}

class Idle extends AppState {
  const Idle();
}

class Uploading extends AppState {
  const Uploading();
}

/// Table of contents shown right after upload. Nothing plays until the
/// user taps a chapter (see Buffering).
class Contents extends AppState {
  const Contents({required this.book});

  final Book book;
}

/// Chapter tapped; waiting for the first chunk to be prefetched (or a
/// timeout) before handing off to Reading. Gives the "Generating voice…"
/// progress bar the tech doc asks for something real to show.
class Buffering extends AppState {
  const Buffering({required this.book, required this.chapter});

  final Book book;
  final Chapter chapter;
}

enum BufferingState { buffering, ready }

class Reading extends AppState {
  const Reading({
    required this.book,
    required this.chapter,
    required this.currentChunkIndex,
    required this.isPlaying,
    required this.speed,
    required this.bufferingState,
  });

  final Book book;
  final Chapter chapter;
  final int currentChunkIndex;
  final bool isPlaying;
  final double speed;
  final BufferingState bufferingState;

  Reading copyWith({
    int? currentChunkIndex,
    bool? isPlaying,
    double? speed,
    BufferingState? bufferingState,
  }) {
    return Reading(
      book: book,
      chapter: chapter,
      currentChunkIndex: currentChunkIndex ?? this.currentChunkIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      speed: speed ?? this.speed,
      bufferingState: bufferingState ?? this.bufferingState,
    );
  }
}

class Failed extends AppState {
  const Failed(this.message);

  final String message;
}
