/// Composition root: concretes wired here only, matching the backend's
/// api/deps.py pattern. Widgets depend on notifiers, never on dio/sockets/
/// just_audio directly (dependency rule, CLAUDE.md).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/datasources/audio_chunk_urls.dart';
import '../data/datasources/backend_rest_api.dart';
import '../data/repositories/book_repository_impl.dart';
import '../domain/entities.dart';
import '../domain/repositories.dart';
import '../src/config.dart';
import 'app_state.dart';
import 'reader_notifier.dart';

/// Runtime-editable backend address (defaults to --dart-define=API_BASE_URL).
final apiBaseUrlProvider = StateProvider<String>((ref) => apiBaseUrl);

// The address is runtime-editable, so this is rebuilt whenever it changes
// and the replaced instance owns a live connection pool. It needs
// releasing, or editing the address in Settings leaks one per edit.
final backendRestApiProvider = Provider<BackendRestApi>((ref) {
  final api = BackendRestApi(ref.watch(apiBaseUrlProvider));
  ref.onDispose(api.close);
  return api;
});

final bookRepositoryProvider = Provider<BookRepository>(
  (ref) => BookRepositoryImpl(ref.watch(backendRestApiProvider)),
);

final audioChunkUrlsProvider = Provider<AudioChunkUrls>(
  (ref) => AudioChunkUrls(ref.watch(apiBaseUrlProvider)),
);



/// Provider and voice used for synthesis, sent on every chunk request.
/// Starts on Piper, the only provider registered without an API key.
final ttsSelectionProvider = StateProvider<TtsSelection>((ref) => TtsSelection.piperDefault);

/// What the backend has configured, for the Settings picker. Re-fetched if
/// the backend address changes, since a different server may offer
/// different providers.
final ttsProvidersProvider = FutureProvider<List<TtsProviderInfo>>((ref) {
  return ref.watch(bookRepositoryProvider).listTtsProviders();
});

/// Whether picking a chapter starts playing it.
///
/// On by default -- picking a chapter is normally a request to hear it.
/// Off suits reading along, or choosing where to start before committing
/// to synthesis: the chapter loads and shows its text, and playback waits
/// for Play or a tap on a paragraph.
final autoPlayProvider = StateProvider<bool>((ref) => true);

/// Images of the book currently open, read from the EPUB the user picked.
/// Set by [ReaderNotifier.uploadAndStart] and null until then (and after a
/// book that turned out not to be readable as a zip).
final bookAssetsProvider = StateProvider<BookAssets?>((ref) => null);

final readerNotifierProvider = NotifierProvider<ReaderNotifier, AppState>(ReaderNotifier.new);
