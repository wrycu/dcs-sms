// identity.js — trust-on-first-use bookkeeping for submitter keys.
//
//   key:<fingerprint>   {"first_seen": iso, "submissions": n}   (KV)
//
// A key is registered by its first accepted submission. Author names are NOT
// claimed in KV: a name belongs to the key behind its earliest *merged*
// catalog entry, read from the base branch (handleOwner). Claiming on PR open
// would let junk PRs squat names like "Mav" and get the real person flagged.
// A submission using a name owned by a different key is NOT rejected — it is
// flagged for the reviewer, because self-declared names are only ever a hint
// (see the upload spec).

export function normalizeHandle(author) {
  return String(author || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

// Most sidecar reads one submission may spend on finding a name's owner
// (Workers cap subrequests per request).
export const MAX_SIDECAR_READS = 10;

const FINGERPRINT = /^sms:[0-9a-f]{16}$/;

// The sidecar next to a catalog prefab: prefabs/x.prefab -> prefabs/x.meta.json.
export function sidecarPath(prefabPath) {
  return String(prefabPath || '').replace(/\.(prefab|lua)$/, '') + '.meta.json';
}

// The key that owns `author` in the merged catalog, or null if no merged
// entry under that name carries a submitter key (unused names, and entries
// that predate keys). `index` is index.json's prefabs[]; `readSidecar(path)`
// resolves to the parsed sidecar on the base branch, or null. A key in the
// index entry itself is used without reading the sidecar. The earliest
// submitted_utc wins; entries without one sort last, in index order.
export async function handleOwner(index, author, readSidecar) {
  const h = normalizeHandle(author);
  if (!h) return null;
  let best = null;
  let reads = 0;
  for (const e of index) {
    if (normalizeHandle(e.author) !== h) continue;
    let key = e.submitter_key;
    let when = e.submitted_utc;
    if (!key && e.path && reads < MAX_SIDECAR_READS) {
      reads++;
      const side = await readSidecar(sidecarPath(e.path)).catch(() => null);
      if (side) { key = side.submitter_key; when = when || side.submitted_utc; }
    }
    if (typeof key !== 'string' || !FINGERPRINT.test(key)) continue;
    when = typeof when === 'string' ? when : '';
    if (!best || (when && (!best.when || when < best.when))) best = { key, when };
  }
  return best ? best.key : null;
}

// Read-only view used to build the PR before anything is written.
// Returns { priorSubmissions }.
export async function lookup(kv, fingerprint) {
  const rec = await kv.get(`key:${fingerprint}`);
  let prior = 0;
  if (rec) {
    try { prior = Number(JSON.parse(rec).submissions) || 0; } catch { prior = 0; }
  }
  return { priorSubmissions: prior };
}

// Record an accepted submission: bump the key's count, registering it on
// first sight.
export async function record(kv, fingerprint, nowIso) {
  const k = `key:${fingerprint}`;
  let rec = { first_seen: nowIso, submissions: 0 };
  const raw = await kv.get(k);
  if (raw) {
    try { rec = { ...rec, ...JSON.parse(raw) }; } catch { /* keep default */ }
  }
  rec.submissions = (Number(rec.submissions) || 0) + 1;
  await kv.put(k, JSON.stringify(rec));
}
