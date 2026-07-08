# Backlog GitHub Issues Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable Postgres/GitHub-Issues backends to `backlog` while preserving the current Postgres CLI behavior by default.

**Architecture:** Keep `tools/backlog` as a portable single-file Node executable, but split it internally into config selection, shared validation, a Postgres adapter, and a GitHub adapter. Use `~/.config/ai-tools/backlog.json` for named backends, fall back to the old `.conf`/`BACKLOG_DATABASE_URL` path, and test GitHub behavior through an injectable/fake HTTP transport with no real network calls.

**Tech Stack:** Node.js built-ins only (`fs`, `path`, `child_process`, `http` in tests), shell tests in `tests/run.sh`, Homebrew formula Ruby syntax checks.

---

## File Structure

- Modify `tools/backlog`: add global `--backend`, JSON config loading, backend adapter dispatch, strict frontmatter helpers, GitHub ID helpers, GitHub HTTP helpers, and GitHub command implementations. Keep the file executable and dependency-free.
- Modify `tests/run.sh`: add deterministic shell tests for config selection, Postgres fallback, GitHub ID/frontmatter helpers through CLI behavior, and GitHub adapter behavior through a local fake HTTP server.
- Modify `install/backlog`: create `~/.config/ai-tools/backlog.json` for new installs, preserve old `.conf`, and keep `--database-url` support.
- Modify `README.md`: document `backlog.json`, backend selection, GitHub token config, and accepted GitHub semantic differences.
- Modify `Formula/backlog.rb`: update caveats for `backlog.json` while preserving the current smoke test path.
- Do not commit `tmp/`; it is agent-thread scratch.

## Implementation Notes

- Use Context7/GitHub REST docs at code time before implementing GitHub API requests. Confirm `/search/issues`, `/user/repos`, `/installation/repositories`, labels, issues create/update, native issue dependencies, issue types, issue field values, pagination, rate-limit headers, and API version behavior.
- GitHub issue fields are issue-only; pull requests do not support them. Use `features.issueFields` as the canonical config name and accept `features.customFields` only as a backward-compatible migration alias.
- Current GitHub issue field docs use `X-GitHub-Api-Version: 2026-03-10`. Organization field definitions are under `/orgs/{org}/issue-fields`; individual values are under `/repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`.
- Mirror backlog metadata with `POST /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`, which adds or updates the provided values without replacing unrelated human-managed issue fields. Avoid `PUT /issue-field-values` for mirroring because it replaces the issue's field value set. Use `DELETE /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values/{issue_field_id}` only when clearing a single mirrored value is required.
- Issue fields can be set, edited, and cleared through the issue sidebar, GitHub Projects, API, or GitHub Actions, but not through URL query parameters or issue templates. They are searchable with `field.<name>:<value>` and changes trigger `issues` webhook activity types `field_added` and `field_removed`.
- Keep `tools/backlog` zero-dependency. The frontmatter format is a strict `key: <JSON literal>` subset inside a leading `---` fence.
- Keep Postgres behavior unchanged under old config and `BACKLOG_DATABASE_URL`; this is the regression baseline.
- GitHub command parity means the commands exist and return matching row shapes, not that GitHub has transaction/audit parity.

### Task 1: Backend Config Selection

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Add failing tests for JSON config selection and legacy fallback**

Add tests near the existing backlog config tests in `tests/run.sh`:

```bash
test_backlog_json_config_selects_postgres_backend() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/config"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/config/backlog.json" <<'JSON'
{
  "default": "pg",
  "backends": [
    { "name": "pg", "type": "postgres", "databaseUrl": "postgres://json.example/backlog" }
  ]
}
JSON

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" BACKLOG_CONFIG="$tmp/config/backlog.json" \
    "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "backlog should use postgres backend from JSON config; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://json.example/backlog' "$(head -n 1 "$tmp/psql.args")" "JSON postgres database URL selected"
  assert_eq '[]' "$(<"$tmp/out")" "JSON postgres output"
}

test_backlog_backend_flag_overrides_default_backend() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/config"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/config/backlog.json" <<'JSON'
{
  "default": "default-pg",
  "backends": [
    { "name": "default-pg", "type": "postgres", "databaseUrl": "postgres://default.example/backlog" },
    { "name": "override-pg", "type": "postgres", "databaseUrl": "postgres://override.example/backlog" }
  ]
}
JSON

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" BACKLOG_CONFIG="$tmp/config/backlog.json" \
    "$ROOT/tools/backlog" --backend override-pg list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "backlog --backend should override default; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://override.example/backlog' "$(head -n 1 "$tmp/psql.args")" "backend flag database URL selected"
}

test_backlog_backend_flag_can_appear_after_command() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/config"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/config/backlog.json" <<'JSON'
{
  "default": "default-pg",
  "backends": [
    { "name": "default-pg", "type": "postgres", "databaseUrl": "postgres://default.example/backlog" },
    { "name": "after-command-pg", "type": "postgres", "databaseUrl": "postgres://after.example/backlog" }
  ]
}
JSON

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" BACKLOG_CONFIG="$tmp/config/backlog.json" \
    "$ROOT/tools/backlog" list-repos --backend after-command-pg > "$tmp/out" 2> "$tmp/err" || {
      fail "backlog should accept --backend after the command; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://after.example/backlog' "$(head -n 1 "$tmp/psql.args")" "after-command backend flag selected"
}

test_backlog_json_config_wins_over_legacy_conf() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/config"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/config/backlog.json" <<'JSON'
{ "default": "json-pg", "backends": [{ "name": "json-pg", "type": "postgres", "databaseUrl": "postgres://json-wins.example/backlog" }] }
JSON
  printf "DATABASE_URL='postgres://legacy.example/backlog'\n" > "$tmp/config/backlog.conf"

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" BACKLOG_CONFIG="$tmp/config/backlog.json" \
    "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "JSON config should win over legacy conf; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://json-wins.example/backlog' "$(head -n 1 "$tmp/psql.args")" "JSON config precedence"
}

test_backlog_discovers_default_json_config_under_xdg_config_home() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/xdg/ai-tools"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/xdg/ai-tools/backlog.json" <<'JSON'
{ "default": "xdg-pg", "backends": [{ "name": "xdg-pg", "type": "postgres", "databaseUrl": "postgres://xdg.example/backlog" }] }
JSON

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" XDG_CONFIG_HOME="$tmp/xdg" BACKLOG_CONFIG= BACKLOG_DATABASE_URL= \
    "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "backlog should discover XDG JSON config; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://xdg.example/backlog' "$(head -n 1 "$tmp/psql.args")" "XDG JSON config discovered"
}

test_backlog_database_url_env_overrides_postgres_backend_url() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/config"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  cat > "$tmp/config/backlog.json" <<'JSON'
{ "default": "pg", "backends": [{ "name": "pg", "type": "postgres", "databaseUrl": "postgres://file.example/backlog" }] }
JSON

  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$tmp/psql.args" BACKLOG_CONFIG="$tmp/config/backlog.json" BACKLOG_DATABASE_URL="postgres://env.example/backlog" \
    "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "BACKLOG_DATABASE_URL should override postgres backend URL; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq 'postgres://env.example/backlog' "$(head -n 1 "$tmp/psql.args")" "DATABASE_URL env override"
}
```

Register them after `test_backlog_reads_database_url_from_config`.

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
bash tests/run.sh
```

Expected: the new config-selection tests fail because default JSON discovery, JSON parsing, env override precedence, and `--backend` are not implemented yet.

- [ ] **Step 3: Implement config object loading and global flag parsing**

In `tools/backlog`:

- Change `parseArgs` only for command flags; add `parseGlobalArgs(argv)` before command dispatch.
- Add `loadBacklogConfig()` that recognizes JSON config files ending in `.json` or containing JSON.
- Keep `loadConfigFile()` for legacy `.conf`.
- Add `selectBackendConfig(globalArgs)` with selection order `--backend`, `BACKLOG_BACKEND`, JSON `default`, legacy implicit Postgres.
- Change `loadDatabaseUrl()` to accept a selected Postgres backend.

Implementation skeleton:

```js
function parseGlobalArgs(argv) {
  const globals = {};
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--backend') {
      const v = argv[++i];
      if (!v) fail('--backend requires a value');
      globals.backend = v;
    } else if (a.startsWith('--backend=')) {
      globals.backend = a.slice('--backend='.length);
      if (!globals.backend) fail('--backend requires a value');
    } else {
      rest.push(a);
      continue;
    }
  }
  return { globals, rest };
}
```

Backend config selection should return:

```js
{ name: 'legacy-postgres', type: 'postgres', databaseUrl: '<url>' }
```

for the old `.conf`/env path when no JSON config exists.

- [ ] **Step 4: Run tests to verify config selection passes**

Run:

```bash
bash tests/run.sh
```

Expected: existing tests and the new config-selection tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add tools/backlog tests/run.sh
git commit -m "feat(backlog): load named backend config"
```

### Task 2: Adapter Dispatch Without Postgres Regression

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Add failing tests for adapter-owned required flags**

Add a test proving GitHub `create-repo` does not require Postgres-only flags once the GitHub adapter exists. Point it at a closed local port so the command can fail only after backend-specific validation:

```bash
test_backlog_github_create_repo_does_not_require_postgres_alias_flags() {
  local tmp="$1"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{
  "default": "gh",
  "backends": [
    { "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:9" }
  ]
}
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-repo --slug GourmetPro/gtm-claude-code > "$tmp/out" 2> "$tmp/err"
  local status=$?

  if [[ "$status" -eq 0 ]]; then
    fail "github create-repo should not succeed against closed fake port"
    return 1
  fi
  if grep -Fq -- "--short-slug is required" "$tmp/err" || grep -Fq -- "--display-name is required" "$tmp/err"; then
    fail "github create-repo must not require Postgres alias flags; stderr was: $(<"$tmp/err")"
    return 1
  fi
}
```

Register it after config selection tests.

- [ ] **Step 2: Run test to verify it fails for the right reason**

Run:

```bash
bash tests/run.sh
```

Expected: the new test fails or emits the old Postgres required-flag error.

- [ ] **Step 3: Refactor command table to adapter dispatch**

In `tools/backlog`, change the command table from direct command functions to:

```js
const postgresAdapter = {
  type: 'postgres',
  commands: {
    'list-repos': { fn: cmdListReposPostgres, flags: [] },
    'create-repo': { fn: cmdCreateRepoPostgres, flags: ['slug', 'short-slug', 'display-name', 'default-branch', 'color'] },
    'list-items': { fn: cmdListItemsPostgres, flags: ['repo', 'workstream', 'status', 'type', 'priority', 'q', 'limit', 'offset'] },
    'get-item': { fn: cmdGetItemPostgres, flags: ['id'] },
    summarize: { fn: cmdSummarizePostgres, flags: ['workstream', 'repo'] },
    'create-item': { fn: cmdCreateItemPostgres, flags: ['repo', 'workstream', 'title', 'type', 'body', 'priority', 'source-context', 'depends-on', 'branch', 'progress-note', 'due-date', 'links', 'id'] },
    'update-item': { fn: cmdUpdateItemPostgres, flags: ['id', 'status', 'priority', 'title', 'body', 'blocked-reason', 'abandoned-reason', 'depends-on', 'branch', 'progress-note', 'due-date', 'links'] },
  },
};

const githubAdapter = {
  type: 'github-issues',
  commands: {
    'list-repos': { fn: cmdListReposGithub, flags: [] },
    'create-repo': { fn: cmdCreateRepoGithub, flags: ['slug'] },
    'list-items': { fn: cmdListItemsGithub, flags: ['repo', 'workstream', 'status', 'type', 'priority', 'q', 'limit', 'offset'] },
    'get-item': { fn: cmdGetItemGithub, flags: ['id'] },
    summarize: { fn: cmdSummarizeGithub, flags: ['workstream', 'repo'] },
    'create-item': { fn: cmdCreateItemGithub, flags: ['repo', 'workstream', 'title', 'type', 'body', 'priority', 'source-context', 'depends-on', 'branch', 'progress-note', 'due-date', 'links', 'id'] },
    'update-item': { fn: cmdUpdateItemGithub, flags: ['id', 'status', 'priority', 'title', 'body', 'blocked-reason', 'abandoned-reason', 'depends-on', 'branch', 'progress-note', 'due-date', 'links'] },
  },
};
```

Rename current Postgres functions with a `Postgres` suffix. Each function receives `(args, backend)` and uses the selected backend for database URL. The shell validates allowed flags from the selected adapter.

Add temporary GitHub command functions that fail after adapter validation:

```js
function githubNotImplemented() {
  fail('github-issues backend is not implemented yet');
}
```

Use specific GitHub command flag lists now so shell validation is correct before implementation.

Extract write validation that both adapters must share:

```js
function validateBacklogWriteTransition(before, args) {
  if (args.status === 'blocked' && !(args['blocked-reason'] || '').trim()) {
    fail('status=blocked requires a non-empty --blocked-reason');
  }
  if (args.status === 'abandoned' && !(args['abandoned-reason'] || '').trim()) {
    fail('status=abandoned requires a non-empty --abandoned-reason');
  }
  const resultingStatus = args.status ?? before.status;
  const resultingBranch = args.branch !== undefined ? args.branch : before.branch;
  const resultingNote = args['progress-note'] !== undefined ? args['progress-note'] : before.progress_note;
  if (resultingStatus === 'in_progress' && !(resultingBranch || '').trim() && !(resultingNote || '').trim()) {
    fail('in_progress requires either --branch or --progress-note (recovery signal)');
  }
}
```

Postgres `update-item` should call this helper instead of keeping a private copy.
GitHub `update-item` must call the same helper after mapping the current issue to
a backlog row.

- [ ] **Step 4: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: Postgres behavior still passes; the GitHub required-flag test no longer reports missing `--short-slug` or `--display-name`.

- [ ] **Step 5: Commit Task 2**

```bash
git add tools/backlog tests/run.sh
git commit -m "refactor(backlog): dispatch commands through backend adapters"
```

### Task 3: GitHub ID And Frontmatter Helpers

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Add black-box helper tests through a temporary test command**

Add a hidden command only enabled when `BACKLOG_TEST_HELPERS=1`:

```bash
test_backlog_github_id_and_frontmatter_helpers() {
  local tmp="$1"

  BACKLOG_TEST_HELPERS=1 "$ROOT/tools/backlog" __test-github-id \
    --repo "GourmetPro/repo.with_under--dash" \
    --number 123 > "$tmp/id.out" 2> "$tmp/id.err" || {
      fail "github id helper should succeed; stderr was: $(<"$tmp/id.err")"
      return 1
    }
  assert_eq 'gourmetpro--repo.with_under--dash--123' "$(<"$tmp/id.out")" "lossless github id"

  cat > "$tmp/body.md" <<'EOF'
---
workstream: "old"
links: []
unknown_key: "preserve me"
---

Human body.

---

Not frontmatter.
EOF

  BACKLOG_TEST_HELPERS=1 "$ROOT/tools/backlog" __test-frontmatter-roundtrip \
    --file "$tmp/body.md" \
    --set '{"workstream":"new","links":[{"kind":"url","url":"https://example.com"}]}' \
    > "$tmp/front.out" 2> "$tmp/front.err" || {
      fail "frontmatter helper should succeed; stderr was: $(<"$tmp/front.err")"
      return 1
    }

  assert_contains 'workstream: "new"' "$tmp/front.out" "frontmatter updates workstream" || return 1
  assert_contains 'unknown_key: "preserve me"' "$tmp/front.out" "frontmatter preserves unknown keys" || return 1
  assert_contains 'Not frontmatter.' "$tmp/front.out" "human body preserved"

  printf '%s' "$(<"$tmp/front.out")" > "$tmp/front-once.md"
  BACKLOG_TEST_HELPERS=1 "$ROOT/tools/backlog" __test-frontmatter-roundtrip \
    --file "$tmp/front-once.md" \
    --set '{"workstream":"new","links":[{"kind":"url","url":"https://example.com"}]}' \
    > "$tmp/front-twice.out" 2> "$tmp/front-twice.err" || {
      fail "second frontmatter roundtrip should succeed; stderr was: $(<"$tmp/front-twice.err")"
      return 1
    }
  assert_eq "$(<"$tmp/front.out")" "$(<"$tmp/front-twice.out")" "frontmatter roundtrip is byte-stable"
}
```

Register this test near the GitHub adapter tests.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash tests/run.sh
```

Expected: the hidden helper command is unknown.

- [ ] **Step 3: Implement GitHub ID helpers**

Add:

```js
const GITHUB_ID_REGEX = /^[a-z0-9._-]+--.+--[1-9][0-9]*$/;

function githubIdFor(repoSlug, issueNumber) {
  if (!GITHUB_SLUG_REGEX.test(repoSlug)) fail('repo must be a full GitHub slug <org>/<repo>');
  const [owner, repo] = repoSlug.split('/');
  const n = Number(issueNumber);
  if (!Number.isInteger(n) || n <= 0) fail('issue number must be a positive integer');
  return `${owner.toLowerCase()}--${repo.toLowerCase()}--${n}`;
}

function parseGithubId(id) {
  const first = id.indexOf('--');
  const last = id.lastIndexOf('--');
  if (first <= 0 || last <= first + 2) fail(`bad github issue id: ${id}`);
  const owner = id.slice(0, first);
  const repo = id.slice(first + 2, last);
  const numberText = id.slice(last + 2);
  if (!/^[a-z0-9._-]+$/.test(owner) || !/^[a-z0-9._-]+(?:--[a-z0-9._-]+)*$/.test(repo) || !/^[1-9][0-9]*$/.test(numberText)) {
    fail(`bad github issue id: ${id}`);
  }
  return { owner, repo, issueNumber: Number(numberText), repoSlug: `${owner}/${repo}` };
}
```

- [ ] **Step 4: Implement strict frontmatter helpers**

Add:

```js
function parseFrontmatter(body) {
  if (!body.startsWith('---\n')) return { meta: {}, body };
  const lines = body.split('\n');
  let endLine = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i] === '---') {
      endLine = i;
      break;
    }
  }
  if (endLine === -1) return { meta: {}, body };
  const raw = lines.slice(1, endLine).join('\n');
  const humanBody = lines.slice(endLine + 1).join('\n').replace(/^\n/, '');
  const meta = {};
  const rawLines = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    const idx = line.indexOf(':');
    if (idx <= 0) fail(`invalid backlog frontmatter line: ${line}`);
    const key = line.slice(0, idx).trim();
    const valueText = line.slice(idx + 1).trim();
    try {
      meta[key] = JSON.parse(valueText);
    } catch (e) {
      fail(`invalid JSON literal for frontmatter key ${key}: ${e.message}`);
    }
    rawLines.push(key);
  }
  return { meta, body: humanBody, rawKeys: rawLines };
}

function formatFrontmatter(meta, body) {
  const keys = Object.keys(meta);
  const lines = ['---'];
  for (const key of keys) lines.push(`${key}: ${JSON.stringify(meta[key])}`);
  lines.push('---');
  if (body) lines.push('', body.replace(/^\n/, ''));
  else lines.push('');
  return lines.join('\n');
}
```

When updating metadata, merge known updates into parsed `meta` and preserve unknown keys by keeping them in the object.

- [ ] **Step 5: Add hidden helper dispatch**

Before normal command dispatch:

```js
if (process.env.BACKLOG_TEST_HELPERS === '1' && cmd === '__test-github-id') {
  const args = parseArgs(rest);
  require_(args, ['repo', 'number']);
  process.stdout.write(`${githubIdFor(args.repo, args.number)}\n`);
  process.exit(0);
}
if (process.env.BACKLOG_TEST_HELPERS === '1' && cmd === '__test-frontmatter-roundtrip') {
  const args = parseArgs(rest);
  require_(args, ['file', 'set']);
  const parsed = parseFrontmatter(fs.readFileSync(args.file, 'utf8'));
  const updates = JSON.parse(args.set);
  process.stdout.write(formatFrontmatter({ ...parsed.meta, ...updates }, parsed.body));
  process.exit(0);
}
```

These helpers are only for tests and are not listed in help.

- [ ] **Step 6: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: helper tests pass and Postgres tests remain green.

- [ ] **Step 7: Commit Task 3**

```bash
git add tools/backlog tests/run.sh
git commit -m "feat(backlog): add github id and frontmatter helpers"
```

### Task 4: GitHub HTTP Transport And Repository Commands

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Add fake GitHub server fixture in tests**

Add a helper in `tests/run.sh`:

```bash
start_fake_github() {
  local tmp="$1"
  local script="$tmp/fake-github.js"
  cat > "$script" <<'JS'
const http = require('http');
const labels = new Set();
const server = http.createServer((req, res) => {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    res.setHeader('content-type', 'application/json');
    if (req.url.startsWith('/user/repos')) {
      res.end(JSON.stringify([
        { full_name: 'GourmetPro/gtm-claude-code', name: 'gtm-claude-code', default_branch: 'main', html_url: 'https://github.com/GourmetPro/gtm-claude-code', created_at: '2026-01-01T00:00:00Z' }
      ]));
      return;
    }
    if (req.url === '/repos/GourmetPro/gtm-claude-code') {
      res.end(JSON.stringify({ full_name: 'GourmetPro/gtm-claude-code', name: 'gtm-claude-code', default_branch: 'main', html_url: 'https://github.com/GourmetPro/gtm-claude-code', created_at: '2026-01-01T00:00:00Z' }));
      return;
    }
    if (req.method === 'POST' && req.url === '/repos/GourmetPro/gtm-claude-code/labels') {
      const parsed = JSON.parse(body || '{}');
      labels.add(parsed.name);
      res.statusCode = 201;
      res.end(JSON.stringify(parsed));
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ message: `not found: ${req.method} ${req.url}` }));
  });
});
server.listen(0, '127.0.0.1', () => {
  console.log(server.address().port);
});
JS
  node "$script" > "$tmp/fake-github.port" 2> "$tmp/fake-github.err" &
  local pid=$!
  for _ in {1..50}; do
    [[ -s "$tmp/fake-github.port" ]] && break
    sleep 0.1
  done
  echo "$pid"
}
```

- [ ] **Step 2: Add failing tests for `list-repos` and `create-repo`**

Add:

```bash
test_backlog_github_lists_token_visible_repos() {
  local tmp="$1"
  local pid
  pid="$(start_fake_github "$tmp")"
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  local port
  port="$(cat "$tmp/fake-github.port")"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{ "default": "gh", "backends": [{ "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:$port" }] }
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err" || {
      fail "github list-repos should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_contains '"slug": "GourmetPro/gtm-claude-code"' "$tmp/out" "github repo slug" || return 1
  assert_contains '"short_slug": "gourmetpro--gtm-claude-code"' "$tmp/out" "github repo short slug" || return 1
}
```

Add this `create-repo` test:

```bash
test_backlog_github_create_repo_bootstraps_labels() {
  local tmp="$1"
  local pid
  pid="$(start_fake_github "$tmp")"
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  local port
  port="$(cat "$tmp/fake-github.port")"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{ "default": "gh", "backends": [{ "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:$port" }] }
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-repo --slug GourmetPro/gtm-claude-code > "$tmp/out" 2> "$tmp/err" || {
      fail "github create-repo should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_contains '"slug": "GourmetPro/gtm-claude-code"' "$tmp/out" "github create-repo slug" || return 1
  assert_contains '"short_slug": "gourmetpro--gtm-claude-code"' "$tmp/out" "github create-repo short slug" || return 1
}
```

- [ ] **Step 3: Run tests to verify GitHub commands fail as not implemented**

Run:

```bash
bash tests/run.sh
```

Expected: GitHub list/create repo tests fail with the temporary not-implemented error.

- [ ] **Step 4: Implement GitHub request helper**

Add:

```js
function githubToken(backend) {
  const envName = backend.tokenEnv || 'GITHUB_TOKEN';
  const token = process.env[envName];
  if (!token) fail(`${envName} is not set for github-issues backend ${backend.name}`);
  return token;
}

async function githubRequest(backend, method, pathName, { query, body, apiVersion } = {}) {
  const base = backend.apiBaseUrl || 'https://api.github.com';
  const url = new URL(pathName, base);
  for (const [k, v] of Object.entries(query || {})) url.searchParams.set(k, String(v));
  const res = await fetch(url, {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${githubToken(backend)}`,
      'X-GitHub-Api-Version': apiVersion || backend.apiVersion || '2026-03-10',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : null;
  if (!res.ok) fail(`github ${method} ${pathName} failed (${res.status}): ${json?.message || text || res.statusText}`);
  return { json, headers: res.headers };
}
```

Because top-level command dispatch is currently synchronous, wrap final execution in:

```js
(async () => {
  const result = await selected.commands[cmd].fn(args, backend);
  console.log(JSON.stringify(result, null, 2));
})().catch((e) => fail(e.message || String(e)));
```

- [ ] **Step 5: Implement native capability helpers**

Add a process-local capability cache:

```js
const githubCapabilityCache = new Map();

function capabilityKey(backend, owner, repo, name) {
  return `${backend.name || 'github'}:${owner.toLowerCase()}/${repo.toLowerCase()}:${name}`;
}

function capabilityEnabled(backend, owner, repo, name) {
  return githubCapabilityCache.get(capabilityKey(backend, owner, repo, name)) !== false;
}

function markCapabilityUnavailable(backend, owner, repo, name) {
  githubCapabilityCache.set(capabilityKey(backend, owner, repo, name), false);
}
```

Add helper wrappers:

```js
async function tryGithubNativeType(backend, owner, repo, body, backlogType) {
  const typeName = backend.features?.issueTypes?.[backlogType];
  if (!typeName || !capabilityEnabled(backend, owner, repo, 'issueTypes')) return false;
  body.type = typeName;
  return true;
}

function configuredGithubIssueFields(backend) {
  return backend.features?.issueFields || backend.features?.customFields || {};
}

function normalizeGithubIssueFieldValue(field, value) {
  const dataType = field.dataType || 'text';
  if (!['text', 'single_select', 'number', 'date'].includes(dataType)) return undefined;
  if (value === undefined || value === null) return undefined;
  return field.optionMap?.[value] ?? value;
}

async function tryGithubIssueFields(backend, owner, repo, issueNumber, fieldValues) {
  const configured = configuredGithubIssueFields(backend);
  const issue_field_values = [];
  for (const [name, value] of Object.entries(fieldValues)) {
    const field = configured[name];
    const mappedValue = field ? normalizeGithubIssueFieldValue(field, value) : undefined;
    if (field?.fieldId !== undefined && mappedValue !== undefined) {
      issue_field_values.push({ field_id: Number(field.fieldId), value: mappedValue });
    }
  }
  if (!issue_field_values.length || !capabilityEnabled(backend, owner, repo, 'issueFields')) return false;
  try {
    await githubRequest(backend, 'POST', `/repos/${owner}/${repo}/issues/${issueNumber}/issue-field-values`, {
      apiVersion: '2026-03-10',
      body: { issue_field_values },
    });
    return true;
  } catch (e) {
    markCapabilityUnavailable(backend, owner, repo, 'issueFields');
    return false;
  }
}
```

Use POST for metadata mirroring so unrelated issue fields remain untouched. Do
not use `PUT /repos/{owner}/{repo}/issues/{issueNumber}/issue-field-values`
unless the command intentionally owns the complete issue field value set. When a
configured mirror value must be cleared, use
`DELETE /repos/{owner}/{repo}/issues/{issueNumber}/issue-field-values/{issue_field_id}`
for that single field.

For issue dependencies, add helpers in Task 6 where item IDs can be resolved to
issue `id` values.

- [ ] **Step 6: Implement GitHub `list-repos` and `create-repo`**

Implement:

```js
async function cmdListReposGithub(args, backend) {
  const pathName = backend.tokenType === 'app-installation' ? '/installation/repositories' : '/user/repos';
  const repos = await githubPaginate(backend, pathName, backend.tokenType === 'app-installation' ? 'repositories' : null);
  return repos.map(githubRepoRow).sort((a, b) => a.slug.localeCompare(b.slug));
}
```

For PAT `/user/repos`, the response is an array. For app installation, the response has `repositories`.

Implement `cmdCreateRepoGithub`:

```js
async function cmdCreateRepoGithub(args, backend) {
  require_(args, ['slug']);
  const [owner, repo] = args.slug.split('/');
  const repoJson = (await githubRequest(backend, 'GET', `/repos/${owner}/${repo}`)).json;
  for (const label of GITHUB_BACKLOG_LABELS) {
    await ensureGithubLabel(backend, owner, repo, label);
  }
  return githubRepoRow(repoJson);
}
```

Handle label already-exists 422 as success inside `ensureGithubLabel`.

- [ ] **Step 7: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: GitHub repository command tests pass; Postgres tests remain green.

- [ ] **Step 8: Commit Task 4**

```bash
git add tools/backlog tests/run.sh
git commit -m "feat(backlog): add github repository commands"
```

### Task 5: GitHub Create/Get/Update Item Commands

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Extend fake GitHub server for issue create/get/patch**

Update the fake server to keep an in-memory `issues` map and handle:

```text
POST /repos/GourmetPro/gtm-claude-code/issues
GET /repos/gourmetpro/gtm-claude-code/issues/1
PATCH /repos/gourmetpro/gtm-claude-code/issues/1
POST /repos/gourmetpro/gtm-claude-code/issues/1/issue-field-values
PATCH /__test/issues/1
```

The created issue should include labels, timestamps, `html_url`, `number`,
numeric `id`, `state`, optional `type`, optional `issue_field_values`, and body.
The `/__test/issues/1` endpoint is test-only and mutates the in-memory issue so
tests can simulate human edits in GitHub.

- [ ] **Step 2: Add failing create/get/update tests**

Add:

```bash
test_backlog_github_create_get_update_item() {
  local tmp="$1"
  local pid port
  pid="$(start_fake_github "$tmp")"
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  port="$(cat "$tmp/fake-github.port")"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{ "default": "gh", "backends": [{ "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:$port" }] }
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "GitHub backend" --type engineering --priority p1 --body "Human body" \
    > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github create-item should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  assert_contains '"id": "gourmetpro--gtm-claude-code--1"' "$tmp/create.out" "github create id" || return 1
  assert_contains '"console_url": "https://github.com/GourmetPro/gtm-claude-code/issues/1"' "$tmp/create.out" "github console_url" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err" || {
      fail "github get-item should succeed; stderr was: $(<"$tmp/get.err")"
      return 1
    }
  assert_contains '"workstream": "tooling"' "$tmp/get.out" "github get workstream" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --status done --progress-note "Shipped" \
    > "$tmp/update.out" 2> "$tmp/update.err" || {
      fail "github update-item should succeed; stderr was: $(<"$tmp/update.err")"
      return 1
    }
  assert_contains '"status": "done"' "$tmp/update.out" "github update status" || return 1
}
```

Add two focused tests:

```bash
test_backlog_github_rejects_explicit_create_id() {
  local tmp="$1"
  local pid port
  pid="$(start_fake_github "$tmp")"
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  port="$(cat "$tmp/fake-github.port")"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{ "default": "gh", "backends": [{ "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:$port" }] }
JSON

  if BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "Bad ID" --type engineering --id explicit--id > "$tmp/out" 2> "$tmp/err"; then
    fail "github create-item --id should fail"
    return 1
  fi
  assert_contains "--id is not supported by github-issues backends" "$tmp/err" "github create id rejection" || return 1
}

test_backlog_github_read_tolerates_human_edited_status_drift() {
  local tmp="$1"
  local pid port
  pid="$(start_fake_github "$tmp")"
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  port="$(cat "$tmp/fake-github.port")"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{ "default": "gh", "backends": [{ "name": "gh", "type": "github-issues", "tokenEnv": "TEST_GITHUB_TOKEN", "apiBaseUrl": "http://127.0.0.1:$port" }] }
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "Drift" --type engineering > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github create drift fixture should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  curl -sS -X PATCH "http://127.0.0.1:$port/__test/issues/1" -d '{"state":"closed","labels":["backlog"]}' > /dev/null

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err" || {
      fail "github get drifted issue should succeed; stderr was: $(<"$tmp/get.err")"
      return 1
    }
  assert_contains '"status": "done"' "$tmp/get.out" "closed issue without status label maps to done" || return 1
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
bash tests/run.sh
```

Expected: create/get/update tests fail because item commands are not implemented.

- [ ] **Step 4: Implement issue row mapping**

Add:

```js
function githubIssueToBacklogItem(issue, repoSlug) {
  if (!issue.labels?.some((l) => labelName(l) === 'backlog')) fail(`not_backlog_item: ${repoSlug}#${issue.number}`);
  const parsed = parseFrontmatter(issue.body || '');
  const status = reconcileGithubStatus(issue, parsed.meta);
  return {
    id: githubIdFor(repoSlug, issue.number),
    workstream: parsed.meta.workstream || 'default',
    title: issue.title || '',
    body: parsed.body || '',
    status,
    priority: reconcileGithubPriority(issue, parsed.meta),
    type: reconcileGithubType(issue, parsed.meta),
    blocked_reason: parsed.meta.blocked_reason ?? null,
    abandoned_reason: parsed.meta.abandoned_reason ?? null,
    links: Array.isArray(parsed.meta.links) ? parsed.meta.links : [],
    source_context: parsed.meta.source_context ?? null,
    created_at: issue.created_at,
    updated_at: issue.updated_at,
    completed_at: status === 'done' ? issue.closed_at : null,
    repo: parsed.meta.repo || repoSlug,
    depends_on: Array.isArray(parsed.meta.depends_on) ? parsed.meta.depends_on : [],
    branch: parsed.meta.branch ?? null,
    progress_note: parsed.meta.progress_note ?? null,
    due_date: parsed.meta.due_date ?? null,
    console_url: issue.html_url,
  };
}
```

- [ ] **Step 5: Implement `create-item`**

Build labels from status `queued`, priority, type, and `backlog`. Format frontmatter plus human body. POST issue. Return mapped row.

Reject `--id` on GitHub before POST.

Before POST, ensure the baseline labels exist in the target repo unless the
backend config sets `skipEnsureLabels: true`. This avoids GitHub auto-creating
labels with arbitrary colors or rejecting the create because labels are missing.
If `features.issueTypes` maps the backlog type, include the native `type` in the
create body; if GitHub rejects the type, retry once without `type` and continue
with the `backlog/type:*` label fallback.

After POST, mirror configured issue fields with `tryGithubIssueFields`.
Failure to set optional issue fields should mark the capability unavailable and
still return the created backlog row.

- [ ] **Step 6: Implement `get-item`**

Parse GitHub ID, GET issue, map row, and return `blocks: []` for this task. Full dependency lookup lands in Task 6.

- [ ] **Step 7: Implement `update-item`**

GET issue, map current row, apply existing write validations, merge frontmatter updates, replace only human body when `--body` is passed, compute labels, and PATCH the issue.

If the update changes a configured native issue type, include `type` in the PATCH
body. If GitHub rejects it, retry once without `type` and keep labels as fallback.
After PATCH, call `tryGithubIssueFields` for configured issue fields.

State mapping:

```js
const closed = nextStatus === 'done' || nextStatus === 'abandoned';
body.state = closed ? 'closed' : 'open';
if (nextStatus === 'done') body.state_reason = 'completed';
if (nextStatus === 'abandoned') body.state_reason = 'not_planned';
```

- [ ] **Step 8: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: create/get/update GitHub tests pass.

- [ ] **Step 9: Commit Task 5**

```bash
git add tools/backlog tests/run.sh
git commit -m "feat(backlog): manage github issue items"
```

### Task 6: GitHub List, Search, Summarize, And Blocks

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] **Step 1: Extend fake GitHub server for search and issue listing**

Add handlers for:

```text
GET /repos/GourmetPro/gtm-claude-code/issues
GET /search/issues
GET /repos/gourmetpro/gtm-claude-code/issues/1/dependencies/blocked_by
POST /repos/gourmetpro/gtm-claude-code/issues/1/dependencies/blocked_by
DELETE /repos/gourmetpro/gtm-claude-code/issues/1/dependencies/blocked_by/2
GET /repos/gourmetpro/gtm-claude-code/issues/2/dependencies/blocking
```

Return the in-memory issues as `items` for search and as an array for repo issue
listing. Store native dependency relationships in memory using issue numeric
`id`, not backlog string ID, to match GitHub's API.

- [ ] **Step 2: Add failing tests for list/summarize/blocks**

Add a test that creates two issues, updates one dependency, then asserts:

```bash
backlog list-items --backend gh --repo GourmetPro/gtm-claude-code --status queued
backlog list-items --backend gh --q GitHub
backlog summarize --backend gh --repo GourmetPro/gtm-claude-code
backlog get-item --backend gh --id gourmetpro--gtm-claude-code--1
```

Expected assertions:

```bash
assert_contains '"status": "queued"' "$tmp/list.out" "list-items status filter"
assert_contains '"workstream": "tooling"' "$tmp/summary.out" "summarize workstream"
assert_contains '"blocks": [' "$tmp/get.out" "get-item includes blocks"
```

The test should set `--depends-on gourmetpro--gtm-claude-code--1` on issue 2,
then call `get-item --id gourmetpro--gtm-claude-code--1` and assert the `blocks`
array includes issue 2. This proves the native `dependencies/blocking` path works
when available.

- [ ] **Step 3: Implement GitHub pagination helper**

Add:

```js
async function githubPaginate(backend, pathName, arrayKey, query = {}) {
  const rows = [];
  for (let page = 1; page <= Number(backend.pageCap || 10); page++) {
    const { json } = await githubRequest(backend, 'GET', pathName, { query: { ...query, per_page: 100, page } });
    const pageRows = arrayKey ? json[arrayKey] : json;
    if (!Array.isArray(pageRows) || !pageRows.length) break;
    rows.push(...pageRows);
    if (pageRows.length < 100) break;
  }
  return rows;
}
```

Call sites must pass the correct shape:

```js
await githubPaginate(backend, '/user/repos', null);
await githubPaginate(backend, '/installation/repositories', 'repositories');
await githubPaginate(backend, '/search/issues', 'items', { q: 'type:issue label:backlog' });
await githubPaginate(backend, `/repos/${owner}/${repo}/issues`, null, { labels: 'backlog', state: 'all' });
```

- [ ] **Step 4: Implement `list-items`**

With `--repo`, call `/repos/{owner}/{repo}/issues` with `labels=backlog`, `state=all`, `sort=created`, `direction=desc`.

Without `--repo`, call `/search/issues` with query:

```text
type:issue label:backlog
```

Append the `--q` text to the search query when provided. Map all issues to rows, filter client-side by reconciled status/priority/type/workstream, sort by priority order and created_at desc, then apply offset/limit.

- [ ] **Step 5: Implement `summarize`**

Reuse `cmdListItemsGithub` with a high bounded limit from backend config or default cap, then group by `workstream` and `status`.

- [ ] **Step 6: Implement native dependency helpers and fallback `blocks`**

Add:

```js
async function getGithubBlockedBy(backend, owner, repo, issueNumber) {
  if (!capabilityEnabled(backend, owner, repo, 'issueDependencies')) return null;
  try {
    return await githubPaginate(backend, `/repos/${owner}/${repo}/issues/${issueNumber}/dependencies/blocked_by`, null);
  } catch (e) {
    markCapabilityUnavailable(backend, owner, repo, 'issueDependencies');
    return null;
  }
}

async function getGithubBlocking(backend, owner, repo, issueNumber) {
  if (!capabilityEnabled(backend, owner, repo, 'issueDependencies')) return null;
  try {
    return await githubPaginate(backend, `/repos/${owner}/${repo}/issues/${issueNumber}/dependencies/blocking`, null);
  } catch (e) {
    markCapabilityUnavailable(backend, owner, repo, 'issueDependencies');
    return null;
  }
}
```

For `update-item --depends-on`, resolve each dependency backlog ID to a GitHub
issue and use POST/DELETE `/dependencies/blocked_by` when native dependencies
are enabled. If resolving or updating native dependencies fails because the
feature is unavailable, update frontmatter `depends_on` instead.

For `get-item.blocks`, prefer `dependencies/blocking`. If unavailable, search for
the item ID string within backlog issues:

```text
type:issue label:backlog "<id>"
```

Map candidates, parse `depends_on`, and include rows whose `depends_on` contains the ID. Return `id`, `title`, `status`, and `repo`.

- [ ] **Step 7: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: list/search/summarize/blocks tests pass.

- [ ] **Step 8: Commit Task 6**

```bash
git add tools/backlog tests/run.sh
git commit -m "feat(backlog): list and summarize github backlog issues"
```

### Task 7: Installer, README, Formula, And Help Text

**Files:**
- Modify: `tools/backlog`
- Modify: `install/backlog`
- Modify: `README.md`
- Modify: `Formula/backlog.rb`
- Test: `tests/run.sh`

- [ ] **Step 1: Add failing docs/installer/formula tests**

Update existing tests:

```bash
assert_contains "backlog.json" "$tmp/config/backlog.json" "installer JSON config path"
assert_contains '"backends"' "$tmp/config/backlog.json" "installer writes backend array"
assert_contains 'BACKLOG_BACKEND' "$tmp/help.out" "help documents backend override"
assert_contains 'github-issues' "$tmp/help.out" "help documents github backend"
assert_contains '~/.config/ai-tools/backlog.json' "$formula" "formula caveats mention JSON config"
```

Add a new installer test that existing `.conf` is not overwritten when present.

- [ ] **Step 2: Run tests to verify docs/installer expectations fail**

Run:

```bash
bash tests/run.sh
```

Expected: installer/formula/help assertions fail.

- [ ] **Step 3: Update `install/backlog`**

Change default config to `~/.config/ai-tools/backlog.json`.

When `--database-url` is provided, write:

```json
{
  "default": "gtm-console",
  "backends": [
    {
      "name": "gtm-console",
      "type": "postgres",
      "databaseUrl": "postgres://install.example/backlog"
    }
  ]
}
```

When no URL is provided, write a template with `databaseUrlEnv`.

If an old `.conf` exists and no JSON exists, do not delete or rewrite it. Print a note that the CLI still supports the old config.

- [ ] **Step 4: Update `tools/backlog` help**

General help must document:

```text
Configuration:
  Reads ~/.config/ai-tools/backlog.json by default.
  Set --backend <name> to choose a backend for one command.
  BACKLOG_BACKEND is a fallback backend selector for automation.
  Old ~/.config/ai-tools/backlog.conf and BACKLOG_DATABASE_URL remain supported for Postgres compatibility.
```

Add a short GitHub limitations block.

- [ ] **Step 5: Update README and formula caveats**

README should include:

```json
{
  "default": "gtm-console",
  "backends": [
    { "name": "gtm-console", "type": "postgres", "databaseUrlEnv": "BACKLOG_DATABASE_URL" },
    { "name": "github", "type": "github-issues", "tokenEnv": "GITHUB_TOKEN" }
  ]
}
```

Formula caveats should point to `~/.config/ai-tools/backlog.json` and mention old `.conf` compatibility.

- [ ] **Step 6: Run tests**

Run:

```bash
bash tests/run.sh
```

Expected: docs/installer/formula tests pass.

- [ ] **Step 7: Commit Task 7**

```bash
git add tools/backlog install/backlog README.md Formula/backlog.rb tests/run.sh
git commit -m "docs(backlog): document backend configuration"
```

### Task 8: Full Verification And Polish

**Files:**
- Modify: `tools/backlog`
- Modify: `tests/run.sh`
- Modify: `install/backlog`
- Modify: `README.md`
- Modify: `Formula/backlog.rb`
- Modify: any touched formula or installer file that a verification command identifies by exact path.

- [ ] **Step 1: Run required repository verification**

Run:

```bash
bash tests/run.sh
zsh -n tools/wt
sh -n tools/envrun
node --check tools/backlog
sh -n install/wt
sh -n install/envrun
sh -n install/backlog
bash -n scripts/bump-homebrew-release
ruby -c Formula/wt.rb
ruby -c Formula/envrun.rb
ruby -c Formula/backlog.rb
brew style Formula/wt.rb Formula/envrun.rb Formula/backlog.rb
git diff --check
```

Expected: all pass. If `brew style` is unavailable in the environment, record the failure and run all other checks.

- [ ] **Step 2: Fix verification failures**

For each failure, make the smallest scoped patch and rerun the failing command.

- [ ] **Step 3: Run final git status**

Run:

```bash
git status --short
```

Expected: only intentional tracked changes are present. `tmp/` may remain untracked scratch and must not be committed.

- [ ] **Step 4: Commit final verification fixes if any**

If verification required changes:

```bash
git add tools/backlog tests/run.sh install/backlog README.md Formula/backlog.rb
git commit -m "fix(backlog): polish backend implementation"
```

If no changes were needed, do not create an empty commit.

## Final Review

After all tasks are complete, dispatch a final code review subagent for the entire branch. The reviewer should check:

- Postgres legacy behavior is unchanged.
- JSON backend config selection works.
- GitHub commands have CLI parity.
- GitHub adapter does not require real network in tests.
- No secrets or local absolute paths were added to tracked files.
- `tmp/` is not committed.
