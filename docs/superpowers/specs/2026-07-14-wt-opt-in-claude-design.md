# `wt` Opt-In Claude Launch Design

## Goal

Make `wt` useful for humans and agents that only need an isolated Git worktree.
Creating or reusing a worktree must no longer launch Claude Code automatically.
Users can preserve the current Claude workflow with an explicit `--claude` flag.

## Command Behavior

`wt <name>` will:

1. Create or reuse `.claude/worktrees/<name>` and its `worktree-<name>` branch.
2. Link or copy the existing local environment and Claude settings files.
3. Ensure the worktree's `tmp/` directory exists.
4. Print the prepared worktree path and exit successfully without starting another
   process.

`wt <name> --claude` will perform the same preparation and then preserve the
current Claude Code launch behavior: change into the worktree, set the terminal
title, and run Claude with remote control and session name set to `<name>`.

The existing `--model`, `--prompt`, and `--tmux` options remain supported, but
they are valid only with `--claude`. Using any of them without `--claude` will
exit with an actionable error. This makes process creation strictly opt-in and
prevents agent automation from launching Claude accidentally.

## Interface

The usage string becomes:

```text
Usage: wt <name> [--from <branch>] [--claude [--model <model>] [--prompt "..."] [--tmux]]
```

Examples:

```sh
wt feature
wt feature --from develop
wt feature --claude
wt feature --claude --model opus --prompt "Implement the feature" --tmux
```

## Output and Errors

The preparation messages remain unchanged. After successful preparation without
`--claude`, `wt` prints a final line identifying the worktree path. It does not
attempt to change the caller's directory because a child process cannot change
its parent shell.

Claude-only options without `--claude` fail before any Git or filesystem changes
are made. Missing values and unknown flags continue to fail with a nonzero exit
status and a concise diagnostic.

## Testing

The test suite will verify that:

- default invocation creates the worktree but never invokes a fake `claude`;
- `--claude` preserves the existing argument forwarding for model, prompt, and
  tmux;
- every Claude-only option is rejected without `--claude` before worktree
  creation;
- the standalone installer exposes the updated help text;
- existing environment-file synchronization behavior remains unchanged.

README examples will document the non-launching default and explicit Claude
launch. No installer or Homebrew formula structure changes are required because
both already install `tools/wt` directly.
