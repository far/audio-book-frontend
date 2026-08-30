# AI Reader — Implementation Plan

Derived from [tech_doc.md](./tech_doc.md). Covers backend (FastAPI TTS service), frontend (Flutter app), and the contract between them.

Items marked ⚠️ are schedule risks, not checkboxes. Milestone 0 exists to surface them first.

---

## Decisions

| Topic | Decision |
| --- | --- |
| Python version | **3.13** — 3.12 fallback if a wheel is missing |
| Default TTS engine | **Piper** (offline, no API key) |
| External providers (v1) | **ElevenLabs**, **OpenAI TTS** — registered only when their API key is set; selectable per request, default Piper |
| Deferred providers | Google Cloud TTS, Azure, Amazon Polly, Coqui — see [CLAUDE.md](../CLAUDE.md) |
| Supported format | **EPUB only** |
| Transport | **HTTP only** — the WebSocket control plane was removed after testing showed the player's own read-ahead covered it (see ADR-1) |
| Highlight granularity | **Sentence/chunk level**, driven by client playback position (see ADR-2) |
| Flutter state management | **Riverpod** |
| Audio playback | `just_audio` + `audio_service` |
| Target platforms | **Mobile only** (iOS + Android) is the officially supported v1 scope — but **Flutter web works in practice**, unverified end-to-end (see note below) |
| Repo layout | **Monorepo** — new `backend/` folder alongside the Flutter root |
| Playback controls | **Play/pause + previous/next part + speed + tap-to-seek** — seek and skip were added after landing, reversing the original "no seek/skip in v1" call (see ADR-3) |
| Speed implementation | **Client-side** via `just_audio.setSpeed` — audio synthesized once at 1× |
| Persistence | **None** — ephemeral per upload; in-memory sessions, temp files with TTL |
| Chapter content | **Ordered typed blocks** — `TextBlock` (segments) / `HeadingBlock` / `ImageBlock` / `CodeBlock`, preserving document order. Replaces flattening a chapter to plain text. |
| Shown vs. voiced | **Separate** — a `TextBlock` is a sequence of segments, each with a chunk ID *or null*. Formulas, inline snippets and text past the synthesis budget stay on the page unvoiced. Readability is decided by shape, not by a dictionary (`parsers/text_quality.py`). |
| Images | **Extracted client-side from the uploaded EPUB** — the backend stores and serves nothing. Keeps synthesis memory off the critical path (see note below). |
| Auth / deployment | **None for testing** — LAN or a hosted test instance, plain HTTP. TLS added later; auth remains out of scope. |

**On Python:** nothing here needs bleeding-edge CPython, and the ML/audio ecosystem lags new releases — Piper pulls `onnxruntime`, and wheel availability is the practical constraint. 3.13 is current while keeping the install matrix boring.

**On EPUB:** it's structured HTML with a spine and TOC, so chapter detection and non-text stripping come nearly free — no layout heuristics needed.

**On images:** the upload already contains them, so client-side extraction costs no extra bandwidth — the client keeps the picked bytes and unzips locally. Serving them from the backend instead would mean holding a picture-heavy archive in the in-memory session store for the full 2-hour TTL, on a service already doing synthesis. The tradeoff is a second place (Dart) that knows a little about EPUB paths; `ImageBlock.src` is resolved to an archive-root-relative key by the parser to keep that knowledge as small as possible.

**On web:** the original mobile-only call was partly informed by expecting the Milestone 0 audio spike to need a platform-specific loopback `StreamAudioSource` for gapless playback, which has real quirks on web. That never happened — the app ended up using plain `AudioSource.uri` / `setAudioSources` on mobile too, so that specific tradeoff doesn't apply. Spot-checked live: `flutter build web` compiles clean, `flutter run -d chrome` launches against the backend with no runtime errors, and the widget tree renders correctly (verified via the Dart VM service — `UploadScreen`, address field, and button all present). Every package in use (`just_audio`, `dio`, `archive`, `file_picker`) has first-class web support, and the backend's CORS is already wide open. **Not verified**: the actual file-picker dialog and a full upload → audio-playback cycle in a browser — both need a real user click, which can't be driven headlessly. Mobile stays the officially supported target; web is a "probably works, try it" bonus, not a tested platform.

---

## Engineering conventions

Full detail in [CLAUDE.md](../CLAUDE.md#engineering-conventions). Summary of what the milestones below assume:

**Layering (dependency rule — inward only).**

- Backend: `domain/` (entities, no imports) ← `application/` (use cases + **ports**) ← `infrastructure/` (adapters) ← `api/` (FastAPI, DTOs). Framework and vendor imports live only in the outer two layers.
- Frontend: `domain/` (pure Dart) ← `data/` (repositories, datasources) ← `presentation/` (Riverpod + widgets). Widgets never touch `dio`, `archive`, or `just_audio` directly.

**SOLID where it bites in this project.** OCP is the load-bearing one: the tech doc requires new TTS providers without redesign, so adding Google/Azure/Polly must mean *one adapter file + one registry entry*, nothing else. ISP keeps `TTSProvider` narrow — optional abilities (timestamps, voice listing) are separate opt-in protocols, not fat-interface stubs. DIP means use cases depend on ports and concretes are wired only at the composition root.

**Patterns in play:** Strategy (provider selection), Adapter (vendor SDKs), Registry/Factory (provider lookup), **Decorator** (`CachingTTSProvider` wraps any provider so caching is written once), Repository (sessions), Result/Either (expected failures as values), sealed-class state machines (session + playback).

**DRY:** the API contract has a single source of truth — OpenAPI, self-documenting via FastAPI. Dart DTOs are hand-written against it (codegen was dropped, see the client README) and must be kept in sync.

**Guardrail:** YAGNI wins over speculative abstraction. Add an interface when there's a second implementation or the spec demands pluggability (TTS providers, parsers) — not by reflex.

---

## Architecture decision records

### ADR-1 — HTTP only (supersedes the transport split)

**Originally:** a WebSocket carried control messages (prefetch signals, "generating"/"ready" events) while audio was fetched over HTTP. The socket warmed the server's cache ahead of the playhead so chunk boundaries wouldn't stall.

**Now: there is no control plane.** Everything is `GET /tts/chunk/{id}`, synthesized on demand and cached server-side.

**Why it was removed.** The split was a reasonable bet, but running the thing showed the socket cost far more than it bought:

- **It was the source of nearly every hard bug here** — the chapter-switch races that ADR-5 exists for, stale events needing `chapter_id` tagging, a cancellable prefetch task, a reconnect loop that hammered the server after a restart, and a blocked-socket failure that killed sessions which were perfectly fine.
- **Its main benefit was already covered.** `just_audio`/ExoPlayer reads ahead on a playlist on its own, so it requests the next chunk while the current one plays — triggering the same on-demand synthesis the prefetcher was performing. Verified by listening: with the socket disabled, continuous playback had no audible gaps.
- **It cost a persistent connection and a synthesis task per reader**, on a single-vCPU host.

**What was given up:** the blue "being synthesized" highlight and the dimming of not-yet-synthesized text, both of which needed the server's view of its own work. The green currently-playing highlight comes from the player and is unaffected. Leaving a chapter's buffering state now means awaiting the first chunk's fetch, which is more precise than the event it replaced.

**If prefetch is ever needed again**, do it client-side with plain HTTP GETs ahead of the playhead — the client knows its own playhead exactly, where the server only knew what it was last told. Don't reintroduce a second protocol for it.

### ADR-2 — Highlight granularity
Word-level timing is **not** achievable across the v1 provider set: Piper emits no timestamps, OpenAI TTS emits none, ElevenLabs offers character-level timings only via its streaming API. So the `TTSProvider` contract treats **audio as mandatory, timing metadata as optional**, and the UI highlights at sentence/chunk level using the client's own playback position. This satisfies the tech doc's "mark the text currently being read".

### ADR-3 — Playback speed & buffering guards

**Speed is applied client-side** (`just_audio.setSpeed`), not as a synthesis parameter. Audio is synthesized once at 1× and the player resamples. Two consequences:

1. **Speed is *not* part of the cache key.** Keying on it would re-synthesize the whole book on every speed change — expensive on Piper, a real bill on ElevenLabs. Cache key is `hash(text + provider + voice)`.
2. **Prefetch depth must scale with speed.** At 1.5× the playhead consumes chunks 1.5× faster while synthesis takes the same wall-clock time, so a buffer tuned at 1× will starve. Required depth ≈ `ceil(base_depth × speed)`.

**Buffering guards** — playback must never stutter mid-sentence:

- **Buffer floor before starting**: don't begin playback until a minimum lead is ready (target ~2 chunks or a few seconds of audio, tuned against Milestone 0 numbers).
- **Low/high water marks with hysteresis**: if the ready-lead drains below the low mark, pause and surface a buffering state; resume only at the high mark. Two distinct thresholds — a single threshold makes the UI flap on every chunk boundary.
- **Pause stops prefetch advance** after topping up to the high mark — a paused player shouldn't keep synthesizing the whole chapter and burning paid-API credits.

**Seek — reversed after landing.** This ADR originally deferred seek/skip on the reasoning that an arbitrary jump invalidates the prefetch window and demands on-demand synthesis at the target position. Built anyway on explicit direction (`ReaderNotifier.seekToChunk`, tap any paragraph in the text view), and it turned out cheap specifically *because* of the architecture already documented in `ReaderNotifier`'s class doc: the player was always given the whole chapter's chunk URIs up front (`setAudioSources`), and `GET /tts/chunk/{id}` already synthesizes on-demand regardless of prefetch state. Seeking is just `_player.seek(index: ...)` — the "demands on-demand synthesis at the target position" concern this ADR raised turned out to be something the design handled for free, not a blocker. `currentIndexStream` (already wired for highlighting) reports the new index the same way it reports natural forward progress, so the existing `advance` WS message fires automatically and starts prefetching from the new position too.

### ADR-4 — Chunk ID vs. cache key

A chunk has **two identifiers** and they serve different purposes:

- **Chunk ID** — stable per session, assigned during ingestion (Milestone 2). This is what the client holds, what `GET /tts/chunk/{id}` takes, and what timing/highlight metadata references.
- **Cache key** — `hash(text + provider + voice)` (ADR-3), content-derived, provider/voice-scoped, and shared across sessions that read the same book with the same settings.

`GET /tts/chunk/{id}` resolves chunk ID → session's chunk text → cache key → cached audio (or triggers synthesis on miss). The session store is what holds the chunk-ID → text mapping; the audio cache is keyed independently. Don't conflate the two — a chunk ID is not a cache key and must never be used as one.

### ADR-5 — Chapter switching is a supersede, on both sides

Selecting a chapter cancels the previous selection outright rather than letting the two overlap. Synthesis is slow (~0.5s+ per chunk) and chapter selection spans several awaits, so "the user picked a different chapter mid-flight" is the normal case, not an edge case. Both sides need an answer:

- **Server** — prefetch runs as one cancellable `asyncio.Task` per connection; a new `start_chapter`/`advance` cancels the in-flight run before starting its own. Previously the synthesis loop ran inline in the WS receive loop, so a new command queued behind the old chapter's remaining synthesis and the socket went deaf for seconds.
- **Wire** — every prefetch event (`generating`, `chunk_ready`, `error`) carries `chapter_id`. Cancellation is not instant; events already on the wire still arrive, and the client must be able to tell them apart. A missing `chapter_id` is treated as "not attributable" and accepted, so an older backend degrades rather than going silent.
- **Client** — `ReaderNotifier._epoch` is bumped per `selectChapter`; every callback that resumes after an await (buffering timeout, `_finishBuffering`, `_startReading`, both player stream listeners) checks it before touching `state` or the player. The player is `stop()`ped and unsubscribed *before* the next chapter is set up, and `state` only becomes `Reading` once `setAudioSources` has resolved — a `Reading` state must never describe a chapter the player isn't actually loaded with, or a tap-to-seek lands in the previous chapter's audio.

`PlayerInterruptedException` from `setAudioSources` means "superseded," not "failed" — it must not surface as `Failed`.

---

## Milestone 0 — Walking skeleton & risk spikes ⚠️

Prove the genuine unknowns end-to-end before building around them. No upload, no parsing, no highlighting — hardcoded paragraph, audible in the Flutter app.

- [x] Verify clean install of `piper`, `onnxruntime`, `numpy`, `soundfile`, `fastapi`, `uvicorn` on 3.13 — clean install via `uv`, no 3.12 fallback needed
- [x] **Spike: Flutter chunked playback.** Decision: `AudioPlayer.setAudioSources` (the modern replacement for the now-deprecated `ConcatenatingAudioSource`), one source per chunk over HTTP. Accepting the audible-seam tradeoff for v1 rather than building a gapless loopback source — revisit if seams prove noticeable in practice.
- [x] Minimal FastAPI service: hardcoded paragraphs → Piper → WAV on disk → `GET /tts/chunk/{id}` (`backend/app/main.py`)
- [x] Minimal Flutter screen: fetch chunks and play them audibly, with a runtime-editable backend address field defaulting to `API_BASE_URL` (`lib/main.dart`)
- [x] Device connectivity: uvicorn bound to `0.0.0.0`; `--dart-define=API_BASE_URL=…` picked up in `lib/src/config.dart`, defaulting to `http://127.0.0.1:8000`
- [x] Cleartext HTTP allowed on device — Android: `usesCleartextTraffic` in the debug-only manifest; iOS: `NSAllowsLocalNetworking` in `Info.plist` (covers LAN IPs without opening cleartext to the whole internet)
- [x] Baseline timings measured on the backend in isolation: cold model load ~0.51s, first-sentence synthesis ~0.49–0.64s, cached fetch ~0.01s. Full on-device time-to-first-audio (network + player startup included) measured in the testing pass.
- [x] `backend/` created; `uv` for dependency management

**Exit criteria:** backend confirmed serving synthesized audio over HTTP (`curl` verified); on-device audible playback confirmed in the testing pass (Milestone 7) once a device/emulator is available.

---

## Milestone 1 — Backend foundations

### 1.1 App skeleton
- [x] Scaffold layered structure: `domain/`, `application/` (use cases + ports), `infrastructure/` (adapters), `api/` (routers + DTOs)
- [x] Define domain entities as frozen dataclasses: `Book`, `Chapter`, `Chunk`, `Voice`
- [x] Define ports in `application/`: `TTSProvider`, `BookParser`, `AudioCache`, `SessionStore`
  - `SessionStore` is the one port with a single v1 implementation (in-memory) — justified only because Redis is a *named* future path (see Milestone 1.3), not by reflex. If that plan changes, fold it back to a concrete class per the YAGNI guardrail.
- [x] Composition root (`app/api/deps.py`): concretes wired via `lru_cache`-memoized providers, injected into routers via `Depends`
- [x] `Result`/error-type convention (`app/application/result.py`) for expected failures; exceptions reserved for bugs
- [x] `GET /health`
- [x] CORS middleware for the Flutter dev client
- [x] Structured logging + error-handling middleware (`LoggingMiddleware`, cross-cutting, not per-handler)
- [x] Env-based config (`app/api/config.py`: provider selection, API keys, storage paths, limits)
- [x] `mypy --strict` + `ruff` run locally, both clean (no CI pipeline planned yet — revisit if one gets set up)

### 1.2 Security & abuse limits
- [x] Max upload size cap — enforced via a running-total read loop (`read_upload_with_cap`), rejects mid-stream once the cap is exceeded
  - **Deviation from the original wording**: buffers up to the cap in memory rather than streaming to a temp file on disk. Simpler for v1 and the cap keeps worst-case memory bounded (default 50MB); revisit if that stops being an acceptable ceiling.
- [x] MIME detection by **magic bytes** (`check_epub_magic_bytes` — checks for the zip local-file-header signature), not file extension
- [x] Zip-bomb guard (uncompressed-size ceiling) and zip-slip path-traversal guard, both in `EbooklibParser._guard_zip_bomb`
- [ ] Temp-file cleanup on **all** failure paths — not yet applicable: uploads currently stay in memory (see deviation above), so there's no temp file to clean up on that path. Revisit together if upload handling moves to disk streaming.
- [x] Per-session character cap for paid providers — **truncates rather than rejects**: `IngestBook._truncate_to_budget` keeps whole chapters/chunks (never cuts mid-sentence) up to `MAX_CHARACTERS_PER_SESSION`, drops the rest, and returns the book as normal. Books over the cap play their first part instead of failing to upload at all. The cap still exists and still does its job — bounding synthesis cost against paid providers — it just no longer blocks the user outright.

No auth, TLS, or rate limiting during testing — a LAN address or a hosted test instance over plain HTTP is fine. The caps and guards above stay regardless: they protect against malformed files and runaway API spend, not attackers.

Two config defaults keep an open test instance cheap to leave running, without adding auth:

- [x] Hosted test instances default to **Piper only** — `PAID_PROVIDERS_ENABLED` env flag (default off) keeps ElevenLabs/OpenAI adapters unregistered unless explicitly enabled
- [ ] Keep ElevenLabs/OpenAI keys on local dev machines; don't put them on the test box — operational practice, not something code enforces; noting it here as a reminder for whoever deploys a test instance

TLS is a later addition (terminate at a reverse proxy — no application changes needed).

### 1.3 Session state
- [x] In-memory session store (`InMemorySessionStore`) keyed by book ID: book metadata, chunk-ID → text mapping (ADR-4)
  - Accepted v1 tradeoff: precludes horizontal scaling. Revisit with Redis if multi-instance is needed.
- [x] `GET /session/{id}` so the client can recover state after reconnect without replaying the socket
- [x] TTL/cleanup for expired sessions — `cleanup_expired()` swept every 15 minutes via a background task in the app's lifespan (`app/api/app.py`); deliberately kept off the `SessionStore` port since a future Redis implementation would use native TTL instead

---

## Milestone 2 — EPUB ingestion & text extraction

- [x] `POST /upload` accepting multipart EPUB upload; rejects non-`.epub` filenames and non-EPUB magic bytes with a clear 422
- [x] Extract via `ebooklib`, HTML → plain text (`EbooklibParser`)
- [ ] Use the TOC for chapter boundaries — **not yet implemented as written**: the parser currently iterates spine documents directly (`get_items_of_type(ITEM_DOCUMENT)`) filtered by EPUB3 `properties` (skips items marked `cover`/`toc`/etc.) rather than walking `book.toc`. Works correctly for well-formed EPUB3 files but won't pick up custom TOC-only chapter titles or reorder against a TOC that diverges from spine order. Worth revisiting against a wider range of real-world EPUB files.
- [x] Strip images, tables, nav, and heading tags (headings extracted separately for chapter titles) from chunk body text
- [x] Identify the true **first chapter** — skips EPUB3 front-matter `properties` types and chapters under a minimum word count (`_MIN_CHAPTER_WORDS = 50`) as a proxy for "not real chapter content"
- [x] Split chapter text into sentence-level chunks with stable UUIDs (`chunking.py`)
- [x] ⚠️ **Asymmetric chunk sizing**: first chunk of each chapter is a single sentence, later chunks group 3 sentences (`chunk_chapter_text`)
- [x] Return structure (chapters + chunks + IDs) as JSON (`BookDTO`)
- [x] Error handling: corrupt archive and empty text raise `InvalidUploadError` → 422. DRM-protected files aren't specifically detected — they fail generically via the same "could not read EPUB" path, which is honest but not diagnosable by the user as "this book has DRM."

---

## Milestone 3 — TTS layer

### 3.1 Provider port & adapters
- [x] Narrow `TTSProvider` port: `synthesize(text, settings) -> SynthesisResult`, `list_voices()`
  - Per ADR-2 + ISP: timings are a **separate opt-in protocol** (`SupportsTimings`) — defined but intentionally unimplemented by all three adapters, since none of Piper/ElevenLabs/OpenAI provide timings the way we'd need them (per ADR-2)
- [x] Implement **Piper** adapter (offline default) — verified end-to-end against real synthesis
- [x] Implement **ElevenLabs** adapter — implemented against the documented API; not yet exercised against a real key/account
- [x] Implement **OpenAI TTS** adapter — same caveat as ElevenLabs
- [x] **Registry/Factory** (`ProviderRegistry`) for provider lookup by name
- [x] **Retry with backoff** (`RetryingTTSProvider`) applied to every provider via the composition root, not just paid ones — harmless for Piper, and keeps the decorator stack uniform
- [x] `GET /tts/providers` (list + capabilities), `POST /tts/config` (select active)
  - The Flutter client ended up not using `POST /tts/config`'s global active-provider state: `GET /tts/chunk/{id}` already took `provider`/`voice_id` query params, and `WS start_chapter`/`advance` gained the same, so each session carries its own selection explicitly rather than mutating shared server state. `POST /tts/config` still exists and works, just isn't on the client's actual path anymore.
- [x] Per-provider settings: voice ID, language (`TTSSettings`) — speed is deliberately absent here per ADR-3 (client-side, not a synthesis parameter)

### 3.2 Concurrency ⚠️
- [x] Piper inference runs in a `ThreadPoolExecutor` via `loop.run_in_executor`, never inline in the handler
- [x] Bounded worker pool (`SYNTHESIS_WORKER_POOL_SIZE`, default 2) shared by Piper inference **and** Opus transcoding — both are blocking CPU work
- [x] Piper model kept warm: lazy-loaded once, reused across requests

### 3.3 Caching & encoding
- [x] `CachingTTSProvider` decorator wraps any provider — one implementation for all three adapters
- [x] Cache key is `hash(text + provider + voice)` — verified via test: cold fetch ~0.9s, cached fetch ~0.002s
- [x] `EncodingTTSProvider` decorator transcodes to **Opus** via `ffmpeg` subprocess (`libopus`, 32kbps)
  - Applies to every provider's output — the decorator wraps the raw adapter *before* caching, so cached bytes are always already-Opus regardless of source format
  - Runs through the same thread pool as Piper inference (Milestone 3.2), never inline
- [x] Cache eviction policy: `FilesystemAudioCache` evicts oldest-by-mtime files once total cache size exceeds a configurable budget (default 500MB)

---

## Milestone 4 — Delivery

- [x] `WS /ws/read/{session_id}` — **control plane only**: `generating`, `chunk_ready`, `progress`, `error` messages; never carries audio bytes
- [x] `GET /tts/chunk/{id}` — **data plane**: audio bytes, cacheable
  - **Not range-request capable** as written: returns the full `Response` body, not a `FileResponse`/`StreamingResponse` with `Range` support. Deferred rather than fixed, since per-chunk files are small (a few KB–tens of KB) — the original motivation for range support (resuming a large partial transfer) doesn't really apply at this file size. Seek (ADR-3) doesn't change this: it jumps between whole chunks via separate requests, not partway through one, so it doesn't need range support either. Revisit if chunk sizes grow substantially.
- [x] ⚠️ **Pipelined prefetch**: `start_chapter` and `advance` WS messages synthesize N chunks ahead of the playhead
- [x] Client sends its current speed; server sizes the prefetch window via `ceil(base_depth × speed)` (`_Prefetcher.depth_for`, ADR-3)
- [x] Client may override `base_depth` itself via an optional `depth` field on `start_chapter`/`advance` (Settings screen "buffer size", Milestone 5.4 addendum) — same formula, just substitutes the client's value for the server's `PREFETCH_BASE_DEPTH`
- [x] Bounded concurrency — implemented as an `asyncio.Semaphore` sized to the worker pool rather than an explicit queue data structure; achieves the same "generation can't run unbounded ahead" goal
- [x] Reconnect: client rehydrates full book/chapter/chunk state via `GET /session/{id}`, then resumes prefetch by sending `advance` with its own known position. Client-authoritative rather than server-tracked "last acknowledged chunk" — simpler, and avoids the server needing per-connection state that complicates the already-stated "server restart drops sessions" behavior.
- [ ] Publish the contract as **OpenAPI + JSON Schema for WS messages** — REST endpoints get OpenAPI for free from FastAPI (`/openapi.json`), but the WS message shapes (`generating`/`chunk_ready`/`progress`/`error`/`start_chapter`/`advance`) aren't yet written up as a formal JSON Schema, and Dart codegen from it hasn't been wired. Real gap — worth doing before the Flutter WS client is built against assumptions that could drift.

---

## Milestone 5 — Flutter app

### 5.1 Architecture
- [x] Add dependencies: `dio`, `web_socket_channel`, `just_audio`, `audio_service`, `flutter_riverpod`, `file_picker`
  - **`freezed` dropped**: `build_runner`'s current `analyzer` requirement and `freezed`'s stable-release support don't overlap on this Dart SDK (3.13) — the same "tooling lags the newest release" pattern as the backend's Python version risk, just in the Flutter codegen ecosystem. Rather than pin to a prerelease `freezed` or fight the version solver, dropped codegen entirely: state uses a native Dart `sealed class` (built into Dart 3, gives exhaustive `switch` for free) and DTOs are hand-written `fromJson`.
- [x] Scaffold layers: `domain/` (entities, repository interfaces — no Flutter import), `data/` (repository impls, DTOs, REST/WS datasources), `presentation/` (notifiers, screens, widgets)
- [ ] Generate Dart models from the backend OpenAPI/JSON Schema — **not done**, hand-written DTOs instead (`lib/data/dto/book_dto.dart`), consistent with the codegen-toolchain issue above and the WS-schema gap already noted in Milestone 4. Real drift risk if the backend DTO shape changes without a corresponding manual update here.
- [x] Riverpod providers as the composition root (`lib/presentation/providers.dart`); widgets depend on notifiers only, never on `dio`/sockets/`just_audio` directly
- [x] App state as a **native Dart `sealed class`** (see freezed note above): `Idle | Uploading | Contents(book, providers, selection, loadingProviders) | Buffering(book, chapter, selection) | Reading(book, chapter, selection, currentChunkIndex, generatingChunkId, readyChunkIds, isPlaying, speed, bufferingState) | Failed(message)`
  - `Extracting` was removed after landing: EPUB parsing happens synchronously inside the `POST /upload` response, so it was never a real distinct phase — dropped per the YAGNI guardrail rather than kept as dead state.
  - `Contents` and `Buffering` were added for the contents-first flow below — not in the original design, added mid-build on explicit direction.

### 5.2 Upload screen
- [x] File picker restricted to EPUB (`allowedExtensions: ['epub']`)
- [x] Wire to `POST /upload`; validation and error states
- [x] Status text: `Uploading file…`
- [x] Error messaging shown on failure
  - **No explicit "Retry" affordance** — the same "Upload EPUB" button re-triggers the flow, so retry is *possible*, just not a labeled/highlighted action distinct from the first attempt.

### 5.2b Contents screen (added — not in the original plan)

The tech doc's single-screen, auto-play-from-first-chapter design was revised mid-build: **upload now lands on a table-of-contents screen** (`ContentsScreen`) listing every chapter, and reading only begins once the user taps one.

- [x] Chapter list (title + part count) sorted by `order`, tap-to-read
- [x] Extracted into a reusable `ContentsPanel` widget (chapter list only, no `Scaffold` of its own) rather than being `ContentsScreen`-only — reused as-is inside the Reading screen's `Drawer` (5.3) so chapters can be switched mid-listen, not just from the initial full-screen pick

**Provider/voice picker added, then removed the same session.** A dropdown-based picker (`GET /tts/providers`, two dropdowns) was built, then explicitly removed once only one provider (Piper) was actually registered — a picker offering a single option is clutter, not a feature (CLAUDE.md degrade-gracefully guardrail cuts both ways: don't build a choice that isn't a real choice yet). The domain type `TtsSelection` and the provider/voice_id fields on the WS/HTTP wire contract stayed — the app still sends `piper`/`en_US-lessac-medium` on every call — only the *user-facing choice* was cut. Revisit if `PAID_PROVIDERS_ENABLED` is ever turned on for real, at which point there'd be more than one option worth exposing again.

This also resolves a previously-noted gap: the tech doc's "reading should start from first chapter" is now one of several reachable chapters rather than the *only* one.

### 5.2c Buffering screen (added — not in the original plan)

Tapping a chapter transitions to a `Buffering` state — a real wait for the first chunk's `chunk_ready` WS event (or a 5s timeout fallback, consistent with the degrade-gracefully guardrail if the socket never connects), then hands off to Reading. This is what actually closes the previously-noted "no visual progress bar" gap: the tech doc's "Generating voice…" step now has something concrete to wait on instead of being a UI-only flash between two auto-transitioning states.

- [x] `CircularProgressIndicator` + "Generating voice…" while waiting
- [x] Resolves on first `chunk_ready` for the selected chapter, or after a 5s timeout
- [x] Backend prefetch base depth reduced from 3 to 1 (`PREFETCH_BASE_DEPTH`) — asymmetric chunking already makes the first chunk a single sentence and Piper synthesis is well under a chunk's speech duration, so 1-ahead has margin at normal speed; ADR-3's `ceil(base × speed)` scaling still grows it at higher speeds where that margin matters more

### 5.3 Reading screen
- [x] Scrollable text view rendering chunks (`ChunkTextView`, `ListView.builder`)
- [x] Chapter selected from Contents triggers `start_chapter` (WS reused across chapters within the same book rather than reconnecting each time)
- [x] **Chapters `Drawer`** (added — not in the original plan, added on explicit direction) — the reading screen embeds `ContentsPanel` as a `Drawer`, toggled by the icon `Scaffold` auto-adds when a `drawer` is set. Lets the user switch chapters **while listening**, not just once up front:
  - Tapping a different chapter in the drawer pauses the current player and runs the same Buffering → Reading transition as the initial pick, from whichever chapter the user was on
  - The current chapter is highlighted in the drawer's list (`currentChapterId`)
- [x] **Tap-to-seek** (added — not in the original plan, reverses ADR-3's "no seek/skip in v1"): tapping any paragraph in the text view — generated or not — jumps playback there via `ReaderNotifier.seekToChunk` (`_player.seek(index: ...)`), and the existing `currentIndexStream` listener reports the new position exactly as it would a natural transition, so WS prefetch (`advance`) and highlighting pick up from the new spot automatically. See ADR-3 for why this turned out cheap.
- [x] **Not-yet-generated parts are visible and distinguishable**: `ChunkTextView` renders the *entire* chapter's text (already known client-side — the backend parses the whole chapter up front, only audio is lazy), dimming chunks that aren't the current/generating/prefetched one (`theme.colorScheme.onSurfaceVariant`) so it's visually clear what hasn't been processed yet, without hiding it or blocking taps on it.
- [x] **Fixed: chunk text not updating after switching chapters via the drawer.** Root cause: `ChunkTextView` cached a `GlobalKey` per list index and reused it across chapter switches. Flutter's reconciliation uses `GlobalKey` to track *one element as it moves in the tree* — reusing the same key for index N of the old chapter and index N of the new one made Flutter treat them as the same element and could leave stale rendered text on screen. Fixed by resetting the key map whenever `chapter.id` changes (`didUpdateWidget`).
- [ ] Feed `just_audio` using `LockCachingAudioSource` — **not done**. Uses plain `AudioSource.uri` per chunk instead. This is a real deviation from the Milestone 0 decision, not just a simplification: `LockCachingAudioSource` would give on-device disk caching of fetched audio for free, which plain `AudioSource.uri` doesn't. Worth revisiting — likely a small, contained change.
  - **Design note**: rather than build the playlist incrementally as WS `chunk_ready` events arrive, the player is given the *entire* chapter's chunk URIs up front. `GET /tts/chunk/{id}` synthesizes on-demand (with server-side caching) regardless of whether the WS prefetch has reached that chunk yet, so any URI is servable at any time. WS prefetch is a latency optimization (reduces time-to-first-audio for chunks ahead of the playhead) and drives the "generating" highlight — it is not a hard dependency for audio playback itself. This design is also what made tap-to-seek and "show ungenerated parts" cheap to add above.
- [x] Two-state highlighting: **currently playing** (`primaryContainer`) vs. **currently generating** (`secondaryContainer`)
- [x] Highlight transitions driven by `just_audio`'s `currentIndexStream` (ADR-2)
- [x] Auto-scroll to keep the active chunk in view (`Scrollable.ensureVisible`)
- [x] Playback controls: play/pause + speed (`setSpeed`, 0.75×–2× via dropdown)
  - **`audio_service` added as a dependency but not actually wired** — no `AudioHandler` implemented, so there's no lock-screen/notification playback control yet. Real gap, not a design decision.
- [ ] **Buffering guards** per ADR-3 — **simplified rather than built as specified**. Relies on `just_audio`/ExoPlayer's own `ProcessingState.buffering` signal instead of hand-rolled low/high water marks with hysteresis. Reimplementing buffering logic the platform player already does well seemed like duplicated risk, not added robustness, but this is a deliberate scope-down from what ADR-3 describes, worth flagging as such rather than silently substituting. (Distinct from the `Buffering` *app state*, which covers the earlier "waiting for the first chunk" gap, not mid-playback stalls.)
- [x] Pause halts prefetch advance — **achieved incidentally, not by explicit design**: `advance` is sent from `currentIndexStream` changes, and the index doesn't move while paused, so prefetch naturally stops. There's no explicit "pause signal" sent to the server; if that stops being true (e.g. prefetch driven some other way later), this behavior could silently break.
- [x] Speed changes recompute required prefetch depth and request the extra lead immediately (`setSpeed` calls `_reportAdvance`)
- [x] End-of-chapter handling (shows "End of chapter" when the last chunk finishes)
  - **No auto-advance to the next chapter** — the user opens the drawer and taps the next one manually. Auto-advance is a reasonable follow-up, not built here.
- [ ] Reconnect handling with UI feedback — **not implemented**. A WS connect failure silently no-ops (playback continues via direct HTTP fetch, per the design note above), but there's no retry-with-backoff if the socket drops *mid-session*, and no UI banner surfacing degraded state to the user. Real gap.

### 5.4 Settings screen (added — not in the original plan)

Client-adjustable knobs, in-memory only (no persistence dependency added — resets on app restart, revisit with e.g. `shared_preferences` if that stops being acceptable), reachable via a settings icon on the Upload/Contents/Reading app bars:

- [x] Backend address — moved here from the upload screen (was a duplicate field in two places; now a single source of truth)
- [x] Default playback speed — applied when a chapter starts
- [x] Buffer size — overrides the server's prefetch base depth (`PREFETCH_BASE_DEPTH`, default 1) when set; sent as an optional `depth` field on `start_chapter`/`advance`, which the server's `ceil(depth × speed)` formula uses in place of its own base depth. Most users never need this; it exists for exactly the kind of person who wants to tune it.
- [x] Buffering timeout — how long the `Buffering` screen waits for the first `chunk_ready` event before giving up and starting playback anyway (was a hardcoded 5s constant, now adjustable 2–15s)

---

## Milestone 6 — Testing & ops

Backend: 36 tests, all passing, `mypy --strict` + `ruff` clean (`backend/tests/`). Flutter: minimal — see gaps below. **Per explicit direction, on-device/emulator verification and further manual e2e testing are out of scope here** — the user is handling that themselves.

- [x] Unit tests: EPUB extraction (`test_epub_parser.py`) — **against in-memory generated fixtures, not on-disk fixture files** as originally worded. Avoids maintaining binary `.epub` files in the repo; a helper (`build_epub_bytes`) builds one per test case with whatever chapter/heading shape the test needs.
- [x] Unit tests: chunk splitting and first-chapter detection (`test_chunking.py`, plus a first-chapter case in `test_epub_parser.py`)
- [x] Unit tests: use cases against **fake adapters** — no network, no real model, no filesystem (`test_use_cases.py`)
- [x] Unit tests: `TTSProvider` via a stub provider (`FakeTTSProvider`); cache-key correctness; caching decorator hit/miss (`test_caching.py`)
- [x] **Integration test of the audio pipeline** — upload → extract → synthesize → chunk fetch, through the real HTTP layer via `TestClient` with a dependency-injected fake provider (`test_upload_and_chunk_flow.py`). Also added (beyond the original ask): two tests against the **real** Piper + ffmpeg path (`test_piper_provider_real.py`), skipped automatically if the voice model/ffmpeg aren't present, so the fast suite doesn't require either.
- [ ] Reconnect/resume integration test — **not written**. The backend half (`GET /session/{id}` 200/404) is covered incidentally in `test_upload_and_chunk_flow.py`, but there's no test of a full WS disconnect/reconnect cycle. Consistent with Milestone 5's noted gap that reconnect-with-backoff isn't actually built on the client side yet — nothing to integration-test until it is.
- [ ] Widget tests: upload screen states, highlight transitions — **only the original Idle-state smoke test exists** (`test/widget_test.dart`). Upload error states, buffering states, and highlight-transition tests weren't written. Real gap if the Flutter side changes without a human driving it through the states manually.
- [ ] Mock service layer for the playback state machine — **not written** as a distinct artifact. `ReaderNotifier` depends on repository interfaces, so it's mockable, but no test currently exercises it that way.
- [x] Dockerfile (`backend/Dockerfile`, Python 3.13-slim + ffmpeg, voice model mounted as a volume rather than baked in)
- [x] READMEs: `backend/README.md` covers setup, running, testing, provider configuration (env var table), the API contract (OpenAPI is self-documenting; WS contract explicitly flagged as still hand-synced, not schema-generated), and Docker usage

---

## Milestone 7 — Integration & polish

**Deferred to the user's own testing pass** (explicit direction: on-device/emulator verification and manual e2e are out of scope here) — listed so they aren't forgotten, not because they're done:

- [ ] End-to-end manual test with real EPUB samples
- [ ] Large-book test: streaming must not block UI or exhaust memory on either side
- [ ] Verify time-to-first-audio meets the Milestone 0 budget (needs a live device/emulator measurement)

Handled without needing a live run:

- [x] Verify voice switching mid-session invalidates cache correctly — covered at the unit level (`test_cache_key_differs_by_voice`, `backend/tests/test_caching.py`): the cache key includes voice ID, so switching voices can never return another voice's cached audio. Not a live "switch mid-session and listen" test, but the mechanism is verified.
- [x] Cost check: characters-per-chapter against ElevenLabs/OpenAI pricing — rough estimate below; **confirm against current published pricing before relying on it**, these numbers move.

**Illustrative cost estimate** (order-of-magnitude, not a live measurement): a typical novel chapter runs roughly 3,000–5,000 words, or **~18,000–30,000 characters**. At ElevenLabs' per-character pricing on its paid tiers (order of $0.10–$0.30 per 1,000 characters depending on plan), one chapter costs roughly **$0.002–$0.01**, so a ~250,000-character novel costs on the order of **$0.03–$0.08** end to end if synthesized once. The `MAX_CHARACTERS_PER_SESSION` default of 500,000 (`backend/app/api/config.py`) sits comfortably above a full novel, which is the point — it's a runaway-cost guard, not a per-book budget. Caching means a re-read of the same book/voice combination costs nothing further. OpenAI TTS pricing is in a similar order of magnitude. These figures are rough and provider pricing changes; treat them as a sanity check that the session cap isn't wildly out of proportion, not as a bill forecast.

---

## Open questions

**Open bug — the same sentence plays for every chapter.** After the ADR-5 chapter-switch fixes, text selection and chapter switching behave correctly but playback returns one copyright-page sentence whatever chapter is chosen. Prime suspect is duplicate `item.get_id()` values used as chapter IDs, which would collapse the WS chapter lookup onto the first match. Details and the diagnostic plan are in [CLAUDE.md](../CLAUDE.md#known-bug--one-wrong-sentence-plays-for-every-chapter).

**Front-matter detection is too weak for real books** — `_MIN_CHAPTER_WORDS = 50` plus EPUB3 `properties` lets copyright pages through as chapters. Milestone 2 already flags that the parser walks the spine rather than the TOC; these are the same underlying gap.

Otherwise: all decisions are recorded in the [decisions table](#decisions).

Deferred (not blocking, listed so they aren't forgotten): **TLS** (reverse-proxy termination, planned), auth, persistence / book library, seek & skip controls, Flutter web support, additional TTS providers (see [CLAUDE.md](../CLAUDE.md)).
