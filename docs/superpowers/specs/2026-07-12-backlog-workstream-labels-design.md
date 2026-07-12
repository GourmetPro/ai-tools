# Backlog Workstream Labels Design

## Goal

Store GitHub backlog workstreams as visible, searchable `ws:<slug>` labels instead
of a single-value `Workstream` organization issue field. An issue may belong to
multiple workstreams without losing compatibility with existing agents that read
the singular `workstream` property.

## Chosen approach

The GitHub backend owns labels whose names begin with `ws:`. They are canonical
for workstream membership. The adapter continues to expose `workstream` as the
first deterministic workstream and adds `workstreams` as the complete sorted
array. Existing `--workstream` commands accept one value as before or a
comma-separated set on the GitHub backend.

Alternatives rejected:

- Keeping the custom field and mirroring labels would leave two writable sources
  of truth and still make multiple membership ambiguous.
- Replacing `workstream` outright with an array would break existing scripts and
  the compatibility Postgres backend.
- Using unprefixed labels would mix workstream taxonomy with human labels and make
  safe replacement impossible.

## Label normalization and ownership

- Canonical names are lowercase kebab-case labels such as `ws:about-page`.
- CLI input may include the `ws:` prefix and may contain comma-separated values.
- Values are trimmed, slugified, deduplicated, sorted, and limited to 64
  characters after normalization. An empty normalized set is rejected.
- Backlog replaces only `ws:*` and `backlog/{status,priority,type}:*` labels.
  It preserves every unrelated human or automation label.
- Before assigning a workstream label, backlog creates it when missing with a
  stable description and color. GitHub's issue update API replaces the full label
  set, so the adapter constructs that set from current unrelated labels plus the
  desired managed labels.

## Read and write model

On read, the GitHub adapter resolves workstreams in this order:

1. all valid `ws:*` issue labels;
2. the legacy `Workstream` issue-field value;
3. `workstreams` from invisible compatibility metadata;
4. the legacy singular `workstream` metadata value;
5. `default` if no source has a usable value.

The returned item contains both:

```json
{
  "workstream": "about-page",
  "workstreams": ["about-page", "website-design"]
}
```

On create or update, the adapter writes all workstreams as `ws:*` labels and
stores both compatibility shapes in invisible metadata. `list-items
--workstream <slug>` matches membership in the array. `summarize` counts an issue
once in each workstream, so totals across workstreams may exceed the unique issue
count for multi-workstream issues.

The GitHub `update-item` command gains `--workstream <slug[,slug...]>`; omitting
the flag preserves all current memberships. The Postgres backend keeps its
existing singular behavior.

## Legacy custom-field migration

The organization-level `Workstream` field remains in GitHub because it may be
used by systems outside backlog. Backlog treats it as read-only migration input:

- it is never provisioned for a new organization;
- it is never populated on new issues;
- an update reads its value when no `ws:*` label exists, creates the equivalent
  label, and clears the legacy field value on that issue;
- it is excluded from native-field capability completeness checks.

This makes the migration idempotent and avoids deleting shared organization
schema.

## Compatibility and fallback behavior

Native issue types and custom fields remain optional. `ws:*` labels are used in
both native-capable and fallback repositories. Existing visible fallback labels
for status, priority, and type remain unchanged when native metadata APIs are
unavailable.

Existing metadata containing only `workstream` remains readable. Existing agents
that ignore `workstreams` continue to receive a meaningful singular value.

## Validation and tests

The fake GitHub integration suite must prove:

- create provisions and assigns `ws:<slug>` without writing a Workstream field;
- a multi-value create round-trips `workstreams` and singular compatibility data;
- a human-added second `ws:*` label is read and preserved by unrelated updates;
- `update-item --workstream` replaces only managed workstream labels;
- unrelated labels survive every write;
- list filtering matches any membership and summaries count each membership;
- an existing legacy Workstream field value migrates to a label and is cleared;
- fallback repositories still retain `ws:*` labels;
- all previous native fields, issue types, relationships, and comments continue
  to work.

## Release and repository migration

This behavior is a backward-compatible feature and receives a minor version
bump. After merge, the release flow tags the merged payload, updates Homebrew
formulae, upgrades the local installation, and replays every actual issue in
`GourmetPro/gourmetpro-website` through `backlog update-item`. The final audit
requires every issue to have at least one `ws:*` label and no Workstream
issue-field value.
