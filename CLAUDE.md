# AI Reader

Flutter app that reads EPUB books aloud using generated voice, backed by a FastAPI TTS service.

## Project docs

| Doc | What it is |
| --- | --- |
| [spec/tech_doc.md](spec/tech_doc.md) | Product spec — the source of requirements |
| **[spec/plan.md](spec/plan.md)** | **Implementation plan — the working checklist. Read this before starting any task.** |

**[spec/plan.md](spec/plan.md) is the single source of truth for what to build and in what order.** It contains:

- **[Decisions table](spec/plan.md#decisions)** — settled choices (Python 3.13, Piper/ElevenLabs/OpenAI, EPUB-only, mobile officially supported (web works in practice, unverified end-to-end), monorepo with `backend/`, no persistence, no auth (TLS deferred), Riverpod, `just_audio`). Don't re-litigate these; if one needs to change, update the table.
- **[ADRs](spec/plan.md#architecture-decision-records)** — ADR-1 HTTP only (the WebSocket control plane was removed — see the ADR for why, and don't reintroduce it), ADR-2 highlight granularity (sentence-level, not word-level), ADR-3 playback speed & buffering guards (client-side speed, so speed is *not* in the cache key), ADR-4 chunk ID vs. cache key (two identifiers, don't conflate them), ADR-5 chapter switching is a supersede on both sides (cancellable server-side prefetch, `chapter_id` on every control event, epoch-guarded client callbacks).
- **Milestones 0–7** — ordered checklist. Milestone 0 is a walking skeleton that must clear before the rest.
- **[Open questions](spec/plan.md#open-questions)** — unresolved items needing a decision from the user.

Working rules:

- Tick checkboxes in `spec/plan.md` as work completes; keep it current rather than tracking progress elsewhere.
- Items marked ⚠️ are schedule risks (Flutter chunked playback, Piper blocking the event loop, asymmetric chunk sizing) — treat them as spikes, not one-line tasks.
- When a decision is made, record it in the decisions table or as a new ADR, and update any task that assumed otherwise.

## Engineering conventions

Apply these to all code in this repo. They are conventions, not suggestions — deviations should be justified in review.

### Clean architecture — dependency rule

Dependencies point **inward only**. Inner layers never import outer ones, and never import a framework.

**Backend (`/backend/app/`)**

| Layer | Contains | May import |
| --- | --- | --- |
| `domain/` | Entities (`Book`, `Chapter`, `Chunk`), value objects, domain errors | nothing but stdlib |
| `application/` | Use cases (`IngestBook`, `SynthesizeChunk`, `StreamSession`) and **ports** (abstract interfaces) | `domain/` |
| `infrastructure/` | Port implementations: `PiperProvider`, `ElevenLabsProvider`, `EbooklibParser`, `FilesystemAudioCache`, `InMemorySessionStore` | `domain/`, `application/` |
| `api/` | FastAPI routers, WS handlers, Pydantic request/response DTOs | all of the above |

`fastapi`, `ebooklib`, `onnxruntime` and other framework/vendor imports appear **only** in `infrastructure/` and `api/`. If `domain/` imports FastAPI, the design is wrong.

`domain/` *is* the models layer — do not also create a `models/` folder alongside it.

**Frontend (`/lib/`)**

| Layer | Contains |
| --- | --- |
| `domain/` | Entities, repository interfaces, use cases — pure Dart, no Flutter import |
| `data/` | Repository implementations, DTOs + mappers, datasources (REST, audio URLs, EPUB archive) |
| `presentation/` | Riverpod notifiers, screens, widgets |

Widgets never call `dio`, `archive`, or `just_audio` directly — they read state from a notifier, which calls a repository interface. In practice the notifier (`ReaderNotifier`) plays the application/use-case role directly rather than delegating to separate use-case classes — reasonable for the app's current size; split it out if orchestration logic grows past what one notifier should own.

### SOLID — how it applies here

- **SRP** — parsing, chunking, synthesis, caching, and delivery are separate units. A class that both extracts EPUB text *and* splits it into chunks is two classes.
- **OCP** — the tech doc requires adding TTS providers without redesign. Adding Google/Azure/Polly must mean *one new adapter file and one registry entry*, with zero edits to existing providers or call sites. Treat any change outside those two places as a design smell.
- **LSP** — every `TTSProvider` is substitutable. A provider without word timings reports that through a capability flag; it must not throw where others succeed.
- **ISP** — keep `TTSProvider` narrow (`synthesize`). Optional abilities (timestamps, streaming, voice listing) go in separate opt-in protocols rather than a fat interface with `NotImplementedError` stubs.
- **DIP** — use cases depend on ports, never on `PiperProvider` or `dio`. Concretes are wired at composition root only (FastAPI lifespan / Riverpod providers).

### Patterns to use

| Pattern | Where |
| --- | --- |
| **Strategy** | TTS provider selection at runtime |
| **Adapter** | Wrapping vendor SDKs (ElevenLabs, OpenAI) behind our port |
| **Registry / Factory** | Provider lookup by name; keeps OCP honest |
| **Decorator** | `CachingTTSProvider` wraps *any* provider — caching written once, not per adapter |
| **Repository** | Session and book access behind an interface |
| **Result / Either** | Expected failures (bad file, provider down) as return values; exceptions only for bugs |
| **State machine** | Session and playback states as sealed classes / discriminated unions |
| **Observer (streams)** | Progress and `chunk_ready` events |
| **Composition root** | All wiring in one place per app |

### DRY

- **The API contract has one source of truth** — OpenAPI, which FastAPI generates from the DTOs. The Dart DTOs are hand-written against it (codegen was dropped; see the client README), so changing one side means changing the other in the same commit.
- Cross-cutting concerns (logging, auth, error mapping, rate limiting) live in middleware/interceptors, never copy-pasted into handlers.
- Caching and error-mapping logic is written once and applied by decorator, not repeated in each provider.

### Guardrails

- **YAGNI beats speculative abstraction.** Introduce an interface when there is a second implementation or the spec demands pluggability (TTS providers, book parsers). One implementation behind three layers of indirection is not clean architecture, it is overhead.
- **Test through ports.** Use cases are tested against fake adapters; no network or real model in unit tests.
- **Immutability by default** — frozen dataclasses in Python, `freezed`/`const` in Dart.
- **Type checking is enforced**: `mypy --strict` on the backend, no `dynamic` in Dart domain code.
- **A user action that supersedes another must cancel it, not race it.** Anything that resumes after an `await` — a timer callback, a stream listener, the tail of an async method — has to prove it's still current before it writes to shared state. On the client that's the `_epoch` token in `ReaderNotifier` (ADR-5). Long-running work triggered by a user choice never runs inline in a loop that also has to stay responsive to that user.
- **State must not describe something that isn't loaded yet.** Set the new state *after* the resource it names is ready (`_startReading` awaits `setAudioSources` before assigning `Reading`), not before. A state that advertises chapter B while the player still holds chapter A is a bug generator — every widget reading it will act on the wrong thing.
- **Content types must describe the actual bytes.** `EncodingTTSProvider` emits Ogg-Opus, so the type is `audio/ogg; codecs=opus` (`OGG_OPUS_MIME_TYPE`) — the bare `audio/opus` means raw Opus and makes Safari/iOS refuse the response. If the container changes, the constant changes with it.
- **Anything with a `dispose()` belongs to a State, never to `build()`.** Controllers, gesture recognizers, animation controllers and stream subscriptions all own resources that outlive a frame. Constructing one in `build()` leaks it *and* resets whatever it holds — a `TextEditingController` rebuilt per frame throws the caret back to position 0 on every keystroke. Create them in `initState`, release them in `dispose`. Put such state on the **widget that matches its lifetime**: per-item recognizers belong to the list item, so `ListView.builder` reclaims them when it scrolls out (`_ProseText`), not to the list, where they pile up for the whole chapter.
- **The reading view rebuilds on every playback tick**, so anything O(chunks) inside `build()` scales with chapter length several times a second. Chapter-scoped lookups (`_chunksById`, `_blockIndexByChunkId`) are built once in `initState`/`didUpdateWidget` when the chapter changes, never per frame.
- **A provider that rebuilds owns what it replaces.** `apiBaseUrlProvider` is runtime-editable, so everything watching it is torn down and rebuilt on each edit — and `BackendRestApi` holds a connection pool. Anything holding a connection, socket, or file handle needs a matching `ref.onDispose`, or each edit leaks one.
- **Degrade gracefully over reject outright**, when the degraded result is still useful. A book over the character cap gets truncated to what fits rather than failing the upload (`IngestBook._truncate_to_budget`); a WS control-plane connection failure doesn't stop audio playback, since chunks are still servable over HTTP (`ReaderNotifier._startReading`). Apply this by default for limits and non-critical dependencies — reject outright only when there's truly nothing useful to hand back.

## The document model

The reader shows the book as an ordinary EPUB reader would — headings and images in place — while only prose is voiced. Before this, `EbooklibParser._extract_text` deleted `img`, `table` and `h1`–`h3` outright, so the client never received them at all.

A chapter is an ordered `tuple[Block, ...]` alongside its chunks (`domain/entities.py`, mirrored as a sealed class in `lib/domain/entities.dart`):

| Block | Rendered | Voiced |
| --- | --- | --- |
| `TextBlock` | its segments, in order | segments that carry a chunk ID |
| `HeadingBlock` | at heading weight | yes — a listener expects to hear "Chapter One" |
| `ImageBlock` | from the client's copy of the EPUB | never |
| `CodeBlock` | verbatim, monospace, syntax-coloured | never |

**Shown and voiced are separate.** A `TextBlock` is a sequence of `Segment`s — text plus the chunk that voices it, *or null*. This is the load-bearing decision: blocks used to render *from* their chunks, so making anything unreadable deleted it from the page. Anything that shouldn't be spoken (a formula mid-paragraph, text past the synthesis budget) is now a segment with no chunk. **Never re-couple these.** Use `chunk_ids_of(block)` / `Block.chunkIds` to ask what's readable rather than testing the block's type — that set has already changed twice.

**Chunking is per block**, so a paragraph break is a hard chunk boundary and the highlight stays inside the paragraph the listener is looking at. ADR-3's short first chunk applies to the first *paragraph* of a chapter, not to the heading above it (already short) and not to every paragraph.

**Deciding what's prose** (`parsers/text_quality.py`): no dictionary. It measures whether a sentence is *shaped* like prose — mostly alphabetic tokens, few operators, vowels where words have vowels. A lexicon would mean per-language word lists and would still reject proper nouns, loan words and archaic spellings, all of which read fine. Thresholds are deliberately permissive: **skipping a sentence the listener wanted is worse than voicing an awkward one**, and the tests pin that bias rather than accuracy. Consecutive sentences are grouped into readable/unreadable runs before chunking so one formula doesn't fragment the prose around it.

**Images are extracted client-side** (`EpubArchiveAssets` behind the `BookAssets` port). The upload already contains them, so the backend stores and serves nothing — it's already carrying synthesis, and a picture-heavy book in an in-memory store with a 2-hour TTL is real memory per session. `ImageBlock.src` is archive-root relative because EPUB `src`s are relative to the *chapter document* (`../images/x.png` in `text/ch1.xhtml` → `images/x.png`), and that resolution belongs in the parser that already understands EPUB paths. Lookup tries an exact match, then a **unique** path-suffix match, since real archives nest under `EPUB/` or `OEBPS/`; an ambiguous match renders alt text rather than risking the wrong picture.

**Not a general HTML renderer.** Inline markup is flattened to text; tables are read as their text content. Faithful book-CSS rendering is a different project — correct reading order is what the listener needs.

**`backend/tools/inspect_book.py`** prints a book's blocks and resolves every image `src` against the archive exactly as the client does, which separates a parsing problem from a lookup problem in one run: `uv run python -m tools.inspect_book /path/to/book.epub`.

## There is no control plane

The WebSocket was removed (ADR-1). Everything is `GET /tts/chunk/{id}`, synthesized on demand and cached server-side, so there is no connection to drop, no session-lost state machine, and no reconnect logic. The client is stateless against the backend between requests.

This deleted ~850 lines and, with them, the source of most of the hard bugs in this project: the chapter-switch races, stale-event filtering, cancellable server-side prefetch, a reconnect loop that hammered the server after a restart, and a blocked-socket path that killed working sessions.

**ADR-5's epoch guards still apply** — the player still has async callbacks that can outlive the selection that started them. What went away is only the *event* side of it.

**Don't reintroduce a socket for prefetch.** If chunk-boundary latency ever becomes a real problem, issue HTTP GETs ahead of the playhead from the client: it knows its own position exactly, where the server only ever knew what it was last told. The blue "generating" highlight and the dimmed "not yet ready" style are gone with the socket, because the client has no view of server-side work and inventing one would mean guessing.

## Known gaps

- **Chapter order comes from the spine**, not the manifest — `get_items_of_type(ITEM_DOCUMENT)` yields manifest order, which routinely differs from reading order and had the contents list shuffled. `_documents_in_reading_order` walks `book.spine` and appends any unreferenced document last rather than dropping it.
- **Image-only pages are dropped**: `_MIN_CHAPTER_WORDS = 50` discards any document that doesn't clear 50 words, which is exactly what a full-page illustration looks like. Likely why a picture-heavy book shows no images.
- **SVG-wrapped images aren't walked** — `<svg><image xlink:href=…/></svg>` is a common cover idiom that `document_blocks.py` doesn't handle.
- **Flutter can't decode SVG**, so an SVG image renders as alt text even when found.

## TTS providers

Piper (default, offline, no key), ElevenLabs and OpenAI TTS all ship. **A provider is registered only when its API key is configured** (`deps.py`), so `/tts/providers` never offers one that would fail on first use, and the client's picker is built from that response rather than a hardcoded list. There is no separate enable flag: selection is per request and defaults to Piper, so a key present costs nothing until someone picks that voice.

Provider and voice ride as query parameters on `GET /tts/chunk/{id}` — **not** as path segments. The chunk ID names *what text*; the provider and voice are rendering options on it. Path-prefixing (`/piper/...`) would mean two routes doing identical work and would break the "one adapter file + one registry entry" rule the port exists to protect.

The client bakes the selection into the playlist URLs when a chapter loads, so changing voice reloads the open chapter at the current playhead (`ReaderNotifier.reloadForSelectionChange`) — otherwise a change appears to do nothing until the next chapter.

**There is no retry decorator.** Piper is the default and its failures are deterministic (missing model, missing ffmpeg), so retrying never helped the common case — and a failed chunk isn't fatal, since the reader can tap the paragraph again. If a paid provider's transient failures ever prove to be a real problem, retry only 5xx/408 and anything without an HTTP status; never 4xx, and never 429 without honouring `Retry-After`.

Still to add, and the port supports them without redesign:

- [ ] Google Cloud TTS
- [ ] Azure Cognitive Services TTS
- [ ] Amazon Polly
- [ ] Coqui TTS (open-source, higher quality / GPU-friendly alternative to Piper)
