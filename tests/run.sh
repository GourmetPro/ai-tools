#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
CURRENT_TEST_FAILED=0
FAKE_GITHUB_PID=""

fail() {
  printf 'not ok - %s\n' "$CURRENT_TEST"
  printf '  %s\n' "$1"
  FAILED=1
  CURRENT_TEST_FAILED=1
}

pass() {
  printf 'ok - %s\n' "$CURRENT_TEST"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$message: expected [$expected], got [$actual]"
    return 1
  fi
}

assert_contains() {
  local needle="$1"
  local file="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$message: expected to find [$needle] in $file"
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  local message="$2"
  if [[ ! -f "$file" ]]; then
    fail "$message: missing $file"
    return 1
  fi
}

formula_version() {
  local formula="$1"
  sed -nE 's/^[[:space:]]*version "([0-9]+[.][0-9]+[.][0-9]+)".*/\1/p' "$formula" | head -n 1
}

assert_formula_release_metadata() {
  local formula="$1"
  local name="$2"
  local version
  version="$(formula_version "$formula")"
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    fail "$name formula version should be SemVer; got [$version]"
    return 1
  fi
  assert_contains "tag:      \"v$version\"," "$formula" "$name formula tag matches version" || return 1
  if ! grep -Eq 'revision: "[0-9a-f]{40}"' "$formula"; then
    fail "$name formula revision should be a 40-character Git SHA"
    return 1
  fi
}

with_tmpdir() {
  local fn="$1"
  local tmp
  tmp="$(mktemp -d)"
  "$fn" "$tmp"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

run_test() {
  CURRENT_TEST="$1"
  CURRENT_TEST_FAILED=0
  shift
  if "$@"; then
    pass
  elif [[ "$CURRENT_TEST_FAILED" -eq 0 ]]; then
    fail "test command failed"
  fi
}

test_wt_runs_as_executable() {
  local output
  output="$("$ROOT/tools/wt" --help 2>&1)" || {
    fail "tools/wt --help should exit 0; output was: $output"
    return 1
  }
  assert_eq 'Usage: wt <name> [--from <branch>] [--model <model>] [--prompt "..."] [--tmux]' "$output" "wt help output"
}

test_wt_passes_model_to_claude() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/repo"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$PWD" > "$CLAUDE_PWD_FILE"' \
    'printf "%s\n" "$@" > "$CLAUDE_ARGS_FILE"' > "$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"

  git -C "$tmp/repo" init -q -b main || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp/repo" config user.email "test@example.invalid"
  git -C "$tmp/repo" config user.name "Test Runner"
  printf 'initial\n' > "$tmp/repo/README.md"
  git -C "$tmp/repo" add README.md
  git -C "$tmp/repo" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  local args="$tmp/claude.args"
  local pwd_file="$tmp/claude.pwd"
  (
    cd "$tmp/repo" &&
      PATH="$tmp/bin:$PATH" CLAUDE_ARGS_FILE="$args" CLAUDE_PWD_FILE="$pwd_file" \
        "$ROOT/tools/wt" feature --model opus --prompt "do work" --tmux
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "wt should accept --model and launch claude; stderr was: $(<"$tmp/err")"
    return 1
  }

  local expected_args=$'--remote-control\nfeature\n--name\nfeature\n--model\nopus\n--tmux\ndo work'
  local repo_physical
  repo_physical="$(cd "$tmp/repo" && pwd -P)"
  assert_eq "$expected_args" "$(<"$args")" "claude args include model" || return 1
  assert_eq "$repo_physical/.claude/worktrees/feature" "$(<"$pwd_file")" "claude launched in worktree"
}

test_wt_copies_env_local() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/repo"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' > "$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"

  git -C "$tmp/repo" init -q -b main || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp/repo" config user.email "test@example.invalid"
  git -C "$tmp/repo" config user.name "Test Runner"
  printf 'initial\n' > "$tmp/repo/README.md"
  git -C "$tmp/repo" add README.md
  git -C "$tmp/repo" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  printf 'SHARED=linked\n' > "$tmp/repo/.env"
  printf 'LOCAL=copied\n' > "$tmp/repo/.env.local"

  (
    cd "$tmp/repo" &&
      PATH="$tmp/bin:$PATH" "$ROOT/tools/wt" feature
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "wt should launch claude after preparing env files; stderr was: $(<"$tmp/err")"
    return 1
  }

  local worktree_env="$tmp/repo/.claude/worktrees/feature/.env"
  local worktree_env_local="$tmp/repo/.claude/worktrees/feature/.env.local"
  [[ -L "$worktree_env" ]] || {
    fail "wt should still symlink .env"
    return 1
  }
  [[ -f "$worktree_env_local" && ! -L "$worktree_env_local" ]] || {
    fail "wt should copy .env.local as a regular file"
    return 1
  }
  assert_eq 'LOCAL=copied' "$(<"$worktree_env_local")" "copied .env.local contents" || return 1
}

test_envrun_runs_as_executable() {
  local output
  output="$("$ROOT/tools/envrun" --help 2>&1)" || {
    fail "tools/envrun --help should exit 0; output was: $output"
    return 1
  }
  assert_contains 'Usage: envrun [--test|--production] [-c COMMAND | -- COMMAND [ARG...]]' <(printf '%s\n' "$output") "envrun help output"
}

test_envrun_loads_local_env_files_from_git_root() {
  local tmp="$1"
  mkdir -p "$tmp/repo/subdir"

  git -C "$tmp/repo" init -q -b main || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp/repo" config user.email "test@example.invalid"
  git -C "$tmp/repo" config user.name "Test Runner"
  printf 'initial\n' > "$tmp/repo/README.md"
  git -C "$tmp/repo" add README.md
  git -C "$tmp/repo" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  printf '%s\n' \
    'SHARED=from-env' \
    'OVERRIDE=from-env' > "$tmp/repo/.env"
  printf '%s\n' \
    'LOCAL_ONLY=from-local' \
    'OVERRIDE=from-local' > "$tmp/repo/.env.local"

  (
    cd "$tmp/repo/subdir" &&
      "$ROOT/tools/envrun" sh -c 'printf "%s|%s|%s\n" "$SHARED" "$LOCAL_ONLY" "$OVERRIDE"'
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "envrun should load repo-root .env files; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq 'from-env|from-local|from-local' "$(<"$tmp/out")" "envrun exported env values"
}

test_envrun_shell_command_expands_loaded_env() {
  local tmp="$1"
  mkdir -p "$tmp/repo"
  printf 'POSTGRES_URL=postgres://local.example/test\n' > "$tmp/repo/.env.local"

  (
    cd "$tmp/repo" &&
      "$ROOT/tools/envrun" -c 'printf "%s\n" "$POSTGRES_URL"'
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "envrun -c should execute after loading .env.local; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq 'postgres://local.example/test' "$(<"$tmp/out")" "envrun -c expands loaded env"
}

test_envrun_test_flag_loads_test_env() {
  local tmp="$1"
  mkdir -p "$tmp/repo"
  printf 'DATABASE_URL=postgres://base.example/app\n' > "$tmp/repo/.env"
  printf 'DATABASE_URL=postgres://local.example/app\n' > "$tmp/repo/.env.local"
  printf '%s\n' \
    'DATABASE_URL=postgres://test.example/app' \
    'TEST_ONLY=enabled' > "$tmp/repo/.env.test"

  (
    cd "$tmp/repo" &&
      "$ROOT/tools/envrun" --test -c 'printf "%s|%s\n" "$DATABASE_URL" "$TEST_ONLY"'
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "envrun --test should load .env.test; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq 'postgres://test.example/app|enabled' "$(<"$tmp/out")" "envrun --test env values"
}

test_envrun_production_flag_loads_production_env() {
  local tmp="$1"
  mkdir -p "$tmp/repo"
  printf 'DATABASE_URL=postgres://base.example/app\n' > "$tmp/repo/.env"
  printf 'DATABASE_URL=postgres://local.example/app\n' > "$tmp/repo/.env.local"
  printf '%s\n' \
    'DATABASE_URL=postgres://production.example/app' \
    'PRODUCTION_ONLY=enabled' > "$tmp/repo/.env.production"

  (
    cd "$tmp/repo" &&
      "$ROOT/tools/envrun" --production -c 'printf "%s|%s\n" "$DATABASE_URL" "$PRODUCTION_ONLY"'
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "envrun --production should load .env.production; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq 'postgres://production.example/app|enabled' "$(<"$tmp/out")" "envrun --production env values"
}

test_backlog_reads_database_url_from_config() {
  local tmp="$1"
  mkdir -p "$tmp/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  local config="$tmp/backlog.conf"
  printf '%s\n' \
    '# Backlog CLI configuration' \
    "DATABASE_URL='postgres://user:pass@example.com/backlog?sslmode=require'" > "$config"

  local output="$tmp/out.json"
  local args="$tmp/psql.args"
  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$args" BACKLOG_CONFIG="$config" BACKLOG_DATABASE_URL= \
    "$ROOT/tools/backlog" list-repos > "$output" 2> "$tmp/err" || {
      fail "backlog list-repos should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq '[]' "$(<"$output")" "backlog JSON output" || return 1
  assert_eq 'postgres://user:pass@example.com/backlog?sslmode=require' "$(head -n 1 "$args")" "psql database URL argument"
}

test_backlog_explains_missing_config() {
  local tmp="$1"
  if BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err"; then
    fail "backlog should fail when BACKLOG_CONFIG points to a missing file"
    return 1
  fi
  assert_contains "DATABASE_URL is not configured" "$tmp/err" "missing config error" || return 1
  assert_contains "$tmp/missing.conf" "$tmp/err" "missing config path" || return 1
}

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

  assert_eq 'postgres://json.example/backlog' "$(head -n 1 "$tmp/psql.args")" "JSON postgres database URL selected" || return 1
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

test_backlog_list_backends_redacts_configured_secrets() {
  local tmp="$1"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<'JSON'
{
  "default": "gh",
  "backends": [
    { "name": "pg", "type": "postgres", "databaseUrl": "postgres://secret.example/backlog" },
    { "name": "gh", "type": "github-issues", "token": "secret-token" }
  ]
}
JSON

  BACKLOG_CONFIG="$tmp/config/backlog.json" "$ROOT/tools/backlog" list-backends > "$tmp/out" 2> "$tmp/err" || {
    fail "backlog list-backends should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_contains '"name": "pg"' "$tmp/out" "postgres backend listed" || return 1
  assert_contains '"has_database_url": true' "$tmp/out" "database URL presence listed" || return 1
  assert_contains '"name": "gh"' "$tmp/out" "github backend listed" || return 1
  assert_contains '"default": true' "$tmp/out" "default backend listed" || return 1
  assert_contains '"has_token": true' "$tmp/out" "token presence listed" || return 1
  if grep -Fq 'secret.example' "$tmp/out" || grep -Fq 'secret-token' "$tmp/out"; then
    fail "list-backends must not print secret values"
    return 1
  fi
}

start_fake_github() {
  local tmp="$1"
  local script="$tmp/fake-github.js"
  cat > "$script" <<'JS'
const http = require('http');
const disableNativeMetadata = process.env.FAKE_GITHUB_DISABLE_NATIVE_METADATA === '1';
const repo = {
  full_name: 'GourmetPro/gtm-claude-code',
  name: 'gtm-claude-code',
  default_branch: 'main',
  html_url: 'https://github.com/GourmetPro/gtm-claude-code',
  created_at: '2026-01-01T00:00:00Z'
};
const labels = new Set();
const issues = new Map();
const blockedBy = new Map();
const commentsByIssue = new Map();
const fieldLog = [];
const schemaLog = [];
const headerLog = [];
const issueFields = [
  { id: 101, name: 'Priority', data_type: 'single_select', options: [
    { id: 1001, name: 'Urgent' }, { id: 1002, name: 'High' },
    { id: 1003, name: 'Medium' }, { id: 1004, name: 'Low' }
  ] },
  { id: 104, name: 'Target date', data_type: 'date' }
];
const issueTypes = [
  { id: 201, name: 'Task', is_enabled: true },
  { id: 202, name: 'Bug', is_enabled: true },
  { id: 203, name: 'Feature', is_enabled: true }
];
let nextFieldId = 105;
let nextTypeId = 204;
let nextNumber = 1;
let nextCommentId = 5001;
const now = '2026-01-02T00:00:00Z';

function send(res, status, value) {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(value));
}
function repoPath(pathname) {
  const m = pathname.match(/^\/repos\/([^/]+)\/([^/]+)(.*)$/);
  if (!m) return null;
  return { owner: m[1], repo: m[2], rest: m[3] || '' };
}
function issueJson(number) {
  return issues.get(Number(number));
}
function allIssues() {
  return [...issues.values()];
}
function allComments() {
  return [...commentsByIssue.values()].flat();
}
function mutateIssue(issue, patch) {
  if (patch.title !== undefined) issue.title = patch.title;
  if (patch.body !== undefined) issue.body = patch.body;
  if (patch.labels !== undefined) issue.labels = patch.labels.map((name) => ({ name }));
  if (patch.state !== undefined) {
    issue.state = patch.state;
    issue.closed_at = patch.state === 'closed' ? now : null;
  }
  if (patch.type !== undefined) issue.type = { name: patch.type };
  issue.updated_at = now;
  return issue;
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://127.0.0.1');
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    const parsed = body ? JSON.parse(body) : {};
    if (url.pathname === '/user/repos' || url.pathname.includes('/issue-field-values') || url.pathname.match(/^\/orgs\/[^/]+\/issue-(fields|types)$/)) {
      headerLog.push({ method: req.method, path: url.pathname, version: req.headers['x-github-api-version'], authorization: req.headers.authorization });
    }
    if (req.method === 'GET' && url.pathname === '/user/repos') return send(res, 200, [repo]);
    if (req.method === 'GET' && url.pathname === '/installation/repositories') return send(res, 200, { repositories: [repo] });
    if (req.method === 'GET' && url.pathname === '/search/issues') return send(res, 200, { items: allIssues() });
    if (req.method === 'GET' && url.pathname === '/__test/field-log') return send(res, 200, fieldLog);
    if (req.method === 'GET' && url.pathname === '/__test/schema-log') return send(res, 200, schemaLog);
    if (req.method === 'GET' && url.pathname === '/__test/issues') return send(res, 200, allIssues());
    if (req.method === 'GET' && url.pathname === '/__test/comments') return send(res, 200, allComments());
    if (req.method === 'GET' && url.pathname === '/__test/headers') return send(res, 200, headerLog);
    if (req.method === 'GET' && /^\/orgs\/GourmetPro\/issue-fields$/i.test(url.pathname)) {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue fields unavailable' });
      return send(res, 200, issueFields);
    }
    if (req.method === 'POST' && /^\/orgs\/GourmetPro\/issue-fields$/i.test(url.pathname)) {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue fields unavailable' });
      if (parsed.name === 'Status') return send(res, 422, { message: 'Status is a reserved issue field name' });
      const field = { id: nextFieldId++, ...parsed };
      issueFields.push(field);
      schemaLog.push({ kind: 'field', ...field });
      return send(res, 200, field);
    }
    if (req.method === 'GET' && /^\/orgs\/GourmetPro\/issue-types$/i.test(url.pathname)) {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue types unavailable' });
      return send(res, 200, issueTypes);
    }
    if (req.method === 'POST' && /^\/orgs\/GourmetPro\/issue-types$/i.test(url.pathname)) {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue types unavailable' });
      const type = { id: nextTypeId++, ...parsed };
      issueTypes.push(type);
      schemaLog.push({ kind: 'type', ...type });
      return send(res, 200, type);
    }
    if (req.method === 'PATCH' && url.pathname.startsWith('/__test/issues/')) {
      const number = Number(url.pathname.split('/').pop());
      const issue = issueJson(number);
      if (!issue) return send(res, 404, { message: 'not found' });
      if (parsed.labels) parsed.labels = parsed.labels.map((name) => ({ name }));
      Object.assign(issue, parsed);
      return send(res, 200, issue);
    }

    const rp = repoPath(url.pathname);
    if (!rp) return send(res, 404, { message: `not found: ${req.method} ${url.pathname}` });
    if (req.method === 'GET' && rp.rest === '') return send(res, 200, repo);
    if (req.method === 'GET' && rp.rest === '/issue-types') {
      return disableNativeMetadata ? send(res, 404, { message: 'issue types unavailable' }) : send(res, 200, issueTypes);
    }
    if (req.method === 'POST' && rp.rest === '/labels') {
      labels.add(parsed.name);
      return send(res, labels.has(parsed.name) ? 201 : 422, parsed);
    }
    if (req.method === 'GET' && rp.rest === '/issues') return send(res, 200, allIssues());
    if (req.method === 'POST' && rp.rest === '/issues') {
      if (disableNativeMetadata && parsed.type) return send(res, 422, { message: 'type unavailable' });
      const number = nextNumber++;
      const issue = {
        id: 1000 + number,
        number,
        title: parsed.title,
        body: parsed.body || '',
        labels: (parsed.labels || []).map((name) => ({ name })),
        state: 'open',
        type: parsed.type ? { name: parsed.type } : null,
        field_values: [{ issue_field_id: 999, issue_field_name: 'Unrelated', data_type: 'text', value: 'keep' }],
        html_url: `${repo.html_url}/issues/${number}`,
        repository_url: 'https://api.github.test/repos/GourmetPro/gtm-claude-code',
        repository: repo,
        created_at: now,
        updated_at: now,
        closed_at: null
      };
      issues.set(number, issue);
      commentsByIssue.set(number, []);
      return send(res, 201, issue);
    }

    const issueMatch = rp.rest.match(/^\/issues\/([0-9]+)(.*)$/);
    if (!issueMatch) return send(res, 404, { message: `not found: ${req.method} ${url.pathname}` });
    const number = Number(issueMatch[1]);
    const suffix = issueMatch[2] || '';
    const issue = issueJson(number);
    if (!issue) return send(res, 404, { message: 'not found' });
    if (req.method === 'GET' && suffix === '') return send(res, 200, issue);
    if (req.method === 'PATCH' && suffix === '') {
      if (disableNativeMetadata && parsed.type) return send(res, 422, { message: 'type unavailable' });
      return send(res, 200, mutateIssue(issue, parsed));
    }
    if (req.method === 'GET' && suffix === '/comments') {
      const rows = commentsByIssue.get(number) || [];
      const perPage = Number(url.searchParams.get('per_page') || 30);
      const page = Number(url.searchParams.get('page') || 1);
      return send(res, 200, rows.slice((page - 1) * perPage, page * perPage));
    }
    if (req.method === 'POST' && suffix === '/comments') {
      const id = nextCommentId++;
      const comment = {
        id,
        body: parsed.body,
        user: { login: 'agent-bot' },
        created_at: now,
        updated_at: now,
        html_url: `${issue.html_url}#issuecomment-${id}`
      };
      commentsByIssue.get(number).push(comment);
      return send(res, 201, comment);
    }
    if (req.method === 'GET' && suffix === '/issue-field-values') {
      return disableNativeMetadata ? send(res, 404, { message: 'issue fields unavailable' }) : send(res, 200, issue.field_values);
    }
    if (req.method === 'POST' && suffix === '/issue-field-values') {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue fields unavailable' });
      for (const value of parsed.issue_field_values || []) {
        fieldLog.push({ issue: number, ...value });
        const field = issueFields.find((candidate) => Number(candidate.id) === Number(value.field_id));
        const idx = issue.field_values.findIndex((v) => Number(v.issue_field_id) === Number(value.field_id));
        const next = {
          issue_field_id: value.field_id,
          issue_field_name: field?.name || `field-${value.field_id}`,
          data_type: field?.data_type || 'text',
          value: value.value,
          ...(field?.data_type === 'single_select' ? { single_select_option: { name: value.value } } : {})
        };
        if (idx === -1) issue.field_values.push(next);
        else issue.field_values[idx] = { ...issue.field_values[idx], ...next };
      }
      return send(res, 200, issue.field_values);
    }
    const delField = suffix.match(/^\/issue-field-values\/([0-9]+)$/);
    if (req.method === 'DELETE' && delField) {
      if (disableNativeMetadata) return send(res, 404, { message: 'issue fields unavailable' });
      fieldLog.push({ issue: number, deleted_field_id: Number(delField[1]) });
      issue.field_values = issue.field_values.filter((v) => Number(v.issue_field_id) !== Number(delField[1]));
      return send(res, 204, {});
    }
    if (req.method === 'GET' && suffix === '/dependencies/blocked_by') {
      const ids = blockedBy.get(number) || new Set();
      return send(res, 200, allIssues().filter((i) => ids.has(i.id)));
    }
    if (req.method === 'POST' && suffix === '/dependencies/blocked_by') {
      if (!blockedBy.has(number)) blockedBy.set(number, new Set());
      blockedBy.get(number).add(Number(parsed.issue_id));
      return send(res, 201, {});
    }
    const delDep = suffix.match(/^\/dependencies\/blocked_by\/([0-9]+)$/);
    if (req.method === 'DELETE' && delDep) {
      if (blockedBy.has(number)) blockedBy.get(number).delete(Number(delDep[1]));
      return send(res, 204, {});
    }
    if (req.method === 'GET' && suffix === '/dependencies/blocking') {
      const targetId = issue.id;
      const rows = allIssues().filter((candidate) => {
        const ids = blockedBy.get(candidate.number);
        return ids && ids.has(targetId);
      });
      return send(res, 200, rows);
    }
    return send(res, 404, { message: `not found: ${req.method} ${url.pathname}` });
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
  FAKE_GITHUB_PID="$pid"
}

write_github_config() {
  local tmp="$1"
  local port="$2"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{
  "default": "gh",
  "backends": [
    {
      "name": "gh",
      "type": "github-issues",
      "tokenEnv": "TEST_GITHUB_TOKEN",
      "apiBaseUrl": "http://127.0.0.1:$port",
      "features": { "issueDependencies": "auto" }
    }
  ]
}
JSON
}

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

test_backlog_github_id_and_body_metadata_helpers() {
  local tmp="$1"

  BACKLOG_TEST_HELPERS=1 "$ROOT/tools/backlog" __test-github-id \
    --repo "GourmetPro/repo.with_under--dash" \
    --number 123 > "$tmp/id.out" 2> "$tmp/id.err" || {
      fail "github id helper should succeed; stderr was: $(<"$tmp/id.err")"
      return 1
    }
  assert_eq 'gourmetpro--repo.with_under--dash--123' "$(<"$tmp/id.out")" "lossless github id" || return 1

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

  assert_contains '<!-- backlog-metadata:v2 ' "$tmp/front.out" "body stores invisible backlog metadata" || return 1
  assert_contains '"workstream":"new"' "$tmp/front.out" "body metadata updates workstream" || return 1
  assert_contains '"unknown_key":"preserve me"' "$tmp/front.out" "body metadata preserves unknown keys" || return 1
  assert_contains '## Related context' "$tmp/front.out" "body renders related links cleanly" || return 1
  assert_contains '[example.com](https://example.com)' "$tmp/front.out" "body renders URL link" || return 1
  assert_contains 'Not frontmatter.' "$tmp/front.out" "human body preserved" || return 1
  if [[ "$(head -n 1 "$tmp/front.out")" == '---' ]] || grep -Eq '^workstream:' "$tmp/front.out"; then
    fail "body metadata helper must not emit visible YAML frontmatter"
    return 1
  fi

  printf '%s' "$(<"$tmp/front.out")" > "$tmp/front-once.md"
  BACKLOG_TEST_HELPERS=1 "$ROOT/tools/backlog" __test-frontmatter-roundtrip \
    --file "$tmp/front-once.md" \
    --set '{"workstream":"new","links":[{"kind":"url","url":"https://example.com"}]}' \
    > "$tmp/front-twice.out" 2> "$tmp/front-twice.err" || {
      fail "second frontmatter roundtrip should succeed; stderr was: $(<"$tmp/front-twice.err")"
      return 1
    }
  assert_eq "$(<"$tmp/front.out")" "$(<"$tmp/front-twice.out")" "body metadata roundtrip is byte-stable"
}

test_backlog_github_repository_commands() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-repos > "$tmp/list.out" 2> "$tmp/list.err" || {
      fail "github list-repos should succeed; stderr was: $(<"$tmp/list.err")"
      return 1
    }
  assert_contains '"slug": "GourmetPro/gtm-claude-code"' "$tmp/list.out" "github repo slug" || return 1
  assert_contains '"short_slug": "gourmetpro--gtm-claude-code"' "$tmp/list.out" "github repo short slug" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-repo --slug GourmetPro/gtm-claude-code > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github create-repo should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }
  assert_contains '"slug": "GourmetPro/gtm-claude-code"' "$tmp/create.out" "github create-repo slug" || return 1
  curl -sS "http://127.0.0.1:$port/__test/headers" > "$tmp/headers.out"
  assert_contains '"path":"/orgs/GourmetPro/issue-fields"' "$tmp/headers.out" "github probes organization issue fields" || return 1
  curl -sS "http://127.0.0.1:$port/__test/schema-log" > "$tmp/schema.out"
  assert_contains '"name":"Workstream"' "$tmp/schema.out" "github provisions missing backlog issue fields" || return 1
  assert_contains '"name":"Backlog status"' "$tmp/schema.out" "github avoids GitHub reserved Status field name" || return 1
  assert_contains '"name":"Engineering"' "$tmp/schema.out" "github provisions missing backlog issue types" || return 1
  if grep -Fq '"name":"Priority"' "$tmp/schema.out" || grep -Fq '"name":"Target date"' "$tmp/schema.out"; then
    fail "github must reuse existing Priority and Target date fields"
    return 1
  fi
  assert_contains '"version":"2026-03-10"' "$tmp/headers.out" "github issue field probe uses current API version" || return 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_literal_token_config() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"

  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<JSON
{
  "default": "gh",
  "backends": [
    { "name": "gh", "type": "github-issues", "token": "literal-test-token", "apiBaseUrl": "http://127.0.0.1:$port" }
  ]
}
JSON

  env -u GITHUB_TOKEN -u GH_TOKEN -u TEST_GITHUB_TOKEN \
    BACKLOG_CONFIG="$tmp/config/backlog.json" \
    "$ROOT/tools/backlog" list-repos > "$tmp/list.out" 2> "$tmp/list.err" || {
      fail "github literal token config should succeed without token env; stderr was: $(<"$tmp/list.err")"
      return 1
    }

  curl -sS "http://127.0.0.1:$port/__test/headers" > "$tmp/headers.out"
  assert_contains '"path":"/user/repos"' "$tmp/headers.out" "github literal token request path" || return 1
  assert_contains '"authorization":"Bearer literal-test-token"' "$tmp/headers.out" "github literal token auth header" || return 1

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_create_get_update_item_and_fields() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "GitHub backend" --type engineering --priority p1 --body "Human body" \
      --source-context "Decision brief" --progress-note "Ready" --due-date 2026-07-18 \
      --links '[{"kind":"url","label":"Decision brief","url":"https://example.com/brief"}]' \
    > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github create-item should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  assert_contains '"id": "gourmetpro--gtm-claude-code--1"' "$tmp/create.out" "github create id" || return 1
  assert_contains '"console_url": "https://github.com/GourmetPro/gtm-claude-code/issues/1"' "$tmp/create.out" "github console_url" || return 1
  curl -sS "http://127.0.0.1:$port/__test/field-log" > "$tmp/fields.out"
  assert_contains '"field_id":101' "$tmp/fields.out" "github reuses native Priority field" || return 1
  assert_contains '"field_id":104' "$tmp/fields.out" "github reuses native Target date field" || return 1
  assert_contains '"value":"High"' "$tmp/fields.out" "github maps p1 to native High priority" || return 1
  assert_contains '"value":"2026-07-18"' "$tmp/fields.out" "github mirrors due date" || return 1
  assert_contains '"value":"tooling"' "$tmp/fields.out" "github mirrors workstream" || return 1
  assert_contains '"value":"Decision brief"' "$tmp/fields.out" "github mirrors source context" || return 1
  curl -sS "http://127.0.0.1:$port/__test/issues" > "$tmp/issues.out"
  assert_contains '"type":{"name":"Engineering"}' "$tmp/issues.out" "github uses native backlog issue type" || return 1
  assert_contains '"labels":[{"name":"backlog"}]' "$tmp/issues.out" "github keeps only backlog label when native metadata works" || return 1
  assert_contains '"body":"Human body\n\n<!-- backlog-metadata:v2 ' "$tmp/issues.out" "github writes clean human-first issue body" || return 1
  assert_contains '## Related context' "$tmp/issues.out" "github renders related context" || return 1
  if grep -Fq '"body":"---' "$tmp/issues.out"; then
    fail "github issue body must not contain visible YAML frontmatter"
    return 1
  fi
  curl -sS "http://127.0.0.1:$port/__test/headers" > "$tmp/headers.out"
  assert_contains '"path":"/repos/GourmetPro/gtm-claude-code/issues/1/issue-field-values"' "$tmp/headers.out" "github posts issue field values" || return 1
  assert_contains '"version":"2026-03-10"' "$tmp/headers.out" "github issue field values use current API version" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err" || {
      fail "github get-item should succeed; stderr was: $(<"$tmp/get.err")"
      return 1
    }
  assert_contains '"workstream": "tooling"' "$tmp/get.out" "github get workstream" || return 1

  curl -sS "http://127.0.0.1:$port/__test/comments" > "$tmp/automatic-create-comments.out"
  assert_contains '### Progress update' "$tmp/automatic-create-comments.out" "create progress note posts native timeline comment" || return 1
  assert_contains 'Ready' "$tmp/automatic-create-comments.out" "create progress comment contains note" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --progress-note "Halfway" \
    > "$tmp/progress.out" 2> "$tmp/progress.err" || {
      fail "github progress update should succeed; stderr was: $(<"$tmp/progress.err")"
      return 1
    }
  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --progress-note "Halfway" \
    > "$tmp/progress-again.out" 2> "$tmp/progress-again.err" || {
      fail "github repeated progress update should succeed; stderr was: $(<"$tmp/progress-again.err")"
      return 1
    }

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --status blocked --blocked-reason "Waiting on API" \
    > "$tmp/blocked.out" 2> "$tmp/blocked.err" || {
      fail "github blocked update should succeed; stderr was: $(<"$tmp/blocked.err")"
      return 1
    }
  curl -sS "http://127.0.0.1:$port/__test/comments" > "$tmp/automatic-comments.out"
  local automatic_comment_count
  automatic_comment_count="$(node -e 'const fs=require("fs"); const rows=JSON.parse(fs.readFileSync(process.argv[1])); process.stdout.write(String(rows.length))' "$tmp/automatic-comments.out")"
  assert_eq '3' "$automatic_comment_count" "automatic comments post once per changed progress note and blocker" || return 1
  assert_contains '### Blocked' "$tmp/automatic-comments.out" "blocked transition posts native timeline comment" || return 1
  assert_contains 'Waiting on API' "$tmp/automatic-comments.out" "blocker comment contains reason" || return 1

  curl -sS -X PATCH "http://127.0.0.1:$port/__test/issues/1" -d '{"labels":["backlog","human-label"]}' > /dev/null

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --status done --progress-note "" \
    > "$tmp/update.out" 2> "$tmp/update.err" || {
      fail "github update-item should succeed; stderr was: $(<"$tmp/update.err")"
      return 1
  }
  assert_contains '"status": "done"' "$tmp/update.out" "github update status" || return 1
  curl -sS "http://127.0.0.1:$port/__test/issues" > "$tmp/issues-updated.out"
  curl -sS "http://127.0.0.1:$port/__test/field-log" > "$tmp/fields-updated.out"
  curl -sS "http://127.0.0.1:$port/__test/headers" > "$tmp/headers-updated.out"
  assert_contains '"name":"human-label"' "$tmp/issues-updated.out" "github update preserves human labels" || return 1
  if grep -Fq 'backlog/status:' "$tmp/issues-updated.out" || grep -Fq 'backlog/priority:' "$tmp/issues-updated.out" || grep -Fq 'backlog/type:' "$tmp/issues-updated.out"; then
    fail "github update must remove redundant managed metadata labels; fields were: $(<"$tmp/fields-updated.out"); headers were: $(<"$tmp/headers-updated.out"); issues were: $(<"$tmp/issues-updated.out")"
    return 1
  fi
  assert_contains '"deleted_field_id":' "$tmp/fields-updated.out" "github clears nullable managed field values" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" update-item --id gourmetpro--gtm-claude-code--1 --status abandoned --abandoned-reason "No longer needed" \
    > "$tmp/abandoned.out" 2> "$tmp/abandoned.err" || {
      fail "github abandoned update should succeed; stderr was: $(<"$tmp/abandoned.err")"
      return 1
    }
  assert_contains '"status": "abandoned"' "$tmp/abandoned.out" "closed issue honors native abandoned status field" || return 1
  assert_contains '"abandoned_reason": "No longer needed"' "$tmp/abandoned.out" "github mirrors abandoned reason" || return 1
  curl -sS "http://127.0.0.1:$port/__test/comments" > "$tmp/final-automatic-comments.out"
  local final_automatic_comment_count
  final_automatic_comment_count="$(node -e 'const fs=require("fs"); const rows=JSON.parse(fs.readFileSync(process.argv[1])); process.stdout.write(String(rows.length))' "$tmp/final-automatic-comments.out")"
  assert_eq '3' "$final_automatic_comment_count" "clearing progress and abandoning do not add automatic comments" || return 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_rejects_explicit_create_id() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  if BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "Bad ID" --type engineering --id explicit--id > "$tmp/out" 2> "$tmp/err"; then
    fail "github create-item --id should fail"
    return 1
  fi
  assert_contains "--id is not supported by github-issues backends" "$tmp/err" "github create id rejection" || return 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_add_and_list_comments() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream comments --title "Comment fixture" --type engineering \
    > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github comment fixture create should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  curl -sS -X POST "http://127.0.0.1:$port/repos/GourmetPro/gtm-claude-code/issues/1/comments" \
    -H 'content-type: application/json' -d '{"body":"Human observation"}' > /dev/null

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" add-comment --id gourmetpro--gtm-claude-code--1 --kind decision \
      --dedupe-key external:decision:1 --body "Use option B" \
    > "$tmp/add.out" 2> "$tmp/add.err" || {
      fail "github add-comment should succeed; stderr was: $(<"$tmp/add.err")"
      return 1
    }
  assert_contains '"author": "agent-bot"' "$tmp/add.out" "add-comment returns author" || return 1
  assert_contains '"body": "Use option B"' "$tmp/add.out" "add-comment returns clean body" || return 1
  assert_contains '"managed": true' "$tmp/add.out" "add-comment marks managed comment" || return 1
  assert_contains '"kind": "decision"' "$tmp/add.out" "add-comment returns kind" || return 1
  assert_contains '"dedupe_key": "external:decision:1"' "$tmp/add.out" "add-comment returns dedupe key" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" add-comment --id gourmetpro--gtm-claude-code--1 --kind decision \
      --dedupe-key external:decision:1 --body "Use option B" \
    > "$tmp/add-again.out" 2> "$tmp/add-again.err" || {
      fail "github duplicate add-comment should succeed; stderr was: $(<"$tmp/add-again.err")"
      return 1
    }
  assert_eq "$(<"$tmp/add.out")" "$(<"$tmp/add-again.out")" "dedupe returns the existing normalized comment" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-comments --id gourmetpro--gtm-claude-code--1 \
    > "$tmp/list.out" 2> "$tmp/list.err" || {
      fail "github list-comments should succeed; stderr was: $(<"$tmp/list.err")"
      return 1
    }
  assert_contains '"body": "Human observation"' "$tmp/list.out" "list-comments includes human comments" || return 1
  assert_contains '"managed": false' "$tmp/list.out" "list-comments identifies human comments" || return 1
  assert_contains '"body": "Use option B"' "$tmp/list.out" "list-comments includes managed comments" || return 1

  curl -sS "http://127.0.0.1:$port/__test/comments" > "$tmp/comments.out"
  local comment_count
  comment_count="$(node -e 'const fs=require("fs"); const rows=JSON.parse(fs.readFileSync(process.argv[1])); process.stdout.write(String(rows.length))' "$tmp/comments.out")"
  assert_eq '2' "$comment_count" "dedupe prevents duplicate native comments" || return 1
  assert_contains '### Decision' "$tmp/comments.out" "managed native comment has readable heading" || return 1
  assert_contains '<!-- backlog-comment:v1 ' "$tmp/comments.out" "managed native comment has invisible metadata" || return 1

  if BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" add-comment --id gourmetpro--gtm-claude-code--1 --kind invalid --body "Bad" \
    > "$tmp/invalid.out" 2> "$tmp/invalid.err"; then
    fail "github add-comment should reject unknown kinds"
    return 1
  fi
  assert_contains 'note|progress|decision|blocker|handoff' "$tmp/invalid.err" "add-comment kind validation" || return 1

  if BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" add-comment --id gourmetpro--gtm-claude-code--1 --body "   " \
    > "$tmp/blank.out" 2> "$tmp/blank.err"; then
    fail "github add-comment should reject a blank body"
    return 1
  fi
  assert_contains '--body must be at least 1 character' "$tmp/blank.err" "add-comment blank body validation" || return 1

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_postgres_rejects_comment_commands() {
  local tmp="$1"
  mkdir -p "$tmp/config"
  cat > "$tmp/config/backlog.json" <<'JSON'
{"default":"pg","backends":[{"name":"pg","type":"postgres","databaseUrl":"postgres://example.invalid/db"}]}
JSON

  if BACKLOG_CONFIG="$tmp/config/backlog.json" "$ROOT/tools/backlog" add-comment --id item --body note \
    > "$tmp/out" 2> "$tmp/err"; then
    fail "postgres add-comment should be unsupported"
    return 1
  fi
  assert_contains 'command add-comment is not supported by backend pg' "$tmp/err" "postgres comment command error" || return 1
}

test_backlog_github_native_metadata_fallback() {
  local tmp="$1"
  local pid port
  export FAKE_GITHUB_DISABLE_NATIVE_METADATA=1
  start_fake_github "$tmp"
  unset FAKE_GITHUB_DISABLE_NATIVE_METADATA
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream fallback --title "Fallback metadata" --type wiki_ops --priority p0 --body "Readable body" \
    > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github fallback create should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  curl -sS "http://127.0.0.1:$port/__test/issues" > "$tmp/issues.out"
  assert_contains '"name":"backlog/status:queued"' "$tmp/issues.out" "fallback keeps searchable status label" || return 1
  assert_contains '"name":"backlog/priority:p0"' "$tmp/issues.out" "fallback keeps searchable priority label" || return 1
  assert_contains '<!-- backlog-metadata:v2 ' "$tmp/issues.out" "fallback keeps invisible lossless metadata" || return 1
  if grep -Fq '"body":"---' "$tmp/issues.out"; then
    fail "fallback issue body must not restore visible YAML frontmatter"
    return 1
  fi

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err" || {
      fail "github fallback get should succeed; stderr was: $(<"$tmp/get.err")"
      return 1
    }
  assert_contains '"workstream": "fallback"' "$tmp/get.out" "fallback metadata round trips" || return 1
  assert_contains '"type": "wiki_ops"' "$tmp/get.out" "fallback type round trips" || return 1

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_read_tolerates_human_edited_status_drift() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

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
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_ignores_pull_requests() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "PR shaped" --type engineering > "$tmp/create.out" 2> "$tmp/create.err" || {
      fail "github create PR fixture should succeed; stderr was: $(<"$tmp/create.err")"
      return 1
    }

  curl -sS -X PATCH "http://127.0.0.1:$port/__test/issues/1" -d '{"pull_request":{"url":"https://api.github.test/repos/GourmetPro/gtm-claude-code/pulls/1"}}' > /dev/null

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-items --repo GourmetPro/gtm-claude-code > "$tmp/list.out" 2> "$tmp/list.err" || {
      fail "github list should ignore pull requests; stderr was: $(<"$tmp/list.err")"
      return 1
    }
  assert_eq '[]' "$(<"$tmp/list.out")" "github list-items excludes pull requests" || return 1

  if BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err"; then
    fail "github get-item should reject pull requests"
    return 1
  fi
  assert_contains "is a pull request" "$tmp/get.err" "github get-item pull request rejection" || return 1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_github_list_summarize_and_blocks() {
  local tmp="$1"
  local pid port
  start_fake_github "$tmp"
  pid="$FAKE_GITHUB_PID"
  port="$(cat "$tmp/fake-github.port")"
  write_github_config "$tmp" "$port"

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "GitHub parent" --type engineering > "$tmp/create1.out" 2> "$tmp/create1.err" || {
      fail "github create parent should succeed; stderr was: $(<"$tmp/create1.err")"
      return 1
    }
  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "GitHub child" --type engineering --depends-on gourmetpro--gtm-claude-code--1 > "$tmp/create2.out" 2> "$tmp/create2.err" || {
      fail "github create child should succeed; stderr was: $(<"$tmp/create2.err")"
      return 1
    }
  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" create-item --repo GourmetPro/gtm-claude-code --workstream tooling --title "GitHub nonbacklog dependency" --type engineering --depends-on gourmetpro--gtm-claude-code--1 > "$tmp/create3.out" 2> "$tmp/create3.err" || {
      fail "github create nonbacklog dependency fixture should succeed; stderr was: $(<"$tmp/create3.err")"
      return 1
    }
  curl -sS -X PATCH "http://127.0.0.1:$port/__test/issues/3" -d '{"labels":[]}' > /dev/null

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-items --repo GourmetPro/gtm-claude-code --status queued > "$tmp/list.out" 2> "$tmp/list.err" || {
      fail "github list-items should succeed; stderr was: $(<"$tmp/list.err")"
      return 1
    }
  assert_contains '"status": "queued"' "$tmp/list.out" "list-items status filter" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" list-items --q GitHub > "$tmp/search.out" 2> "$tmp/search.err" || {
      fail "github search list-items should succeed; stderr was: $(<"$tmp/search.err")"
      return 1
    }
  assert_contains '"title": "GitHub parent"' "$tmp/search.out" "search list-items returns parent" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" summarize --repo GourmetPro/gtm-claude-code > "$tmp/summary.out" 2> "$tmp/summary.err" || {
      fail "github summarize should succeed; stderr was: $(<"$tmp/summary.err")"
      return 1
    }
  assert_contains '"workstream": "tooling"' "$tmp/summary.out" "summarize workstream" || return 1

  BACKLOG_CONFIG="$tmp/config/backlog.json" TEST_GITHUB_TOKEN=test \
    "$ROOT/tools/backlog" get-item --id gourmetpro--gtm-claude-code--1 > "$tmp/get.out" 2> "$tmp/get.err" || {
      fail "github get parent should succeed; stderr was: $(<"$tmp/get.err")"
      return 1
  }
  assert_contains '"blocks": [' "$tmp/get.out" "get-item includes blocks" || return 1
  assert_contains '"id": "gourmetpro--gtm-claude-code--2"' "$tmp/get.out" "get-item blocks include child" || return 1
  if grep -Fq '"id": "gourmetpro--gtm-claude-code--3"' "$tmp/get.out"; then
    fail "get-item blocks should skip non-backlog native dependencies"
    return 1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

test_backlog_documents_cli_for_agents() {
  local tmp="$1"

  BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" --help > "$tmp/help.out" 2> "$tmp/help.err" || {
    fail "backlog --help should succeed without database config; stderr was: $(<"$tmp/help.err")"
    return 1
  }
  assert_eq '' "$(<"$tmp/help.err")" "backlog --help stderr" || return 1
  assert_contains "Purpose:" "$tmp/help.out" "help explains purpose" || return 1
  assert_contains "Use this CLI when an AI or human needs to inspect or update the shared GourmetPro backlog" "$tmp/help.out" "help explains when to use backlog" || return 1
  assert_contains "Commands:" "$tmp/help.out" "help lists commands" || return 1
  assert_contains "create-item --repo <org/repo> --workstream <name> --title <text> --type engineering|spec_pending_impl|wiki_ops" "$tmp/help.out" "help documents create-item" || return 1
  assert_contains "AI workflow:" "$tmp/help.out" "help includes AI workflow" || return 1
  assert_contains "links JSON:" "$tmp/help.out" "help documents links JSON" || return 1

  local commands=(list-backends list-repos create-repo list-items get-item summarize create-item update-item add-comment list-comments)
  local command
  for command in "${commands[@]}"; do
    BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" "$command" --help > "$tmp/$command.help.out" 2> "$tmp/$command.help.err" || {
      fail "backlog $command --help should succeed without database config; stderr was: $(<"$tmp/$command.help.err")"
      return 1
    }
    assert_eq '' "$(<"$tmp/$command.help.err")" "backlog $command --help stderr" || return 1
    assert_contains "Usage: backlog $command" "$tmp/$command.help.out" "$command help includes usage" || return 1
    assert_contains "Purpose:" "$tmp/$command.help.out" "$command help explains purpose" || return 1
    assert_contains "Examples:" "$tmp/$command.help.out" "$command help includes examples" || return 1
  done

  assert_contains "Usage: backlog list-repos" "$tmp/list-repos.help.out" "list-repos help usage" || return 1
  assert_contains "Shows repositories available to the selected backend" "$tmp/list-repos.help.out" "list-repos help purpose" || return 1
  assert_contains "Usage: backlog create-repo --slug <org/repo>" "$tmp/create-repo.help.out" "create-repo help usage" || return 1
  assert_contains "--color <#RRGGBB>" "$tmp/create-repo.help.out" "create-repo help documents color" || return 1
  assert_contains "Usage: backlog list-items [--repo <org/repo>] [--workstream <name>]" "$tmp/list-items.help.out" "list-items help usage" || return 1
  assert_contains "--status <queued,in_progress,blocked,done,abandoned>" "$tmp/list-items.help.out" "list-items help documents statuses" || return 1
  assert_contains "Usage: backlog get-item --id <item-id>" "$tmp/get-item.help.out" "get-item help usage" || return 1
  assert_contains "Includes a blocks array" "$tmp/get-item.help.out" "get-item help explains blocks" || return 1
  assert_contains "Usage: backlog summarize [--workstream <name>] [--repo <org/repo>]" "$tmp/summarize.help.out" "summarize help usage" || return 1
  assert_contains "Counts backlog items by workstream and status" "$tmp/summarize.help.out" "summarize help purpose" || return 1
  assert_contains "Usage: backlog create-item --repo <org/repo> --workstream <name> --title <text> --type engineering|spec_pending_impl|wiki_ops" "$tmp/create-item.help.out" "create-item help usage" || return 1
  assert_contains "--source-context <text>" "$tmp/create-item.help.out" "create-item help documents source context" || return 1
  assert_contains "Usage: backlog update-item --id <item-id> [--status queued|in_progress|blocked|done|abandoned]" "$tmp/update-item.help.out" "update-item help usage" || return 1
  assert_contains "status=blocked requires --blocked-reason" "$tmp/update-item.help.out" "update-item help documents blocked reason" || return 1
  assert_contains "Usage: backlog add-comment --id <item-id> --body <text>" "$tmp/add-comment.help.out" "add-comment help usage" || return 1
  assert_contains "--dedupe-key <key>" "$tmp/add-comment.help.out" "add-comment help documents retry dedupe" || return 1
  assert_contains "Usage: backlog list-comments --id <item-id>" "$tmp/list-comments.help.out" "list-comments help usage" || return 1
  assert_contains "BACKLOG_BACKEND" "$tmp/help.out" "help documents backend override" || return 1
  assert_contains "github-issues" "$tmp/help.out" "help documents github backend" || return 1
  assert_contains "discovers fields by name" "$tmp/help.out" "help documents automatic native field discovery" || return 1
  assert_contains "YAML frontmatter is read but replaced" "$tmp/help.out" "help documents legacy body migration" || return 1
  assert_contains "preserves unrelated labels" "$tmp/help.out" "help documents human metadata preservation" || return 1
  assert_contains "GitHub comments provide append-only collaboration history" "$tmp/help.out" "help documents comment history" || return 1
  assert_contains "dedupe keys make agent retries safe" "$tmp/help.out" "help documents automatic comment dedupe" || return 1

  BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" help update-item > "$tmp/help-command.out" 2> "$tmp/help-command.err" || {
    fail "backlog help update-item should succeed without database config; stderr was: $(<"$tmp/help-command.err")"
    return 1
  }
  assert_eq '' "$(<"$tmp/help-command.err")" "backlog help update-item stderr" || return 1
  assert_contains "Usage: backlog update-item" "$tmp/help-command.out" "help subcommand returns command docs" || return 1

  if BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" > "$tmp/bare.out" 2> "$tmp/bare.err"; then
    fail "bare backlog should exit non-zero after printing usage"
    return 1
  fi
  assert_eq '' "$(<"$tmp/bare.out")" "bare backlog stdout" || return 1
  assert_contains "Purpose:" "$tmp/bare.err" "bare backlog includes docs on stderr" || return 1
  assert_contains "Try: backlog --help" "$tmp/bare.err" "bare backlog points to help" || return 1
  if grep -Fq "see header comment" "$tmp/bare.err"; then
    fail "bare backlog should not refer to source header comments"
    return 1
  fi
}

write_fake_backlog_for_migration() {
  local fake="$1"
  cat > "$fake" <<'JS'
#!/usr/bin/env node
const fs = require('fs');

const args = process.argv.slice(2);
fs.appendFileSync(process.env.FAKE_BACKLOG_LOG, `${JSON.stringify(args)}\n`);

function valueAfter(flag) {
  const idx = args.indexOf(flag);
  return idx === -1 ? null : args[idx + 1];
}

function commandName() {
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--backend') {
      i++;
      continue;
    }
    if (arg.startsWith('--')) {
      i++;
      continue;
    }
    return arg;
  }
  return null;
}

function sourceRows() {
  return [
    {
      id: 'ai-tools--tooling--existing',
      repo: 'GourmetPro/ai-tools',
      workstream: 'tooling',
      title: 'Existing item',
      type: 'engineering',
      body: 'Existing body',
      status: 'queued',
      priority: 'p2',
      blocked_reason: null,
      abandoned_reason: null,
      links: [],
      source_context: 'Original context',
      depends_on: [],
      branch: null,
      progress_note: null,
      due_date: null,
      console_url: 'https://gtm.gourmetpro.co/work/backlog/ai-tools--tooling--existing'
    },
    {
      id: 'ai-tools--tooling--new',
      repo: 'GourmetPro/ai-tools',
      workstream: 'tooling',
      title: 'New item',
      type: 'engineering',
      body: 'New body',
      status: 'blocked',
      priority: 'p1',
      blocked_reason: 'Waiting for dependency',
      abandoned_reason: null,
      links: [{ kind: 'url', url: 'https://example.com/context' }],
      source_context: null,
      depends_on: ['ai-tools--tooling--existing'],
      branch: null,
      progress_note: null,
      due_date: '2026-07-08',
      console_url: 'https://gtm.gourmetpro.co/work/backlog/ai-tools--tooling--new'
    }
  ];
}

function targetRows() {
  if (process.env.FAKE_EXISTING_TARGETS !== '1') return [];
  return [{
    id: 'gourmetpro--ai-tools--3',
    repo: 'GourmetPro/ai-tools',
    workstream: 'tooling',
    title: 'Existing item',
    type: 'engineering',
    body: 'Existing body',
    status: 'queued',
    priority: 'p2',
    links: [],
    source_context: 'Migrated from Postgres backlog item: ai-tools--tooling--existing',
    depends_on: [],
    branch: null,
    progress_note: null,
    due_date: null,
    console_url: 'https://github.com/GourmetPro/ai-tools/issues/3'
  }];
}

function createdRow() {
  const sourceContext = valueAfter('--source-context') || '';
  const sourceId = (sourceContext.match(/Migrated from Postgres backlog item: ([^\n]+)/) || [])[1] || 'unknown';
  const number = sourceId.endsWith('--existing') ? 10 : 11;
  return {
    id: `gourmetpro--ai-tools--${number}`,
    repo: valueAfter('--repo'),
    workstream: valueAfter('--workstream'),
    title: valueAfter('--title'),
    type: valueAfter('--type'),
    body: valueAfter('--body') || '',
    status: 'queued',
    priority: valueAfter('--priority') || 'p2',
    links: [],
    source_context: sourceContext,
    depends_on: [],
    branch: valueAfter('--branch'),
    progress_note: valueAfter('--progress-note'),
    due_date: valueAfter('--due-date'),
    console_url: `https://github.com/GourmetPro/ai-tools/issues/${number}`
  };
}

const backend = valueAfter('--backend');
const command = commandName();
if (backend === 'pg' && command === 'list-items') {
  const offset = Number(valueAfter('--offset') || 0);
  process.stdout.write(JSON.stringify(offset === 0 ? sourceRows() : []));
} else if (backend === 'gh' && command === 'list-items') {
  process.stdout.write(JSON.stringify(targetRows()));
} else if (backend === 'gh' && command === 'create-item') {
  process.stdout.write(JSON.stringify(createdRow()));
} else if (backend === 'gh' && command === 'update-item') {
  process.stdout.write(JSON.stringify({ id: valueAfter('--id'), status: valueAfter('--status') || 'queued' }));
} else {
  console.error(`unexpected fake backlog call: ${args.join(' ')}`);
  process.exit(2);
}
JS
  chmod +x "$fake"
}

test_migrate_postgres_backlog_to_github_dry_run() {
  local tmp="$1"
  write_fake_backlog_for_migration "$tmp/backlog"
  : > "$tmp/calls.log"

  FAKE_BACKLOG_LOG="$tmp/calls.log" FAKE_EXISTING_TARGETS=1 \
    "$ROOT/scripts/migrate-postgres-backlog-to-github" \
    --backlog-bin "$tmp/backlog" \
    --source-backend pg \
    --target-backend gh > "$tmp/out" 2> "$tmp/err" || {
      fail "migration dry-run should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_contains '"dryRun": true' "$tmp/out" "dry-run summary" || return 1
  assert_contains '"sourceCount": 2' "$tmp/out" "dry-run source count" || return 1
  assert_contains '"existingCount": 1' "$tmp/out" "dry-run existing count" || return 1
  assert_contains '"wouldCreateCount": 1' "$tmp/out" "dry-run create count" || return 1
  assert_contains '"target_id": null' "$tmp/out" "dry-run dependency waits for created target" || return 1
  assert_contains '"--status","queued,in_progress,blocked"' "$tmp/calls.log" "source query only requests open statuses" || return 1
  if grep -Fq '"create-item"' "$tmp/calls.log"; then
    fail "dry-run migration must not create issues"
    return 1
  fi
}

test_migrate_postgres_backlog_to_github_execute() {
  local tmp="$1"
  write_fake_backlog_for_migration "$tmp/backlog"
  : > "$tmp/calls.log"

  FAKE_BACKLOG_LOG="$tmp/calls.log" FAKE_EXISTING_TARGETS=0 \
    "$ROOT/scripts/migrate-postgres-backlog-to-github" \
    --backlog-bin "$tmp/backlog" \
    --source-backend pg \
    --target-backend gh \
    --execute > "$tmp/out" 2> "$tmp/err" || {
      fail "migration execute should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_contains '"dryRun": false' "$tmp/out" "execute summary" || return 1
  assert_contains '"createdCount": 2' "$tmp/out" "execute created count" || return 1
  assert_contains '"statusUpdateCount": 1' "$tmp/out" "execute status update count" || return 1
  assert_contains '"dependencyUpdateCount": 1' "$tmp/out" "execute dependency update count" || return 1
  assert_contains '"create-item"' "$tmp/calls.log" "execute creates issues" || return 1
  assert_contains '"--depends-on","gourmetpro--ai-tools--10"' "$tmp/calls.log" "execute translates dependencies to GitHub IDs" || return 1
}

test_wt_installs_separately() {
  local tmp="$1"
  "$ROOT/install/wt" --bin-dir "$tmp/bin" > "$tmp/out" 2> "$tmp/err" || {
    fail "install/wt should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }
  [[ -L "$tmp/bin/wt" ]] || {
    fail "install/wt should create a wt symlink"
    return 1
  }
  local output
  output="$("$tmp/bin/wt" --help 2>&1)" || {
    fail "installed wt --help should exit 0; output was: $output"
    return 1
  }
  assert_eq 'Usage: wt <name> [--from <branch>] [--model <model>] [--prompt "..."] [--tmux]' "$output" "installed wt help output"
}

test_envrun_installs_separately() {
  local tmp="$1"
  "$ROOT/install/envrun" --bin-dir "$tmp/bin" > "$tmp/out" 2> "$tmp/err" || {
    fail "install/envrun should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }
  [[ -L "$tmp/bin/envrun" ]] || {
    fail "install/envrun should create an envrun symlink"
    return 1
  }
  local output
  output="$("$tmp/bin/envrun" --help 2>&1)" || {
    fail "installed envrun --help should exit 0; output was: $output"
    return 1
  }
  assert_contains 'Usage: envrun [--test|--production] [-c COMMAND | -- COMMAND [ARG...]]' <(printf '%s\n' "$output") "installed envrun help output"
}

test_backlog_installs_separately_and_writes_config() {
  local tmp="$1"
  "$ROOT/install/backlog" \
    --bin-dir "$tmp/bin" \
    --config "$tmp/config/backlog.json" \
    --database-url "postgres://install.example/backlog" > "$tmp/out" 2> "$tmp/err" || {
      fail "install/backlog should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  [[ -L "$tmp/bin/backlog" ]] || {
    fail "install/backlog should create a backlog symlink"
    return 1
  }
  assert_contains '"backends"' "$tmp/config/backlog.json" "installer writes backend array" || return 1
  assert_contains '"databaseUrl": "postgres://install.example/backlog"' "$tmp/config/backlog.json" "installer database config" || return 1
  assert_contains '"type": "github-issues"' "$tmp/config/backlog.json" "installer writes github backend template" || return 1
}

test_backlog_installer_creates_blank_config_template() {
  local tmp="$1"
  "$ROOT/install/backlog" \
    --bin-dir "$tmp/bin" \
    --config "$tmp/config/backlog.json" > "$tmp/out" 2> "$tmp/err" || {
      fail "install/backlog should create a blank config without --database-url; stderr was: $(<"$tmp/err")"
      return 1
    }

  [[ -L "$tmp/bin/backlog" ]] || {
    fail "install/backlog should create a backlog symlink"
    return 1
  }
  assert_contains '"databaseUrlEnv": "BACKLOG_DATABASE_URL"' "$tmp/config/backlog.json" "blank config database env key" || return 1
  assert_contains '"tokenEnv": "GITHUB_TOKEN"' "$tmp/config/backlog.json" "blank config github token env" || return 1
}

test_backlog_installer_preserves_existing_legacy_conf() {
  local tmp="$1"
  mkdir -p "$tmp/config"
  printf "DATABASE_URL='postgres://legacy.example/backlog'\n" > "$tmp/config/backlog.conf"

  "$ROOT/install/backlog" \
    --bin-dir "$tmp/bin" \
    --config "$tmp/config/backlog.json" > "$tmp/out" 2> "$tmp/err" || {
      fail "install/backlog should succeed when legacy conf exists; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_contains "DATABASE_URL='postgres://legacy.example/backlog'" "$tmp/config/backlog.conf" "legacy conf preserved" || return 1
  assert_contains '"backends"' "$tmp/config/backlog.json" "new JSON config created" || return 1
}

test_homebrew_wt_formula() {
  local formula="$ROOT/Formula/wt.rb"
  assert_file_exists "$formula" "wt Homebrew formula" || return 1
  assert_contains "class Wt < Formula" "$formula" "wt formula class" || return 1
  assert_contains 'url "https://github.com/GourmetPro/ai-tools.git",' "$formula" "wt formula GitHub source" || return 1
  assert_formula_release_metadata "$formula" "wt" || return 1
  assert_contains 'bin.install "tools/wt" => "wt"' "$formula" "wt formula installs executable" || return 1
  assert_contains 'depends_on "zsh"' "$formula" "wt formula zsh dependency" || return 1
  assert_contains 'system "#{bin}/wt", "--help"' "$formula" "wt formula test block" || return 1
  ruby -c "$formula" > /dev/null || {
    fail "wt formula should be valid Ruby"
    return 1
  }
}

test_homebrew_backlog_formula() {
  local formula="$ROOT/Formula/backlog.rb"
  assert_file_exists "$formula" "backlog Homebrew formula" || return 1
  assert_contains "class Backlog < Formula" "$formula" "backlog formula class" || return 1
  assert_contains 'url "https://github.com/GourmetPro/ai-tools.git",' "$formula" "backlog formula GitHub source" || return 1
  assert_formula_release_metadata "$formula" "backlog" || return 1
  assert_contains 'libexec.install "tools/backlog" => "backlog"' "$formula" "backlog formula installs raw executable" || return 1
  assert_contains '(bin/"backlog").write' "$formula" "backlog formula writes command wrapper" || return 1
  assert_contains 'formula_opt_bin("libpq")' "$formula" "backlog formula wrapper includes psql path" || return 1
  assert_contains 'formula_opt_bin("node")' "$formula" "backlog formula wrapper includes node path" || return 1
  assert_contains 'depends_on "node"' "$formula" "backlog formula node dependency" || return 1
  assert_contains 'depends_on "libpq"' "$formula" "backlog formula psql dependency" || return 1
  assert_contains 'ENV["BACKLOG_DATABASE_URL"] = "postgres://example.invalid/backlog"' "$formula" "backlog formula test config override" || return 1
  assert_contains 'assert_match "Purpose:", shell_output("#{bin}/backlog --help")' "$formula" "backlog formula test uses help output" || return 1
  assert_contains '~/.config/ai-tools/backlog.json' "$formula" "backlog formula caveats mention JSON config" || return 1
  ruby -c "$formula" > /dev/null || {
    fail "backlog formula should be valid Ruby"
    return 1
  }
}

test_homebrew_envrun_formula() {
  local formula="$ROOT/Formula/envrun.rb"
  assert_file_exists "$formula" "envrun Homebrew formula" || return 1
  assert_contains "class Envrun < Formula" "$formula" "envrun formula class" || return 1
  assert_contains 'url "https://github.com/GourmetPro/ai-tools.git",' "$formula" "envrun formula GitHub source" || return 1
  assert_formula_release_metadata "$formula" "envrun" || return 1
  assert_contains 'bin.install "tools/envrun" => "envrun"' "$formula" "envrun formula installs executable" || return 1
  assert_contains 'depends_on "git"' "$formula" "envrun formula git dependency" || return 1
  assert_contains 'assert_match "Usage: envrun", shell_output("#{bin}/envrun --help")' "$formula" "envrun formula test uses help output" || return 1
  ruby -c "$formula" > /dev/null || {
    fail "envrun formula should be valid Ruby"
    return 1
  }
}

setup_release_helper_fixture() {
  local tmp="$1"
  mkdir -p "$tmp/Formula" "$tmp/scripts"
  cp "$ROOT"/Formula/*.rb "$tmp/Formula/"
  cp "$ROOT/Formula/envrun.rb" "$tmp/Formula/synthetic.rb"
  cp "$ROOT/scripts/bump-homebrew-release" "$tmp/scripts/bump-homebrew-release"
  chmod +x "$tmp/scripts/bump-homebrew-release"
}

assert_formulae_bumped_to_release() {
  local formula_dir="$1"
  local version="$2"
  local revision="$3"
  local formula name

  for formula in "$formula_dir"/*.rb; do
    name="$(basename "$formula" .rb)"
    assert_contains "tag:      \"v$version\"," "$formula" "$name formula bumped tag" || return 1
    assert_contains "revision: \"$revision\"" "$formula" "$name formula bumped revision" || return 1
    assert_contains "version \"$version\"" "$formula" "$name formula bumped version" || return 1
  done
}

test_bump_homebrew_release_script_updates_formulae_and_tag() {
  local tmp="$1"
  setup_release_helper_fixture "$tmp"

  git -C "$tmp" init -q || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp" config user.email "test@example.invalid"
  git -C "$tmp" config user.name "Test Runner"
  git -C "$tmp" add Formula scripts
  git -C "$tmp" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  local revision
  revision="$(git -C "$tmp" rev-parse HEAD)" || return 1

  (cd "$tmp" && scripts/bump-homebrew-release --version 9.8.7) > "$tmp/out" 2> "$tmp/err" || {
    fail "bump-homebrew-release should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq "$revision" "$(git -C "$tmp" rev-parse v9.8.7^{commit})" "created release tag revision" || return 1
  assert_formulae_bumped_to_release "$tmp/Formula" "9.8.7" "$revision" || return 1
  assert_contains "Updated Homebrew formulae to v9.8.7" "$tmp/out" "script success output" || return 1
}

test_bump_homebrew_release_script_bumps_semver_levels() {
  local tmp="$1"
  setup_release_helper_fixture "$tmp"

  git -C "$tmp" init -q || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp" config user.email "test@example.invalid"
  git -C "$tmp" config user.name "Test Runner"
  git -C "$tmp" add Formula scripts
  git -C "$tmp" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  local current_version major minor patch expected_minor expected_major revision
  current_version="$(formula_version "$tmp/Formula/wt.rb")"
  IFS=. read -r major minor patch <<< "$current_version"
  expected_minor="$major.$((minor + 1)).0"
  expected_major="$((major + 1)).0.0"
  revision="$(git -C "$tmp" rev-parse HEAD)" || return 1

  (cd "$tmp" && scripts/bump-homebrew-release --minor) > "$tmp/out" 2> "$tmp/err" || {
    fail "minor bump should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }
  assert_formulae_bumped_to_release "$tmp/Formula" "$expected_minor" "$revision" || return 1

  (cd "$tmp" && scripts/bump-homebrew-release --major) > "$tmp/out2" 2> "$tmp/err2" || {
    fail "major bump should succeed; stderr was: $(<"$tmp/err2")"
    return 1
  }
  assert_formulae_bumped_to_release "$tmp/Formula" "$expected_major" "$revision" || return 1
}

run_test "wt runs as a standalone executable" test_wt_runs_as_executable
run_test "wt passes model flag to claude" with_tmpdir test_wt_passes_model_to_claude
run_test "wt copies .env.local into worktrees" with_tmpdir test_wt_copies_env_local
run_test "envrun runs as a standalone executable" test_envrun_runs_as_executable
run_test "envrun loads local env files from the Git root" with_tmpdir test_envrun_loads_local_env_files_from_git_root
run_test "envrun shell mode expands loaded env values" with_tmpdir test_envrun_shell_command_expands_loaded_env
run_test "envrun test flag loads .env.test" with_tmpdir test_envrun_test_flag_loads_test_env
run_test "envrun production flag loads .env.production" with_tmpdir test_envrun_production_flag_loads_production_env
run_test "backlog reads DATABASE_URL from editable config" with_tmpdir test_backlog_reads_database_url_from_config
run_test "backlog explains missing config" with_tmpdir test_backlog_explains_missing_config
run_test "backlog selects postgres backend from JSON config" with_tmpdir test_backlog_json_config_selects_postgres_backend
run_test "backlog backend flag overrides default backend" with_tmpdir test_backlog_backend_flag_overrides_default_backend
run_test "backlog backend flag can appear after command" with_tmpdir test_backlog_backend_flag_can_appear_after_command
run_test "backlog database URL env overrides JSON postgres URL" with_tmpdir test_backlog_database_url_env_overrides_postgres_backend_url
run_test "backlog lists configured backends without secrets" with_tmpdir test_backlog_list_backends_redacts_configured_secrets
run_test "backlog github create-repo validation is adapter-owned" with_tmpdir test_backlog_github_create_repo_does_not_require_postgres_alias_flags
run_test "backlog github id and body metadata helpers" with_tmpdir test_backlog_github_id_and_body_metadata_helpers
run_test "backlog github repository commands" with_tmpdir test_backlog_github_repository_commands
run_test "backlog github supports literal token config" with_tmpdir test_backlog_github_literal_token_config
run_test "backlog github create get update item and issue fields" with_tmpdir test_backlog_github_create_get_update_item_and_fields
run_test "backlog github rejects explicit create id" with_tmpdir test_backlog_github_rejects_explicit_create_id
run_test "backlog github adds and lists comments" with_tmpdir test_backlog_github_add_and_list_comments
run_test "backlog postgres rejects comment commands" with_tmpdir test_backlog_postgres_rejects_comment_commands
run_test "backlog github falls back without native metadata APIs" with_tmpdir test_backlog_github_native_metadata_fallback
run_test "backlog github read tolerates status drift" with_tmpdir test_backlog_github_read_tolerates_human_edited_status_drift
run_test "backlog github ignores pull requests" with_tmpdir test_backlog_github_ignores_pull_requests
run_test "backlog github list summarize and blocks" with_tmpdir test_backlog_github_list_summarize_and_blocks
run_test "backlog documents CLI usage for agents" with_tmpdir test_backlog_documents_cli_for_agents
run_test "migration dry-run plans open postgres items" with_tmpdir test_migrate_postgres_backlog_to_github_dry_run
run_test "migration execute creates issues and dependencies" with_tmpdir test_migrate_postgres_backlog_to_github_execute
run_test "wt has its own installer" with_tmpdir test_wt_installs_separately
run_test "envrun has its own installer" with_tmpdir test_envrun_installs_separately
run_test "backlog has its own installer and config setup" with_tmpdir test_backlog_installs_separately_and_writes_config
run_test "backlog installer creates skippable blank config template" with_tmpdir test_backlog_installer_creates_blank_config_template
run_test "backlog installer preserves existing legacy conf" with_tmpdir test_backlog_installer_preserves_existing_legacy_conf
run_test "wt has a Homebrew formula" test_homebrew_wt_formula
run_test "envrun has a Homebrew formula" test_homebrew_envrun_formula
run_test "backlog has a Homebrew formula" test_homebrew_backlog_formula
run_test "release helper bumps Homebrew formulae and tag" with_tmpdir test_bump_homebrew_release_script_updates_formulae_and_tag
run_test "release helper supports SemVer bump levels" with_tmpdir test_bump_homebrew_release_script_bumps_semver_levels

exit "$FAILED"
