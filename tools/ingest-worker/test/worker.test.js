import { test } from 'node:test';
import assert from 'node:assert/strict';

import { handle } from '../src/index.js';
import { slugify, sniffImage, cleanTags, CAPS } from '../src/submission.js';
import { toBase64 } from '../src/github.js';
import * as ratelimit from '../src/ratelimit.js';

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
const JPG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 9, 9]);
const PREFAB = 'return {\n  meta = { name = "Test" },\n  groups = {},\n}\n';

function fakeKV() {
  const m = new Map();
  return {
    store: m,
    async get(k) { return m.has(k) ? m.get(k) : null; },
    async put(k, v) { m.set(k, v); },
  };
}

// Fake GitHub + raw.githubusercontent. Records every call; `existing` is the
// set of repo paths that exist on main; `index` is the served manifest.
function fakeGitHub({ existing = [], index = [], openPrs = [] } = {}) {
  const calls = [];
  const blobs = [];
  const fetchFn = async (url, init = {}) => {
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method, url, body });
    const ok = (obj, status = 200) => new Response(JSON.stringify(obj), { status });
    if (url.startsWith('https://raw.githubusercontent.com/')) return ok({ schema: 1, prefabs: index });
    const path = url.replace(/^https:\/\/api\.github\.com\/repos\/[^/]+\/[^/]+/, '');
    if (path.startsWith('/contents/')) {
      const p = decodeURI(path.slice('/contents/'.length).split('?')[0]);
      return existing.includes(p) ? ok({ path: p }) : new Response('{}', { status: 404 });
    }
    if (method === 'GET' && path === '/pulls?state=open&per_page=100') return ok(openPrs);
    if (path === '/git/ref/heads/main') return ok({ object: { sha: 'base-sha' } });
    if (path === '/git/commits/base-sha') return ok({ tree: { sha: 'base-tree' } });
    if (path === '/git/blobs') { blobs.push(body); return ok({ sha: `blob-${blobs.length}` }, 201); }
    if (path === '/git/trees') return ok({ sha: 'new-tree' }, 201);
    if (path === '/git/commits') return ok({ sha: 'new-commit' }, 201);
    if (path === '/git/refs') return ok({ ref: body.ref }, 201);
    if (path === '/pulls') return ok({ number: 7, html_url: 'https://github.com/o/r/pull/7' }, 201);
    if (path === '/issues/7/labels') return ok([]);
    return new Response('unexpected', { status: 500 });
  };
  return { fetchFn, calls, blobs };
}

function env(extra = {}) {
  return { GITHUB_TOKEN: 't', GITHUB_REPO: 'o/r', BASE_BRANCH: 'main', RATE_KV: fakeKV(), ...extra };
}

function submissionRequest({ meta, prefab = PREFAB, images = [], ip = '1.2.3.4' } = {}) {
  const form = new FormData();
  if (meta !== null) {
    form.set('meta', JSON.stringify(meta || {
      name: 'Test Site', author: 'Shuffle', description: 'A test.', tags: ['FOB', 'fob', ' Props '],
      client: 'me-mod 0.29.0',
    }));
  }
  if (prefab !== null) form.set('prefab', new Blob([prefab]), 'test.prefab');
  images.forEach((b, i) => form.append('image', new Blob([b]), `shot${i}.png`));
  return new Request('https://ingest.example/v1/submit', {
    method: 'POST', body: form, headers: { 'cf-connecting-ip': ip },
  });
}

const NOW = () => new Date('2026-09-26T12:00:00.123Z');

test('slugify matches the catalog stems', () => {
  assert.equal(slugify('AC Ammo and Fuel (Bombs) F/A'), 'ac-ammo-and-fuel-bombs-f-a');
  assert.equal(slugify('  Crew Chief 2.0 '), 'crew-chief-2-0');
  assert.equal(slugify('Café Défense'), 'cafe-defense');
  assert.equal(slugify('!!!'), 'prefab');
  assert.ok(slugify('x'.repeat(200)).length <= 60);
});

test('sniffImage recognises PNG/JPEG and rejects the rest', () => {
  assert.equal(sniffImage(PNG), 'png');
  assert.equal(sniffImage(JPG), 'jpg');
  assert.equal(sniffImage(new TextEncoder().encode('MZ\x90\x00')), null);
});

test('cleanTags lowercases, trims, de-duplicates', () => {
  assert.deepEqual(cleanTags(['FOB', 'fob', ' Props ', '', 3]), ['fob', 'props']);
  assert.throws(() => cleanTags('fob'));
});

test('toBase64 handles large arrays', () => {
  const big = new Uint8Array(200000).fill(65);
  assert.equal(Buffer.from(toBase64(big), 'base64').length, 200000);
});

test('happy path opens one PR with prefab, sidecar and images', async () => {
  const gh = fakeGitHub();
  const res = await handle(submissionRequest({ images: [PNG, JPG] }), env(), { fetch: gh.fetchFn, now: NOW });
  assert.equal(res.status, 202);
  const out = await res.json();
  assert.equal(out.pr_url, 'https://github.com/o/r/pull/7');
  assert.match(out.submission_id, /^[0-9a-f-]{36}$/);

  const tree = gh.calls.find((c) => c.url.endsWith('/git/trees')).body;
  assert.equal(tree.base_tree, 'base-tree');
  assert.deepEqual(tree.tree.map((t) => t.path), [
    'prefabs/test-site.prefab',
    'prefabs/test-site.meta.json',
    'images/test-site/1.png',
    'images/test-site/2.jpg',
  ]);

  // Prefab bytes survive byte-exact.
  assert.equal(Buffer.from(gh.blobs[0].content, 'base64').toString('utf8'), PREFAB);
  const sidecar = JSON.parse(Buffer.from(gh.blobs[1].content, 'base64').toString('utf8'));
  assert.deepEqual(sidecar, {
    name: 'Test Site', author: 'Shuffle', description: 'A test.', tags: ['fob', 'props'],
    images: ['test-site/1.png', 'test-site/2.jpg'], submitted_utc: '2026-09-26T12:00:00Z',
  });

  const ref = gh.calls.find((c) => c.url.endsWith('/git/refs')).body;
  assert.match(ref.ref, /^refs\/heads\/submission\/test-site-[0-9a-f]{8}$/);
  const pr = gh.calls.find((c) => c.url.endsWith('/pulls')).body;
  assert.equal(pr.base, 'main');
  assert.equal(pr.draft, false);
  assert.match(pr.body, /Shuffle/);
  const labels = gh.calls.find((c) => c.url.endsWith('/issues/7/labels')).body;
  assert.deepEqual(labels.labels, ['community-submission']);
});

test('slug collisions get a numeric suffix', async () => {
  const gh = fakeGitHub({
    existing: ['prefabs/test-site-2.prefab'],
    index: [{ name: 'Old', path: 'prefabs/test-site.prefab', sha256: 'x' }],
  });
  const res = await handle(submissionRequest(), env(), { fetch: gh.fetchFn, now: NOW });
  assert.equal(res.status, 202);
  const tree = gh.calls.find((c) => c.url.endsWith('/git/trees')).body;
  assert.equal(tree.tree[0].path, 'prefabs/test-site-3.prefab');
});

test('a prefab already in the catalog is rejected with 409', async () => {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(PREFAB)));
  const sha = Array.from(digest, (b) => b.toString(16).padStart(2, '0')).join('');
  const gh = fakeGitHub({ index: [{ name: 'Existing', path: 'prefabs/e.prefab', sha256: sha }] });
  const res = await handle(submissionRequest(), env(), { fetch: gh.fetchFn, now: NOW });
  assert.equal(res.status, 409);
  assert.equal((await res.json()).existing, 'Existing');
  assert.ok(!gh.calls.some((c) => c.url.endsWith('/pulls')));
});

test('a prefab already awaiting review in an open PR is rejected with 409', async () => {
  // Round trip: the first submission's own PR body is what the check matches.
  const first = fakeGitHub();
  assert.equal((await handle(submissionRequest(), env(), { fetch: first.fetchFn, now: NOW })).status, 202);
  const body = first.calls.find((c) => c.url.endsWith('/pulls')).body.body;

  const gh = fakeGitHub({ openPrs: [{
    number: 3, html_url: 'https://github.com/o/r/pull/3', title: 'Community submission: Test Site',
    head: { ref: 'submission/test-site-abcd1234' }, body,
  }] });
  const res = await handle(submissionRequest(), env(), { fetch: gh.fetchFn, now: NOW });
  assert.equal(res.status, 409);
  const out = await res.json();
  assert.equal(out.pr_url, 'https://github.com/o/r/pull/3');
  assert.equal(out.existing, 'Test Site (awaiting review)');
  assert.ok(!gh.calls.some((c) => c.method === 'POST'), 'no branch, commit or PR created');
});

test('open PRs that are not submissions, or carry another hash, do not block', async () => {
  const gh = fakeGitHub({ openPrs: [
    { number: 5, html_url: 'u5', title: 't', head: { ref: 'feature/x' },
      body: '- Prefab SHA-256: `' + 'f'.repeat(64) + '`' },
    { number: 6, html_url: 'u6', title: 't', head: { ref: 'submission/other-1' },
      body: '- Prefab SHA-256: `' + '0'.repeat(64) + '`' },
  ] });
  const res = await handle(submissionRequest(), env(), { fetch: gh.fetchFn, now: NOW });
  assert.equal(res.status, 202);
});

test('validation failures return 400 / 413 and never touch GitHub', async () => {
  const cases = [
    [{ meta: null }, 400],
    [{ meta: { name: 'x', author: '', description: 'd' } }, 400],
    [{ prefab: null }, 400],
    [{ prefab: new Uint8Array([0xff, 0xfe, 0x00]) }, 400],
    [{ prefab: new Uint8Array(CAPS.prefabBytes + 1).fill(32) }, 413],
    [{ images: [new TextEncoder().encode('MZ not an image')] }, 400],
    [{ images: Array(CAPS.images + 1).fill(PNG) }, 413],
  ];
  for (const [opts, status] of cases) {
    const gh = fakeGitHub();
    const res = await handle(submissionRequest(opts), env(), { fetch: gh.fetchFn, now: NOW });
    assert.equal(res.status, status, JSON.stringify(Object.keys(opts)));
    assert.equal(gh.calls.length, 0);
  }
});

test('per-IP limit returns 429 with Retry-After', async () => {
  const e = env({ LIMIT_PER_IP_HOUR: '2' });
  const now = () => new Date('2026-09-26T12:12:00Z');
  for (let i = 0; i < 2; i++) {
    const res = await handle(submissionRequest({ prefab: PREFAB + i }), e, { fetch: fakeGitHub().fetchFn, now });
    assert.equal(res.status, 202);
  }
  const res = await handle(submissionRequest({ prefab: PREFAB + 'x' }), e, { fetch: fakeGitHub().fetchFn, now });
  assert.equal(res.status, 429);
  assert.equal(res.headers.get('retry-after'), String(3600 - 12 * 60));
  // A different IP is unaffected.
  const other = await handle(submissionRequest({ prefab: PREFAB + 'y', ip: '5.6.7.8' }), e,
    { fetch: fakeGitHub().fetchFn, now });
  assert.equal(other.status, 202);
});

test('global breaker opens PRs as drafts', async () => {
  const kv = fakeKV();
  const limits = { perIp: 100, globalDraft: 1 };
  const t = 1_000_000;
  assert.equal((await ratelimit.check(kv, 'a', limits, t)).draft, false);
  assert.equal((await ratelimit.check(kv, 'b', limits, t)).draft, true);
  // Next hour starts a fresh window.
  assert.equal((await ratelimit.check(kv, 'c', limits, t + 3600)).draft, false);
});

test('GitHub failures surface as 502 without leaking details', async () => {
  const fetchFn = async (url) => (url.startsWith('https://raw.')
    ? new Response('{"prefabs":[]}') : new Response('boom', { status: 500 }));
  const orig = console.error;
  console.error = () => {};
  try {
    const res = await handle(submissionRequest(), env(), { fetch: fetchFn, now: NOW });
    assert.equal(res.status, 502);
    assert.doesNotMatch((await res.json()).error, /boom/);
  } finally {
    console.error = orig;
  }
});

test('routing: health, 404, 405', async () => {
  assert.equal((await handle(new Request('https://i/v1/health'), env())).status, 200);
  assert.equal((await handle(new Request('https://i/nope'), env())).status, 404);
  assert.equal((await handle(new Request('https://i/v1/submit'), env())).status, 405);
});
