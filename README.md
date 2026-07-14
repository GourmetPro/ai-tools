# GourmetPro ai-tools

Portable command-line tools and Homebrew formulae for humans and agents.

## Tools

- `wt`: create or reuse an isolated Git worktree, with optional Claude launch.
- `envrun`: run a command with local `.env` / `.env.local` files exported.
- `backlog`: query and mutate the GourmetPro backlog from Postgres or GitHub Issues.

## Install With Homebrew

This repository is a public Homebrew tap. Because the repo is named `ai-tools`
instead of `homebrew-ai-tools`, use the explicit URL form:

```sh
brew tap GourmetPro/ai-tools https://github.com/GourmetPro/ai-tools.git
brew install GourmetPro/ai-tools/wt
brew install GourmetPro/ai-tools/envrun
brew install GourmetPro/ai-tools/backlog
```

The formulae live in:

- `Formula/wt.rb`
- `Formula/envrun.rb`
- `Formula/backlog.rb`

`backlog` uses `~/.config/ai-tools/backlog.json` by default after Homebrew
installation. Create or edit it with:

```sh
mkdir -p ~/.config/ai-tools
$EDITOR ~/.config/ai-tools/backlog.json
```

The file can contain one or more named backends:

```json
{
  "default": "gtm-console",
  "backends": [
    { "name": "gtm-console", "type": "postgres", "databaseUrlEnv": "BACKLOG_DATABASE_URL" },
    { "name": "github", "type": "github-issues", "tokenEnv": "GITHUB_TOKEN" }
  ]
}
```

Choose a backend for one command with `backlog --backend github ...`, or set
`BACKLOG_BACKEND` for automation. Old `~/.config/ai-tools/backlog.conf` files
and `BACKLOG_DATABASE_URL` remain supported for Postgres compatibility.

The GitHub backend stores backlog metadata in native issue fields, issue types,
open/closed state, and dependency relationships. It automatically reuses the
organization's `Priority` and `Target date` fields and provisions the remaining
backlog fields and types when the token has organization administration access.
Issues use the `backlog` label plus one or more `ws:<slug>` workstream labels.
Related links render as normal Markdown; lossless fallback metadata lives in an
invisible HTML comment instead of visible YAML frontmatter.

Native schema setup requires organization `Issue Fields` and `Issue Types`
write permission (or `admin:org` for a classic PAT). Setting values requires
repository push access. Tokens without the organization permissions still work:
the backend falls back to managed status/priority/type labels and invisible
metadata. Configure `GITHUB_TOKEN` with repository issue write access, or put a
`"token": "..."` value directly in your private `backlog.json` so the backend
does not need a token environment variable. Keep that file mode `0600` and do
not commit it.

The default mapping is:

- `priority` → `Priority` (`p0` Urgent, `p1` High, `p2` Medium, `p3` Low)
- `due_date` → `Target date`
- `status` → `Backlog status` (`Queued`, `In progress`, `Blocked`, `Done`, or
  `Abandoned`); the qualified name avoids GitHub's reserved `Status` field name
- `workstream` → one or more `ws:<slug>` labels; the GitHub backend accepts a
  comma-separated set and returns both `workstream` and `workstreams`
- source/reason, branch, and progress values → matching organization issue fields
- backlog type → native `Engineering`, `Spec pending implementation`, or
  `Wiki ops` issue type
- `depends_on` → native blocked-by relationships

These values are directly searchable in GitHub, for example:

```text
label:backlog field.priority:high
label:ws:about-page
label:backlog field."backlog status":blocked
label:backlog field."target date":<=2026-07-31
```

Existing `features.issueFields` and `features.issueTypes` mappings remain
supported as explicit name/ID overrides. Set `features.issueFieldsMode` to
`"off"` to disable issue-field discovery and use compatibility storage only.
Legacy frontmatter remains readable and is migrated to the clean body format on
the next `backlog update-item`. A legacy `Workstream` field value is also read
during migration, converted to a `ws:*` label, and cleared from that issue. The
organization field itself is not deleted.

GitHub create and update commands accept multiple memberships as a comma-separated
`--workstream` value:

```sh
backlog create-item --repo GourmetPro/gourmetpro-website \
  --workstream about-page,website-design \
  --title "Refresh the broader team grid" \
  --type engineering
backlog update-item --id gourmetpro--gourmetpro-website--119 \
  --workstream website-design,content-pipeline
```

`list-items --workstream website-design` matches any membership. `summarize`
counts a multi-workstream issue once in each membership, so category totals may
exceed the number of unique issues.

### Issue comments

GitHub issue fields hold the current backlog state, while issue comments provide
append-only collaboration history. Add or inspect comments with:

```sh
backlog add-comment --id gourmetpro--gourmetpro-website--113 \
  --kind progress \
  --body "Received the first batch of team headshots"
backlog add-comment --id gourmetpro--gourmetpro-website--113 \
  --kind decision \
  --dedupe-key decision:about-grid \
  --body "Keep the existing expert-card visual grammar"
backlog list-comments --id gourmetpro--gourmetpro-website--113
```

Kinds are `note`, `progress`, `decision`, `blocker`, and `handoff`. Managed
comments are normal readable GitHub comments with an invisible marker for their
kind and optional dedupe key. `list-comments` also returns ordinary comments
left directly by humans or other agents. Reusing a dedupe key returns the
existing comment, which makes retries safe.

On the GitHub backend, a new non-empty progress note posts a progress comment;
changing it posts another, while clearing or resubmitting the same note does
not. Transitioning an item to blocked posts the blocked reason. The Progress
note, Backlog status, and Blocked reason fields remain canonical and searchable.
Comments trigger normal GitHub notifications. Comment commands are not
supported by the compatibility Postgres backend.

List configured backend names without printing secrets:

```sh
backlog list-backends
```

## Backlog Migration

Migrate open Postgres backlog items to GitHub Issues with:

```sh
scripts/migrate-postgres-backlog-to-github
scripts/migrate-postgres-backlog-to-github --execute
```

The script migrates `queued`, `in_progress`, and `blocked` items by default.
Dry-run is the default; `--execute` performs writes. It preserves title, body,
priority, status, type, links, due date, branch/progress metadata, source
context, and dependencies when the dependency targets have also been migrated.

## Install Without Homebrew

Install each tool independently:

```sh
./install/wt
./install/envrun
./install/backlog
```

Prepare a worktree for any human or agent:

```sh
wt feature
```

Launch Claude Code in the prepared worktree when requested:

```sh
wt feature --claude
wt feature --claude --model opus --prompt "Implement the feature" --tmux
```

These installers symlink into `$AI_TOOLS_BIN_DIR` or `~/.local/bin` by default.
Use `--bin-dir /some/path` to install somewhere else.

Use `envrun` when a raw executable needs variables from the repo's local env
files:

```sh
envrun -c 'psql "$POSTGRES_URL" -Atc "select 1"'
envrun --test -c 'psql "$POSTGRES_URL" -Atc "select 1"'
envrun --production -- node scripts/smoke-check.js
envrun -- node scripts/example.js
```

`install/backlog` prompts for `DATABASE_URL` when it creates a new JSON config.
Press Enter to skip; it will still create a template that reads
`BACKLOG_DATABASE_URL` and `GITHUB_TOKEN` from the environment. You can also pass
the Postgres value directly:

```sh
./install/backlog --database-url 'postgres://user:pass@host/db'
```

`backlog` writes its config to `$BACKLOG_CONFIG`,
`$XDG_CONFIG_HOME/ai-tools/backlog.json`, or
`~/.config/ai-tools/backlog.json`. Edit that file later to change backend
selection or credentials. Existing `.conf` files are left in place and remain
readable by the CLI when no JSON config is present.

## Development

Run tests with:

```sh
bash tests/run.sh
```

Release a new tool payload and update the Homebrew formulae with:

```sh
scripts/bump-homebrew-release --patch
scripts/bump-homebrew-release --minor
scripts/bump-homebrew-release --major
scripts/bump-homebrew-release --version 0.2.0
```

The script creates or reuses the matching Git tag and rewrites both formulae to
the tag plus exact commit revision.

See `AGENTS.md` for release and verification notes.
