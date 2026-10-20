const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

// Execute the workflow's actual inline script; no second implementation of its decision rules.
const workflow = fs.readFileSync(path.join(__dirname, '../.github/workflows/pr-comment-monitor.yml'), 'utf8').replace(/\r\n/g, '\n');
const script = workflow.split('          script: |\n')[1];
assert.ok(script, 'workflow script must exist');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction('github', 'context', script.replace(/^            /gm, ''));
const marker = '<!-- bioinfo-review-reminder-v1 -->';
const footer = '🤖 Co-Authored-By: Codex (gpt-6.1-sol) <199175422+chatgpt-codex-connector[bot]@users.noreply.github.com>';
const comment = (login = 'ehojune', association = 'OWNER', body = 'Review finding') =>
  ({ user: { login }, author_association: association, body });

async function fixture({
  trigger = comment(), issueComments = [], reviewComments = [],
  state = 'open', head = 'ehojune/bioinfo-agent', base = 'ehojune/bioinfo-agent',
  event = 'issue_comment',
} = {}) {
  const calls = [];
  const posts = [];
  const github = {
    rest: {
      pulls: {
        get: async args => {
          calls.push(['get', args]);
          return { data: { state, head: { repo: head && { full_name: head } },
            base: { repo: base && { full_name: base } } } };
        },
        listReviewComments: 'reviews',
      },
      issues: {
        listComments: 'issues',
        createComment: async args => { posts.push(args); },
      },
    },
    paginate: async (endpoint, args) => {
      calls.push([endpoint, args]);
      assert.equal(args.per_page, 100);
      return endpoint === 'reviews' ? reviewComments : issueComments;
    },
  };
  const payload = { comment: trigger };
  if (event === 'pull_request_review_comment') payload.pull_request = { number: 42 };
  else payload.issue = { number: 42, ...(event === 'issue_comment' ? { pull_request: {} } : {}) };
  await run(github, { repo: { owner: 'ehojune', repo: 'bioinfo-agent' }, payload });
  return { calls, posts };
}

test('plain issues and untrusted triggers make no API requests', async () => {
  for (const options of [
    { event: 'plain_issue' }, { trigger: null },
    { trigger: comment('outsider', 'NONE') },
    { trigger: comment('github-actions[bot]', 'COLLABORATOR') },
  ]) assert.deepEqual(await fixture(options), { calls: [], posts: [] });
});

test('closed, fork, deleted-head and wrong-base PRs produce no reminder', async () => {
  for (const options of [{ state: 'closed' }, { head: 'fork/bioinfo-agent' },
    { head: null }, { base: 'other/repo' }]) {
    const result = await fixture({ ...options, issueComments: Array.from({ length: 30 }, () => comment()) });
    assert.equal(result.posts.length, 0);
    assert.equal(result.calls.length, 1);
  }
});

test('15 trusted comments stay quiet; 16 and 20 only post a reminder', async () => {
  for (const count of [15, 16, 20]) {
    const result = await fixture({ issueComments: Array.from({ length: count }, () => comment()) });
    assert.equal(result.posts.length, count < 16 ? 0 : 1);
    if (count >= 16) {
      const { body, issue_number } = result.posts[0];
      assert.equal(issue_number, 42);
      assert.ok(body.includes(`${count} trusted comments`));
      assert.ok(body.endsWith(footer));
      assert.ok(body.includes('latest commit'));
    }
  }
});

test('count includes trusted inline reviews but excludes strangers, blank bodies and this workflow', async () => {
  const result = await fixture({
    event: 'pull_request_review_comment',
    trigger: comment('chatgpt-codex-connector[bot]', 'NONE'),
    reviewComments: Array.from({ length: 8 }, () => comment('reviewer', 'COLLABORATOR')),
    issueComments: [
      ...Array.from({ length: 8 }, () => comment('chatgpt-codex-connector[bot]', 'NONE')),
      ...Array.from({ length: 120 }, () => comment('outsider', 'NONE')),
      comment('github-actions[bot]', 'COLLABORATOR'), comment('ehojune', 'OWNER', ' \n'),
      comment('ehojune', 'OWNER', null), { body: 'Missing author' },
    ],
  });
  assert.equal(result.posts.length, 1);
  assert.ok(result.posts[0].body.includes('16 trusted comments'));
  assert.deepEqual(result.calls.map(([endpoint]) => endpoint), ['get', 'reviews', 'issues']);
});

test('only a workflow-authored marker suppresses duplicate reminders, including later pages', async () => {
  const discussion = Array.from({ length: 120 }, () => comment());
  const own = await fixture({ issueComments: [...discussion, comment('github-actions[bot]', 'NONE', marker)] });
  assert.equal(own.posts.length, 0);
  const spoofed = await fixture({ issueComments: [...discussion, comment('outsider', 'NONE', marker)] });
  assert.equal(spoofed.posts.length, 1);
});

test('workflow cannot write contents or pull requests; comment jobs never check out PR code', () => {
  assert.match(workflow, /^permissions: \{\}$/m);
  assert.doesNotMatch(workflow, /(?:contents|pull-requests): write/);
  const monitor = workflow.split('  monitor:\n')[1];
  assert.doesNotMatch(monitor, /actions\/checkout|pulls\.merge|checks\.|setOutput|Date\(/);
  assert.match(monitor, /cancel-in-progress: false/);
  assert.match(monitor, /pull-requests: read/);
  assert.match(monitor, /issues: write/);
});
