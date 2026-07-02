# Syncing your local workspace to the new repo (`shoplens2026ai/shoplens2026`)

The shoplens2026-dev repo moved from `suryaraor/shoplens2026` (personal account) to
`shoplens2026ai/shoplens2026` (org) on 2026-07-02. If you cloned or added a remote
before that date, follow this to repoint your local workspace. Background/history
is in `docs/shoplens-2026-dev-resume.md` → "GitHub Org Migration".

---

## 1. Get access to the org

Before anything else, you need to actually be a member of the `shoplens2026ai` org —
repo access alone isn't enough if you're used to working with `suryaraor/shoplens2026`
directly.

1. Ask an org owner (currently `shoplens2026ai-source` or `suryaraor`) to invite you
   to `shoplens2026ai` via **github.com/shoplens2026ai** → People → Invite member.
2. Accept the invite (email link, or check **github.com/notifications**).
3. Confirm it stuck: **github.com/settings/organizations** should list `shoplens2026ai`
   with no "Pending" badge.

## 2. Repoint your local remote

If you already have a remote pointing at the old location, rename/update it in place
so any existing branch tracking carries over automatically:

```bash
git remote rename origin shoplens2026ai   # or whatever your remote is currently named
git remote set-url shoplens2026ai https://github.com/shoplens2026ai/shoplens2026.git
git fetch shoplens2026ai
```

If you're cloning fresh instead:

```bash
git clone https://github.com/shoplens2026ai/shoplens2026.git
```

Verify it worked:

```bash
git remote -v
git ls-remote --heads shoplens2026ai   # or 'origin' if that's what you named it
```

## 3. Re-set upstream on your working branches

For any local branch you were tracking against the old remote, re-point its upstream:

```bash
git branch --set-upstream-to=shoplens2026ai/<branch-name> <branch-name>
```

(If you renamed the remote in place rather than re-adding it, `git` usually updates
tracking refs automatically — check with `git status -sb` before manually re-setting.)

## 4. If you use `gh` CLI

- `git` operations (clone/fetch/push/`ls-remote`) work normally once your account is
  an org member with an authorized token.
- **Known quirk:** `gh api` and commands built on it (like `gh secret list/set`) may
  404 against this repo even when plain `git` access works fine — we hit this
  ourselves during the migration and never fully root-caused it (org access grants
  looked correct on paper). If you hit this, don't burn time chasing it — just use
  the GitHub web UI for anything that needs the REST API (managing secrets, repo
  settings, etc.), and plain `git` for everything else.
- If `gh` prompts about org access, go to **github.com/settings/connections/applications**
  → **GitHub CLI** → make sure `shoplens2026ai` shows as granted under Organization access.

## 5. CI/CD secrets

The 4 GitHub Actions secrets (`SHOPLENS2026DEV_AI_ANALYZER_ENV`,
`SHOPLENS2026DEV_PRODUCT_MATCHER_ENV`, `SHOPLENS2026DEV_STATE_MANAGER_ENV`,
`SHOPLENS2026DEV_VOICE_ASSISTANT_ENV`) now live under
`shoplens2026ai/shoplens2026` → Settings → Secrets and variables → Actions.
They are **not** present on the old `suryaraor/shoplens2026` repo going forward —
don't bother checking secrets there.

## 6. WIF / GCP auth

No action needed here — the Workload Identity Federation provider and the
`shoplens-runner` service account binding were already repointed to
`shoplens2026ai/shoplens2026` as part of the migration. Deploys from this repo's
`main` branch via `.github/workflows/deploy-shoplens2026-dev.yml` should work
without any GCP-side changes on your part.
