# dcs-sms ingest worker

Cloudflare Worker that turns an in-editor prefab submission into a pull request
on the community catalog (`wrycu/dcs-sms-prefabs`). Design:
[`docs/superpowers/specs/2026-09-19-community-prefab-upload.md`](../../docs/superpowers/specs/2026-09-19-community-prefab-upload.md).

Plain JavaScript, no dependencies, no build step.

## API

`POST /v1/submit` — `multipart/form-data`:

| Part | Content |
|---|---|
| `meta` | JSON: `name`, `author`, `description` (all required), `tags[]`, `client` |
| `prefab` | the `.prefab` file (≤ 2 MB, UTF-8) |
| `image` | 0–6 PNG/JPEG files (≤ 8 MB each; total body ≤ 24 MB) |

| Status | Body |
|---|---|
| `202` | `{submission_id, pr_url}` |
| `400` / `413` | `{error}` — bad or oversized submission |
| `409` | `{error, existing}` — identical prefab already in the catalog |
| `429` | `{error}` + `Retry-After` — per-IP hourly limit |
| `502` | `{error}` — GitHub call failed |

`GET /v1/health` → `{ok: true}`.

A submission becomes one commit on `submission/<slug>-<id>` adding
`prefabs/<slug>.prefab`, `prefabs/<slug>.meta.json` and
`images/<slug>/<n>.<ext>`, and a PR labelled `community-submission`. The
catalog's `validate.yml` runs on the PR; a human merge is the gate.

**No client authentication yet.** Protections are the size caps, the per-IP
limit, a global hourly breaker (past it, PRs open as drafts) and the manual
merge. Shared-key HMAC and Ed25519 identity from the spec are additive headers
on the same POST.

## First-time setup

End to end, from nothing to "Share in the Mission Editor opens a PR". Takes
about 15 minutes. You need a GitHub account that owns (or can write to) the
catalog repo.

### 1. Prerequisites

- **A Cloudflare account.** Free: <https://dash.cloudflare.com/sign-up>. No
  domain and no payment details are needed; the worker gets a `*.workers.dev`
  address.
- **Node.js 22 or newer.** Wrangler (Cloudflare's CLI, fetched on demand by
  `npx`) refuses older versions with *"Wrangler requires at least Node.js
  v22.0.0"*. Distro and toolbox images often ship 18. Without root, use nvm:
  ```sh
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  # open a new shell, then:
  nvm install 22
  node --version   # v22.x
  ```
- **The catalog repo** (`wrycu/dcs-sms-prefabs`, or your fork of it) with
  **GitHub Actions enabled**. Forks start with Actions off: open the repo's
  **Actions** tab and click *"I understand my workflows, go ahead and enable
  them"*. Without this, submitted PRs never get the `validate` check and merges
  never regenerate `index.json`.

All commands below run from this directory (`tools/ingest-worker/`).

### 2. Log Wrangler in to Cloudflare

```sh
npx wrangler login
```

Answer `y` when `npx` offers to install Wrangler. A browser tab opens; click
**Allow**.

### 3. Create the rate-limit store

```sh
npx wrangler kv namespace create RATE_KV
```

It prints an `id`. Put it in `wrangler.toml`:

```toml
[[kv_namespaces]]
binding = "RATE_KV"
id = "<the id it printed>"
```

The committed id belongs to the maintainer's Cloudflare account. If you deploy
under your own account, replace it with yours. The id is not a secret.

### 4. Point the worker at the catalog repo

In `wrangler.toml`, `[vars]`:

| Var | Default | Meaning |
|---|---|---|
| `GITHUB_REPO` | `wrycu/dcs-sms-prefabs` | `owner/name` of the catalog PRs open against |
| `BASE_BRANCH` | `main` | branch PRs target; also where `index.json` is read for dedup |
| `LIMIT_PER_IP_HOUR` | `10` | submissions per IP per hour before `429` |
| `LIMIT_GLOBAL_HOUR` | `60` | submissions per hour (all IPs) before PRs open as drafts |

### 5. Create the GitHub token

The worker opens PRs with a fine-grained personal access token. PRs appear as
opened by the token's owner.

1. GitHub → **Settings → Developer settings → Personal access tokens →
   Fine-grained tokens → Generate new token**.
2. **Repository access:** *Only select repositories* → the catalog repo only.
3. **Permissions → Repository permissions:**
   - **Contents: Read and write** (branch + commit)
   - **Pull requests: Read and write** (open the PR)

   Metadata: Read-only is added automatically. Nothing else is needed.
4. Pick an expiry, generate, and copy the token. It is shown once.

### 6. Store the token in the worker

```sh
npx wrangler secret put GITHUB_TOKEN
```

Paste the token at the prompt. It is stored encrypted in Cloudflare and never
touches the repo. If Wrangler says the worker doesn't exist yet and offers to
create it, say yes.

### 7. Deploy

```sh
npx wrangler deploy
```

On an account's first Worker, Wrangler asks you to register a `workers.dev`
subdomain. It then prints the URL, e.g.
`https://dcs-sms-ingest.<subdomain>.workers.dev`.

### 8. Verify

Health:

```sh
curl https://dcs-sms-ingest.<subdomain>.workers.dev/v1/health
# {"ok":true}
```

A real submission. **This opens a real PR** — close it without merging
afterwards:

```sh
printf 'return {\n  meta = { name = "Ingest Test" },\n  groups = {},\n}\n' > /tmp/test.prefab
curl -X POST https://dcs-sms-ingest.<subdomain>.workers.dev/v1/submit \
  -F 'meta={"name":"Ingest Test (delete me)","author":"you","description":"Setup check. Close without merging.","tags":["test"],"client":"curl"};type=application/json' \
  -F 'prefab=@/tmp/test.prefab'
# {"submission_id":"…","pr_url":"https://github.com/<owner>/<repo>/pull/N"}
```

Open the PR and check: it adds `prefabs/<slug>.prefab` and
`prefabs/<slug>.meta.json` (plus `images/<slug>/<n>.<ext>` when images are
attached), is labelled `community-submission`, and its `validate` check passes.
Then close it without merging and delete its branch.

### 9. Connect the mod

Set the submit URL in
[`tools/me-mod/lua/dcs_sms_me/community_config.lua`](../me-mod/lua/dcs_sms_me/community_config.lua):

```lua
M.SUBMIT_URL = 'https://dcs-sms-ingest.<subdomain>.workers.dev/v1/submit'
```

Reinstall the mod (`dcs-sms install-me-mod`, or copy the **whole**
`tools/me-mod/lua/dcs_sms_me/` folder over
`<DCS install>/MissionEditor/modules/dcs_sms_me/` — copying single files onto an
older install mixes versions) and restart DCS. In the Prefab Manager,
right-click one of your prefabs → **Share to community...**. The full checklist
is under "Share to community" in
[`docs/release-gate/me-mod-smoke.md`](../../docs/release-gate/me-mod-smoke.md).

The mod also needs the LuaSec payload in `Saved Games\DCS\dcs-sms\lib\`
(installed by `install-me-mod`). If the Community tab can sync, it's there.

## Operating it

- **Redeploy after code changes:** `npx wrangler deploy`.
- **Live logs:** `npx wrangler tail` streams every request, including the
  GitHub error behind a `502`.
- **Rotate the token** (or when it expires): create a new one (step 5), run
  `npx wrangler secret put GITHUB_TOKEN` again. Takes effect immediately, no
  redeploy.
- **Change limits:** edit `[vars]` in `wrangler.toml`, then redeploy.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Wrangler requires at least Node.js v22.0.0` | Old Node — see Prerequisites (nvm). |
| `502 {"error":"submission could not be forwarded…"}` | A GitHub call failed. `npx wrangler tail` shows which. Usually: token missing (`secret put` not run), expired, lacking Contents/Pull requests write, or scoped to a different repo; or `GITHUB_REPO` is wrong. |
| `429` during testing | The per-IP limit (10/hour). Wait for the hour to roll over, or raise `LIMIT_PER_IP_HOUR`. |
| `409 already in the catalog` | That exact prefab (byte-identical) is in `index.json`. Change it, or it's genuinely a duplicate. |
| PR has no `validate` check | Actions is disabled on the catalog repo (common on forks) — see Prerequisites. |
| Large submissions fail with Cloudflare error 1102 | The free plan's 10 ms CPU limit; base64-encoding big images for the GitHub API is the expensive part. Move to Workers Paid, or lower the image caps (worker `CAPS` and `share_submit.lua` `M.CAPS` together). |
| Mod says "Community uploads are not configured in this build." | `SUBMIT_URL` is empty in the installed `community_config.lua` (step 9). |
| Mod stuck on "Uploading…" or Submit does nothing | Look for `sms.me.share` / `GUI Error` lines in `Saved Games\DCS\Logs\dcs.log`. A "loop or previous error loading module" error means a mixed-version install — copy the whole folder and restart DCS. |

## Test

```sh
npm test      # node --test; no install needed
```
