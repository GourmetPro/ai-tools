# Backlog Native GitHub Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace visible backlog frontmatter and redundant labels with GitHub-native issue fields, types, state, and relationships while retaining lossless fallback behavior.

**Architecture:** Extend the existing GitHub adapter with organization schema discovery/provisioning and a resolved capability map. Build issue patches from that map, synchronize each managed field without replacing unrelated values, and use an invisible body payload only for unsupported metadata and structured links.

**Tech Stack:** Node.js 18+, GitHub REST API 2026-03-10, Bash integration tests with the existing fake GitHub server.

## Global Constraints

- Preserve Postgres backend behavior and the existing backlog JSON output shape.
- Preserve unrelated labels, fields, assignees, milestone, Projects, and Development links.
- Parse legacy YAML frontmatter but never emit it from normal GitHub writes.
- Fall back gracefully when organization-level type/field APIs are unavailable.

---

### Task 1: Body metadata codec

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `parseGithubBody(body) -> { meta, body }`
- Produces: `formatGithubBody(meta, body, links) -> string`

- [ ] Add a failing helper/integration test that parses legacy frontmatter, emits an invisible `backlog-metadata` comment, renders related links once, and is byte-stable on a second pass.
- [ ] Run `bash tests/run.sh` and confirm the new assertions fail because the codec still emits `---` frontmatter.
- [ ] Implement the codec, retaining legacy parsing only as an input compatibility path.
- [ ] Rerun the targeted/full shell suite and confirm it passes.

### Task 2: Native schema discovery and provisioning

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `resolveGithubMetadataSchema(backend, owner, repo) -> { fields, issueTypes }`
- Produces: resolved field entries with `fieldId`, `dataType`, and `optionMap`.

- [ ] Extend the fake GitHub server and write failing tests for case-insensitive reuse of `Priority`/`Target date`, creation of missing fields/types, and configured-ID overrides.
- [ ] Verify the tests fail on absent discovery/provisioning requests.
- [ ] Add default field/type definitions, organization API discovery, best-effort creation, and per-organization caching.
- [ ] Verify the tests pass and capability failures remain non-fatal.

### Task 3: Native-first create/read/update

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: resolved schema and the body codec.
- Produces: issue create/update requests that preserve unmanaged labels and synchronize managed field values individually.

- [ ] Write failing integration assertions that capable creates use only `backlog`, set exact native values/type, and omit visible frontmatter.
- [ ] Add failing assertions for native read precedence, nullable field deletion, native dependency round trips, unrelated-label preservation, and legacy migration.
- [ ] Implement field synchronization/deletion, native-first reconciliation, dynamic fallback labels/payload, and clean issue patches.
- [ ] Rerun the full suite until all GitHub and Postgres cases pass.

### Task 4: Documentation and verification

**Files:**
- Modify: `README.md`
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] Document automatic native metadata, search examples, permissions, fallback behavior, and explicit config overrides; update CLI help assertions.
- [ ] Run every command from `AGENTS.md`, including syntax checks, Homebrew style, and `git diff --check`.
- [ ] Review the diff against the design acceptance criteria, fix any important findings, commit the branch, push it, and open a draft PR.
