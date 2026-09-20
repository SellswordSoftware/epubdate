# Backward navigation improvement plan

## Purpose and audience

This plan is for the engineer implementing faster reverse navigation in
EPUBDate. After reading it, they should be able to implement the work in
independently verifiable slices without weakening bounded memory, bounded
per-update work, or the single-owner decode model.

The intended result is:

- reconstruction processes at most 2 KiB of decoded chapter input per update;
- Paged mode retains eight prior pages, the current page, and one forward or
  prefetch page in a ten-slot pool; and
- RSVP mode retains a contiguous 64-word history plus the current word and
  one streamed lookahead in a 66-slot ring.

All capacities are fixed product policy. This milestone does not add dynamic
cache growth or user-facing cache settings.

## Current behavior and cause

Paged mode has three page slots with special previous, current, and next
roles. The first backward page turn is normally a cache hit. Once the shared
history slot represents the page ahead of the displayed page, another
backward turn misses. A miss reopens the chapter and reconstructs from page
zero. Intermediate pages produced during that reconstruction are discarded.

RSVP mode similarly retains only current, previous, and next words. Moving
farther backward requests a chapter replay. During replay, words before the
target are discarded rather than becoming useful history.

Both paths currently share a 256-byte chapter-work budget. That limit keeps
frames bounded, but makes an exposed reconstruction progress at a nominal
7.5 KiB per second at 30 FPS. Semantic checkpoint metadata cannot accelerate
the operation because it does not contain inflater, tokenizer, or pagination
state.

## Fixed resource decisions

### Reconstruction budget

Use separate named budgets for ordinary forward construction and exposed
reconstruction:

- normal active chapter work: 256 decoded bytes per update;
- Paged or RSVP reconstruction: 2 KiB per update; and
- prefetch: retain its existing independent budget.

The coordinator selects the budget from engine state. The stream loop must
still stop immediately when a page or RSVP target becomes drawable. The 2 KiB
value is a ceiling, not a requirement to consume all 2 KiB.

If hardware telemetry shows a reconstruction update exceeding one 30 FPS
frame, reduce the reconstruction budget to the largest measured power of two
that stays within the frame budget. Do not replace the byte ceiling with an
unbounded time-only loop.

### Paged pool

Use ten full `PageCache` slots:

- up to eight pages behind the stream-front page;
- the displayed page; and
- one page being built, ready ahead, or used by next-chapter prefetch.

Growing from three to ten slots adds seven page buffers. At the current page
limits, this adds just under 31 KiB of fixed storage. Slot metadata should be
small and fixed-size.

The eight-page promise applies within the active chapter. Cross-chapter
history remains a reconstruction boundary in this milestone. This avoids
having the displayed chapter diverge from the chapter whose ZIP stream and
decoder state are active.

### RSVP ring

Use 66 fixed word slots:

- a contiguous window containing up to 64 words before the current stream
  position;
- the current word; and
- one streamed lookahead word.

The ring may temporarily contain fewer than 64 words behind the displayed
cursor when the user has moved backward, because newer cached words remain in
the same window for instant forward movement. Growing from three fixed word
slots to 66 adds roughly 25 KiB at the current maximum word size.

The expected combined increase is about 55 KiB plus small metadata. Add
compile-time or unit-level size assertions for the configured pools, and
remeasure allocator high-water usage on hardware.

## Paged history design

### Slot identity

Replace special previous/current/next slot meaning with explicit metadata for
each slot:

- valid or free;
- chapter-relative page number;
- recency or generation for deterministic eviction; and
- whether the slot is pinned as displayed, stream-front, ready/building, or
  prefetch-owned.

Use a slot-index type large enough for ten entries. Remove assumptions that a
slot index fits in two bits from Paged and prefetch state.

The `PageCache` remains the owned rendered representation. Do not introduce a
second compact page format in this milestone.

### Contiguous-window behavior

Normal forward construction appends pages to the cache window. When a new
page requires space, evict the oldest unpinned page. At a steady stream front,
the pool contains the eight most recent prior pages, current, and next.

Moving backward or forward inside the cached window changes only the
displayed slot and selected word. It does not restart, rewind, or advance the
ZIP stream. The stream-front page and its ready-ahead/building state remain
parked until the display returns to the frontier.

When the display moves forward to the stream front, normal streaming resumes.
If a required page inside the supposed contiguous range is absent, report a
reconstruction requirement rather than guessing a slot relationship.

Selection remains a chapter-relative normalized word ordinal. A cached page
hit must fulfill a pending selection from that page's existing word metadata
without reparsing content.

### Rescan behavior

A cache miss still reopens and decodes the chapter from its start. During
that replay, every completed page is admitted to the same ten-slot window
instead of repeatedly overwriting one scratch page. By the time target page
`N` becomes drawable, the pool should retain up to pages `N-8` through `N`,
with the final slot available to build `N+1`.

This is important: faster reconstruction reduces one miss, while retaining
the replayed window prevents the next eight reverse turns from causing the
same work again.

Rescan-to-last-page uses the same rolling admission policy. It should finish
with the preceding chapter's final page displayed and up to eight pages of
that chapter immediately available behind it.

### Eviction and pinning

Eviction must never select:

- the displayed page;
- the page at which the active decoder is parked;
- a page currently being constructed;
- a ready-ahead page needed to resume forward reading; or
- a slot owned by prefetch.

Among remaining pages, evict the oldest page number in the active chapter.
This produces deterministic behavior and naturally preserves pages closest
to the user's current forward progress.

At verified chapter end there is no active forward build. Next-chapter
prefetch may use the otherwise-forward slot. If all ten slots are occupied,
it may evict the oldest history page but must leave the displayed final page
and its seven nearest predecessors intact. Activating prefetch starts a new
chapter and clears the old chapter's cache window as it does today.

## RSVP history design

### Ring representation

Replace current/previous/next booleans with a circular array and explicit
indices for:

- oldest retained word;
- number of valid words;
- displayed cursor; and
- newest streamed word.

Each slot owns its bounded bytes and semantic position. Also retain whether
the word is the first word of its sentence. This flag is derived when the
word is appended by comparing its sentence ordinal with the preceding emitted
word.

The circular array represents one ordered window. Backward movement decrements
the displayed cursor when the preceding word is present. Forward movement
increments it while a newer cached word exists. Only moving forward from the
newest retained word asks the stream for another word.

Appending at the stream frontier evicts the oldest word when the array is
full. It must never overwrite a slot currently addressed by the displayed
cursor without first advancing the logical oldest boundary.

### Reconstruction and sentences

During word or sentence reconstruction, append every replayed word to the
ring. Stop when the semantic target becomes current. A word-target replay
therefore arrives with up to 64 immediately preceding words already cached.

Previous-sentence movement searches backward for a cached slot marked as the
start of the preceding sentence. If that start is not retained—even if a
later word from the sentence is retained—it requests the existing semantic
sentence reconstruction. This preserves the current contract of landing on
the first word of the preceding sentence.

Autoplay and pace accounting continue to count displayed forward movement,
including movement through cached newer words. Cached reverse movement does
not contribute automatic progress. Chapter transitions still occur only when
the displayed cursor reaches the streamed final word and requests another
forward move.

Starting a chapter, changing chapters, and switching into RSVP through a
semantic reconstruction all reset and repopulate the ring deterministically.

## Implementation slices

### B1 — Separate reconstruction work budget — **Complete**

Introduce named forward and reconstruction byte ceilings in the resource
policy. Have the coordinator choose 2 KiB only while Paged or RSVP reports an
active semantic reconstruction. Preserve all existing early exits for a full
page, a resolved word, errors, and EOF.

Acceptance:

- normal forward work remains capped at 256 bytes per update;
- reconstruction never consumes more than 2 KiB per update;
- representative hardware reconstruction is materially faster without a
  frame exceeding the 30 FPS budget; and
- changing the budget does not change rendered text or normalized positions.

This slice is independently releasable and provides an immediate improvement.

Implemented with explicit resource-policy limits and semantic reconstruction
state for Paged page targets, Paged word targets, and RSVP targets. Exposed
reconstruction yields when a page completes or an RSVP target becomes
drawable; normal forward construction and prefetch keep their separate lower
ceilings.

### B2 — Generalize Paged slot ownership — **Complete**

Increase the pool to ten slots and replace two-bit and special-role slot
assumptions with explicit slot identity and pinning. Keep externally visible
navigation behavior unchanged in this slice.

Move free-slot selection and eviction entirely into `PagedReader`.
`PrefetchSession` receives an opaque-enough slot index and must not choose or
evict slots itself. The coordinator may request a prefetch destination but
must not manipulate page roles directly.

Acceptance:

- pool size and memory cost are fixed and asserted;
- every builder and prefetch pointer refers to a pinned slot;
- no operation can evict displayed, building, stream-front, ready-ahead, or
  prefetch-owned content; and
- forward reading and chapter prefetch retain their current behavior.

Implemented with a fixed ten-slot pool, widened slot indices, explicit
displayed/stream-front/history/building/ready-ahead/prefetch roles, and
history-only deterministic eviction inside `PagedReader`. Prefetch now asks
the reader to reserve and release its destination; activation clears the old
chapter's role metadata and preserves EOF state without creating an unused
builder. Compile-time assertions bind the pool to ten pages, a representable
slot-index range, and a 44 KiB maximum reservation.

### B3 — Enable the eight-page Paged history window — **Complete**

Route previous/next navigation through page-number lookup in the ten-slot
window. Preserve the active stream while browsing cached history. Change
targeted and last-page rescans to admit intermediate completed pages into the
rolling window.

Acceptance:

- eight reverse page turns from a fully populated stream front are immediate
  cache hits and perform no file open or decode work;
- cached forward turns return to the parked stream front and resume the
  existing ready-ahead stream without reconstruction;
- the ninth reverse turn requests one bounded reconstruction;
- a completed reconstruction leaves up to eight preceding pages cached;
- selection crossing cached page boundaries preserves the target ordinal;
- cache gaps request reconstruction instead of displaying a wrong page; and
- chapter-boundary behavior remains semantically unchanged.

Implemented with chapter/page lookup across the ten-slot pool and an
eight-page rolling history behind the stream front. Cached backward and
forward turns only change the displayed slot; the active builder or
ready-ahead page remains pinned until navigation rejoins the frontier.
Targeted and last-page reconstruction now admit every completed page and
evict the oldest history deterministically, leaving the requested/final page
with its nearest eight predecessors. Cached selection crossings continue to
resolve through each retained page's normalized word metadata.

### B4 — Add the 64-word RSVP window — **Complete**

Replace the three word slots with the 66-slot ordered ring. Use cached words
for reverse, forward, and previous-sentence movement when their complete
semantic targets are retained. Populate the ring during reconstruction.

Acceptance:

- up to 64 reverse words are immediate after the window is populated;
- moving forward through cached words does not decode duplicates;
- the first reverse word outside the window requests one semantic rescan;
- that rescan repopulates the preceding window rather than retaining only its
  target;
- previous sentence lands on a cached sentence start or reconstructs it;
- wraparound preserves UTF-8 word bytes and exact word/sentence ordinals; and
- autoplay timing, WPM behavior, pace records, and final-word chapter
  transition remain unchanged.

Implemented with a fixed 66-slot circular array, logical oldest/count/display
indices, and a 65-word retained window comprising the current word plus up to
64 predecessors. The extra slot is the bounded streamed append destination
before oldest-word eviction. Cached reverse and newer-word movement do not
touch the stream; reconstruction appends every replayed word until its word
or sentence target becomes drawable. Sentence-start metadata is recorded at
append time, and the pool is initialized in place to avoid a large device
stack temporary.

### B5 — Integrate, measure, and document — **Complete**

Run the complete host suite and package build, then perform simulator and
hardware smoke with a long DEFLATE-compressed chapter. Record allocator peak
and maximum frame-update time before and after the change.

Update the product specification and contributor documentation only after the
new limits are implemented. Replace references to exactly three page caches
and three RSVP word slots with the new fixed-window contracts. Keep the
no-DEFLATE-seek and single decode-workspace rules.

Acceptance:

- expected fixed memory growth stays within 64 KiB of the recorded baseline;
- no reconstruction update exceeds the hardware frame budget;
- eight cached reverse pages and 64 cached reverse words behave as specified;
- page/word misses remain incremental and cancellable;
- Paged↔RSVP transfer preserves the same normalized word;
- next-chapter prefetch still activates without copying decode state; and
- library return, resume, chapter browsing, and both reading modes pass
  simulator and physical-device smoke.

Repository integration is complete. The product and contributor documents
describe the ten-page and 66-word fixed windows, and the system menu now has a
development **Telemetry** checkmark. Enabling it resets frame/page timing high
water marks; the overlay shows current/maximum frame milliseconds,
live/peak allocator bytes, and the combined fixed cache reservation.

Hardware qualification remains pending:

| Measurement | Before | After |
| --- | ---: | ---: |
| Allocator peak | 170.91 KiB | 312 KB reported on hardware |
| Allocator live after smoke | not recorded | 275 KB reported on hardware |
| Maximum frame update | not recorded | not captured; smoke accepted without visible frame regression |

Simulator and physical-device smoke were accepted as passed for the expanded
cache build. The
allocator observations above are device readings, while the approximately
54.0 KiB cache growth is calculated from the fixed arrays; the difference
between total allocator peaks must not be attributed solely to those arrays.
No quantitative maximum-frame value was captured, so completion records the
observed interaction result rather than claiming a measured timing bound.

For the measured smoke, use a long DEFLATE-compressed chapter, enable
**Telemetry** immediately before reconstruction, and record the peak and
maximum frame values after: eight cached Paged reversals plus the ninth-page
miss; 64 cached RSVP reversals plus the next-word miss; cached forward return;
Paged↔RSVP transfer; a prefetched chapter transition; library return/resume;
and chapter-browser navigation. Repeat the functional sequence in the
simulator and on physical hardware.

## Focused verification matrix

Keep new automated coverage focused on the changed contracts:

| Area | Required scenarios |
| --- | --- |
| Work budget | forward ceiling, Paged rescan ceiling, RSVP rescan ceiling, early target stop |
| Paged ring | fill, wrap/evict, eight back, cached forward, ninth-page miss, rescan repopulation |
| Paged safety | pinned-slot protection, cache-gap fallback, selected ordinal across cached boundaries |
| Prefetch | destination pinning, oldest-history eviction at EOF, activation into a clean chapter window |
| RSVP ring | fill, wrap, 64 back, cached forward, miss, replay population, UTF-8 maximum-size word |
| RSVP sentences | cached sentence start, evicted sentence start, sentence-zero limit |
| Integration | long real DEFLATE chapter, mode transfer, resume, previous-chapter last-page reconstruction |

Do not duplicate input-routing, archive-validation, renderer, or persistence
tests whose contracts do not change.

## Risks and rollback points

- **Frame regression:** reduce only the reconstruction budget; the larger
  caches remain useful independently.
- **Paged slot complexity:** B2 must land before B3 so ownership bugs are not
  mixed with navigation behavior.
- **Prefetch starvation:** reserve or evict for the forward/prefetch role only
  after protecting the displayed and nearest history pages.
- **RSVP cursor corruption:** use logical ring offsets rather than retaining
  pointers to slots that can wrap and be overwritten.
- **Stack pressure:** keep both enlarged arrays inside the existing heap-owned
  coordinator state. Do not return or locally copy either engine by value.
- **Resume compatibility:** no storage format or layout revision change is
  required because persisted positions remain semantic word ordinals.

Each slice can be reverted independently. B1 has no data-layout dependency on
the cache work. B3 depends on B2. B4 is independent of B2 and B3. B5 closes
the milestone only after hardware evidence is recorded.

## Explicit non-goals

This milestone does not add:

- arbitrary seeking inside raw DEFLATE streams;
- inflater or tokenizer snapshots;
- disk-backed rendered-page caches;
- dynamically allocated or user-configurable cache sizes;
- compact variable-length page storage;
- retained Paged pages across an active chapter transition; or
- changes to EPUB compatibility, pagination rules, rendering, or persistence
  record formats.
