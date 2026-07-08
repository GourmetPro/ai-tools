# Backlog GitHub Issues Backend Design

Date: 2026-06-30

## Purpose

`tools/backlog` currently talks directly to the GourmetPro backlog Postgres
database. The next version should keep that backend, add GitHub Issues as a
swappable backend, and make backend selection a normal CLI/config concern.

The goal is command-level parity: every existing `backlog` command should be
available on both backends, return the same broad JSON shape, and preserve the
current stdout/stderr contract. GitHub will not match every Postgres storage
semantic because it is an issue tracker, not a transactional query database.
Those differences are accepted and documented below.

## Current Behavior

The current CLI is a single Node executable at `tools/backlog`.

It supports:

- `list-repos`
- `create-repo`
- `list-items`
- `get-item`
- `summarize`
- `create-item`
- `update-item`

It reads `DATABASE_URL` from `~/.config/ai-tools/backlog.conf` by default, with
`BACKLOG_CONFIG` and `BACKLOG_DATABASE_URL` overrides. It prints pretty JSON to
stdout. Failures print one line to stderr and exit non-zero.

Postgres has a curated `backlog_repos` registry with `slug` and `short_slug`.
Current item IDs are semantic IDs:

```text
<short_slug>--<workstream>--<slugified-title>
```

Examples from current data:

```text
GourmetPro/gtm-claude-code      -> gtm
GourmetPro/gourmetpro-daiquiri  -> portal
GourmetPro/gtm-console          -> gtm-console
```

Postgres IDs should not be migrated as part of this change.

## Config

The primary config file becomes:

```text
~/.config/ai-tools/backlog.json
```

Example:

```json
{
  "default": "gtm-console",
  "backends": [
    {
      "name": "github",
      "type": "github-issues",
      "tokenEnv": "GITHUB_TOKEN",
      "apiBaseUrl": "https://api.github.com",
      "apiVersion": "2026-03-10",
      "features": {
        "issueDependencies": "auto",
        "issueTypes": {
          "engineering": "Engineering",
          "spec_pending_impl": "Spec pending implementation",
          "wiki_ops": "Wiki ops"
        },
        "issueFields": {
          "priority": {
            "fieldId": 12345,
            "dataType": "single_select",
            "optionMap": { "p0": "P0", "p1": "P1", "p2": "P2", "p3": "P3" }
          },
          "status": {
            "fieldId": 12346,
            "dataType": "single_select",
            "optionMap": {
              "queued": "Queued",
              "in_progress": "In progress",
              "blocked": "Blocked",
              "done": "Done",
              "abandoned": "Abandoned"
            }
          },
          "workstream": { "fieldId": 12347, "dataType": "text" },
          "due_date": { "fieldId": 12348, "dataType": "date" }
        }
      }
    },
    {
      "name": "gtm-console",
      "type": "postgres",
      "databaseUrlEnv": "BACKLOG_DATABASE_URL"
    }
  ]
}
```

Backend selection order:

1. `--backend <name>`
2. `BACKLOG_BACKEND`
3. `default` in `backlog.json`
4. compatibility fallback to the old `.conf` behavior when no JSON config exists

The old `~/.config/ai-tools/backlog.conf`, `BACKLOG_CONFIG`, and
`BACKLOG_DATABASE_URL` paths remain supported for compatibility. When only the
old config exists, the CLI treats it as a single implicit Postgres backend.

Both backends support env-var indirection for secrets:

- GitHub: `tokenEnv`
- Postgres: `databaseUrlEnv`

Literal `token` and `databaseUrl` remain supported for private local setups, but
durable shared examples should prefer `tokenEnv` and `databaseUrlEnv`.

`features.issueFields` is the canonical GitHub issue field configuration name.
During migration, the implementation may accept `features.customFields` as a
backward-compatible alias, but new config and documentation should use
`issueFields`.

## Architecture

Split the CLI into three layers:

1. CLI shell: command dispatch, global flags, help, JSON output, and one-line
   error formatting.
2. Shared validation and mapping: statuses, priorities, types, links, dates,
   common field limits, and response shaping.
3. Backend adapters: storage-specific implementation of the command surface.

Backend adapters implement:

```text
listRepos(args)
createRepo(args)
listItems(args)
getItem(args)
summarize(args)
createItem(args)
updateItem(args)
```

The adapter owns backend-specific required flags, command validation, and ID
validation. The CLI shell may reject unknown commands and unknown flags, but it
must not enforce Postgres-only required flags before backend selection. For
example, Postgres `create-repo` requires `--short-slug` and `--display-name`;
GitHub `create-repo` only requires `--slug`.

The existing Postgres ID regex continues to apply to Postgres. GitHub gets its
own ID grammar. `--id` handling is also adapter-owned: Postgres accepts explicit
IDs on create, while GitHub rejects them because GitHub assigns issue numbers.

The GitHub adapter should be built around an injectable HTTP transport:

```text
request(method, path, { query, headers, body })
```

Production uses Node's built-in `fetch`; tests inject a fake transport. This
keeps tests deterministic and avoids real network calls. The implementation
should require Node 18 or newer for GitHub support.

## GitHub Backend

### Authentication

The GitHub adapter reads a token from the backend's literal `token` when present,
otherwise from the configured `tokenEnv`, defaulting to `GITHUB_TOKEN`.

Requests use GitHub REST API conventions:

- `Accept: application/vnd.github+json`
- `Authorization: Bearer <token>`
- `X-GitHub-Api-Version: 2026-03-10` unless overridden by config. This is the
  first version used by this design because issue fields are part of the backend
  contract.

The default `apiBaseUrl` is `https://api.github.com`. This keeps the door open
for GitHub Enterprise by changing config.

Supported token modes:

- Personal access tokens and fine-grained personal access tokens use
  `GET /user/repos` for repository discovery.
- GitHub App installation tokens use `GET /installation/repositories`.

The config may include `tokenType: "pat"` or `tokenType: "app-installation"`.
If omitted, the adapter starts with the PAT/fine-grained PAT path and reports a
clear error if the token shape is unsupported. Creating or updating issues
requires issue write permission. `create-repo` label bootstrapping also requires
permission to create repository labels.

### Capability Detection

GitHub has native issue capabilities that vary by organization, repository,
token, and feature configuration. The adapter uses capability detection and
graceful fallback instead of assuming every repository supports every native
feature.

Supported capabilities:

- Native issue dependencies: `blocked_by` and `blocking` endpoints.
- Native issue type: issue `type` field on create/update.
- Native issue fields: organization issue fields under
  `/orgs/{org}/issue-fields` and per-issue values under
  `/repos/{owner}/{repo}/issues/{issue_number}/issue-field-values` for
  configured field IDs.

Configuration:

```json
{
  "features": {
    "issueDependencies": "auto",
    "issueTypes": {
      "engineering": "Engineering",
      "spec_pending_impl": "Spec pending implementation",
      "wiki_ops": "Wiki ops"
    },
    "issueFields": {
      "priority": {
        "fieldId": 12345,
        "dataType": "single_select",
        "optionMap": { "p0": "P0", "p1": "P1", "p2": "P2", "p3": "P3" }
      },
      "status": {
        "fieldId": 12346,
        "dataType": "single_select",
        "optionMap": {
          "queued": "Queued",
          "in_progress": "In progress",
          "blocked": "Blocked",
          "done": "Done",
          "abandoned": "Abandoned"
        }
      },
      "workstream": { "fieldId": 12347, "dataType": "text" },
      "due_date": { "fieldId": 12348, "dataType": "date" }
    }
  }
}
```

Rules:

- `issueDependencies: "auto"` means try native dependencies and fall back to
  frontmatter `depends_on` if the endpoint returns unsupported/not found/gone.
- `issueTypes` maps backlog types to existing GitHub issue type names. If the
  type update fails because the type is unavailable, fall back to
  `backlog/type:*` labels.
- `issueFields` is optional and field-ID based. `customFields` may be accepted
  as a migration alias, but `issueFields` is the canonical name. When configured
  and accepted by GitHub, issue fields mirror priority/status/workstream/due_date
  into native fields. Labels remain the baseline canonical fallback for priority
  and status, and frontmatter remains the baseline canonical fallback for
  workstream and due_date.
- Issue fields are issue-only. Pull requests do not support issue fields.
- GitHub users can set, edit, and clear issue field values through the issue
  sidebar, GitHub Projects, the API, or GitHub Actions. Issue field values are
  not set through URL query parameters or issue templates.
- The adapter mirrors only `text`, `single_select`, `number`, and `date`
  issue fields. Organization issue field definitions also support
  `multi_select`, but this backend should leave multi-select and unrelated
  fields untouched.
- `optionMap` maps backlog enum values to GitHub single-select option names.
- Per-issue `GET /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`
  lists the issue's field values.
- Per-issue `POST /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`
  adds or updates the provided field values without replacing unrelated existing
  issue field values. The request body shape is:
  `{ "issue_field_values": [{ "field_id": 123, "value": "Critical" }] }`.
- Per-issue `PUT /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`
  sets/replaces the issue's field values with the provided set. Avoid PUT when
  mirroring backlog metadata because it can clobber unrelated human-managed
  fields.
- `DELETE /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values/{issue_field_id}`
  clears a single issue field value.
- Issue fields are searchable with `field.<name>:<value>` query syntax, but the
  backend still applies the same final client-side reconciliation used by reads.
- Issue field changes trigger `issues` webhook activity types `field_added` and
  `field_removed`. Webhook handling is out of scope for this backend, but these
  event names should be used by future sync integrations.
- Native capability failures should be cached per backend/repo for the current
  process so one unsupported repo does not repeatedly hit failing endpoints.

This tiered model lets GourmetPro org repos use native GitHub fields and
relationships where available while preserving the "works with ordinary issues"
backend behavior.

### Repository Discovery

GitHub repos are not statically listed in config. `list-repos` returns
repositories visible to the configured token.

The adapter uses the authenticated repository listing endpoint for the configured
token type and paginates results. Output is sorted by full repository slug for
determinism and shaped like current repo rows:

```json
{
  "slug": "GourmetPro/gtm-claude-code",
  "short_slug": "gourmetpro--gtm-claude-code",
  "display_name": "gtm-claude-code",
  "default_branch": "main",
  "color": "#1A4D4A",
  "created_at": "2026-01-01T00:00:00Z",
  "html_url": "https://github.com/GourmetPro/gtm-claude-code"
}
```

For GitHub rows, `short_slug` means the issue ID prefix
`<lowercase-owner>--<lowercase-repo>`. It is not a manually curated Postgres
short slug.

GitHub repositories do not have backlog palette colors. The shaped `color` field
is derived deterministically from the lowercased `full_name` using the existing
repo palette. The same repo should always receive the same color on one machine.

`list-repos` has different semantics by backend:

- Postgres: curated backlog repo registry.
- GitHub: token-visible GitHub repository set.

Docs and help text must make this explicit.

### GitHub IDs

GitHub item IDs are backend-scoped and use the native issue number:

```text
<owner>--<repo>--<issue-number>
```

Examples:

```text
gourmetpro--gtm-claude-code--123
gourmetpro--gourmetpro-daiquiri--42
```

Normalization is lowercase only. It preserves `.`, `_`, `-`, and any `--` inside
repository names. This avoids lossy slug collisions.

GitHub ID validation:

- owner segment: `[a-z0-9._-]+`
- repo segment: `[a-z0-9._-]+`, and may contain `--`
- issue number: positive integer

Parsing rule:

- owner is before the first `--`
- issue number is after the last `--`
- repo is everything between

This makes repo names containing `--` safe.

`get-item --id gourmetpro--gtm-claude-code--123` routes directly to:

```text
GET /repos/gourmetpro/gtm-claude-code/issues/123
```

GitHub repository owner/name lookup is case-insensitive, so lowercase-only IDs
remain routable.

### Issue Representation

GitHub issue title maps to backlog `title`.

GitHub issue body contains a frontmatter metadata block followed by the
human-readable body.

Example:

```yaml
---
backlog_schema: 1
repo: "GourmetPro/gtm-claude-code"
workstream: "deal-analysis"
status: "queued"
priority: "p1"
type: "engineering"
depends_on: []
links: []
source_context: "created from backlog CLI"
blocked_reason: null
abandoned_reason: null
branch: null
progress_note: null
due_date: null
---

Human-readable issue body.
```

Do not store `backlog_id` in frontmatter. The GitHub ID is derived from
repository owner, repository name, and issue number.

The parser only recognizes frontmatter when the issue body starts with `---` at
offset 0. The closing fence is the next line that is exactly `---`. Everything
after that closing fence, including later thematic breaks or markdown fences, is
opaque human content and must be preserved verbatim on metadata updates.

The metadata block uses a strict zero-dependency YAML-compatible subset:

```text
key: <JSON literal>
```

Values are serialized as JSON literals: strings are JSON-quoted, null is `null`,
arrays and objects are JSON on one line, booleans and numbers use JSON syntax.
This is valid enough frontmatter for humans to recognize while avoiding a YAML
runtime dependency and avoiding lossy ad hoc parsing. Unknown keys are preserved
when rewriting frontmatter.

Frontmatter is the baseline representation for fields that do not have an
available GitHub-native or label representation:

- `workstream`
- `depends_on`
- `links`
- `source_context`
- `blocked_reason`
- `abandoned_reason`
- `branch`
- `progress_note`
- `due_date`

Frontmatter mirrors status, priority, and type for readability, but labels and
issue state are canonical for those enum fields.

When native dependencies are available, `depends_on` is mirrored from GitHub's
`blocked_by` relationship and frontmatter is fallback only. When native issue
fields are configured, workstream/priority/status/due_date are mirrored into
those fields, but the read mapper still tolerates missing or unsupported issue
fields.

### Labels And State

Every backlog-managed issue has:

```text
backlog
```

Status label:

```text
backlog/status:queued
backlog/status:in_progress
backlog/status:blocked
backlog/status:done
backlog/status:abandoned
```

Priority label:

```text
backlog/priority:p0
backlog/priority:p1
backlog/priority:p2
backlog/priority:p3
```

Type label:

```text
backlog/type:engineering
backlog/type:spec_pending_impl
backlog/type:wiki_ops
```

Do not create workstream labels. Workstream is an open string and belongs in
frontmatter only.

Status reconciliation on read:

- closed issue + `backlog/status:abandoned` means `abandoned`
- closed issue + any other or missing backlog status means `done`
- open issue + valid status label means that label's status
- open issue + missing status label means `queued`

Priority reconciliation on read:

- valid priority labels win
- configured native issue fields may be used before frontmatter when present
- frontmatter is fallback
- missing priority defaults to `p2`

Type reconciliation on read:

- configured native issue `type` wins when `features.issueTypes` maps the GitHub
  type name to a backlog type
- valid `backlog/type:*` labels are fallback
- frontmatter is final fallback
- missing type defaults to `engineering`

Issue field reconciliation on read:

- Fetch
  `GET /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values` with
  `X-GitHub-Api-Version: 2026-03-10` only when `features.issueFields` is
  configured.
- Use only configured field IDs and only supported mirror data types
  `text`, `single_select`, `number`, and `date`.
- Leave unrelated issue fields untouched and ignore missing, unsupported, or
  unconfigured values.

The read path must tolerate human-edited GitHub issues that violate CLI write
rules. Validation remains strict for CLI writes.

Filtering must use the same reconciliation rules as reads. Server-side labels or
states may narrow candidate sets only when they cannot exclude an issue that the
read mapper would return as matching. Final filtering always maps each issue to a
backlog row and compares the reconciled `status`, `priority`, `type`, and
frontmatter `workstream`.

### Command Parity

#### `list-repos`

Lists token-visible GitHub repositories and shapes them like repo rows. Supports
pagination internally. If the token can see many repos, the adapter may apply a
documented cap and include a warning field or stderr note only when it does not
break JSON output expectations.

#### `create-repo`

On GitHub, this means "enable backlog in an existing repository."

Behavior:

1. Verify the configured token can access `--slug <org/repo>`.
2. Ensure the `backlog`, status, priority, and type labels exist.
3. Return the shaped repo row.

It does not create a GitHub repository.

If the token cannot create labels, fail with a clear one-line error explaining
the missing permission.

Label bootstrapping is idempotent. Re-running `create-repo` should treat
GitHub's "already exists" response as success for that label. Labels are created
from a fixed map:

```text
backlog                           color 5319e7  description "Managed by backlog CLI"
backlog/status:queued             color d4c5f9  description "Backlog status: queued"
backlog/status:in_progress        color fbca04  description "Backlog status: in progress"
backlog/status:blocked            color d73a4a  description "Backlog status: blocked"
backlog/status:done               color 0e8a16  description "Backlog status: done"
backlog/status:abandoned          color 6a737d  description "Backlog status: abandoned"
backlog/priority:p0               color b60205  description "Backlog priority: p0"
backlog/priority:p1               color d93f0b  description "Backlog priority: p1"
backlog/priority:p2               color fbca04  description "Backlog priority: p2"
backlog/priority:p3               color c5def5  description "Backlog priority: p3"
backlog/type:engineering          color 1d76db  description "Backlog type: engineering"
backlog/type:spec_pending_impl    color 5319e7  description "Backlog type: spec pending implementation"
backlog/type:wiki_ops             color 006b75  description "Backlog type: wiki ops"
```

If native issue dependencies, issue types, or configured issue fields are
available, `create-repo` may also run a non-mutating capability probe and include
capability details in the returned row under `github_capabilities`. It must not
fail solely because optional native capabilities are unavailable.

#### `list-items`

Lists issues labeled `backlog`.

With `--repo`, query one repository's issues.

Without `--repo`, use GitHub issue search across repositories visible to the
token:

```text
type:issue label:backlog
```

This avoids one issue-list request per visible repository. The tradeoff is that
GitHub Search is eventually consistent and may miss very recent writes. With
`--repo`, use the repository issues endpoint because it is bounded and more
read-after-write friendly.

The adapter sorts returned rows client-side by the current Postgres-compatible
order:

```text
priority ASC, created_at DESC
```

Filtering:

- `--status` narrows by GitHub state where safe, then filters by reconciled
  status. For example, `done` fetches closed backlog issues and excludes those
  reconciled as `abandoned`; `queued` fetches open backlog issues and filters to
  items with no status label or `backlog/status:queued`.
- `--priority` and `--type` may use labels as an optimization only when that
  cannot exclude frontmatter fallback values. Final filtering uses reconciled row
  fields.
- `--workstream` parses frontmatter and filters client-side.
- Configured issue fields may use GitHub's `field.<name>:<value>` search syntax
  as an optimization only when that cannot exclude frontmatter or label fallback
  values. Final filtering still uses reconciled row fields.
- `--q` uses GitHub issue search and then maps results back to backlog rows.
- `--limit` and `--offset` apply to the merged client-side result set.

The GitHub Search API is eventually consistent and rate-limited. Cross-repo
`list-items`, `--q`, and `--offset` pagination may miss very recent writes or
shift if repositories/issues change between calls.

#### `get-item`

Parses the GitHub ID, fetches the issue directly, and maps it to the current
backlog item shape.

If the issue does not have the `backlog` label, fail clearly instead of mapping
an arbitrary GitHub issue as a backlog item.

The `blocks` field is supported by searching or scanning for issues whose
frontmatter `depends_on` contains the requested ID. When native issue
dependencies are available, use:

```text
GET /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocking
```

and map the returned issues to `blocks`. The native path is preferred because it
is not full-text search and is less likely to be stale. The frontmatter
search/scan path remains the fallback.

#### `summarize`

Supported on GitHub by listing backlog issues and grouping by workstream/status
client-side.

With `--repo`, this is bounded to one repo.

Without `--repo`, use the same cross-repo Search path as `list-items` and group
the mapped results client-side. The adapter may use a cache or documented cap to
avoid excessive API usage.

#### `create-item`

Creates a GitHub issue with:

- title from `--title`
- body from frontmatter plus `--body`
- backlog labels
- open issue state

This is a single `POST /repos/{owner}/{repo}/issues` call. The returned issue
number determines the item ID.

`--id` cannot be honored on GitHub because GitHub assigns issue numbers. If
provided for a GitHub backend, fail clearly:

```text
tools/backlog: --id is not supported by github-issues backends because GitHub assigns issue numbers
```

#### `update-item`

Fetches the issue, maps current state, applies CLI validation, then patches:

- title when `--title` is passed
- body/frontmatter when body or metadata fields change
- labels when status/priority/type changes
- native issue type when configured and accepted
- native issue fields when configured and accepted
- native issue dependencies when available and `--depends-on` changes
- issue state when status enters or leaves `done`/`abandoned`

On GitHub, `--body` replaces only the human-readable content below the closing
frontmatter fence. Metadata flags rewrite only the frontmatter block. Updating
one side must not clobber the other.

Use a single issue PATCH with `labels` where feasible to reduce partial-write
risk. Conditional requests or `updated_at` checks should be used where practical
to avoid silent lost updates.

Changing status to `done` closes the issue with `state_reason: completed` where
the API accepts it. Changing status to `abandoned` closes the issue with
`state_reason: not_planned`. Moving from `done` or `abandoned` to an open status
reopens the issue.

For `--depends-on`, the GitHub adapter resolves dependency backlog IDs to GitHub
issues. If native dependencies are available and the dependency is in a
compatible repository scope, it updates `/dependencies/blocked_by`. If native
dependencies are unavailable or reject the relationship, it updates frontmatter
`depends_on` instead and reports a normal row response.

## Output Shape

GitHub rows should preserve the current `backlog_items`-like field names:

```json
{
  "id": "gourmetpro--gtm-claude-code--123",
  "workstream": "deal-analysis",
  "title": "Plan D",
  "body": "Human-readable issue body.",
  "status": "queued",
  "priority": "p1",
  "type": "engineering",
  "blocked_reason": null,
  "abandoned_reason": null,
  "links": [],
  "source_context": "created from backlog CLI",
  "created_at": "2026-06-30T00:00:00Z",
  "updated_at": "2026-06-30T00:00:00Z",
  "completed_at": null,
  "repo": "GourmetPro/gtm-claude-code",
  "depends_on": [],
  "branch": null,
  "progress_note": null,
  "due_date": null,
  "console_url": "https://github.com/GourmetPro/gtm-claude-code/issues/123"
}
```

For Postgres rows, `console_url` remains the GTM console URL. For GitHub rows,
`console_url` is the GitHub issue `html_url`.

Timestamp mapping for GitHub rows:

- `created_at` is issue `created_at`
- `updated_at` is issue `updated_at`
- `completed_at` is issue `closed_at` only when reconciled status is `done`
- `completed_at` is null for open, blocked, queued, in-progress, and abandoned
  items

## Accepted Differences From Postgres

GitHub has no transaction that spans body, labels, state, and comments. Writes
can partially fail. The adapter should minimize multi-call writes and report
failures clearly.

GitHub writes do not write `console_audit_log`. GitHub items will not appear in
console audit views unless a future sync/indexing layer is added.

GitHub Search API is eventually consistent, separately rate-limited, and has
result caps. This affects cross-repo `list-items`, `list-items --q`, broad
`summarize`, and fallback dependency `blocks` lookup. Native dependency endpoints
avoid this limitation when available.

Broad `summarize` and broad `list-items` can be expensive because they may scan
many token-visible repositories.

Manual edits in GitHub can create states the CLI writer would reject. The read
mapper must tolerate and normalize those states instead of crashing.

## Compatibility And Migration

Postgres remains the default backend for existing users unless they create
`~/.config/ai-tools/backlog.json` or pass `--backend`.

Fallback behavior:

1. If JSON config exists, use it.
2. Otherwise, if old `.conf` config exists or `BACKLOG_DATABASE_URL` is set, use
   the current Postgres behavior.

Installer changes:

- `install/backlog` should create or update `backlog.json` for new installs.
- If passed `--database-url`, write a Postgres backend using `databaseUrl`.
- Docs should prefer `databaseUrlEnv` for durable setups.
- Existing `.conf` files should not be overwritten.

Homebrew formula changes:

- Caveats should document `~/.config/ai-tools/backlog.json`.
- Tests should keep a compatibility smoke test using `BACKLOG_DATABASE_URL`.

README changes:

- Document backend config.
- Document `--backend`.
- Document old `.conf` compatibility.
- Document GitHub token requirements and accepted semantic differences.

## Testing

Focused tests should cover:

- JSON config parsing and backend selection order.
- Compatibility fallback to old `.conf` and `BACKLOG_DATABASE_URL`.
- Postgres behavior unchanged under old config.
- GitHub ID validation and first-/last-`--` parsing.
- Strict frontmatter parse/update behavior, including preservation of human body
  text and unknown frontmatter keys.
- Label/state reconciliation, including human-edited drift.
- Filter behavior matching reconciliation for status, priority, type, and
  workstream.
- Capability detection and fallback for native issue dependencies, issue types,
  and configured issue fields. Issue field tests should exercise
  `GET /orgs/{org}/issue-fields` and
  `POST /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values` with
  `X-GitHub-Api-Version: 2026-03-10`.
- GitHub command mapping with a fake HTTP server or injectable API client.
- `create-repo` label bootstrapping behavior.
- `create-item --id` rejection on GitHub.
- Help text for `--backend` and backend semantic differences.

The existing `tests/run.sh` style should remain cheap and deterministic. Tests
must not require real GitHub credentials or network access.

## References

GitHub REST API endpoints used by this design:

- `GET /user/repos`
- `GET /installation/repositories`
- `GET /repos/{owner}/{repo}`
- `GET /repos/{owner}/{repo}/issues`
- `GET /repos/{owner}/{repo}/issues/{issue_number}`
- `POST /repos/{owner}/{repo}/issues`
- `PATCH /repos/{owner}/{repo}/issues/{issue_number}`
- `GET /search/issues`
- `GET /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocked_by`
- `POST /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocked_by`
- `DELETE /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocked_by/{issue_id}`
- `GET /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocking`
- organization issue field endpoints under `/orgs/{org}/issue-fields`
- `GET /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`
- `POST /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values`
- `DELETE /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values/{issue_field_id}`
- repository label endpoints under `/repos/{owner}/{repo}/labels`

Issue field endpoints use `X-GitHub-Api-Version: 2026-03-10`. The backend should
avoid `PUT /repos/{owner}/{repo}/issues/{issue_number}/issue-field-values` for
metadata mirroring because it replaces the issue's field value set and can
clobber unrelated human-managed fields.

Implementation should rely on current GitHub REST documentation when coding
request details, headers, permissions, and pagination.
