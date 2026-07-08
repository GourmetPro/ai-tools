# GourmetPro ai-tools

Portable command-line tools and Homebrew formulae for humans and agents.

## Tools

- `wt`: launch a Claude session in an isolated Git worktree.
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

The GitHub backend stores backlog metadata in issue labels, issue body
frontmatter, native issue dependencies, issue types, and configured issue fields
when available. Configure `GITHUB_TOKEN` with repository issue write access, or
put a `"token": "..."` value directly in your private `backlog.json` so the
backend does not need a token environment variable. Keep that file mode `0600`
and do not commit it.

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
