// ratelimit.js — fixed-window hourly counters in Workers KV.
//
// KV is eventually consistent, so a burst can slip a few submissions past a
// limit. That is acceptable: this is a spam filter in front of a manual merge,
// not a quota. The global breaker is the real protection — past it, PRs still
// open but as drafts, so a flood never lands in the review queue as ready.

const HOUR = 3600;

function windowKey(prefix, id, nowSec) {
  return `${prefix}:${id}:${Math.floor(nowSec / HOUR)}`;
}

async function bump(kv, key) {
  const n = Number((await kv.get(key)) || 0) + 1;
  // Expire well after the window closes; KV's minimum TTL is 60s.
  await kv.put(key, String(n), { expirationTtl: HOUR * 2 });
  return n;
}

// Returns { allowed, retryAfter, draft }. `limits` = { perIp, globalDraft }.
export async function check(kv, ip, limits, nowSec = Math.floor(Date.now() / 1000)) {
  const ipKey = windowKey('ip', ip || 'unknown', nowSec);
  const used = Number((await kv.get(ipKey)) || 0);
  if (used >= limits.perIp) {
    return { allowed: false, retryAfter: HOUR - (nowSec % HOUR), draft: false };
  }
  await bump(kv, ipKey);
  const global = await bump(kv, windowKey('global', 'all', nowSec));
  return { allowed: true, retryAfter: 0, draft: global > limits.globalDraft };
}
