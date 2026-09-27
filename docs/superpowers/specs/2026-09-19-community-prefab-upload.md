# In-Editor Community Prefab Upload — Design Spec

**Date:** 2026-09-19
**Status:** Draft (for review)
**Area:** `tools/me-mod`, new ingest service, `dcs-sms-prefabs` CI
**Related:** [`2026-09-20-prefab-3d-render-automation.md`](2026-09-20-prefab-3d-render-automation.md)
— optional image upgrade, explicitly *not* a dependency of this spec.

## Goal

Let a user share a prefab to the community catalog **from inside the Mission
Editor**, without visiting Discord, without a GitHub account, and without
creating an account of any kind. Submission opens a PR against
`dcs-sms-prefabs`; the existing manual merge stays the gate.

## User value

Today sharing means: leave DCS, open Discord, find the channel, locate the
`.prefab` on disk, drag it in, type a description, attach screenshots, wait for
the bot. That friction is why the catalog has 20 entries. After this, sharing is
a button in the Prefab Manager.

## The three planes

1. **ME-mod share UI** (`tools/me-mod`) — collects metadata + images, validates
   locally, reports progress and the result.
2. **ME-mod submitter** (`tools/me-mod`) — holds the embedded credential, signs
   the envelope, and drives the multipart POST over the existing LuaSec
   transport on the UpdateManager tick.
3. **Ingest service + catalog CI** (new worker; `dcs-sms-prefabs`) — verifies,
   rate-limits, opens the PR. CI renders derived images and regenerates
   `index.json` exactly as it does today.

## Architecture

Everything runs **inside the ME-mod**. `dcs-sms.exe` is an install-time tool,
not a runtime dependency (see Constraints) — no submission path may require it.

```
Mission Editor (LuaJIT, single-threaded)
└─ dcs_sms_me
   ├─ share_dialog.lua        new: form, image picker, progress, result
   ├─ share_submit.lua        new: build multipart body, drive the transport
   ├─ share_auth.lua          new: shared key + keyid; envelope HMAC
   ├─ share_identity.lua      new: Ed25519 keypair gen/load/export, TOFU identity
   ├─ ed25519.lua             new: vendored pure-Lua Ed25519 (RFC 8032 vectors)
   ├─ sha256.lua              new: pure-Lua SHA-256 (LuaJIT `bit`); envelope only
   ├─ community_transport.lua extended: POST + request body, chunked sends
   ├─ prefab_safe_load.lua    reused: local pure-data pre-check
   ├─ base64.lua              reused
   └─ (tick pump)             reused: UpdateManager, same as community_fetch
        │
        │  multipart POST over the LuaSec stack that install-me-mod
        │  already deployed to dcs-sms\lib\ + DCS bin\ (persistent)
        ▼
   ingest worker
     ├─ verify sig / keyid / skew / nonce
     ├─ rate limit (install uuid, IP, global breaker)
     ├─ dedup + re-upload flag
     └─ open PR on dcs-sms-prefabs
            │
            ▼
     CI on the PR
     ├─ validate.yml   (pure-data gate, exists)
     ├─ image validate (decode, caps, EXIF strip)
     └─ render schematic PNG + optimize images
            │
       human merge → build-index.yml → index.json
```

## Auth model

Two orthogonal layers. Neither is an account, and there is no login step.

| Layer | Mechanism | Answers |
|---|---|---|
| Client attestation | shared key embedded in the mod, HMAC-SHA256 | "is the caller running our mod?" |
| Submitter identity | per-install Ed25519 keypair, TOFU | "is this the same person as last time?" |

### Layer 1 — client attestation (shared embedded key)

Filters endpoint scanners and drive-by abuse. **It is a spam filter, not a
gate**, and every server-side decision assumes the key is already public. It
raises the bar from "anyone with curl and the URL" to "anyone willing to grep an
installed Lua file". It stops nothing else.

Two consequences carry the weight:

- **`keyid` is mandatory from day one.** When the key leaks, rotation is a
  release: bump the keyid, serve a grace window, then demote old-keyid
  submissions to auto-quarantine. Without it there is no rotation that doesn't
  break every install at once.
- **The human merge remains the real gate.** `validate.yml` already proves every
  payload is inert data. A leaked key floods a PR queue; it cannot ship code.

### Layer 2 — submitter identity (per-install keypair)

On first run the mod generates an **Ed25519 keypair** and stores it at
`<writedir>/dcs-sms/identity.json`. Under `lfs.writedir()`, not the module dir,
so it survives reinstalls — the same reasoning that puts the LuaSec payload in
`dcs-sms\lib\`.

The public key is sent with every submission; the private key never leaves the
machine. First accepted submission from an unseen pubkey registers it (trust on
first use). No pre-registration, no handshake.

**What it proves:** the holder of key K submitted this, and also submitted those
earlier entries. Proof of possession, not a bearer claim — a captured submission
cannot be replayed into a new one.

**What it does not prove:** anything about who K is. The first submission is
anonymous and sybil cost is zero — anyone can generate unlimited keypairs. This
asserts *same as before*, never *this is Shuffle*. Do not describe it in the UI
as verification.

Two capabilities follow, and they are the point of the layer:

- **Entry ownership.** The merged entry records the submitter's fingerprint.
  Only that keyholder can publish an update to it — cryptographically, with no
  moderation judgment. This is what gives the catalog a notion of "v2" at all.
- **Handle binding, first-come.** The first submission claiming
  `author: "Shuffle"` binds that handle to that pubkey. A later submission
  claiming it from a different key is flagged `needs-review: handle-conflict`.
  Self-declared author becomes unverified exactly once, then enforced — which
  covers the impersonation case without an IdP.

Banning a pubkey therefore has teeth: regenerating is free, but the holder
forfeits their history and their claimed handle.

**Identity portability.** A machine move or OS reinstall loses the identity
unless the key is kept. The share dialog offers **Export identity** / **Import
identity** (the `identity.json` file), and says plainly that losing it means
losing the ability to update your own entries.

### Signature

```
X-SMS-KeyId:      4                         (shared-key generation)
X-SMS-PubKey:     <base64 Ed25519 public key>
X-SMS-Timestamp:  <unix seconds>
X-SMS-Nonce:      <16 random hex>
X-SMS-Client:     hex(HMAC-SHA256(shared_key,
                      keyid \n pubkey \n timestamp \n nonce))
X-SMS-Signature:  base64(Ed25519(privkey,
                      keyid \n pubkey \n timestamp \n nonce \n sha256(meta_json)))
```

The pubkey fingerprint replaces the install UUID entirely — a better identity
for the same slot, not an extra one.

**The signature covers the envelope plus a hash of the `meta` part only, never
the full body.** `meta_json` is a few hundred bytes (name, author, tags, target
entry), so hashing is free, and the signature binds exactly the fields that
ownership and handle-binding depend on. Hashing a 24 MB multipart body in pure
Lua would stall the editor for seconds and buy nothing: TLS covers body
integrity in transit, and the server computes its own content hashes for dedup.
This is what makes in-Lua signing viable — do not extend it to payload bytes.

### Where the shared key lives — and where it must not

In the **Lua**, in `share_auth.lua`, as a placeholder substituted at
release-build time. Never committed: `tools/` is GPL v3 with public source, so a
committed key is a published key.

```yaml
# .github/workflows/release-me-mod.yml
# MUST run BEFORE the "Cross-compile dcs-sms.exe" step at line 55 —
# tools/me-mod/lua/ is go:embed'ed into the binary (tools/me-mod/lua/embed.go:11),
# so the substitution has to happen before the Go build reads the tree.
- name: Inject submission key
  run: |
    sed -i "s|@@SMS_SUBMIT_KEY@@|${{ secrets.SMS_SUBMIT_KEY }}|; \
            s|@@SMS_SUBMIT_KEYID@@|${{ vars.SMS_SUBMIT_KEYID }}|" \
        tools/me-mod/lua/dcs_sms_me/share_auth.lua
```

One substitution serves **both** distribution paths: the copy embedded into
`dcs-sms.exe` and the OVGME zip staged from the same tree at line 57. A source
build gets the literal placeholder, which `share_auth.lua` detects and reports
as "submission unavailable in this build" (see Open questions).

The shared key is plaintext in an installed `.lua` file and a `grep` will find
it. That is accepted. Obfuscating the constant is theatre and must not be
implemented or described as security. The per-user private key is a different
matter and is never transmitted.

## Wire format

`POST https://<ingest>/v1/submit`, `multipart/form-data`:

| Part | Content |
|---|---|
| `meta` | JSON: `name`, `description`, `tags[]`, `author` (self-declared), `client` version string |
| `prefab` | raw `.prefab` bytes |
| `image` (repeatable) | raw image bytes, original filename preserved |

Caps, enforced client-side and server-side: prefab ≤ 2 MB, each image ≤ 8 MB,
≤ 6 images, total body ≤ 24 MB.

Responses: `202` + `{submission_id, pr_url}` · `409` + existing entry name on
sha256 dedup · `413` over caps · `429` rate-limited with `Retry-After` · `401`
bad signature/keyid.

## Server behaviour

1. **Verify** — keyid known and not revoked; `|now - timestamp| ≤ 300s`; nonce
   unseen (KV, 600s TTL); signature matches; caps respected.
1b. **Identity** — register an unseen pubkey on first accepted submission
   (TOFU). Bind the claimed `author` handle to it if unclaimed; flag
   `needs-review: handle-conflict` if the handle belongs to another key. Reject
   outright if the pubkey is on the ban list.
2. **Rate limit** — per pubkey (5/hour, 20/day), per IP (10/hour), and a
   **global circuit breaker**: above N submissions/hour, new PRs open as drafts
   and an alert fires. The breaker is the actual protection against a leaked key.
3. **Dedup** — prefab sha256 already in `index.json` → `409`.
4. **Re-upload flag** — if the incoming prefab already carries
   `meta.community.author` and it differs from the submitted author, label the
   PR `needs-review: reupload`. This catches the likeliest abuse (submitting
   someone else's catalogued prefab) better than any identity check would.
5. **Slug** — `slugify(name)`, collision suffix `-2`. If the name matches an
   existing entry **and** the signing pubkey matches that entry's recorded
   owner, this is an **update**: reuse the slug and open the PR as a revision
   rather than a new entry.
6. **Commit + PR** — `prefabs/<slug>.prefab`, `prefabs/<slug>.meta.json`,
   `images/<slug>/<n>.<ext>`; label `community-submission`; body carries author,
   description, keyid, pubkey fingerprint, prior-submission count for that key,
   and any flags.

The service does **no** image processing and **no** prefab validation beyond
size. Both are CI's job, which keeps the worker stateless and keeps the trust
boundary where it already is.

## Sidecar produced

```json
{
  "author": "Shuffle",
  "description": "...",
  "tags": ["fob", "props"],
  "images": ["<slug>/1.jpg", "<slug>/schematic.png"],
  "submitted_utc": "2026-09-19T14:02:11Z",
  "submitter_key": "SHA256:9f2a…",
  "source": "https://github.com/nielsvaes/dcs-sms-prefabs/pull/123"
}
```

`submitter_key` is the owner fingerprint — publishing it means anyone can
verify authorship from the repo alone, without trusting the ingest worker.
`gen_index.py` ignores unknown sidecar keys, so it needs no change; surfacing
the field in `index.json` is a later, optional step.

**No schema change is needed.** `gen_index.py` requires only a non-empty
`author` and `description`; `thread_id` is optional and simply absent.
`community_config.image_url(rel)` resolves `<slug>/1.jpg` to
`images/<slug>/1.jpg` with no client change, so submissions render correctly on
**existing installs** that never update the mod.

## Catalog CI additions (`dcs-sms-prefabs`)

- `tools/render_schematic.py` — top-down layout diagram from the prefab alone.
  Entity coordinates are prefab-relative (`x=0.506, y=10.508`), so no geographic
  projection is required; `meta.world_anchor` and theatre are carried separately.
  Draws unit icons by category, zone circles, drawing polylines, scale bar, north
  arrow. **Emits PNG, not SVG** — the client renders images through
  `SkinUtils.setStaticPicture`, a DCS skin texture path, which will not load SVG.
  A flat-colour 1200×900 PNG is ~30–80 KB against the current 300 KB–1.3 MB JPEGs.
- `tools/optimize_images.py` — downscale >1600px, recompress, **strip EXIF**
  (submitted screenshots can carry a Windows username or GPS).
- `validate.yml` — extend with image checks: extension allowlist, real decode
  (not a renamed executable), dimension caps.
- `build-index.yml` — run both renderers, append the schematic to the sidecar's
  `images[]`, commit alongside `index.json`.

Derived images follow the precedent `build-index.yml` already sets for
`index.json`: a build artifact, not contributed content. Backfilling gives all
20 existing entries a schematic with no mod update and no author involvement.

## ME-mod UI

**Share** button on a selected prefab in the My Prefabs grid → modal:

- **Name** (prefilled from `meta.name`), **Author** (free text, remembered
  across sessions), **Description** (multiline), **Tags** (comma-separated,
  lowercased on submit).
- **Images** — a thumbnail strip with checkboxes, populated from the most recent
  ~12 files in `lfs.writedir() .. 'Screenshots\\'`. This is where DCS already
  writes screenshots, and it is how the current catalog's 2560×1440 beauty shots
  were made, so the common path needs no file dialog at all. Plus **Browse…**
  (opens a staging folder via `explorer`, mirroring `context_menu.lua:327`) and
  **Capture now**, shown only when `dcs-sms.exe` happens to be locatable —
  a bonus on the .exe path, never a requirement. The recent-screenshots picker
  needs nothing but `lfs`.
- **Pre-flight** — run `prefab_safe_load` locally and block submission with a
  clear message if it fails, so a bad file is caught before the round trip.
- **Submit** — builds the multipart body, signs the envelope, and drives the
  POST from a coroutine pumped on the UpdateManager tick, exactly as
  `community_fetch` does for downloads. Progress bar off the bytes-sent
  counter; the editor never blocks. Cancel abandons the coroutine and closes
  the socket.
- **Result** — PR URL with an "open in browser" button, or a readable error.

## Scope

**In:** share dialog + recent-screenshot picker; `sha256.lua`, `ed25519.lua`,
`share_identity.lua` (keygen/export/import) and `share_auth.lua`; entry
ownership + handle binding server-side; POST support in `community_transport.lua`; `share_submit.lua`
multipart builder; build-time key injection in the release workflow; the ingest
worker; schematic renderer, image optimizer, and CI wiring; docs/CHANGELOG/AGENTS
updates; a manual-smoke entry in `docs/release-gate/me-mod-smoke.md`.

**Known inherited limitation:** the OVGME zip ships no LuaSec payload (only the
exe embeds it — `tools/me-mod/luasec/embed.go`), so an OVGME-only install
already cannot refresh the Community tab and will not be able to upload either.
This feature inherits that gap rather than creating it; those users get an
"export submission bundle to a folder" fallback and manual instructions. Closing
it properly means shipping LuaSec in the OVGME zip, which is its own decision.

**Out:** OAuth or any verified identity (additive later — it is a header on the
same POST, not a rewrite); automated 3D renders (separate spec, gated on a
`LoSetCameraPosition` spike); a likes mechanism to replace Discord ♥; editing or
withdrawing a submission after the PR opens; moving `images/` off git.

## Constraints

- LuaJIT 5.1, single-threaded. No blocking calls on the ME thread; everything
  async runs on the UpdateManager tick.
- Never throw out of ME-mod code — `pcall`-guard every step, degrade to a logged
  failure and a safe UI state.
- `tools/` is GPL v3 and public; no secret may be committed.
- **`dcs-sms.exe` is not guaranteed to exist at runtime and must not be
  required.** Two install paths ship: the .exe, which users are told to save
  "anywhere convenient" and which writes nothing to its own folder (so it is
  routinely discarded after install), and the OVGME zip staged at
  `release-me-mod.yml:57`, which contains only the Lua tree. Any design that
  shells out to the CLI per submission excludes the entire OVGME population and
  breaks for anyone who deleted the binary.
- HTTPS from the mod is available because `install-me-mod` deploys the LuaSec
  payload **persistently** to `dcs-sms\lib\` and the DCS `bin` folders. It
  survives without the exe; this is the same stack the Community tab refreshes
  over today.
- Pure-Lua SHA-256 on LuaJIT is fast enough for a short envelope and nothing
  larger. Do not extend it to hash payload bytes.
- Vendored Ed25519 must be tested against the **RFC 8032 test vectors** in the
  existing standalone-Lua harness before it is trusted. Signing runs ~100 ms on
  LuaJIT — acceptable once per submission, but keygen and signing both belong
  off the first paint of the dialog.
- Side-channel resistance is out of scope: the only party positioned to attack
  the private key is the machine's own user, who already holds it.

## Decisions

- **Signing key in the Lua, signed in the Lua, uploaded from the Lua.** The exe
  is an install-time tool; making it a runtime dependency would exclude OVGME
  installs entirely. An earlier draft put signing in the binary to avoid
  vendoring SHA-256 — that reasoning collapsed once the signature stopped
  covering the body, which reduced the hashing to ~100 bytes.
- **Envelope + meta-hash signature.** See Auth model. This is the decision that
  makes in-Lua signing fit at all.
- **Ed25519 over a server-registered HMAC secret**, though both give identical
  continuity. Asymmetric wins on two properties worth the vendored code: the
  fingerprint can be published in the sidecar so authorship is verifiable from
  the repo without trusting the worker, and a server breach leaks nothing that
  can impersonate a contributor. RFC 8032 vectors bound the correctness risk.
- **TOFU, not verification.** The keypair proves continuity, never who someone
  is. The UI must not call it verified.
- **Multipart in one POST** over a two-step upload URL handshake. One round
  trip, standard, ~30 lines with Go's `mime/multipart`. Revisit if image counts
  grow.
- **Worker does no validation beyond size.** CI is already the trust boundary;
  duplicating the validator in a second language would mean two grammars to keep
  in sync.
- **Self-declared author is accepted.** With a manual merge and re-upload
  flagging, a verified identity would add friction disproportionate to what it
  prevents.

## Key rotation runbook

1. Generate a new key; set `SMS_SUBMIT_KEY` and bump `SMS_SUBMIT_KEYID`.
2. Add the new keyid to the worker's accepted set; keep the old one accepted.
3. Ship a release.
4. After the grace window (suggest 60 days), demote the old keyid to
   auto-quarantine (PRs open as drafts), then drop it.

## Open questions

1. **Source builds get no key** (the placeholder survives the build). Disable
   the Share button with an explanatory tooltip, or accept them into a
   quarantine queue? Disabling is simpler and honest.
2. **Rate-limit numbers** — the figures above are placeholders; pick real ones
   from expected volume.
3. **Where does the worker run**, and who holds the GitHub bot token that opens
   PRs?
4. **Schematic icon set** — reuse the ME's own map icons (licensing?) or draw a
   neutral NATO-ish set.
5. **Withdrawal** — a submitter has no way to cancel a PR they regret. Out of
   scope for v1; worth a note in the share dialog.
6. **Lost keys.** Someone reinstalls Windows without exporting `identity.json`
   and can no longer update their own entries. Manual re-binding on request
   (you edit the recorded fingerprint) is the only recovery, and it is a social
   check, not a cryptographic one. Acceptable at this scale; document it.
7. **Pre-keypair entries.** The 20 existing catalog entries have no owner
   fingerprint. Leave them unowned (updates go through review), or bind them by
   hand as their authors resurface?

## Phasing

| Phase | Deliverable | Depends on |
|---|---|---|
| 1 | Schematic renderer + image optimizer + CI wiring; backfill all 20 | nothing |
| 2 | `sha256.lua`, `ed25519.lua` (+ RFC 8032 vectors), `share_identity.lua`, `share_auth.lua`; POST support in `community_transport` | key provisioned |
| 3 | Ingest worker + PR creation | phase 2 |
| 4 | Share dialog + screenshot picker + `share_submit.lua` | phases 2–3 |

Phase 1 is independently valuable, carries no risk, and needs no key, no worker
and no mod update. By the time uploads open, every entry already has an image.

## Implementation status (2026-09-26)

A working end-to-end slice with **Layer 2 (Ed25519 identity) but not Layer 1
(shared-key HMAC)**:

- **Worker** — `tools/ingest-worker/` (Cloudflare, plain JS). Wire format,
  caps, sha256 dedup against `index.json` and open submission PRs (matched on
  the hash line in the PR body), slug + `-N` suffix, one-commit PR via the Git
  Data API, per-IP / per-key hourly + per-key daily limits, global draft
  breaker, `BANNED_KEYS` → 403. Signature verification with native WebCrypto
  Ed25519, ±300 s timestamp window, single-use nonces (KV, 600 s). TOFU key
  registry and first-come handle binding in KV; a conflicting handle is
  labelled `needs-review: handle-conflict`, not refused. Sidecar carries
  `submitter_key`.
- **ME-mod** — `sha512.lua` + `ed25519.lua` (pure arithmetic: the ME is **PUC
  Lua 5.1 with no bit library**, not LuaJIT as written above; RFC 8032 vectors
  + cross-checked against OpenSSL; ~0.1 s keygen+sign), `share_identity.lua`,
  signing phase in `share_submit.lua`, fingerprint + "Show key file" in
  `share_dialog.lua`.
- **Deviations from the design above:**
  - The signature covers the `meta` bytes directly, with no keyid and no
    sha256(meta). Ed25519 already hashes its message with SHA-512, so the
    Lua side needs no SHA-256.
  - The fingerprint is `sms:` + 16 hex of SHA-512(pubkey), not
    `SHA256:<b64>`.
  - There is no CSPRNG in DCS Lua. The seed is SHA-512 over pooled
    timers, jitter and addresses (documented in `share_identity.lua`). A native
    RNG via the bundled OpenSSL is a possible later hardening step.
- **Not yet:** entry ownership / updates-as-revisions, the re-upload flag,
  identity export/import UI (the file can be copied by hand), Layer 1, Phase 1
  (schematics, image optimiser, `validate.yml` image checks).
