# EPUBDate

EPUBDate is a small, offline, text-first EPUB reader for Playdate. It reads
ordinary unencrypted reflowable books from the Playdate data area.

Start with the [product spec](spec.md) for reader behavior and supported EPUB
features. [The refactor roadmap](refactor.md) explains the architecture work
that shaped the current code. The [backward-navigation plan](backward-navigation-plan.md)
records the fixed-memory reverse-navigation milestone.
The [reading-progress plan](progress-feature-plan.md) defines the next
incremental milestone for exact percentages, learned pace, and progress UI.

## Build and run

You need Zig 0.16.0 and Playdate SDK 3.0.0 or newer. Set
`PLAYDATE_SDK_PATH` to the SDK directory.

```sh
zig build test  # host unit and integration tests
zig build       # make the .pdx package
zig build run   # package and open it in the simulator
```

Run the host suite before changing behavior. For reader, rendering, input, or
memory work, also smoke test in the simulator and on hardware.

## How the reader is put together

| Area | Owns | Change it when… |
| --- | --- | --- |
| Platform | Playdate API calls, file adapters, allocation, drawing | adapting a device API or rendering primitive |
| Storage | library discovery, settings, resume records, pace, writes | changing saved data or persistence timing |
| Archive | ZIP validation and bounded stored/DEFLATE streams | changing archive support or validation |
| Publication | EPUB container, OPF spine, and chapter labels | changing EPUB metadata handling |
| Content | XHTML events, page building, word extraction | changing text interpretation, pagination, or word rules |
| Reader coordinator | screens, input intents, reader composition, bounded work order | adding reader UI behavior or a new mode |

`App` is the Playdate-facing shell. It collects buttons and crank input,
adapts file and menu callbacks, hosts the drawing adapter, and gives the
coordinator one bounded update each frame. Reader policy belongs in the
coordinator and reader engines, not in `App` callbacks.

## The important owners

- `OpeningSession` owns the EPUB-opening state machine and its temporary work.
- `PagedReader` owns the ten-page pool, its eight-page history window,
  selection, rescans, checkpoints, and page navigation.
- `RsvpReader` owns the 66-slot word ring, its 64-word reverse window,
  autoplay, and semantic reconstruction targets.
- `PrefetchSession` prepares one next-chapter page only after it owns the
  shared decode lease.
- The persistence service owns record names, validation, debounce scheduling,
  and writes.
- The Playdate renderer turns prepared text and geometry into graphics calls.

## Rules that keep this safe

- Keep substantial reader state on the heap. The Playdate callback stack is
  tiny; do not return or copy large reader structs during startup.
- Decode only a bounded amount per update. Opening, page builds, rescans, and
  prefetch must yield between steps.
- Keep the page pool fixed at ten caches: up to eight history pages, the
  displayed page, and one building, ready-ahead, or prefetch page.
- Keep the RSVP pool fixed at 66 word slots, with no more than 64 prior words
  retained behind the current word.
- Do not seek inside a DEFLATE stream. Rebuild semantic positions from the
  start of a chapter.
- There is one reusable decode workspace. Active reading and prefetch must
  never use it at the same time.
- Paged and RSVP positions use the same normalized word ordinal.
- Keep Playdate bindings in platform-facing code. Reader, archive, content,
  publication, and storage code should stay host-testable.

## Where a change belongs

For a new button rule or screen transition, start with the input policy and
reader coordinator. For page behavior, work in `PagedReader`; for RSVP timing
or word movement, work in `RsvpReader`. EPUB opening failures and metadata go
through `OpeningSession`. Saved settings or positions go through the
persistence service. Add a drawing primitive to the Playdate renderer rather
than calling graphics APIs from a reader engine.

Give every extracted module direct host tests for its contract. Keep an
integration test when a change crosses ZIP, EPUB, XHTML, and reader layers.

## Before you hand it off

Run `zig build test` and `zig build`. For a reader-facing change, smoke test:

- opening a book and browsing chapters;
- Paged and RSVP navigation, including a mode switch;
- returning to the library and reopening the book; and
- the same flow on hardware.

For cache or reconstruction work, enable **Telemetry** in the system menu
immediately before the measured interaction. The overlay reports current and
maximum frame-update milliseconds, page-build timing, allocator live/peak
bytes, and the fixed reader-cache reservation. Exercise eight reverse Paged
turns, 64 reverse RSVP words, and the first miss beyond each window.

The product limits, EPUB compatibility details, and known non-features live in
the [product spec](spec.md).
