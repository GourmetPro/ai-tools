# Backlog Native GitHub Metadata Design

Date: 2026-07-12

## Goal

Make issues created by the GitHub backlog backend look and behave like normal
GitHub issues: structured backlog values live in native issue fields, issue
types, state, and dependency relationships; the visible issue body contains
only useful prose and related links.

## Storage model

- Keep the `backlog` label as the membership marker. Preserve all unrelated
  labels. Status, priority, and type labels are compatibility fallbacks only.
- Use native issue types named `Engineering`, `Spec pending implementation`,
  and `Wiki ops`. Discover existing types case-insensitively and create missing
  types when the token has organization-level permission.
- Auto-discover the organization fields below by name. Reuse GitHub's default
  `Priority` and `Target date` fields, and create missing backlog fields when
  permitted. Explicit `features.issueFields` and `features.issueTypes` config
  remains authoritative.

| Backlog value | GitHub storage |
| --- | --- |
| `status` | `Backlog status` single-select plus open/closed issue state (`Status` is reserved by GitHub) |
| `priority` | `Priority` single-select (`p0`→Urgent, `p1`→High, `p2`→Medium, `p3`→Low) |
| `type` | Native issue type |
| `workstream` | `Workstream` text field |
| `due_date` | `Target date` date field |
| `source_context` | `Source context` text field |
| `blocked_reason` | `Blocked reason` text field |
| `abandoned_reason` | `Abandoned reason` text field |
| `branch` | `Branch` text field; GitHub exposes no public issue API for Development linkage |
| `progress_note` | `Progress note` text field |
| `depends_on` | Native blocked-by relationships |
| `links` | Clean Markdown list plus invisible versioned metadata payload for lossless round trips |

Assignees, milestones, Projects, and Development links are preserved and left
human-managed because the backlog command model has no values for them. The
CLI must not clear or fabricate those attributes.

## Compatibility and fallback

Legacy YAML frontmatter remains readable. Any create or update writes the new
body format and therefore migrates that issue away from visible YAML.

The new body format keeps a full lossless fallback record inside an HTML
comment. Native attributes remain the read/search source of truth, while the
comment protects round trips when a token later loses access to a capability.
Related links are rendered as ordinary Markdown between managed markers so
repeated updates are byte-stable and do not duplicate the section. If type,
field, or dependency APIs are unavailable, the comment and managed fallback
labels preserve the complete backlog record.

Native values win on reads, followed by fallback labels, the invisible payload,
and finally legacy frontmatter. Clearing a nullable backlog value deletes only
its managed issue-field value; unrelated organization fields remain untouched.

## Failure behavior

Schema discovery and provisioning are best effort. Permission, availability,
or validation failures disable only that capability for the current process and
fall back to labels/invisible metadata. Core issue creation still fails normally
for repository/authentication errors. No operation replaces human labels or
unmanaged issue-field values.

## Acceptance criteria

- A capable organization receives an issue with only the `backlog` label,
  native type/fields/dependencies, and no visible frontmatter.
- Existing GourmetPro default Priority and Target date fields are reused by
  name without local field IDs.
- Legacy issues round-trip through `update-item` into the clean body format.
- Native field values can be searched with GitHub `field.<name>:<value>` filters.
- Tests prove native-first behavior, fallback behavior, clearing, label
  preservation, legacy migration, and idempotent body rendering.
