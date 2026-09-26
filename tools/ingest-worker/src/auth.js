// auth.js — verify a submission's Ed25519 envelope.
//
// The mod signs (share_identity.lua):
//   "dcs-sms-submit/1\n<pubkey b64>\n<unix ts>\n<nonce>\n<meta JSON bytes>"
// and sends X-SMS-PubKey / -Timestamp / -Nonce / -Signature. The signature
// binds the exact `meta` part (name, author, …) to the key; the prefab and
// images are covered by TLS in transit and by content hashing server-side.
//
// What a valid signature proves: the holder of this key sent this meta, now
// (timestamp window + single-use nonce). It proves nothing about who they are.

import { SubmissionError } from './submission.js';

export const PROTOCOL = 'dcs-sms-submit/1';
export const MAX_SKEW_SECONDS = 300;
const NONCE_TTL_SECONDS = 600;

function fromBase64(s) {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function hex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

// 'sms:' + first 16 hex chars of SHA-512(pubkey) — matches share_identity.lua.
export async function fingerprint(pub) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-512', pub));
  return 'sms:' + hex(d).slice(0, 16);
}

export function message(pubB64, ts, nonce, metaText) {
  return [PROTOCOL, pubB64, String(ts), nonce, metaText].join('\n');
}

const unauthorized = (msg) => new SubmissionError(401, msg);

// Returns { fingerprint, pubB64 } or throws SubmissionError (401 / 403).
// `kv` holds single-use nonces; `nowSec` is the server clock.
export async function verify(headers, metaText, { kv, nowSec, banned = [] }) {
  const pubB64 = headers.get('x-sms-pubkey');
  const tsRaw = headers.get('x-sms-timestamp');
  const nonce = headers.get('x-sms-nonce');
  const sigB64 = headers.get('x-sms-signature');
  if (!pubB64 || !tsRaw || !nonce || !sigB64) {
    throw unauthorized('unsigned submission; update the dcs-sms mod to share prefabs');
  }
  const pub = fromBase64(pubB64);
  const sig = fromBase64(sigB64);
  if (!pub || pub.length !== 32) throw unauthorized('malformed public key');
  if (!sig || sig.length !== 64) throw unauthorized('malformed signature');
  if (!/^[0-9a-f]{32}$/.test(nonce)) throw unauthorized('malformed nonce');
  if (!/^\d{1,12}$/.test(tsRaw)) throw unauthorized('malformed timestamp');

  const skew = Number(tsRaw) - nowSec;
  if (Math.abs(skew) > MAX_SKEW_SECONDS) {
    const mins = Math.round(Math.abs(skew) / 60);
    throw unauthorized(`your computer's clock is ${mins} minute(s) ${skew > 0 ? 'ahead' : 'behind'}; ` +
      'set it to the correct time and retry');
  }

  let ok = false;
  try {
    const key = await crypto.subtle.importKey('raw', pub, { name: 'Ed25519' }, false, ['verify']);
    ok = await crypto.subtle.verify({ name: 'Ed25519' }, key, sig,
      new TextEncoder().encode(message(pubB64, tsRaw, nonce, metaText)));
  } catch {
    ok = false;
  }
  if (!ok) throw unauthorized('signature does not verify');

  const fp = await fingerprint(pub);
  if (banned.includes(fp)) throw new SubmissionError(403, 'this submitter key is not accepted');

  // Single use, checked only after the signature verifies, so unsigned junk
  // can't fill the store. KV is eventually consistent: a replay racing the
  // original within a second or two could slip through, which the timestamp
  // window and the duplicate-PR check bound.
  const nonceKey = `nonce:${nonce}`;
  if (await kv.get(nonceKey)) throw unauthorized('this request was already used (replay)');
  await kv.put(nonceKey, '1', { expirationTtl: NONCE_TTL_SECONDS });

  return { fingerprint: fp, pubB64 };
}
