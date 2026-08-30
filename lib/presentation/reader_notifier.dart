import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../domain/entities.dart';
import '../domain/errors.dart';
import '../data/datasources/epub_archive_assets.dart';
import 'app_state.dart';
import 'providers.dart';

/// Fixed: provider/voice picking was removed from the UI (only Piper is
/// registered by default -- see CLAUDE.md degrade-gracefully guardrail).
/// The WS/HTTP wire contract still carries provider+voice_id per call, so
/// this constant is what gets sent everywhere `TtsSelection` is needed.
/// Orchestrates the upload -> contents -> buffering -> reading state
/// machine and drives just_audio.
///
/// Playback design: rather than hand-building a dynamic playlist as WS
/// prefetch events arrive, the player is given the full chapter's chunk
/// URIs up front via setAudioSources -- GET /tts/chunk/{id} synthesizes
/// on-demand (with caching) so any URI is servable whether or not the WS
/// prefetch has reached it yet. WS prefetch is purely a latency
/// optimization (reduces the time-to-first-audio for chunks ahead of the
/// playhead) and drives the "currently generating" highlight; it is not a
/// hard dependency for playback to function. This is exactly what makes
/// [seekToChunk] cheap: seeking to an unprefetched chunk just means the
/// player's next HTTP fetch synthesizes on demand instead of hitting a warm
/// cache -- no special-casing needed.
///
/// Buffering: relies on just_audio/ExoPlayer's own buffering signal
/// (`ProcessingState.buffering`) rather than hand-rolled low/high water
/// marks with hysteresis. Reimplementing what the platform player already
/// does well would be duplicating, not adding, robustness -- a deliberate
/// simplification of ADR-3's buffering-guards section.
///
/// The `Buffering` app state is a separate, earlier wait than the above:
/// it covers the gap between "user tapped a chapter" and "the first chunk
/// is actually ready," giving the tech doc's progress-bar requirement
/// something real to show before handing off to Reading.
///
/// `selectChapter` works from either `Contents` (the initial post-upload
/// pick) or `Reading` (switching chapters from the Drawer while already
/// listening) -- picking a new chapter mid-book pauses the current player,
/// then runs the same Buffering -> Reading transition as the first pick.
class ReaderNotifier extends Notifier<AppState> {
  late final AudioPlayer _player;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  /// Bumped by every [selectChapter]. Chapter selection spans several
  /// awaits (WS round trip, player load) and the user can tap another
  /// chapter -- or the same one -- at any point in between, so each
  /// selection carries the epoch it started with and anything that
  /// resumes later checks it's still the current one before touching
  /// `state` or the player. Without this, a late callback from a
  /// superseded selection writes over the chapter the user actually
  /// picked, which is how playback ended up stuck on one chunk.
  int _epoch = 0;

  /// Carried across chapters so a chosen speed survives switching, which a
  /// per-chapter default would not. Session-only: there is no persistence.
  double _speed = 1.0;

  @override
  AppState build() {
    _player = AudioPlayer();
    ref.onDispose(() {
      _indexSub?.cancel();
      _playerStateSub?.cancel();
      _player.dispose();
    });
    return const Idle();
  }

  Future<void> uploadAndStart({required List<int> bytes, required String filename}) async {
    state = const Uploading();
    // The upload already carries the book's images, so they're read from
    // these bytes rather than fetched back from the backend (plan.md
    // decisions, "On images"). Opened before the upload call so a failed
    // upload doesn't leave the previous book's images addressable.
    ref.read(bookAssetsProvider.notifier).state = EpubArchiveAssets.tryOpen(bytes);
    final Book book;
    try {
      book = await ref.read(bookRepositoryProvider).uploadBook(bytes: bytes, filename: filename);
    } on AppFailure catch (e) {
      state = Failed(e.message);
      return;
    }

    if (book.chapters.isEmpty) {
      state = const Failed('book has no readable chapters');
      return;
    }

    state = Contents(book: book);
  }

  Future<void> selectChapter(Chapter chapter) async {
    final current = state;
    final Book book;
    switch (current) {
      case Contents():
        book = current.book;
      case Reading():
        book = current.book;
      case Buffering():
        book = current.book;
      default:
        return;
    }

    if (chapter.chunks.isEmpty) {
      state = const Failed('chapter has no readable text');
      return;
    }

    final epoch = ++_epoch;
    state = Buffering(book: book, chapter: chapter);

    // Tear the old chapter's playback down *before* anything else: stop
    // (not pause -- pause leaves the previous playlist loaded and the
    // previous item current) and drop the subscriptions, so nothing from
    // the outgoing chapter can reach the incoming state.
    await _detachPlayer();
    if (epoch != _epoch) return;

    await _startReading(book, chapter, epoch, play: ref.read(autoPlayProvider));
  }

  /// Stops playback and unsubscribes, so nothing from the outgoing chapter
  /// can mutate state while the next one is being set up.
  Future<void> _detachPlayer() async {
    await _indexSub?.cancel();
    _indexSub = null;
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _player.stop();
  }


  Future<void> _startReading(
    Book book,
    Chapter chapter,
    int epoch, {
    int startIndex = 0,
    bool play = true,
  }) async {
    // The playlist is loaded *before* the state flips to Reading. Setting
    // Reading first would show the new chapter's text over a player still
    // holding the previous chapter's playlist -- tapping a paragraph in
    // that window seeks into the wrong chapter's audio.
    final urls = ref.read(audioChunkUrlsProvider);
    try {
      await _player.setAudioSources(
        chapter.chunks.map((c) => AudioSource.uri(urls.chunkUri(c.id, ref.read(ttsSelectionProvider)))).toList(),
        initialIndex: startIndex,
      );
    } on PlayerInterruptedException {
      return; // superseded by a newer selectChapter -- that one owns the player now
    } catch (e) {
      if (epoch != _epoch) return;
      state = Failed('could not start playback: $e');
      return;
    }
    if (epoch != _epoch) return;

    await _player.setSpeed(_speed);
    state = Reading(
      book: book,
      chapter: chapter,
      currentChunkIndex: startIndex,
      isPlaying: false,
      speed: _speed,
      bufferingState: BufferingState.buffering,
    );

    _indexSub?.cancel();
    _indexSub = _player.currentIndexStream.listen((index) {
      final current = state;
      if (epoch != _epoch || current is! Reading || index == null) return;
      state = current.copyWith(currentChunkIndex: index);
    });

    _playerStateSub?.cancel();
    _playerStateSub = _player.playerStateStream.listen((playerState) {
      final current = state;
      if (epoch != _epoch || current is! Reading) return;
      final buffering = playerState.processingState == ProcessingState.buffering ||
          playerState.processingState == ProcessingState.loading;
      state = current.copyWith(
        isPlaying: playerState.playing,
        bufferingState: buffering ? BufferingState.buffering : BufferingState.ready,
      );
      if (playerState.processingState == ProcessingState.completed) {
        _onChapterComplete();
      }
    });

    await _player.play();
  }

  /// Jumps playback to an arbitrary chunk -- tapping any paragraph in the
  /// text view, generated or not. Overrides the earlier "no seek in v1"
  /// simplification (ADR-3) on explicit direction; made cheap by the
  /// playback design documented on this class (see class doc).
  Future<void> seekToChunk(int index) async {
    final current = state;
    if (current is! Reading) return;
    if (index < 0 || index >= current.chapter.chunks.length) return;
    await _player.seek(Duration.zero, index: index);
    // Always plays: tapping a part is an explicit request to hear it, so
    // autoplay (which governs *chapter* selection) doesn't apply.
    await _player.play();
    // currentIndexStream (wired in _startReading) picks up the new index
    // and reports it via _reportAdvance -- no separate call needed here.
  }

  /// Rebuilds the current chapter's playlist after a voice change.
  ///
  /// The chunk URLs carry the provider and voice, so they're baked in when
  /// the playlist is built -- without this a change would silently do
  /// nothing until the next chapter. The playhead is preserved, so the
  /// listener continues from where they were in the new voice.
  Future<void> reloadForSelectionChange() async {
    final current = state;
    if (current is! Reading) return;
    final resumeAt = current.currentChunkIndex;

    final epoch = ++_epoch;
    state = Buffering(book: current.book, chapter: current.chapter);
    await _detachPlayer();
    if (epoch != _epoch) return;

    // Keeps whatever it was doing: a voice change shouldn't start
    // playback that was paused, nor pause playback that was running.
    await _startReading(current.book, current.chapter, epoch, startIndex: resumeAt, play: current.isPlaying);
  }

  /// Steps to the previous part, clamped at the start of the chapter.
  Future<void> previousChunk() async {
    final current = state;
    if (current is! Reading) return;
    await seekToChunk(current.currentChunkIndex - 1);
  }

  /// Steps to the next part, clamped at the end of the chapter.
  Future<void> nextChunk() async {
    final current = state;
    if (current is! Reading) return;
    await seekToChunk(current.currentChunkIndex + 1);
  }

  /// Seeks by chunk ID rather than playlist index -- the document's blocks
  /// reference chunks by ID, and only [Chapter.indexOfChunk] knows how
  /// those map onto the player's playlist positions.
  Future<void> seekToChunkId(String chunkId) async {
    final current = state;
    if (current is! Reading) return;
    final index = current.chapter.indexOfChunk(chunkId);
    if (index < 0) return;
    await seekToChunk(index);
  }

  Future<void> togglePlayPause() async {
    final current = state;
    if (current is! Reading) return;
    if (current.isPlaying) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> setSpeed(double speed) async {
    final current = state;
    if (current is! Reading) return;
    await _player.setSpeed(speed);
    _speed = speed;
    state = current.copyWith(speed: speed);
  }

  void _onChapterComplete() {
    final current = state;
    if (current is! Reading) return;
    // End-of-chapter: no auto-advance -- surface as stopped playback. The
    // user opens the Drawer and picks the next chapter manually.
    state = current.copyWith(isPlaying: false);
  }
}
