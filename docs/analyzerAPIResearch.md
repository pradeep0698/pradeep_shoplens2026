# SERP API Comparison: Reverse Image Product Search
**Use case:** Given a cropped product image URL, find matching product name, price, and purchase URL.  
**Current stack:** SerpAPI Google Lens — two-pass (products → visual_matches), 15 s timeouts, ~$15/1K requests.  
**Research date:** 2026-06-06 | Sources: 15 fetched, 61 claims extracted, adversarially verified.

---

## TL;DR Recommendation

**Switch to [SearchAPI.io](https://www.searchapi.io/google-lens).** It returns price data in a **single pass** (no fallback needed), claims sub-2 s response, costs $1–4/1K vs SerpAPI's $15/1K, and has a free 100-request trial. As a cost-effective backup or long-term alternative, **Bright Data** matches the same Google Lens tabs (products/visual_matches) with no rate limits and a $500 deposit match.

**Eliminate immediately:** Bing Visual Search API (retiring Aug 11 2025) and Google Cloud Vision Product Search (requires your own catalog, returns no prices).

---

## Current Pain Points (Confirmed)

| Issue | Evidence |
|---|---|
| **Slow** | Two HTTP round trips at 15 s timeout each; up to 30 s worst-case per product |
| **Missing prices** | `visual_matches` rarely carries price fields; current code falls back to `price=0.0` |
| **Outage history** | Two confirmed Google Lens API outages in March–April 2025 (GitHub issues #2451, #2627); 100% failure rate during each event |
| **Result quality drift** | Since March 27 2025 (SerpAPI PR #5988), exact image matches no longer surface correctly without an "Exact Match token" workaround |

---

## Provider Comparison

### SERP API Providers

| Provider | Google Lens Support | Price / 1K requests | p50 latency | p99 latency | Free tier | Rate limits |
|---|---|---|---|---|---|---|
| **SerpAPI** (current) | ✅ Full (products, visual_matches, exact_matches, all) | **$15.00** | 2.1–2.5 s | 3.2–4.6 s | 100–250 searches/mo | Not disclosed |
| **SearchAPI.io** | ✅ Full — returns price + stock in one call | **$1–4** (volume-tiered) | ~2.1 s (measured) | Not published | 100 requests, no CC | Not disclosed |
| **Bright Data** | ✅ Full (products, visual_matches, exact_matches via `brd_lens`) | **$1.00–1.50** | Claims <1 s | Claims <5 s | Trial, no CC; $500 match | **None** |
| **Oxylabs** | ✅ Image URL input → JSON results; Python SDK | **$0.80–1.00** | ~5.5 s (benchmark) | ~15.6 s | 2,000 results, no CC | 10 rps (free), 50 rps (paid) |
| **DataForSEO Live** | ⚠️ Supported but verbose flat JSON, manual filtering needed | **$2.00** | 2.4–4.7 s | 4.1–15.8 s | $1 credit on signup | Not disclosed |
| **DataForSEO Standard** | ⚠️ Same but async queue | **$0.60** | ~5 min | N/A | Same | Not disclosed |
| **Zenserp** | ✅ Explicitly lists "Reverse Image Search" endpoint | **$0.90–2.00** | Not published | Not published | 50 searches/mo | 400 concurrent |
| **Serper.dev** | ❌ No Google Lens endpoint listed; strict QPS limits | **$0.30** | 0.83 s (avg) | 2.10 s | Not confirmed | Strict QPS |
| **ScaleSerp** | ❓ Not confirmed for Google Lens | **$6.60–23** | Not published | Not published | 125 searches/mo | Not disclosed |
| **Apify Google Lens Actor** | ✅ Returns price, vendor; exact/visual/all modes | Pay-per-event | Batch-oriented | Not for real-time | Free trial | Batch/export, not real-time API |

### Non-SERP Alternatives (Evaluated and Eliminated)

| Provider | Verdict | Reason |
|---|---|---|
| **Bing Visual Search API** | ❌ **Dead** | Retiring August 11 2025; replacement "Grounding with Bing" costs $35/1K and blocks raw results |
| **Google Cloud Vision Product Search** | ❌ **Wrong tool** | Requires retailer to pre-load own product catalog; returns no prices or web purchase URLs; limited to 5 product categories |

---

## Detailed Analysis

### SearchAPI.io — Top Recommendation

- **Single-pass price extraction**: Returns `extracted_price`, `currency`, and `stock_information` fields directly in product results — eliminates the two-pass retry loop entirely.
- **Latency**: Self-reported sub-2 s average; a sample API response in their docs shows `total_time_taken: 2.1s`. Comparable to SerpAPI at 1/4 to 1/15 the cost.
- **Pricing**: $4/1K (Developer) → $3 → $2.50 → $2 → **$1/1K** at 5M/month volume.
- **Integration**: Same REST pattern as SerpAPI — drop-in replacement parameters. Returns `visual_matches` and `shopping_results` types.
- **Trial**: 100 free requests, no credit card.
- **Risk**: Smaller provider; no published independent latency benchmarks. Validate with a 100-query trial before committing.

### Bright Data — Strong Alternative

- **Full tab support**: `brd_lens=products,visual_matches,exact_matches` covers exactly what the two-pass approach achieves in one configurable request.
- **Latency claims**: <1 s average, <5 s guarantee (marketing claims — not independently benchmarked).
- **No rate limits**: Explicitly "no limit — send as many requests as you need", ideal for burst workloads.
- **Cost**: $1.50/1K pay-as-you-go, $1.00/1K at $1,999/month plan.
- **Trial**: No CC required; $500 deposit match on first deposit.
- **Integration**: Python SDK available; REST API with JSON/HTML/Markdown output.
- **Risk**: The p99 >13 s in independent HasData benchmark (though that may be for standard SERP, not Lens).

### SerpAPI (Current) — Why to Move Away

- **Cost**: $15/1K is 5–15× more expensive than alternatives. Entry plan is $75/month for only 5,000 searches.
- **Reliability**: Two full outages (100% failure rate) confirmed in March–April 2025. Public status page at `serpapi.com/status/google_lens` exists — a sign outages are recurrent.
- **Result quality**: Since March 2025, exact image matches no longer surface by default without workarounds.
- **Keep as fallback**: SerpAPI's documented API is the most complete reference implementation; keep it as a circuit-breaker fallback with your own retry logic.

### Serper.dev — Not Suitable for This Use Case

Serper.dev is the cheapest provider ($0.30/1K) and fastest for standard Google Search (avg 0.83 s), but:
- **No Google Lens / reverse image search endpoint** listed in their API docs.
- Strict QPS rate limits make concurrent image-analysis pipelines risky.
- Suitable for text-based product search by name, not image-to-product matching.

### DataForSEO — Avoid for Real-Time Use

- Live mode ($2/1K) has p99 of 4.1–15.8 s — uncomfortably close to the 15 s timeout that's already causing problems.
- Standard queue (~$0.60/1K) has p50 of ~5 minutes — completely unsuitable for real-time product lookup.
- Flat verbose JSON structure requires manual filtering to extract shopping results.

---

## Migration Plan

### Option A: Switch to SearchAPI.io (Recommended)

Replace the `_google_lens()` function in [services/ai-analyzer/analyzer.py](../services/ai-analyzer/analyzer.py):

```python
# Replace SerpAPI call with SearchAPI.io
resp = requests.get(
    "https://www.searchapi.io/api/v1/search",
    params={
        "engine":   "google_lens",
        "url":      image_url,
        "api_key":  SEARCHAPI_KEY,
        "search_type": "products",   # single pass — returns price directly
    },
    timeout=10,  # can reduce from 15 s
)
data = resp.json()
for r in data.get("shopping_results", []):
    price = r.get("extracted_price") or _parse_price(r.get("price", "0"))
    if price:
        return _build_result(r, price)
# Fallback to visual_matches only if needed
```

**Expected improvement:** Single pass instead of two, price data directly in response, $1–4/1K vs $15/1K.

### Option B: Add Bright Data as Primary, Keep SerpAPI as Fallback

```python
providers = [
    {"name": "bright_data", "fn": _bright_data_lens},
    {"name": "serpapi",     "fn": _google_lens},       # existing code
]
for p in providers:
    try:
        result = p["fn"](image_url, query)
        if result:
            return result
    except Exception:
        continue
return None
```

### Option C: Parallel-race two providers

Fire both SearchAPI.io and Bright Data simultaneously, return the first response with a non-zero price. Doubles API cost but halves worst-case latency.

---

## Cost Comparison at Scale

| Volume | SerpAPI | SearchAPI.io | Bright Data | Zenserp |
|---|---|---|---|---|
| 5K/mo | $75 | $20 | $7.50 | ~$50 |
| 50K/mo | $225 | $125–150 | $75 | ~$100 |
| 100K/mo | $300+ | $150–200 | $100–150 | ~$180 |
| 1M/mo | $3,000+ | $1,000 | $1,000–1,500 | ~$900 |

---

## Open Questions

1. Does SearchAPI.io's price data coverage rate match SerpAPI's for niche/visual-match-only products? (Trial test needed)
2. What is Bright Data's actual p99 specifically for Google Lens product queries (vs standard SERP)?
3. Can the image upload step (imgbb → public URL) be eliminated by providers that accept base64 image input directly?
4. Would a parallel-race architecture (fire 2 providers, take first with price) be worth the 2× cost given current ~30% price-miss rate?

---

## Sources

| Source | Quality | Key Data |
|---|---|---|
| searchapi.io/google-lens | Primary | Pricing, fields, sub-2s claim |
| serpapi.com/google-lens-products-api | Primary | API schema, supported modes |
| dataforseo.com/apis/serp-api/pricing | Primary | Live $2/1K, Standard $0.60/1K |
| oxylabs.io/products/scraper-api/serp/google/lens | Primary | $0.80-1.00/1K, 50 rps paid |
| zenserp.com/pricing-plans | Primary | $0.90-2.00/1K, reverse image search confirmed |
| brightdata.com/products/serp-api/google/lens | Blog | $1.00-1.50/1K, <1s claim, no rate limits |
| hasdata.com/blog/best-serp-apis | Blog | Independent latency benchmark: SerpAPI 2.5s/4.6s, Oxylabs 5.5s/15.6s |
| serpapi.com/blog/who-has-the-fastest-google-search-api | Blog (SerpAPI) | SerpAPI 0.73s avg, Serper 0.83s avg — self-reported |
| apiserpent.com/blog/serpapi-vs-dataforseo-benchmark | Blog | SerpAPI p50 2.1s/p95 3.2s; DataForSEO Live p50 2.4s/p95 4.1s |
| searchcans.com/blog/serp-api-pricing-index-2026 | Blog | Pricing index: SerpAPI $15/1K, Serper $0.30/1K, DataForSEO $0.60-1.20/1K |
| github.com/serpapi/public-roadmap/issues/2451 | Forum | March 2025 outage: 100% failure rate on Lens |
| github.com/serpapi/public-roadmap/issues/2627 | Forum | April 2025 outage: all Lens searches failing |
| github.com/serpapi/public-roadmap/issues/2605 | Forum | Result quality drift since March 27 2025 |
| cloud.google.com/vision/product-search/docs | Primary | Requires own catalog, no prices — eliminated |
| ppc.land (Bing Search API retirement) | Secondary | Bing retiring Aug 11 2025 — eliminated |
