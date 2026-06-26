# Agent Instructions

Rules for maintaining this repository.

## Repository Scope

This repo is a small public Homebrew tap and portable CLI toolbox for tools used
by humans and agents on the same machine.

Keep the scope narrow:

- `tools/`: runnable tool implementations.
- `install/`: direct non-Homebrew installers.
- `Formula/`: Homebrew formulae.
- `tests/run.sh`: lightweight verification for tool and formula behavior.

Do not add project-specific credentials, database URLs, or local absolute
machine paths to tracked files. `backlog` must keep reading its database URL
from an editable config file or environment override.

## Homebrew Formulae

Formulae live in `Formula/` and should install released tool payloads from this
repo's public Git URL:

```ruby
url "https://github.com/GourmetPro/ai-tools.git",
    tag:      "vX.Y.Z",
    revision: "<tag commit sha>"
```

For scripts:

- Use `bin.install` for direct executables.
- Use a wrapper when Homebrew dependencies need to be placed on `PATH`.
- Keep formula tests cheap and deterministic. They should not require real
  credentials, networked databases, or a `claude` session.

Because this repository is named `ai-tools` rather than `homebrew-ai-tools`,
document tap setup with an explicit URL:

```sh
brew tap GourmetPro/ai-tools https://github.com/GourmetPro/ai-tools.git
```

## Verification

Before committing or pushing changes, run:

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
ruby -c Formula/backlog.rb
brew style Formula/wt.rb Formula/backlog.rb
git diff --check
```

`brew audit` may need to be run against installed tap formula names rather than
local paths, depending on the Homebrew version.

## Release Flow

1. Commit tool payload changes.
2. Tag that commit, for example `v0.2.0`.
3. Update formula `tag` and `revision` fields to the tagged commit.
4. Run verification.
5. Commit formula and docs changes.
6. Push `main` and tags.

Use `scripts/bump-homebrew-release` for steps 2 and 3:

```sh
scripts/bump-homebrew-release --patch
scripts/bump-homebrew-release --minor
scripts/bump-homebrew-release --major
scripts/bump-homebrew-release --version 0.2.0
```

Keep README install instructions in sync with formula names and config behavior.
