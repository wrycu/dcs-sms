// submission.js — parse + validate one multipart submission. Pure: no network,
// no bindings, so every rule here is unit-tested in isolation.
//
// The worker deliberately does NOT validate prefab contents beyond size and
// UTF-8. The catalog's validate.yml (lua_prefab.py, the same parse-don't-execute
// grammar the client enforces) is the trust boundary; duplicating that grammar
// here would mean two parsers to keep in sync.

export const CAPS = {
  prefabBytes: 2 * 1024 * 1024,
  imageBytes: 8 * 1024 * 1024,
  images: 6,
  bodyBytes: 24 * 1024 * 1024,
  name: 80,
  author: 64,
  description: 2000,
  tags: 10,
  tag: 32,
};

// Client-facing failure. `status` is the HTTP status the worker answers with.
export class SubmissionError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Magic-byte sniffing, so a renamed executable can't ride in as `1.png`.
// Returns the canonical extension or null.
export function sniffImage(bytes) {
  if (bytes.length >= 8 &&
      bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 &&
      bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a) {
    return 'png';
  }
  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return 'jpg';
  }
  return null;
}

// Catalog file stem from a display name. Matches the existing stems
// ("AC Ammo and Fuel (Bombs) F/A" -> "ac-ammo-and-fuel-bombs-f-a").
export function slugify(name) {
  const s = String(name || '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '');
  return s || 'prefab';
}

function requiredString(meta, key, max) {
  const v = meta[key];
  if (typeof v !== 'string' || v.trim() === '') {
    throw new SubmissionError(400, `meta.${key} is required`);
  }
  const t = v.trim();
  if (t.length > max) {
    throw new SubmissionError(400, `meta.${key} is longer than ${max} characters`);
  }
  return t;
}

// Lowercased, trimmed, de-duplicated — the same normalisation gen_index.py
// applies, so the sidecar already reads the way index.json will.
export function cleanTags(raw) {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw)) throw new SubmissionError(400, 'meta.tags must be an array');
  const out = [];
  for (const t of raw) {
    if (typeof t !== 'string') continue;
    const v = t.trim().toLowerCase();
    if (!v || out.includes(v)) continue;
    if (v.length > CAPS.tag) throw new SubmissionError(400, `tag "${v}" is longer than ${CAPS.tag} characters`);
    out.push(v);
  }
  if (out.length > CAPS.tags) throw new SubmissionError(400, `at most ${CAPS.tags} tags`);
  return out;
}

export function parseMeta(text) {
  let meta;
  try {
    meta = JSON.parse(text);
  } catch {
    throw new SubmissionError(400, 'meta is not valid JSON');
  }
  if (!meta || typeof meta !== 'object' || Array.isArray(meta)) {
    throw new SubmissionError(400, 'meta must be a JSON object');
  }
  return {
    name: requiredString(meta, 'name', CAPS.name),
    author: requiredString(meta, 'author', CAPS.author),
    description: requiredString(meta, 'description', CAPS.description),
    tags: cleanTags(meta.tags),
    client: typeof meta.client === 'string' ? meta.client.slice(0, 64) : '',
  };
}

async function partBytes(part) {
  return new Uint8Array(await part.arrayBuffer());
}

// Parse a Request into a validated submission:
//   { meta, prefab: Uint8Array, images: [{ bytes, ext }] }
// Throws SubmissionError on anything the client should be told about.
export async function parseSubmission(request) {
  const declared = Number(request.headers.get('content-length') || 0);
  if (declared > CAPS.bodyBytes) throw new SubmissionError(413, 'submission is larger than 24 MB');

  const type = request.headers.get('content-type') || '';
  if (!type.toLowerCase().startsWith('multipart/form-data')) {
    throw new SubmissionError(400, 'expected multipart/form-data');
  }
  let form;
  try {
    form = await request.formData();
  } catch {
    throw new SubmissionError(400, 'malformed multipart body');
  }

  const metaPart = form.get('meta');
  if (metaPart === null) throw new SubmissionError(400, 'missing meta part');
  const meta = parseMeta(typeof metaPart === 'string' ? metaPart : await metaPart.text());

  const prefabPart = form.get('prefab');
  if (prefabPart === null || typeof prefabPart === 'string') {
    throw new SubmissionError(400, 'missing prefab part');
  }
  const prefab = await partBytes(prefabPart);
  if (prefab.length === 0) throw new SubmissionError(400, 'prefab is empty');
  if (prefab.length > CAPS.prefabBytes) throw new SubmissionError(413, 'prefab is larger than 2 MB');
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(prefab);
  } catch {
    throw new SubmissionError(400, 'prefab is not UTF-8 text');
  }

  const imageParts = form.getAll('image');
  if (imageParts.length > CAPS.images) throw new SubmissionError(413, `at most ${CAPS.images} images`);
  const images = [];
  let total = prefab.length;
  for (const part of imageParts) {
    if (typeof part === 'string') throw new SubmissionError(400, 'image parts must be files');
    const bytes = await partBytes(part);
    if (bytes.length > CAPS.imageBytes) {
      throw new SubmissionError(413, `image "${part.name}" is larger than 8 MB`);
    }
    const ext = sniffImage(bytes);
    if (!ext) throw new SubmissionError(400, `image "${part.name}" is not a PNG or JPEG`);
    total += bytes.length;
    images.push({ bytes, ext });
  }
  if (total > CAPS.bodyBytes) throw new SubmissionError(413, 'submission is larger than 24 MB');

  return { meta, prefab, images };
}

// The catalog sidecar for a submission. `name` is carried explicitly so the
// entry keeps the submitter's display name rather than the prefab's meta.name.
export function buildSidecar(meta, imagePaths, submittedUtc) {
  return {
    name: meta.name,
    author: meta.author,
    description: meta.description,
    tags: meta.tags,
    images: imagePaths,
    submitted_utc: submittedUtc,
  };
}
