# Idea: Real-Time Progress Visibility During Scans

*Created: 2026-07-03 — planning only, nothing in this doc has been implemented.*

## The problem

Right now the whole wait — 5s on a good day, 25s+ when SerpAPI has a bad moment (see the
`req=b5e7b770` log from today: Lens timeout → Gemini recovery → Shopping timeout → 0 results,
all under one static "Matching products..." label) — shows the user exactly one generic
message for the entire round trip. There's no sense of *what's happening*, *how far along it
is*, or *whether it's stuck vs. just slow*. This is worse on tap-identify (`PipelineStatusBar`
shows "Matching products..." from the instant the tap lands to the instant it's done or
failed — see `pipeline_provider.dart`'s `identifyTappedObject()`) than on the full multi-item
scan, which at least steps through `analyzing → matching → saving → done`
(`analyze_image_usecase.dart`'s `PipelineStep` enum) — but even that is one label per phase,
not a real checklist.

The backend already has natural phase boundaries for both flows — this is about surfacing them,
not inventing new ones.

## What phases actually exist today (the raw material for any checklist UI)

**Single-tap `/identify`** (`analyzer.py`'s `identify_crop`) — as of 2026-07-04 this is an adaptive
hedge, not a single blocking call, so "phase" now means "what's racing what," not a fixed sequence:
1. Upload crop to GCS
2. Google Lens visual search kicks off immediately (up to `LENS_TIMEOUT_SECONDS`, 60s)
3. *(only if Lens hasn't answered within `LENS_HEDGE_DELAY_SECONDS`, 25s default)* Gemini
   description starts **concurrently with the still-running Lens call** — this used to be
   gated by `IDENTIFY_SKIP_GEMINI` running always-or-never; now it only ever fires on the slow
   tail, and `IDENTIFY_SKIP_GEMINI` is just a hard kill-switch for that tail behavior
4. *(only if Lens still hasn't answered once Gemini has a query)* Shopping search starts, also
   concurrently with the still-running Lens call
5. Whichever of Lens/Shopping produces usable products first wins — the request doesn't wait out
   the loser
6. Save to session (state-manager load → merge → save)

For a checklist UI, this means the honest labels are closer to "Searching visually…" (step 2,
covers the common fast case where nothing else ever runs) escalating to "Still looking — trying a
text search too…" only once the hedge actually fires (step 3/4) — not a fixed N-step sequence,
since steps 3-4 are conditional and race step 2 rather than following it.

**Multi-item `/analyze`** (`analyzer.py`'s `analyze_media` / already-existing `analyze_media_stream`):
1. Gemini full-image detection (finds N items + bounding boxes)
2. Dedup + prioritize + truncate to the search budget
3. Per item, in parallel (`ThreadPoolExecutor`, up to 10 concurrent): crop → GCS upload → Lens
   search → *(on failure)* Shopping fallback
4. Dedup products across all items
5. Save to session

The important thing: **`/analyze/stream` already exists and already emits one NDJSON event per
item as its search completes** (`{"type": "match", "name": ..., "products": [...]}`) — this is
almost exactly the data a checklist UI needs, and it's unclear whether mobile actually consumes
it incrementally today (this is already an open item in `progress.md`'s "In Pipeline": *"Confirm
incremental result rendering on mobile"*). That's the cheapest starting point of everything
below.

## Ideas, roughly low-effort → high-effort

- [ ] **A — Per-item checklist for multi-object scans, using what already streams.**
  Wire the mobile client to actually consume `/analyze/stream`'s existing per-item events (if
  it doesn't already) and render one row per detected item: name, then a status icon that
  flips from ⏳ *searching…* to ✓ *found* or ✗ *no match* as each item's own NDJSON event
  arrives. This is the most literal version of the "TODO list" idea, and needs **zero new
  backend work** — the events already exist, just may not be rendered incrementally client-side.
  *Effort: low (mobile-only, if the stream isn't already consumed). Impact: high — this is the
  single biggest visibility gap for the flow that already has the most items to show progress on.*

- [ ] **B — Skeleton/placeholder cards that fill in live.**
  The moment Gemini detection finishes (`{"type": "items", "items": [...]}`, which already
  fires first in the stream), immediately render N greyed-out placeholder `ProductCard`s — one
  per detected item — instead of a spinner. Each one "fills in" with the real product card as
  its own match event arrives. Familiar pattern (same idea as any shopping app's list-loading
  skeleton), and reuses A's data with no extra backend work.
  *Effort: low-medium (mobile UI work only). Impact: high — turns a blank wait into visible,
  incremental progress the instant detection finishes, which today is invisible until everything
  is done.*

- [ ] **C — "Detective board" overlay on the photo itself.**
  Since Gemini already returns bounding boxes per item, overlay a small status chip
  (🔍 → ✓/✗) directly on each detected object *in the photo the user just took*, instead of
  (or alongside) a separate list. Ties the abstract backend phase directly to the physical
  object the user is looking at — arguably more intuitive than a text list, and especially nice
  on the live-scan flow where the user is already looking at bounding boxes
  (`object_glow_overlay.dart`).
  *Effort: medium (new mobile widget, needs the same per-item box data `/analyze/stream`
  already carries). Impact: medium-high, mostly a delight/clarity win rather than a raw
  latency fix.*

- [ ] **D — Honest sub-phase messaging on tap-identify, tied to the actual recovery path.**
  `identify_crop` already has named internal phases (upload → Lens → Gemini recovery →
  Shopping fallback) — today none of that reaches the user; they just watch one static label
  for up to ~25s. Even without full streaming, a **client-side staged label sequence timed off
  the real p50/p95 numbers already measured** (`docs/analyze-perf-test-results.md`: `/identify`
  p50 19.2s / p95 26.4s on a cache miss) could step through "Looking it up…" → *(if past ~5s,
  the Lens-timeout ballpark)* "Trying a closer look…" → *(if past ~15s)* "Still working on
  it…" — turning what currently reads as "frozen" during exactly the case we saw in the logs
  today into "visibly still trying." This is a *client-side simulated* staging (not truly
  synced to backend state), so it's the cheapest version of this idea but can occasionally lie
  (e.g. label says "still working" after the request already actually finished, if timing
  drifts) — see Option E for the honest version.
  *Effort: low (mobile-only, timer-driven label swap). Impact: medium — doesn't reduce latency,
  but directly addresses the "is this stuck or just slow" anxiety visible in today's UX gap.*

- [ ] **E — True phase-level progress for `/identify`, streamed for real.**
  The fully-honest version of D: convert `/identify` (or add a `/identify/stream` sibling,
  mirroring `/analyze/stream`'s existing pattern) into an NDJSON/SSE response that emits a real
  event at each of `identify_crop`'s actual phase transitions (uploaded → searching → trying
  backup search → done). No guessing/timers — the UI shows exactly what the backend is doing,
  including the "trying a backup search" case that explains *why* a request is taking longer
  than usual instead of leaving the user guessing.
  *Effort: medium-high (new backend streaming endpoint + client consumer, mirrors `/analyze/stream`
  which already proves the pattern works in this codebase). Impact: high, and directly explains
  the exact failure mode from today's log walkthrough instead of hiding it.*

- [ ] **F — Firestore as the progress channel, instead of a new streaming endpoint.**
  A codebase-specific alternative to E: the mobile client *already* holds a live Firestore
  listener for the shopping list (`shoppingListProvider`), and the backend *already* writes to
  Firestore via `state-manager` at the end of every scan. Instead of building new
  streaming/SSE infrastructure, `identify_crop`/`analyze_media` could write a lightweight
  `session/{id}/progress` field ("uploading" → "searching" → "trying backup search" → "saving")
  at each phase transition, and the client's *existing* realtime listener plumbing picks it up
  with no new wire protocol. Reuses infrastructure this app already trusts and has proven
  working (session sync), rather than standing up SSE/WebSocket support on Cloud Run, which has
  its own timeout/scaling quirks worth avoiding if a simpler path exists.
  *Effort: medium (small backend writes + a new provider on mobile, but no new
  transport/protocol). Impact: same as E, cheaper to build and operate long-term — worth
  strongly considering over E for that reason.*

- [ ] **G — Turn a stuck phase into an action, not just a message.**
  Once any of the above gives phase-level visibility, a stuck "trying backup search…" state
  for more than, say, 10s could surface a "Cancel & retry" button right there, instead of the
  user just waiting out a request that might be heading for the same double-timeout seen in
  today's log. Small addition on top of D/E/F, but turns passive waiting into a real choice.
  *Effort: low, once phase visibility exists. Impact: medium — mostly matters for the
  slow-tail cases, which is exactly when it matters most to the user.*

- [ ] **H — Live counters and lightweight delight.**
  Smaller, additive ideas once A/B are in place: a ticking "Found 3 of 5…" counter as items
  resolve; a subtle haptic tick (mobile) when an item's card fills in; sorting the checklist so
  completed items bubble toward the top instead of staying in detection order. None of these
  need new backend data beyond what A already provides.
  *Effort: low. Impact: polish, not a core fix.*

## Suggested sequencing

1. **A + B first** — biggest visibility gap (multi-item scan), and both likely need *zero* new
   backend work if `/analyze/stream` isn't already wired into the mobile UI incrementally.
   Worth confirming that first before writing any new code.
2. **D next** — cheapest way to stop tap-identify from reading as "frozen," even before any
   backend streaming work exists.
3. **F over E** — if true phase-level tap-identify progress is worth building, prefer the
   Firestore-channel approach over a new streaming endpoint; it reuses infrastructure this
   codebase already has proven, instead of introducing a second transport pattern alongside
   `/analyze/stream`.
4. **C, G, H** — layer on once the underlying data (A/D/F) exists; each is a relatively small
   addition on top rather than its own project.

## Open questions before committing to any of this

- Does the mobile client already consume `/analyze/stream` incrementally, or does it currently
  wait for the whole thing like a normal `/analyze` call? This determines whether A/B are a
  UI-only change or need a client networking change too — worth checking before scoping either.
- If F (Firestore progress channel) is pursued, does writing a progress field on every phase
  transition meaningfully add Firestore write volume/cost at scale? Worth a rough estimate
  before committing, given the existing scale-to-zero cost sensitivity already noted elsewhere
  in `progress.md`.
- Is a client-side *simulated* staged label (D) acceptable as a permanent solution, or only as
  a stopgap until E/F ships? It's cheap but can drift out of sync with what's actually
  happening on a given request.
