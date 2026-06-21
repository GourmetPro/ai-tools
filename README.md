# GourmetPro ai-tools

Portable command-line tools and Homebrew formulae for humans and agents.

## Tools

- `wt`: launch a Claude session in an isolated Git worktree.
- `backlog`: query and mutate the GourmetPro backlog database from a terminal.

## Install With Homebrew

This repository is a public Homebrew tap. Because the repo is named `ai-tools`
instead of `homebrew-ai-tools`, use the explicit URL form:

```sh
brew tap GourmetPro/ai-tools https://github.com/GourmetPro/ai-tools.git
brew install GourmetPro/ai-tools/wt
brew install GourmetPro/ai-tools/backlog
```

The formulae live in:

- `Formula/wt.rb`
- `Formula/backlog.rb`

`backlog` uses `~/.config/ai-tools/backlog.conf` by default after Homebrew
installation. Create or edit it with:

```sh
mkdir -p ~/.config/ai-tools
$EDITOR ~/.config/ai-tools/backlog.conf
```

The file should contain:

```sh
DATABASE_URL='postgres://user:pass@host/db'
```

You can override the config path with `BACKLOG_CONFIG`, or use
`BACKLOG_DATABASE_URL` for one-off sessions.

## Install Without Homebrew

Install each tool independently:

```sh
./install/wt
./install/backlog
```

Both installers symlink into `$AI_TOOLS_BIN_DIR` or `~/.local/bin` by default.
Use `--bin-dir /some/path` to install somewhere else.

`install/backlog` prompts for `DATABASE_URL` when it creates a new config. Press
Enter to skip; it will still create a template with `DATABASE_URL=` and the
example `postgres://user:pass@host/db` as a comment. You can also pass the value
directly:

```sh
./install/backlog --database-url 'postgres://user:pass@host/db'
```

`backlog` writes its config to `$BACKLOG_CONFIG`,
`$XDG_CONFIG_HOME/ai-tools/backlog.conf`, or
`~/.config/ai-tools/backlog.conf`. Edit that file later to change the database
URL.

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
