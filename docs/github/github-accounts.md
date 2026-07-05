# GitHub Repos & Accounts — Audit (2026-07-02)

This is a point-in-time record of every GitHub repo/org this project has
used, who owns/controls each, which emails are tied to them, and which one
is authoritative today. Built by grepping every doc/script/workflow in this
repo plus `git log --all` across every branch — see citations inline.
Anything not explicitly documented somewhere is marked **undocumented**
rather than guessed at.

## TL;DR

- **Use `shoplens2026ai/shoplens2026` going forward.** Local remote `origin` points here.
- `shoplensai-coder/shoplens` is legacy but **not fully retired** — cookshop-dev-rajan-prod's GitHub Actions deploy still trusts this repo's identity via Workload Identity Federation. Local remote `legacy` points here.
- `suryaraor/shoplens2026` was a short-lived intermediate step between the two above — deprecated, secrets were not carried forward to it.
- Two more repo names (`suryaraor/shoplens`, `suryaraor/rsr01`) show up in old docs with no corroborating detail — flagged as unconfirmed, not asserted as real/current.

## Repo matrix

| Repo | Status | Owner account | Owner email | GCP project it deploys | CI/CD trust | Notes |
|---|---|---|---|---|---|---|
| **`shoplens2026ai/shoplens2026`** | ✅ **Current / active** | Org `shoplens2026ai`, created by account `shoplens2026ai-source`; `suryaraor` invited & accepted as **Owner** | `suryarao.r@gmail.com` | `project-b1a5dd5a-69e6-4db3-9d7` (number `115535290381`) — "shoplens2026-dev" | WIF pool `github-pool`/`github-provider`, condition `assertion.repository=='shoplens2026ai/shoplens2026'` | Local remote: `origin`. Branches: `main`, `shoplens2026-dev-setup`. 4 Actions secrets (`SHOPLENS2026DEV_*_ENV`) live here only — had to be added manually via web UI because `gh api`/`gh secret` 404s against this repo for both fine-grained PAT and classic OAuth tokens (root cause unresolved). |
| **`shoplensai-coder/shoplens`** | ⚠️ Legacy, but **still load-bearing** | Org `shoplensai-coder` | Git identity tied to it: `shoplens.ai@gmail.com` (commit author `shoplensai-coder`) | `cookshop-dev-prj` (number `82592393149`) — "cookshop-dev / Rajan prod" | WIF for cookshop-dev-prj is locked to `assertion.repository=='shoplensai-coder/shoplens'` (`.github/workflows/deploy-cookshop-dev.yml`) | Local remote: `legacy` (renamed from `origin` 2026-07-02). Private repo, 21 remote branches. Despite being called "unreachable" in the 2026-06-30 migration note, **cookshop-dev's live deploy pipeline still authenticates as this repo** — do not delete/archive it without re-pointing that WIF provider first. A separate worktree (`C:/github/suryaraor/shoplens-serpapi-fix`, branch `fix/serpapi-search-limit`) still tracks `legacy/main` and hasn't been repointed to the new origin. |
| `suryaraor/shoplens2026` | ❌ Deprecated (2026-07-02) | Personal account `suryaraor` | `suryarao.r@gmail.com` | Same GCP project as #1, before the org transfer | WIF briefly pointed here (2026-06-30 → 2026-07-02) before repointing to the org repo | Intermediate step between `shoplensai-coder/shoplens` and `shoplens2026ai/shoplens2026`. Secrets were explicitly **not** carried forward here after the org transfer. |
| `suryaraor/shoplens` | ❓ Unconfirmed | Personal account `suryaraor` (if real) | — | — | — | Referenced exactly once (`docs/shop-lens-cloud-setup.md:167`) with no corroborating mention anywhere else. Could be a real early alias or a documentation typo for `shoplensai-coder/shoplens` — not verified either way. |
| `suryaraor/rsr01` | ❓ Abandoned bootstrap name, current existence unknown | Personal account `suryaraor` | — | — | — | `PUSH_CHECKLIST.md` describes the exact same service set (ai-analyzer, product-matcher, state-manager, pubsub-worker, Next.js frontend) under this name/path — almost certainly the project's original name before the "ShopLens" rename. No later doc mentions it again; whether the GitHub repo still exists is undocumented. |

## Other accounts/emails seen (not GitHub repos, but relevant to "who has access")

| Email/account | Where seen | Relevance |
|---|---|---|
| `aistreamscan@gmail.com` | `infra/infra_status.txt` | Deployed an old, explicitly superseded GCP project (`1017419148960`, last verified 2026-05-04). Not tied to any current repo. |
| `shoplens.ai@gmail.com` | `docs/shop-lens-dev-details.md`, `docs/local-setup.md` | Owner of GCP project `shoplens-dev-499700` (pre-renumbering) and of two earlier abandoned projects (`shoplens-dev-prj`, `shoplens-dev-prj-ccf98`, superseded 2026-06-18). Same email as the `shoplensai-coder` commit-author identity — likely the same person/account operating both the legacy GitHub org and the legacy GCP projects. Known separately to **not** have Firebase access to `cookshop-dev-prj-bd7e2`. |

## Commit-author identities (`git log --all`, every branch, both remotes)

| Name | Email | Commits (author) | First seen | Last seen |
|---|---|---|---|---|
| suryaraor | `suryaraor@users.noreply.github.com` | 74 | 2026-06-15 | 2026-07-02 |
| shoplensai-coder | `shoplens.ai@gmail.com` | 47 | 2026-06-15 | 2026-06-26 |
| bijalm | `02bijal@gmail.com` | 39 | 2026-06-16 | 2026-07-02 |
| Bijal Mugatwala | `33298527+bijalm@users.noreply.github.com` | 13 | 2026-06-22 | 2026-06-29 |
| Tanusakaray / Tanushri Sakaray | `tsakaray3@gmail.com` | 3 | 2026-06-27 | 2026-07-02 |
| GitHub (merge-commit bot) | `noreply@github.com` | 59 (as committer only) | — | — |

Notes:
- `02bijal@gmail.com` and `33298527+bijalm@users.noreply.github.com` are almost certainly the same person (personal email vs. GitHub's noreply alias) — active across most legacy-repo feature/fix branches.
- `tsakaray3@gmail.com` is the only identity active on **both** the legacy repo and the current `shoplens2026ai` repo (forgot-password, recent-search, view-password, voice-chat-on-main, main-prod-cookshop, release/prod, setup/deployment-workflows, and both `shoplens2026-dev-setup` branches).
- No file in this repo documents Bijal's or Tanushri's actual GitHub usernames, roles, or access level — everything about them here is inferred from commit metadata, not from any access-control record.

## Access levels — what's actually documented vs. planned

The only formal access-control scheme on file is `docs/github-org.md` (lines
26-33), and it is a **plan/recommendation**, not a confirmed record: it
proposes a `core-eng` team (Write) and `deploy-admins` team (Admin), with
1-2 org Owners. There's no other document confirming these teams were
actually created or who's in them.

The only access fact confirmed elsewhere: **`suryaraor` is Owner of the
`shoplens2026ai` org** (`docs/shoplens-2026-dev-resume.md`), invited by
`shoplens2026ai-source` after initial transfer attempts failed due to
missing org membership.

## Known gaps (explicitly unconfirmed, not guessed)

- No document lists current collaborators/members for any of these repos beyond the single Owner fact above.
- `suryaraor/shoplens` — single-sourced, unverified as a real distinct repo.
- `suryaraor/rsr01` — current existence/deletion status unknown.
- Bijal's and Tanushri's GitHub usernames and formal roles are not recorded anywhere.
- Root cause of `gh api`/`gh secret` 404-ing against `shoplens2026ai/shoplens2026` for both a fine-grained PAT and a classic OAuth token (with explicit org access granted) was never identified — plain `git` operations work fine against it, so it's isolated to GitHub's REST/GraphQL API layer for this token/org combination.
