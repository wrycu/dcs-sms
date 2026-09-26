// ratelimit.js — fixed-window counters in Workers KV.
//
// KV is eventually consistent, so a burst can slip a few submissions past a
// limit. That is acceptable: this is a spam filter in front of a manual merge,
// not a quota. The global breaker is the real protection — past it, PRs still
// open but as drafts, so a flood never lands in the review queue as ready.
//
// Limits: per IP per hour, per submitter key per hour and per day, and the
// global hourly draft breaker. Every window is read before any is bumped, so
// a refused request doesn't consume quota.

const HOUR = 3600;
const DAY = 86400;

function key(prefix, id, span, nowSec) {
  return `${prefix}:${id}:${span}:${Math.floor(nowSec / span)}`;
}

async function count(kv, k) {
  return Number((await kv.get(k)) || 0);
}

async function bump(kv, k, span) {
  const n = (await count(kv, k)) + 1;
  // Expire well after the window closes; KV's minimum TTL is 60s.
  await kv.put(k, String(n), { expirationTtl: span * 2 });
  return n;
}

// Returns { allowed, retryAfter, draft, reason }.
// `limits` = { perIp, perKeyHour, perKeyDay, globalDraft }. `fp` optional.
export async function check(kv, ip, limits, nowSec = Math.floor(Date.now() / 1000), fp = null) {
  const windows = [{ k: key('ip', ip || 'unknown', HOUR, nowSec), max: limits.perIp, span: HOUR, reason: 'connection' }];
  if (fp) {
    windows.push({ k: key('key', fp, HOUR, nowSec), max: limits.perKeyHour, span: HOUR, reason: 'key-hour' });
    windows.push({ k: key('key', fp, DAY, nowSec), max: limits.perKeyDay, span: DAY, reason: 'key-day' });
  }
  for (const w of windows) {
    if (w.max !== undefined && (await count(kv, w.k)) >= w.max) {
      return { allowed: false, retryAfter: w.span - (nowSec % w.span), draft: false, reason: w.reason };
    }
  }
  for (const w of windows) await bump(kv, w.k, w.span);
  const global = await bump(kv, key('global', 'all', HOUR, nowSec), HOUR);
  return { allowed: true, retryAfter: 0, draft: global > limits.globalDraft, reason: null };
}
