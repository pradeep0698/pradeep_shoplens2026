Explain any ShopLens feature or concept end-to-end for a mixed audience — plain-English summary,
business value, functional importance, technical implementation, architecture, and diagrams — by
reading the current code (not stale docs or memory). Use this when asked to "explain X feature",
"walk me through how Y works", "give me a concept doc/explainer for Z", or to prep a demo,
stakeholder update, or onboarding doc about some part of the product.

## Step 0 — Resolve the target

The argument is the feature/concept to explain (e.g. "the Lens hedge in /identify", "voice assistant
preference learning", "live-scan streaming", "ML Kit routing", "the deploy pipeline"). If no argument
was given, or it's too vague to locate in the code, ask the user to name a specific feature — don't
guess at scope. A good target is narrow enough that one document can cover it thoroughly (a single
mechanism, endpoint, or user-facing capability), not "the whole app."

## Step 1 — Read the current code, not just docs/memory

Docs and memory drift out of date; the code is ground truth for the design-question sections below.

- Grep/Glob for the feature across `services/*/`, `mobile/lib/`, and relevant `.github/workflows/*`
  to find every file that actually implements it — don't stop at the first hit.
- Read the real implementation (not just function signatures) — control flow, thresholds, env-var
  knobs, error handling, edge cases.
- Check `git log -- <files>` / `git show <sha>` for the commits that shaped this feature — recent
  commit messages often explain *why*, which the code alone won't, and reveal whether it's actively
  evolving or settled.
- Cross-check any existing docs under `docs/` that reference this feature (e.g. `docs/diagrams/`,
  `docs/ai-chat/`, `docs/*flow*.md`, `docs/*-changes.md`) for context/history — but if a doc conflicts
  with what the current code does, trust the code and flag the doc as stale in your report.
- If `docs/issues/issues-from-logs.*.md` or `docs/issues/ai-analyzer-metrics.*.md` has real production
  data on this feature (timings, failure modes), fold that in — it's stronger evidence than reading
  the code alone.

## Step 2 — Write the explainer

Produce a single document with these sections, in this order. Skip a section only if it's genuinely
inapplicable (say why) rather than leaving it thin.

1. **What it is (plain English)** — 2-4 sentences, no jargon, readable by a non-engineer PM or exec.
   What does it do, from a user's or the business's point of view?
2. **Business value** — why this matters: what user problem it solves, what breaks/degrades for the
   business without it (conversion, retention, cost, latency-driven drop-off, competitive parity), and
   any tradeoffs it represents (e.g. cost vs. speed, accuracy vs. latency). Ground this in what the
   code actually does — don't invent generic SaaS-speak benefits it doesn't earn.
3. **Functional importance** — how central this is: what depends on it, what fails or degrades if it's
   removed/broken, which user flows touch it, what edge cases it's specifically built to handle.
4. **Technical insights** — the real implementation: key files/functions with `file:line`, the
   algorithm/control-flow in plain steps, config knobs (env vars, defaults), notable tradeoffs or
   known limitations/gotchas, and anything surprising a new engineer would trip over.
5. **Architecture** — where this sits in the broader system: which services/components are involved,
   what calls what, which external dependencies it touches (Gemini, SerpAPI, Firestore, GCS, etc.),
   and how data flows through it end to end.
6. **Diagram(s)** — at least one Mermaid diagram (flowchart for data/control flow, sequence diagram
   for a request lifecycle) matching this repo's existing convention (see
   `docs/diagrams/voice-diagrams.md`, `docs/diagrams/c1-4/` for style/format reference). Diagram the
   feature specifically — not a generic system diagram — labeling real function/file names, not
   abstract boxes.
7. **Recent history / open questions** — anything worth flagging: recent changes (with commit refs),
   known issues (link `docs/issues/*.md` entries if relevant), unverified assumptions, or parts of the
   design that seem incomplete or in flux.

## Step 3 — Ground every claim

Every factual claim about behavior, thresholds, or file locations must be traceable to something you
actually read this run (a file:line, a log line, a commit) — not restated from training data or an
older memory note. If you're not sure something is still true, say so rather than asserting it.

## Step 4 — Output

- Reply in chat with the full explainer — this is usually wanted immediately (demo prep, stakeholder
  question, onboarding).
- Also save a copy to `docs/concepts/<kebab-case-feature-name>.md` (create the `docs/concepts/`
  directory if it doesn't exist yet) so it persists as reusable documentation, and mention the path
  in your reply. Skip the save only if the user says this is a one-off/throwaway question.
