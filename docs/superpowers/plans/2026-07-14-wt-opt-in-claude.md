# `wt` Opt-In Claude Launch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `wt` prepare a reusable Git worktree by default and launch Claude Code only when the user passes `--claude`.

**Architecture:** Keep worktree creation and local-file synchronization as the unconditional preparation phase in `tools/wt`. Add a strict launch gate after preparation: the default path prints the prepared worktree path and returns, while `--claude` enters the worktree and preserves the existing Claude arguments and terminal-title behavior.

**Tech Stack:** zsh, Bash test harness, Git worktrees, Homebrew Ruby formula metadata, Markdown documentation.

## Global Constraints

- `wt <name>` must never launch Claude or another long-running process.
- `wt <name> --claude` must preserve the existing Claude remote-control, name, model, prompt, and tmux behavior.
- `--model`, `--prompt`, and `--tmux` must fail before Git or filesystem changes unless `--claude` is also present.
- The default path must print the prepared worktree path and must not try to change the caller's directory.
- No new runtime dependencies or installer structure changes.

---

### Task 1: Make Claude Launch Strictly Opt-In

**Files:**
- Modify: `tests/run.sh:91-179`
- Modify: `tests/run.sh:1789-1791`
- Modify: `tools/wt:1-130`

**Interfaces:**
- Consumes: existing `wt <name>`, `--from`, `--model`, `--prompt`, and `--tmux` parsing.
- Produces: `--claude` boolean launch option; help text `Usage: wt <name> [--from <branch>] [--claude [--model <model>] [--prompt "..."] [--tmux]]`; final default output `→ Worktree ready: <absolute-path>`.

- [x] **Step 1: Write failing tests for the new default and strict launch gate**

Update both help assertions to the new usage string. Add this default-path test, which installs a fake `claude` that creates a marker if invoked:

```bash
test_wt_does_not_launch_claude_by_default() {
  local tmp="$1"
  mkdir -p "$tmp/bin" "$tmp/repo"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    ': > "$CLAUDE_MARKER"' > "$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"

  git -C "$tmp/repo" init -q -b main || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp/repo" config user.email "test@example.invalid"
  git -C "$tmp/repo" config user.name "Test Runner"
  printf 'initial\n' > "$tmp/repo/README.md"
  git -C "$tmp/repo" add README.md
  git -C "$tmp/repo" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  local marker="$tmp/claude-called"
  (
    cd "$tmp/repo" &&
      PATH="$tmp/bin:$PATH" CLAUDE_MARKER="$marker" "$ROOT/tools/wt" feature
  ) > "$tmp/out" 2> "$tmp/err" || {
    fail "wt should prepare the worktree; stderr was: $(<"$tmp/err")"
    return 1
  }

  [[ -d "$tmp/repo/.claude/worktrees/feature" ]] || {
    fail "wt should create the requested worktree"
    return 1
  }
  [[ ! -e "$marker" ]] || {
    fail "wt should not launch claude by default"
    return 1
  }
  assert_contains '→ Worktree ready:' "$tmp/out" "wt prints the prepared path"
}
```

Change the current launch test invocation to:

```bash
"$ROOT/tools/wt" feature --claude --model opus --prompt "do work" --tmux
```

Add a validation test that invokes each Claude-only option without `--claude`:

```bash
test_wt_requires_claude_for_launch_options() {
  local tmp="$1"
  local -a args

  for option in model prompt tmux; do
    case "$option" in
      model) args=(--model opus) ;;
      prompt) args=(--prompt work) ;;
      tmux) args=(--tmux) ;;
    esac

    if (cd "$tmp" && "$ROOT/tools/wt" feature "${args[@]}") > "$tmp/$option.out" 2> "$tmp/$option.err"; then
      fail "wt should reject --$option without --claude"
      return 1
    fi
    assert_contains "require --claude" "$tmp/$option.err" "--$option explains the launch gate" || return 1
  done
}
```

Register the tests with:

```bash
run_test "wt prepares a worktree without launching claude" with_tmpdir test_wt_does_not_launch_claude_by_default
run_test "wt requires --claude for launch options" with_tmpdir test_wt_requires_claude_for_launch_options
```

Update the `.env.local` test failure message to `wt should prepare env files; stderr was: ...` rather than describing Claude launch.

- [x] **Step 2: Run the focused tests and verify they fail for the intended reasons**

Run:

```sh
bash tests/run.sh
```

Expected: the new help, non-launching default, `--claude` launch, and strict option-gate assertions fail against the old unconditional-launch implementation. Existing unrelated tests continue running.

- [x] **Step 3: Implement the minimal launch gate in `tools/wt`**

Add a reusable `usage` function and two parser-state variables:

```zsh
usage() {
  print -r -- 'Usage: wt <name> [--from <branch>] [--claude [--model <model>] [--prompt "..."] [--tmux]]'
}

local launch_claude=0
local claude_option_used=0
```

Parse `--claude` by setting `launch_claude=1`. Set `claude_option_used=1` in the `--model`, `--prompt`, and `--tmux` branches. After all arguments are parsed and the name is validated, reject invalid combinations before resolving the repository:

```zsh
if (( claude_option_used && ! launch_claude )); then
  print -r -- 'wt: --model, --prompt, and --tmux require --claude' >&2
  return 1
fi
```

After worktree and local-file preparation, return on the default path:

```zsh
if (( ! launch_claude )); then
  print -r -- "→ Worktree ready: $wt_path"
  return 0
fi
```

Keep the terminal-title update, `cd`, Claude argument construction, and `command claude` call after this gate. Update the file header comment and usage comment to describe preparation plus optional launch.

- [x] **Step 4: Run focused verification**

Run:

```sh
zsh -n tools/wt
bash tests/run.sh
```

Expected: zsh syntax exits zero and every test prints `ok`, including the new default and explicit-launch tests.

- [x] **Step 5: Commit the behavior and regression tests**

```sh
git add tools/wt tests/run.sh
git commit -m "feat: make Claude launch opt-in for wt"
```

### Task 2: Document Worktree-First Usage

**Files:**
- Modify: `README.md:5-8`
- Modify: `README.md:160-181`
- Modify: `Formula/wt.rb:3-19`

**Interfaces:**
- Consumes: the Task 1 `wt <name>` and `wt <name> --claude` interface.
- Produces: public installation and usage copy consistent with the executable's help output.

- [x] **Step 1: Add documentation assertions**

Add this lightweight documentation test in `tests/run.sh`:

```bash
test_wt_docs_describe_opt_in_claude() {
  assert_contains '`wt`: create or reuse an isolated Git worktree' "$ROOT/README.md" "README describes wt preparation" || return 1
  assert_contains 'wt feature --claude' "$ROOT/README.md" "README documents explicit Claude launch" || return 1
  assert_contains 'Create isolated Git worktrees with optional Claude launch' "$ROOT/Formula/wt.rb" "wt formula description matches behavior" || return 1
}
```

Register it with the other `wt` checks:

```bash
run_test "wt docs describe opt-in Claude launch" test_wt_docs_describe_opt_in_claude
```

- [x] **Step 2: Run the test and verify it fails**

Run:

```sh
bash tests/run.sh
```

Expected: the new README/formula assertions fail because the existing copy still says `wt` always launches Claude.

- [x] **Step 3: Update README and formula copy**

Change the tool summary to:

```markdown
- `wt`: create or reuse an isolated Git worktree, with optional Claude launch.
```

Add a concise usage section after the direct-install commands:

````markdown
Prepare a worktree for any human or agent:

```sh
wt feature
```

Launch Claude Code in the prepared worktree when requested:

```sh
wt feature --claude
wt feature --claude --model opus --prompt "Implement the feature" --tmux
```
````

Change the formula description to `Create isolated Git worktrees with optional Claude launch` and its caveat to state that only `wt --claude` requires a separately installed and authenticated Claude CLI.

- [x] **Step 4: Run the complete repository verification suite**

Run:

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
ruby -c Formula/envrun.rb
ruby -c Formula/backlog.rb
brew style Formula/wt.rb Formula/envrun.rb Formula/backlog.rb
git diff --check
```

Expected: all tests print `ok`; all syntax, style, and diff checks exit zero.

- [x] **Step 5: Commit the documentation and formula metadata**

```sh
git add README.md Formula/wt.rb tests/run.sh docs/superpowers/plans/2026-07-14-wt-opt-in-claude.md
git commit -m "docs: explain worktree-first wt usage"
```
