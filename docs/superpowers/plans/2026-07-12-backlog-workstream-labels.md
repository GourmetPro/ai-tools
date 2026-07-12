# Backlog Workstream Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the GitHub backend's scalar Workstream custom-field writes with canonical, multi-valued `ws:<slug>` labels while preserving singular API compatibility.

**Architecture:** Normalize GitHub workstream input into a deterministic array, derive managed labels and compatibility metadata from that array, and treat the existing Workstream field as read-only migration input. Keep Postgres singular and make GitHub filtering and summaries array-aware.

**Tech Stack:** Node.js executable, GitHub REST API, Bash integration tests, Homebrew formulae.

## Global Constraints

- Canonical GitHub workstream labels use the exact prefix `ws:` and lowercase kebab-case values.
- GitHub output includes both singular `workstream` and complete `workstreams`.
- Existing singular metadata and Workstream issue-field values remain readable during migration.
- Backlog never deletes the organization Workstream field; it clears only per-issue values.
- Unrelated labels and the Postgres backend's singular behavior remain unchanged.

---

### Task 1: Label-backed create and read behavior

**Files:**
- Modify: `tests/run.sh`
- Modify: `tools/backlog`

**Interfaces:**
- Consumes: existing `--workstream <value>` create flag and GitHub issue labels.
- Produces: `parseGithubWorkstreams(raw)`, `workstreamsFromGithubIssue(...)`, `row.workstreams`, and `ws:<slug>` issue labels.

- [ ] **Step 1: Write failing integration assertions**

Change the native GitHub fixture to create with `--workstream tooling,docs`, then assert the issue labels contain `ws:docs` and `ws:tooling`, the returned JSON contains `"workstreams": [`, and the field log contains no Workstream value.

- [ ] **Step 2: Run the focused suite and verify RED**

Run: `bash tests/run.sh`

Expected: failure because create still writes only `backlog` and mirrors `tooling,docs` into the Workstream field.

- [ ] **Step 3: Implement normalization, labels, and read compatibility**

Add helpers equivalent to:

```js
function parseGithubWorkstreams(raw) {
  const values = String(raw || '').split(',')
    .map((value) => value.trim().replace(/^ws:/i, ''))
    .map(slugify)
    .filter(Boolean);
  const result = [...new Set(values)].sort();
  if (!result.length) fail('--workstream must contain at least one workstream');
  return result;
}

function githubWorkstreamLabels(row) {
  return row.workstreams.map((value) => `ws:${value}`);
}
```

Read all `ws:*` labels first and return both compatibility properties. Add dynamic label provisioning before issue create.

- [ ] **Step 4: Run the focused suite and verify GREEN**

Run: `bash tests/run.sh`

Expected: all assertions through native create/get pass.

### Task 2: Update, filtering, summary, and legacy-field cleanup

**Files:**
- Modify: `tests/run.sh`
- Modify: `tools/backlog`

**Interfaces:**
- Consumes: `row.workstreams`, existing issue labels, legacy Workstream field values.
- Produces: GitHub `update-item --workstream <csv>`, membership filtering, per-membership summaries, and per-issue legacy field deletion.

- [ ] **Step 1: Write failing update and migration assertions**

Extend the fake issue with a human label, a second `ws:*` label, and a legacy Workstream field value. Assert an unrelated update preserves both workstreams and the human label; assert `update-item --workstream replacement,second` replaces only `ws:*`; assert field deletion logs the legacy Workstream field ID; assert list filtering and summary include both memberships.

- [ ] **Step 2: Run the suite and verify RED**

Run: `bash tests/run.sh`

Expected: failure because `update-item` rejects `--workstream`, filtering checks only the scalar, and the field value is not cleared.

- [ ] **Step 3: Implement array-aware writes and migration**

Mark the default Workstream field definition `legacyOnly: true`; resolve it when present but never provision it. Exclude legacy-only fields from capability completeness, skip writes, and delete their per-issue values during updates. Add `workstream` to the GitHub update command flags and derive `next.workstreams` from the override or current memberships.

Update label replacement to remove current `ws:*` labels before adding the desired set while preserving all unrelated labels. Change filtering to `row.workstreams.includes(normalizedFilter)`. Change summary aggregation to increment each workstream membership.

- [ ] **Step 4: Run the suite and verify GREEN**

Run: `bash tests/run.sh`

Expected: native, fallback, filtering, and summary integration tests all pass.

### Task 3: Documentation and complete verification

**Files:**
- Modify: `README.md`
- Modify: `tools/backlog`
- Modify: `docs/superpowers/specs/2026-07-12-backlog-native-github-metadata-design.md`

**Interfaces:**
- Consumes: final CLI and storage behavior.
- Produces: user-facing mapping, examples, and command help.

- [ ] **Step 1: Update documentation**

Document `workstream` as `ws:<slug>` labels, comma-separated GitHub input, `workstreams` output, any-membership filtering, per-membership summary counting, and legacy field cleanup. Update help text for create/update/list/summarize.

- [ ] **Step 2: Run the complete required verification matrix**

Run each command and require exit code zero:

```sh
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

- [ ] **Step 3: Commit the implementation**

Stage only the plan, tests, implementation, README, and relevant design document; commit with `feat: use labels for GitHub workstreams`.

### Task 4: Publish, release, install, and migrate

**Files:**
- Modify after merge: `Formula/backlog.rb`
- Modify after merge: `Formula/envrun.rb`
- Modify after merge: `Formula/wt.rb`

**Interfaces:**
- Consumes: merged feature commit and all 25 target issues.
- Produces: merged PR, minor release, upgraded local CLI, and fully migrated issue labels.

- [ ] **Step 1: Push and merge the PR**

Push `agent/backlog-workstream-labels`, open a ready PR describing behavior and verification, confirm mergeability/checks, and merge with the verified head SHA.

- [ ] **Step 2: Publish the minor Homebrew release**

Fast-forward local main, run `scripts/bump-homebrew-release --minor`, repeat the complete verification matrix, commit formula changes, and push main plus the new tag.

- [ ] **Step 3: Upgrade and test locally**

Run `brew update`, `brew upgrade GourmetPro/ai-tools/backlog`, `brew test GourmetPro/ai-tools/backlog`, and verify the installed formula version with `brew list --versions backlog`.

- [ ] **Step 4: Migrate all actual repository issues**

Paginate all `GourmetPro/gourmetpro-website` issues excluding pull requests. Replay each through installed `backlog update-item --id <id> --depends-on ''`, preserving its current status and metadata.

- [ ] **Step 5: Audit live GitHub state**

Require exactly 25 issues, at least one `ws:*` label per issue, no per-issue Workstream field value, no `backlog/*` fallback labels, native issue types present, no visible YAML frontmatter, and all items readable through `backlog list-items` across queued and done statuses.
