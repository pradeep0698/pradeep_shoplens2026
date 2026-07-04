Deep-review a single request's log trace from `ai-analyzer` or `product-matcher` — either a log
excerpt the user pastes directly, or logs you pull yourself (by `req=<id>`, or the most recent
request if none is specified). This is a different job from `check-ai-analyzer-logs`: that skill
scans for NEW warnings/errors across many requests. This skill takes **one request's full trace**
— which may show zero errors — and checks whether it actually behaved *correctly*, not just
whether it crashed.

## Step 0 — Get the full trace

If the user pasted a log excerpt that looks truncated (starts mid-request, or ends before a
`TIMING` line), pull the rest before analyzing:

```bash
gcloud logging read 'resource.type=cloud_run_revision AND resource.labels.service_name=ai-analyzer AND textPayload:"req=<id>"' \
  --project=project-b1a5dd5a-69e6-4db3-9d7 --freshness=2h --format="value(timestamp,textPayload)" --limit=100 | sort
```

Swap `service_name` for `product-matcher` if the trace is from there. If no request ID was given,
find the most recent one first (`--limit=1 --format="value(textPayload)"` filtered to a line
containing `req=`, or just read the tail of recent logs).

## Checks to run — go through all of these, not just the obvious one

### 1. Timing breakdown vs. known baselines
Extract every phase from the `TIMING` / `TIMING (stream)` line. `/analyze` and `/analyze/stream`
use `gemini=`, `items_phase=`, `items=`, `total=`. `/identify` changed shape on 2026-07-04 when the
Lens/Gemini/Shopping hedge shipped (see §2's regression note below) — current lines use `upload=`,
`lens=`, `gemini=`, `shopping=`, `total=`, plus three flags: `hedge_triggered=` (whether Lens was
still running past `LENS_HEDGE_DELAY_SECONDS`, default 25s, and Gemini+Shopping were raced against
it), `lens_timed_out=` (Lens's own HTTP call hit `LENS_TIMEOUT_SECONDS`, 60s), and
`quota_exhausted=`. Older lines (pre-2026-07-04) instead show `describe_and_upload=`, `lens=`,
`shopping=` with no hedge fields — treat those as the prior sequential design, not a parsing error.
Once hedged (`hedge_triggered=true`), `lens`/`gemini`/`shopping` can legitimately overlap in
wall-clock time and sum to more than `total` — that's by design, not an arithmetic bug; `total` is
the only authoritative wall-clock number. Compare `total` against the measured baselines in
`docs/analyze-perf-test-results.md`: `/analyze` p50 49.3s / p95 60.3s (at `max_searches=5`);
`/identify` p50 19.2s / p95 26.4s on a cache miss, ~55ms on a cache hit — note these `/identify`
baselines predate the hedge change and may no longer reflect typical behavior (fast-path taps
should be unaffected, but a slow-Lens tail that now hedges via Shopping should generally finish
faster than before, not slower). A single phase eating most of `total` is normal (SerpAPI is the
usual bottleneck, not a bug) — only flag it as a **regression** if `total` is meaningfully outside
the p95, or if a phase that should be fast (Gemini detection, GCS upload, crop) is unexpectedly slow.

### 2. SerpAPI call health
For every `SerpAPI [<label>] status=...` / `SerpAPI [<label>] request failed: type=...` line:
- Elapsed time under ~10s is healthy; 10-30s is degraded-but-tolerable; hitting the full configured
  timeout (60s for Lens, 10s for Shopping, 3s for the account probe) is a real failure, not just
  "slow." SerpAPI's own response time is the dominant source of latency in this app right now —
  don't chase it as if it's fixable in our code; just report the pattern (how often, which engine,
  what fraction of requests).
- **Exception-type regression check:** a failure line must show a clean type — `ReadTimeout`,
  `ConnectTimeout`, or `Timeout`. If you see `type=ConnectionError` with a "Max retries exceeded"
  message, that's the exact regression fixed on 2026-07-04 (`Retry(read=0)` silently wrapping
  timeouts) — if it reappears, someone changed `read=False` back to `0`/`None` in
  `_build_session()` (`services/ai-analyzer/analyzer.py`, `services/product-matcher/matcher.py`).
  This still matters for `/identify`'s `lens_timed_out=` log field to be accurate, but as of the
  2026-07-04 hedge change it no longer gates *whether* the Gemini+Shopping hedge fires — that's now
  a plain wall-clock check (`Lens hasn't answered within LENS_HEDGE_DELAY_SECONDS`), independent of
  which exception type Lens eventually raises or whether it raises one at all.
- If `docs/issues/issues-from-logs.md` or the `serpapi_call_duration_seconds` log-based metric
  (Cloud Monitoring, created 2026-07-04) already covers a pattern you're seeing, reference it
  instead of re-deriving it from scratch.

### 3. Item-prioritization correctness (only when preference_terms/shopping_categories are non-empty
   and more items were detected than got searched)
Don't just eyeball whether the "right" item got picked — **actually run the scoring function**
against the detected item list and the request's real preference_terms/shopping_categories:

```python
# from services/ai-analyzer, or the matcher.py equivalent for product-matcher
from analyzer import _preference_score, _prioritize_items, _normalize_terms
items = [{"name": n} for n in [...]]  # paste the detected item names from the log
result = _prioritize_items(items, [...preference_terms...], [...shopping_categories...])
```
Compare the top N (N = the searched item count from the TIMING line) against what actually got
cropped/searched in the log. A mismatch is worth digging into — the compound-word matching bug
fixed 2026-07-03 (`_term_matches`, e.g. "Smart Watch" vs "smartwatch") is the known example of this
class of bug; there may be others (e.g. `_CATEGORY_KEYWORDS` gaps — it's duplicated across
`ai-analyzer`, `product-matcher`, and mobile, and already known to drift, per `docs/consistency/progress.md`'s
"Unify the category-keyword list" backlog item).

### 4. Result quality — not just "did it return results," but "are they good"
For every `Lens match:` / product line in the trace:
- **Price:** tally how many show `price=0.00`. A high fraction (roughly a third or more) is worth
  flagging — SerpAPI didn't provide extractable price data for those, which looks broken to a
  shopper even though it's not a code bug.
- **Is it actually a product?** Skim titles/URLs for anything that isn't a real, currently-available
  single-item listing — Q&A/support pages, "sold out"/"no longer available" banners, or category or
  search-aggregator pages (e.g. `ebay.com/shop/...`, not `ebay.com/itm/...`). If you find one, check
  it against the actual filters before concluding it's a gap:
  - `_is_product_name()` (`analyzer.py:685`) — only rejects titles containing `?`, over 10 words, or
    over 100 chars.
  - `_is_shopping_url()` (`analyzer.py:696`) + `_BLOCKED_DOMAINS` (`analyzer.py:655`) + `_ARTICLE_PATH_RE`
    (`analyzer.py:678`) — only rejects a fixed social-media domain list and article/blog/review-style
    URL paths.
  Neither one currently catches Q&A/support paths (e.g. `/questionandanswer/`), "sold" banners, or
  category/search-aggregator link shapes — if you see one of those slip through, that's a real,
  reportable filter gap, not a one-off fluke.

### 5. MLKit context sanity
Check the `MLKIT | route=... trigger=... confidence=... objects=... labels=...` line against what
it's actually supposed to mean. The backend's `MlKitContext` Pydantic model
(`services/ai-analyzer/main.py`) documents `route` as `'on_device_confident'` or `'gemini_fallback'`
and `trigger` as `'tap'` or `'auto'` — but the mobile client
(`mobile/lib/presentation/screens/live_scan_screen.dart`, around the `mlkitContext` map literal)
actually sends `route` as just `'identify'`/`'analyze'` (the endpoint chosen) and `trigger` as
`'tap'`/`'scan_all'`. This means `route` currently carries **no on-device-confidence signal at
all** — it's redundant with the endpoint already visible elsewhere in the same request's logs.
Found 2026-07-04; not yet fixed. If you're trying to analyze "how often does ML Kit route
confidently vs. fall back to Gemini" from these logs, know that the data doesn't currently support
that question — flag this rather than draw a false conclusion from `route`'s literal value.

## Reporting

Lead with what's confirmed **working** (recent fixes holding up, healthy timing, correct item
selection) before what's wrong — don't just hunt for problems in a request that was actually fine.
For anything you flag as a bug, cite the actual file:line and, where feasible, prove it (run the
scoring function, check the regex against the real log line, re-derive the exact numbers) rather
than asserting from a first read. If nothing in this request is new/notable beyond confirming
known, already-tracked issues, say so briefly instead of padding out a report.
