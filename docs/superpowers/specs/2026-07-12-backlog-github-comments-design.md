# Backlog GitHub Comments Design

Date: 2026-07-12

## Goal

Use GitHub issue comments as an append-only collaboration timeline while issue
fields remain the canonical, searchable current state.

## Behavior

- Add GitHub-only commands:
  - `backlog add-comment --id <id> --body <text> [--kind <kind>] [--dedupe-key <key>]`
  - `backlog list-comments --id <id>`
- Supported managed kinds are `note`, `progress`, `decision`, `blocker`, and
  `handoff`; `note` is the default.
- Managed comments render a human-readable heading and body. An invisible
  versioned marker stores only `kind` and optional `dedupe_key`.
- `list-comments` returns all issue comments, including ordinary GitHub human
  and AI comments. Managed markers/headings are removed from the returned body;
  unmanaged comments have `managed: false`, `kind: null`, and
  `dedupe_key: null`.
- `--dedupe-key` is limited to 1–128 characters from `[A-Za-z0-9._:-]`. Before
  posting, the CLI scans the issue's paginated comments and returns the existing
  matching managed comment instead of creating a duplicate.

## Automatic timeline entries

- A non-empty `--progress-note` on create posts a `progress` comment after the
  issue and field values are created.
- Updating `--progress-note` posts a `progress` comment only when the trimmed
  value is non-empty and differs from the previous current value. Clearing the
  Progress note field does not post a comment.
- Transitioning to `blocked` posts the blocked reason as a `blocker` comment.
- Automatic comments use deterministic SHA-256-based dedupe keys so retrying a
  partially completed command cannot duplicate timeline entries.
- The issue/field mutation happens before its automatic comment. If comment
  creation fails, the command reports the error; retry safely completes the
  comment through the dedupe key.

## API and output

GitHub uses `GET` and `POST
/repos/{owner}/{repo}/issues/{issue_number}/comments` with API version
`2026-03-10`. Creating comments uses the same issue-write permission already
required by the GitHub backend and triggers normal GitHub notifications.

Normalized output fields are:

```json
{
  "id": 123,
  "author": "octocat",
  "body": "Readable note text",
  "managed": true,
  "kind": "progress",
  "dedupe_key": "progress:abc123",
  "created_at": "2026-07-12T00:00:00Z",
  "updated_at": "2026-07-12T00:00:00Z",
  "html_url": "https://github.com/org/repo/issues/1#issuecomment-123"
}
```

Postgres returns a clear unsupported-command error for these two commands and
keeps its existing `progress_note` field behavior. The GitHub backend does not
edit or delete comments in this change.

## Acceptance criteria

- Agents can add categorized, deduplicated comments and list the complete issue
  conversation through `backlog`.
- Progress and blocker changes produce one readable timeline entry each while
  retaining their canonical issue fields.
- Human comments round-trip unchanged.
- Retries do not duplicate managed comments.
- Existing backlog commands, native metadata, Postgres behavior, and JSON item
  shapes remain compatible.
