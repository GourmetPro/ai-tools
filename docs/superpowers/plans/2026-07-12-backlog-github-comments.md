# Backlog GitHub Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native GitHub issue-comment collaboration and automatic progress/blocker history without replacing canonical issue fields.

**Architecture:** Add a small comment codec and normalized comment mapper inside the existing GitHub adapter. New commands call the paginated issue-comments endpoint directly; create/update hooks reuse the same posting function with deterministic dedupe keys.

**Tech Stack:** Node.js 18+, built-in `crypto`, GitHub REST API 2026-03-10, existing Bash fake-GitHub integration suite.

## Global Constraints

- Fields remain canonical current state; comments are append-only history.
- `add-comment` and `list-comments` are GitHub-only and must fail clearly on Postgres.
- Read all native comments, but never rewrite unmanaged human/AI comments.
- Automatic comment retries must be idempotent.

---

### Task 1: Comment commands and codec

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

**Interfaces:**
- Produces: `formatBacklogComment(body, kind, dedupeKey) -> string`
- Produces: `githubCommentToBacklogComment(comment) -> normalized comment`
- Produces commands: `add-comment`, `list-comments`

- [ ] Extend the fake server with paginated issue comment GET/POST endpoints and write failing tests for managed and human comments, normalized output, kind validation, and duplicate-key reuse.
- [ ] Run `bash tests/run.sh`; expect failures because both commands are unknown.
- [ ] Implement the codec, pagination, comment mapping, dedupe scan, GitHub commands, adapter flags, and Postgres unsupported behavior.
- [ ] Rerun `bash tests/run.sh`; expect all command tests to pass.

### Task 2: Automatic progress and blocker history

**Files:**
- Modify: `tools/backlog`
- Test: `tests/run.sh`

**Interfaces:**
- Consumes: the Task 1 comment posting/deduplication helper.
- Produces: deterministic automatic keys based on issue ID, kind, and comment body.

- [ ] Write failing create/update tests asserting one progress comment per changed non-empty note, no comment when clearing/retaining it, and one blocker comment per transition.
- [ ] Run `bash tests/run.sh`; expect comment-count/body assertions to fail.
- [ ] Add post-mutation hooks and SHA-256-based keys; do not change Postgres paths.
- [ ] Rerun `bash tests/run.sh`; expect the full suite to pass.

### Task 3: Documentation, verification, and PR update

**Files:**
- Modify: `README.md`
- Modify: `tools/backlog`
- Test: `tests/run.sh`

- [ ] Document commands, kinds, automatic behavior, notifications, dedupe keys, and GitHub-only scope; extend CLI help assertions.
- [ ] Run `bash tests/run.sh` plus every verification command in `AGENTS.md`.
- [ ] Review the complete diff against both comment and native-metadata specs, commit explicit paths, push the existing branch, and update draft PR #4's description.
