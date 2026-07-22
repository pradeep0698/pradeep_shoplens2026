# Recreating the Ephemeral-Token Setup on `cookshop-dev` (Rajan Prod)

Plan for bringing `cookshop-dev`'s `voice-assistant` Cloud Run service to parity with
`shoplens2026-dev` for the ephemeral-token / trusted-server mechanism described in
`docs/ephemeral_token.md`, **without changing any user-visible behavior** on Rajan's
stable platform.

---

## 0. What "the setup we have today" actually is

Per `docs/ephemeral_token.md`, today's `shoplens2026-dev` setup is:

- Backend code for `mint_ephemeral_token` / `POST /voice/session/token` exists, is
  unit-tested, and is deployed — but sits **behind `VOICE_DIRECT_CONNECT_ENABLED=false`**.
- The mobile app **never calls** the mint-token endpoint regardless of that flag — it
  authenticates direct-connect sessions with a static, baked-in `AI_STUDIO_API_KEY`
  instead (§3c/§6 of that doc).
- So "the setup" is: the trusted-server mechanism exists and is reachable/testable on
  the backend, real traffic doesn't use it, and nothing about the mobile client's
  behavior changes because of it.

**This plan recreates exactly that on cookshop-dev — backend parity, flag off, zero
client-side change.** It does not wire the mobile app to actually use ephemeral
tokens; that's still unbuilt everywhere (tracked as an open item in the source doc,
not something to bundle into a "just match prod" task).

---

## 1. Why this is mostly already true

`scripts/deploy-cookshop-dev.sh` and `scripts/deploy-shoplens2026-dev.sh` both deploy
the **same source directory**, `services/voice-assistant`, via `gcloud run deploy
--source`. There's one codebase, not a fork per environment. That means:

- `mint_ephemeral_token`, `_get_dev_api_client`, `POST /voice/session/token`, and the
  `VOICE_DIRECT_CONNECT_ENABLED` kill-switch check are **already in whatever image is
  currently running on cookshop-dev's `voice-assistant` service** (assuming it's been
  redeployed any time after that code merged to `main`).
- The only thing that can differ between the two environments is **environment
  variables** — specifically the three new ones in `services/voice-assistant/.env.example`:

  ```
  AI_STUDIO_API_KEY=<key>
  VOICE_MODEL_DEV_API=models/gemini-2.5-flash-native-audio-latest
  VOICE_DIRECT_CONNECT_ENABLED=false
  ```

So this is a **config-parity task, not a code-deploy task** — which is exactly what
makes "no impact on current build" achievable.

---

## 2. Verify current state first (don't assume)

Both vault files (`services/voice-assistant/.env.shoplens2026-dev` and
`.env.cookshop-dev`) are gitignored and not present in this checkout, and neither is
`.cookshop-dev-last-deploy` — so the current live values can't be confirmed from this
repo. Before touching anything, whoever has `gcloud` access should run, for **both**
projects:

```bash
# shoplens2026-dev (reference — what we're matching)
gcloud run services describe voice-assistant \
  --project project-b1a5dd5a-69e6-4db3-9d7 --region us-central1 \
  --format="value(spec.template.spec.containers[0].env)"

# cookshop-dev (target — what we're changing)
gcloud run services describe voice-assistant \
  --project cookshop-dev-prj --region us-central1 \
  --format="value(spec.template.spec.containers[0].env)"
```

Check specifically for `AI_STUDIO_API_KEY`, `VOICE_MODEL_DEV_API`, and
`VOICE_DIRECT_CONNECT_ENABLED` on each. Three possible starting states on cookshop-dev:

| State found | Action needed |
|---|---|
| All three vars already present, flag `false` | Nothing to do — already at parity. Document it and stop. |
| Vars missing entirely | Proceed with §3 below. |
| `VOICE_DIRECT_CONNECT_ENABLED=true` already set | **Stop and flag to the user** — this would mean cookshop-dev already diverges from the "off by default" posture; don't silently change it either way without a decision. |

---

## 3. The risk this plan is specifically designed to avoid

`scripts/deploy-cookshop-dev.sh` (and the manual steps in `docs/sunday-prod-install.md`)
both deploy via:

```bash
gcloud run deploy voice-assistant --source services/voice-assistant --set-env-vars "$VARS" --quiet
```

Two things make this the **wrong** tool for a config-only change here:

1. **`--source` rebuilds and redeploys from whatever is on `main` right now.** If any
   other `services/voice-assistant` changes have landed on `main` since cookshop-dev's
   last weekly release, this would ship them early — exactly the "impacting their
   current build" outcome to avoid. (The repo has no local record of the last deployed
   SHA to diff against in this checkout — `git log --oneline <last-prod-sha>..main --
   services/voice-assistant` needs to be run by whoever holds that reference point.)
2. **`--set-env-vars` (not `--update-env-vars`) replaces the entire env-var set** from
   the file. If those three new keys aren't added to the actual
   `services/voice-assistant/.env.cookshop-dev` vault file too, the *next* routine
   `deploy-cookshop-dev.sh` run silently drops them again.

**Mitigation: patch env vars on the live service directly, without rebuilding source,**
then separately update the vault file so future routine deploys don't regress it.

---

## 4. Step-by-step

### Step 1 — Get/confirm a cookshop-dev-specific AI Studio key

Don't reuse shoplens2026-dev's `AI_STUDIO_API_KEY`. Per `docs/ephemeral_token.md` §7,
this key is a bare, unscoped credential tied to one AI Studio project's quota/billing —
sharing it across environments mixes cookshop-dev's usage into shoplens2026-dev's
billing/quota (or vice versa) and makes the "which environment burned this key" question
unanswerable later. Mint or locate a key scoped to the `cookshop-dev-prj` /
`cookshop-dev-prj-bd7e2` Google Cloud/AI Studio project instead.

### Step 2 — Patch the live Cloud Run service (no source rebuild)

```bash
gcloud run services update voice-assistant \
  --project cookshop-dev-prj \
  --region us-central1 \
  --update-env-vars AI_STUDIO_API_KEY=<cookshop-dev-scoped-key>,VOICE_MODEL_DEV_API=models/gemini-2.5-flash-native-audio-latest,VOICE_DIRECT_CONNECT_ENABLED=false
```

`--update-env-vars` merges into the existing env-var set rather than replacing it, and
`gcloud run services update` doesn't touch the container image — the currently-running
revision's code is untouched. `VOICE_DIRECT_CONNECT_ENABLED=false` is set explicitly
(not left to the code default) so the intent is visible in `gcloud describe` output
later, not just implicit.

This alone makes `mint_ephemeral_token`/`POST /voice/session/token` functional on
cookshop-dev. Nothing about `/voice/session/start`'s response changes — it still
returns `direct_connect_allowed: false` (`main.py:317`), so the mobile transport
selector's two-gate check (`voice_transport_selector_native.dart:6-19`) still always
picks the proxy transport, same as before this change, on every existing cookshop-dev
build.

### Step 3 — Update the vault file (prevents regression on the next routine deploy)

Add the same three lines to `services/voice-assistant/.env.cookshop-dev` in whoever's
local vault holds it:

```
AI_STUDIO_API_KEY=<cookshop-dev-scoped-key>
VOICE_MODEL_DEV_API=models/gemini-2.5-flash-native-audio-latest
VOICE_DIRECT_CONNECT_ENABLED=false
```

This is the file `deploy-cookshop-dev.sh`/`sunday-prod-install.md` read on every future
weekly release — without this edit, the very next routine `voice-assistant` deploy
would run `--set-env-vars` from the file and wipe out Step 2's patch.

### Step 4 — Verify without touching real traffic

```bash
curl https://voice-assistant-82592393149.us-central1.run.app/health
```

Then, with a valid Firebase ID token for a cookshop-dev test account:

```bash
# 1. Start a session — confirm direct_connect_allowed is still false
curl -X POST https://voice-assistant-82592393149.us-central1.run.app/voice/session/start \
  -H "Authorization: Bearer <firebase-id-token>"

# 2. Mint a token against the session_id from step 1 — confirm it succeeds
curl -X POST https://voice-assistant-82592393149.us-central1.run.app/voice/session/token \
  -H "Authorization: Bearer <firebase-id-token>" \
  -H "Content-Type: application/json" \
  -d '{"session_id": "<session_id-from-above>"}'
```

Expect: step 1 returns `direct_connect_allowed: false` (proves no client-visible
change); step 2 returns a token successfully (proves `AI_STUDIO_API_KEY` +
`VOICE_MODEL_DEV_API` are valid and `mint_ephemeral_token` works end-to-end on this
project). Step 2 succeeding or failing has no effect on any real user — nothing calls
this endpoint today (§6 of the source doc).

### Step 5 — Explicitly not part of this change

- **Mobile app / Codemagic / `.dart_define/cookshop-dev.json`**: untouched. The
  client-side flag and static-key path are exactly as they are today. This is what
  keeps the change fully server-side and risk-free to the current build.
- **Flipping `VOICE_DIRECT_CONNECT_ENABLED` to `true`**: not part of "recreate the
  current setup" — shoplens2026-dev's own default is `false` too (per `.env.example`
  and the "not verifiable but code default is false" note in the source doc). Flipping
  it anywhere is a separate decision with real security implications (§7 of
  `docs/ephemeral_token.md`) and needs its own sign-off, not a silent side effect here.

---

## 5. Rollback

Since Step 2 only patched env vars on the existing revision (no new image), rollback is
immediate and doesn't cause a redeploy/downtime:

```bash
gcloud run services update voice-assistant \
  --project cookshop-dev-prj --region us-central1 \
  --remove-env-vars AI_STUDIO_API_KEY,VOICE_MODEL_DEV_API
```

(`VOICE_DIRECT_CONNECT_ENABLED` can be left at `false` — removing it just falls back to
the same default.)

---

## 6. Summary checklist

- [ ] Confirm current env vars on both `voice-assistant` Cloud Run services (§2)
- [ ] Obtain a cookshop-dev-scoped `AI_STUDIO_API_KEY` (don't reuse shoplens2026-dev's)
- [ ] `gcloud run services update` with `--update-env-vars` on cookshop-dev (§4 Step 2)
- [ ] Add the same 3 vars to `services/voice-assistant/.env.cookshop-dev` vault file (§4 Step 3)
- [ ] Verify `/voice/session/start` still returns `direct_connect_allowed: false`
- [ ] Verify `/voice/session/token` mints successfully
- [ ] No changes to mobile build, Codemagic, or the server-side flag value
