# AI Reader

Flutter app that renders an EPUB as a readable document and reads it aloud, backed by a FastAPI TTS service.

Tap any paragraph to jump there, or step part-by-part. The sentence being read is highlighted.

| Doc | Contents |
| --- | --- |
| [CLAUDE.md](CLAUDE.md) | Architecture conventions |
| [spec/plan.md](spec/plan.md) | Decisions and ADRs |
| [spec/tech_doc.md](spec/tech_doc.md) | Product spec |
| [backend/README.md](backend/README.md) | The service, and enabling **ElevenLabs** |

## Run

```bash
# backend — full setup in backend/README.md
cd backend
uv sync
uv run python -m piper.download_voices en_US-lessac-medium --data-dir voices
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

```bash
# app — LAN IP for a device or non-macOS simulator; 127.0.0.1 for macOS desktop
flutter pub get
flutter run --dart-define=API_BASE_URL=http://<lan-ip>:8000
flutter analyze && flutter test
```

The address is also editable at runtime in Settings.

## Layout

Dependencies point inward. Widgets read state from a notifier and never touch `dio`, `just_audio` or `archive`.

```
lib/
├── domain/        pure Dart — entities, repository interfaces
├── data/          repository impls, DTOs, datasources
│   └── datasources/  backend_rest_api · audio_chunk_urls · epub_archive_assets
└── presentation/  Riverpod notifiers, screens, widgets
    ├── reader_notifier.dart   state machine, drives just_audio
    └── providers.dart         composition root
```

`ReaderNotifier` plays the use-case role directly — reasonable at this size.

**DTOs are hand-written.** `build_runner`'s analyzer constraint and `freezed`'s stable releases don't overlap on this SDK, so codegen was dropped. `lib/data/dto/book_dto.dart` mirrors `backend/app/api/dto.py` — keep them in sync.

### States

`AppState` is sealed, so `main.dart` switches exhaustively:

```
Idle → Uploading → Contents → Buffering → Reading
                                  ↓          ↓
                                Failed ←─────┘
```

`Buffering` spans the chapter load — it ends when the first chunk is actually available.

## Playback

The player gets the whole chapter's chunk URLs up front via `setAudioSources`. Every URL is servable on demand, so:

- Seeking anywhere needs no special case; a cold chunk synthesizes on request.
- The player's own read-ahead fetches the next chunk while the current one plays. There is no separate prefetcher ([ADR-1](spec/plan.md#architecture-decision-records)).

Buffering state comes from `just_audio`'s `ProcessingState.buffering` rather than hand-rolled water marks.

### Chapter switching is a supersede

Source of the hardest bugs here, so the rules are strict ([ADR-5](spec/plan.md#architecture-decision-records)):

- **`_epoch` is bumped by every `selectChapter`.** Anything resuming after an `await` checks it's still current before touching state or the player.
- **Tear down first.** `_detachPlayer()` cancels subscriptions and `stop()`s — `pause()` leaves the old playlist loaded with its item current.
- **`Reading` is set only after `setAudioSources` resolves.** Otherwise chapter B's text sits over chapter A's player, and a tap seeks into the wrong audio.
- **`PlayerInterruptedException` means superseded**, not failed.

## Document model

A chapter is an ordered list of blocks, one lazily-built widget each:

| Block | Rendered | Voiced |
| --- | --- | --- |
| `TextBlock` | its segments, in order | segments carrying a chunk ID |
| `HeadingBlock` | at heading weight | yes |
| `ImageBlock` | from the app's copy of the EPUB | no |
| `CodeBlock` | monospace, syntax-coloured | no |

**Shown and voiced are separate.** A `TextBlock` is a sequence of `Segment`s — text plus the chunk that voices it, *or null*. Formulas, inline snippets and text past the synthesis budget stay visible but unvoiced. Ask `Block.chunkIds`, don't test the block's type.

Prose renders as one `Text.rich` per paragraph with a span per chunk. Chunks are sentence-sized; boxing each one broke paragraphs into a stack of slabs.

### Images

Read from the uploaded EPUB, not the backend — `EpubArchiveAssets` unzips it locally behind the `BookAssets` port. The file already contains them, and the backend is busy synthesizing.

`ImageBlock.src` is archive-root relative. Lookup tries exact match, then a **unique** path-suffix match (real archives nest under `EPUB/` or `OEBPS/`). Ambiguous matches render alt text rather than risk the wrong picture.

## Connection

All HTTP. No socket, nothing to reconnect, no session-lost state.

Sessions live in the backend's memory — restarting the server invalidates the open book and its chunks start 404ing. Re-upload to recover.

## Settings

In-memory; reset on restart. **Apply** commits the address; **Reset** restores every default.

| Setting | Effect |
| --- | --- |
| Voice | Provider + voice from `GET /tts/providers`. Only what the backend has configured appears. Changing it restarts the open chapter at the current playhead |
| Auto play | On by default. Off loads a chapter without starting it; tapping a paragraph still plays |
| Backend address | Requires re-uploading — the open book belongs to the old server |

Speed lives on the reading screen and persists across chapters for the session.

## Platforms

Mobile (iOS + Android) is supported. Web compiles and runs, but the full upload → playback cycle in a browser is unverified.

Cleartext HTTP is enabled for LAN use: `usesCleartextTraffic` in the debug Android manifest, `NSAllowsLocalNetworking` in `Info.plist`.

## Known gaps

- **Some chapters play the wrong text** (a copyright line). Duplicate chapter IDs are ruled out. Run `backend/tools/inspect_book.py` to see what each chapter contains.
- **Image-only pages are dropped** by the backend's 50-word chapter filter — exactly what a full-page illustration looks like.
- **SVG renders as alt text.** Flutter can't decode it, and `<svg><image xlink:href=…/></svg>` covers aren't walked.
- **No resume after restart.** No persistence means no book ID to recover.
