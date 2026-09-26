// index.js — the dcs-sms community-prefab ingest worker.
//
//   POST /v1/submit   multipart: meta (JSON), prefab (file), image (0-6 files)
//   GET  /v1/health   liveness
//
// A submission becomes a pull request on the catalog repo; a human merge stays
// the gate, and the catalog's validate.yml runs on the PR to prove the prefab
// is pure data. See docs/superpowers/specs/2026-09-19-community-prefab-upload.md.
//
// This first version carries no client authentication (no shared-key HMAC, no
// Ed25519 identity). Both are additive headers on the same POST; until then
// the protections are the size caps, the per-IP limit, the global draft
// breaker, and the manual merge.

import { parseSubmission, buildSidecar, slugify, SubmissionError } from './submission.js';
import { makeClient } from './github.js';
import * as ratelimit from './ratelimit.js';

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}

async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(d, (b) => b.toString(16).padStart(2, '0')).join('');
}

function config(env) {
  return {
    repo: env.GITHUB_REPO || 'wrycu/dcs-sms-prefabs',
    base: env.BASE_BRANCH || 'main',
    perIp: Number(env.LIMIT_PER_IP_HOUR || 10),
    globalDraft: Number(env.LIMIT_GLOBAL_HOUR || 60),
  };
}

// Manifest entries on the base branch, or [] if the index can't be read (a
// missed dedup only costs a reviewer a duplicate PR; it must not block uploads).
async function loadIndex(fetchFn, cfg) {
  try {
    const res = await fetchFn(`https://raw.githubusercontent.com/${cfg.repo}/${cfg.base}/index.json`);
    if (!res.ok) return [];
    const data = await res.json();
    return Array.isArray(data.prefabs) ? data.prefabs : [];
  } catch {
    return [];
  }
}

// First free stem: <slug>, <slug>-2, <slug>-3 ... checked against both the
// manifest and the branch itself (the manifest can lag a fresh merge).
async function freeSlug(gh, cfg, base, index) {
  const taken = new Set(index.map((e) => String(e.path || '')));
  for (let n = 1; n <= 50; n++) {
    const slug = n === 1 ? base : `${base}-${n}`;
    const path = `prefabs/${slug}.prefab`;
    if (taken.has(path)) continue;
    if (!(await gh.fileExists(path, cfg.base))) return slug;
  }
  throw new SubmissionError(409, 'could not find a free name for this prefab; rename it and retry');
}

function prBody(meta, sha, draft) {
  const lines = [
    `**${meta.name}** by **${meta.author}** (self-declared, unverified)`,
    '',
    meta.description,
    '',
    `- Tags: ${meta.tags.length ? meta.tags.join(', ') : '(none)'}`,
    `- Prefab SHA-256: \`${sha}\``,
    `- Client: ${meta.client || '(unknown)'}`,
  ];
  if (draft) lines.push('', '> Opened as a draft: the hourly submission breaker tripped.');
  lines.push('', '_Submitted from the Mission Editor via the dcs-sms ingest worker._');
  return lines.join('\n');
}

export async function submit(request, env, deps = {}) {
  const fetchFn = deps.fetch || fetch;
  const now = deps.now || (() => new Date());
  const cfg = config(env);

  const sub = await parseSubmission(request);

  const ip = request.headers.get('cf-connecting-ip') || '';
  const rl = await ratelimit.check(env.RATE_KV, ip, cfg, Math.floor(now().getTime() / 1000));
  if (!rl.allowed) {
    return json(429, { error: 'too many submissions; try again later' },
      { 'retry-after': String(rl.retryAfter) });
  }

  const sha = await sha256Hex(sub.prefab);
  const index = await loadIndex(fetchFn, cfg);
  const dup = index.find((e) => e.sha256 === sha);
  if (dup) return json(409, { error: 'this prefab is already in the catalog', existing: dup.name });

  const gh = makeClient({ token: env.GITHUB_TOKEN, repo: cfg.repo, fetchFn });
  const slug = await freeSlug(gh, cfg, slugify(sub.meta.name), index);
  const imagePaths = sub.images.map((img, i) => `${slug}/${i + 1}.${img.ext}`);
  const stamp = now().toISOString().replace(/\.\d{3}Z$/, 'Z');
  const sidecar = buildSidecar(sub.meta, imagePaths, stamp);

  const files = [
    { path: `prefabs/${slug}.prefab`, bytes: sub.prefab },
    { path: `prefabs/${slug}.meta.json`,
      bytes: new TextEncoder().encode(JSON.stringify(sidecar, null, 2) + '\n') },
    ...sub.images.map((img, i) => ({ path: `images/${imagePaths[i]}`, bytes: img.bytes })),
  ];
  const submissionId = crypto.randomUUID();
  const pr = await gh.openPullRequest({
    base: cfg.base,
    branch: `submission/${slug}-${submissionId.slice(0, 8)}`,
    files,
    message: `add prefab: ${sub.meta.name}`,
    title: `Community submission: ${sub.meta.name}`,
    body: prBody(sub.meta, sha, rl.draft),
    draft: rl.draft,
    labels: ['community-submission'],
  });
  return json(202, { submission_id: submissionId, pr_url: pr.url });
}

export async function handle(request, env, deps = {}) {
  const url = new URL(request.url);
  if (url.pathname === '/v1/health' && request.method === 'GET') {
    return json(200, { ok: true });
  }
  if (url.pathname !== '/v1/submit') return json(404, { error: 'not found' });
  if (request.method !== 'POST') return json(405, { error: 'use POST' }, { allow: 'POST' });
  try {
    return await submit(request, env, deps);
  } catch (e) {
    if (e instanceof SubmissionError) return json(e.status, { error: e.message });
    console.error(e && e.stack ? e.stack : e);
    return json(502, { error: 'submission could not be forwarded; try again later' });
  }
}

export default {
  fetch: (request, env) => handle(request, env),
};
