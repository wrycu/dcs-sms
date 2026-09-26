// identity.js — trust-on-first-use bookkeeping for submitter keys, in KV.
//
//   key:<fingerprint>   {"first_seen": iso, "submissions": n}
//   handle:<author>     <fingerprint>   (author lowercased, whitespace-collapsed)
//
// A key is registered by its first accepted submission. The first key to
// submit under an author name claims that name; a later submission claiming
// it from a different key is NOT rejected — it is flagged for the reviewer,
// because self-declared names are only ever a hint (see the upload spec).

export function normalizeHandle(author) {
  return String(author || '').trim().toLowerCase().replace(/\s+/g, ' ');
}

// Read-only view used to build the PR before anything is written.
// Returns { priorSubmissions, handleOwner } (handleOwner null if unclaimed).
export async function lookup(kv, fingerprint, author) {
  const rec = await kv.get(`key:${fingerprint}`);
  let prior = 0;
  if (rec) {
    try { prior = Number(JSON.parse(rec).submissions) || 0; } catch { prior = 0; }
  }
  const handleOwner = await kv.get(`handle:${normalizeHandle(author)}`);
  return { priorSubmissions: prior, handleOwner: handleOwner || null };
}

// Record an accepted submission: bump the key's count (registering it on
// first sight) and claim the author name if nobody has.
export async function record(kv, fingerprint, author, nowIso) {
  const k = `key:${fingerprint}`;
  let rec = { first_seen: nowIso, submissions: 0 };
  const raw = await kv.get(k);
  if (raw) {
    try { rec = { ...rec, ...JSON.parse(raw) }; } catch { /* keep default */ }
  }
  rec.submissions = (Number(rec.submissions) || 0) + 1;
  await kv.put(k, JSON.stringify(rec));

  const h = `handle:${normalizeHandle(author)}`;
  if (!(await kv.get(h))) await kv.put(h, fingerprint);
}
