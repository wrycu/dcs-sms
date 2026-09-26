// github.js — the few GitHub REST calls a submission needs. `fetchFn` is
// injected so tests can drive the whole flow against a fake API.
//
// Files go in through the Git Data API (blobs -> tree -> commit -> ref) rather
// than the contents API, so a submission is ONE commit however many files it
// carries, and .prefab bytes land byte-exact (the client SHA-256-verifies them
// against index.json, so any transformation would break the download).

const API = 'https://api.github.com';

export class GitHubError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Base64 for arbitrarily large byte arrays. String.fromCharCode(...bytes) on a
// multi-megabyte array overflows the argument limit, so encode in slices.
export function toBase64(bytes) {
  let bin = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    bin += String.fromCharCode.apply(null, bytes.subarray(i, i + step));
  }
  return btoa(bin);
}

export function makeClient({ token, repo, fetchFn = fetch }) {
  async function call(method, path, body) {
    const res = await fetchFn(`${API}/repos/${repo}${path}`, {
      method,
      headers: {
        authorization: `Bearer ${token}`,
        accept: 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
        'user-agent': 'dcs-sms-ingest',
        ...(body ? { 'content-type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (res.status === 404 && method === 'GET') return null;
    const text = await res.text();
    if (!res.ok) {
      throw new GitHubError(res.status, `GitHub ${method} ${path}: ${res.status} ${text.slice(0, 200)}`);
    }
    return text ? JSON.parse(text) : {};
  }

  return {
    // True if `path` exists on `branch`.
    async fileExists(path, branch) {
      const r = await call('GET', `/contents/${encodeURI(path)}?ref=${encodeURIComponent(branch)}`);
      return r !== null;
    },

    // Commit `files` ([{ path, bytes }]) onto a new branch cut from `base`,
    // then open a PR. Returns { number, url }.
    async openPullRequest({ base, branch, files, message, title, body, draft, labels }) {
      const ref = await call('GET', `/git/ref/heads/${encodeURIComponent(base)}`);
      if (!ref) throw new GitHubError(500, `base branch ${base} not found`);
      const baseSha = ref.object.sha;
      const baseCommit = await call('GET', `/git/commits/${baseSha}`);

      const tree = [];
      for (const f of files) {
        const blob = await call('POST', '/git/blobs', { content: toBase64(f.bytes), encoding: 'base64' });
        tree.push({ path: f.path, mode: '100644', type: 'blob', sha: blob.sha });
      }
      const newTree = await call('POST', '/git/trees', { base_tree: baseCommit.tree.sha, tree });
      const commit = await call('POST', '/git/commits', {
        message, tree: newTree.sha, parents: [baseSha],
      });
      await call('POST', '/git/refs', { ref: `refs/heads/${branch}`, sha: commit.sha });

      const pr = await call('POST', '/pulls', { title, head: branch, base, body, draft: !!draft });
      if (labels && labels.length) {
        // Labels are advisory; a failure here must not lose a PR that exists.
        try {
          await call('POST', `/issues/${pr.number}/labels`, { labels });
        } catch { /* ignore */ }
      }
      return { number: pr.number, url: pr.html_url };
    },
  };
}
