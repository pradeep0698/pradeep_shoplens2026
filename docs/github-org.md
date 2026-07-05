# Setting up a GitHub Organization for shoplens2026 team collaboration

> **Status: done (2026-07-02).** Option A below was followed — org `shoplens2026ai` created, repo transferred, CI/CD repointed. See `docs/shoplens-2026-dev-resume.md` → "GitHub Org Migration" for what actually happened, including a gotcha where the org owner (`shoplens2026ai-source`) had to invite the repo owner (`suryaraor`) as an Owner before the transfer would go through. Rest of this doc kept as the original plan for reference.

## Why `github.com/shoplens2026ai-source/shoplens2026` doesn't work as-is

`shoplens2026ai-source` is already registered as a **personal GitHub user account** (confirmed via `gh api users/shoplens2026ai-source` → `"type": "User"`), not an organization. GitHub usernames and organization names share one global namespace, so you cannot create an org named `shoplens2026ai-source` while that user account exists — the name is taken.

There are two real paths to get a repo living at an org-owned URL:

---

## Option A — Create a brand-new org (recommended)

No dependency on the `shoplens2026ai-source` account or its owner's credentials. Takes ~10 minutes.

1. **Create the org**: go to https://github.com/organizations/new
   - Plan: **Free** (unlimited private repos, unlimited collaborators — see Cost below)
   - Pick a name that's actually available, e.g. `shoplens2026ai`, `shoplens2026-org`, `shoplens2026-team` (anything but `shoplens2026ai-source`, which is taken)
   - Enter a contact email and verify

2. **Move the repo in**:
   - Easiest: transfer the existing repo — from `suryaraor/shoplens2026` go to **Settings → General → Danger Zone → Transfer ownership**, target the new org. This preserves history, issues, stars, and the git remote just needs updating locally.
   - Alternative: push a fresh copy to a new empty repo created directly under the org.

3. **Set up teams** (Settings → Teams → New team). Suggested structure:
   | Team | Access level | Who |
   |---|---|---|
   | `core-eng` | Write | Regular contributors |
   | `deploy-admins` | Admin | People who manage secrets, WIF, branch protection |
   | (org owners) | Owner | 1–2 people max — full control incl. billing |

4. **Invite members**: Settings → People → Invite member → assign each to a team (by GitHub username or email).

5. **Branch protection** on `main` (Settings → Branches → Add rule):
   - Require a pull request before merging
   - Require ≥1 approval (2 if the team grows)
   - Require status checks to pass (once CI checks exist beyond the deploy workflow)
   - Restrict direct pushes to `main`

6. **Update CI/CD to point at the new repo path** — required regardless of transfer vs. fresh push, since the WIF trust condition is locked to a specific `org/repo` string:
   - [ ] Update the WIF provider's attribute condition:
     ```bash
     gcloud iam workload-identity-pools providers update-oidc github-provider \
       --location=global --workload-identity-pool=github-pool \
       --project=project-b1a5dd5a-69e6-4db3-9d7 \
       --attribute-condition="assertion.repository=='<new-org>/shoplens2026'"
     ```
   - [ ] Re-bind the `shoplens-runner` service account to the new principal:
     ```bash
     gcloud iam service-accounts add-iam-policy-binding \
       shoplens-runner@project-b1a5dd5a-69e6-4db3-9d7.iam.gserviceaccount.com \
       --role="roles/iam.workloadIdentityUser" \
       --member="principalSet://iam.googleapis.com/projects/115535290381/locations/global/workloadIdentityPools/github-pool/attribute.repository/<new-org>/shoplens2026" \
       --project=project-b1a5dd5a-69e6-4db3-9d7
     ```
     (and remove the old `suryaraor/shoplens2026` binding once confirmed working)
   - [ ] Re-add the 4 Actions secrets under the new repo's Settings → Secrets and variables → Actions:
     `SHOPLENS2026DEV_AI_ANALYZER_ENV`, `SHOPLENS2026DEV_PRODUCT_MATCHER_ENV`, `SHOPLENS2026DEV_STATE_MANAGER_ENV`, `SHOPLENS2026DEV_VOICE_ASSISTANT_ENV` — full contents of the matching `services/*/.env.shoplens2026-dev` file
   - [ ] Update the repo-path comment in `.github/workflows/deploy-shoplens2026-dev.yml` and `docs/shoplens-2026-dev-resume.md`

---

## Option B — Convert the existing `shoplens2026ai-source` account into an org

Only possible if you (or someone on the team) controls the login credentials for `shoplens2026ai-source`.

1. Log in as `shoplens2026ai-source`
2. Settings → Organizations → **"Turn your account into an organization"**
3. GitHub migrates the account's repos (currently zero) into the new org and moves the personal identity to a newly created replacement account — whoever used that login for personal purposes needs a new username going forward
4. Once converted, `github.com/shoplens2026ai-source/shoplens2026` becomes a valid org-owned path; push/transfer the repo there
5. Same CI/CD update checklist as Option A applies (WIF condition, SA binding, secrets, doc references)

This path is lower-effort content-wise (zero repos to migrate) but requires account-owner access that the current session doesn't have.

---

## Cost

**$0/month** on GitHub's Free plan for either option:
- Unlimited private repositories, unlimited collaborators
- 2,000 GitHub Actions minutes/month on private repos (covers the deploy workflow)
- Basic teams and branch protection rules

Paid tiers only matter if you need more advanced controls later:
- **Team — $4/user/month**: required-reviewer counts >1, CODEOWNERS enforcement on private repos, deployment protection rules/environments, scheduled reminders
- **Enterprise — $21/user/month**: SSO/SAML, audit logs, advanced security scanning

---

## Recommendation

Go with **Option A** — it doesn't block on someone else's account credentials, takes about 10 minutes, and the CI/CD update work is identical either way. Pick an available org name, and this doc's checklist under "Update CI/CD" is the exact sequence to follow once the org and repo exist.
