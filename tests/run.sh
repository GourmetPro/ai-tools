#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
CURRENT_TEST_FAILED=0

fail() {
  printf 'not ok - %s\n' "$CURRENT_TEST"
  printf '  %s\n' "$1"
  FAILED=1
  CURRENT_TEST_FAILED=1
}

pass() {
  printf 'ok - %s\n' "$CURRENT_TEST"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$message: expected [$expected], got [$actual]"
    return 1
  fi
}

assert_contains() {
  local needle="$1"
  local file="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    fail "$message: expected to find [$needle] in $file"
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  local message="$2"
  if [[ ! -f "$file" ]]; then
    fail "$message: missing $file"
    return 1
  fi
}

with_tmpdir() {
  local fn="$1"
  local tmp
  tmp="$(mktemp -d)"
  "$fn" "$tmp"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

run_test() {
  CURRENT_TEST="$1"
  CURRENT_TEST_FAILED=0
  shift
  if "$@"; then
    pass
  elif [[ "$CURRENT_TEST_FAILED" -eq 0 ]]; then
    fail "test command failed"
  fi
}

test_wt_runs_as_executable() {
  local output
  output="$("$ROOT/tools/wt" --help 2>&1)" || {
    fail "tools/wt --help should exit 0; output was: $output"
    return 1
  }
  assert_eq 'Usage: wt <name> [--from <branch>] [--prompt "..."] [--tmux]' "$output" "wt help output"
}

test_backlog_reads_database_url_from_config() {
  local tmp="$1"
  mkdir -p "$tmp/bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$@" > "$PSQL_ARGS_FILE"' \
    'printf "[]\n"' > "$tmp/bin/psql"
  chmod +x "$tmp/bin/psql"

  local config="$tmp/backlog.conf"
  printf '%s\n' \
    '# Backlog CLI configuration' \
    "DATABASE_URL='postgres://user:pass@example.com/backlog?sslmode=require'" > "$config"

  local output="$tmp/out.json"
  local args="$tmp/psql.args"
  PATH="$tmp/bin:$PATH" PSQL_ARGS_FILE="$args" BACKLOG_CONFIG="$config" BACKLOG_DATABASE_URL= \
    "$ROOT/tools/backlog" list-repos > "$output" 2> "$tmp/err" || {
      fail "backlog list-repos should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  assert_eq '[]' "$(<"$output")" "backlog JSON output" || return 1
  assert_eq 'postgres://user:pass@example.com/backlog?sslmode=require' "$(head -n 1 "$args")" "psql database URL argument"
}

test_backlog_explains_missing_config() {
  local tmp="$1"
  if BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" list-repos > "$tmp/out" 2> "$tmp/err"; then
    fail "backlog should fail when BACKLOG_CONFIG points to a missing file"
    return 1
  fi
  assert_contains "DATABASE_URL is not configured" "$tmp/err" "missing config error" || return 1
  assert_contains "$tmp/missing.conf" "$tmp/err" "missing config path" || return 1
}

test_backlog_documents_cli_for_agents() {
  local tmp="$1"

  BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" --help > "$tmp/help.out" 2> "$tmp/help.err" || {
    fail "backlog --help should succeed without database config; stderr was: $(<"$tmp/help.err")"
    return 1
  }
  assert_eq '' "$(<"$tmp/help.err")" "backlog --help stderr" || return 1
  assert_contains "Purpose:" "$tmp/help.out" "help explains purpose" || return 1
  assert_contains "Use this CLI when an AI or human needs to inspect or update the shared GourmetPro backlog" "$tmp/help.out" "help explains when to use backlog" || return 1
  assert_contains "Commands:" "$tmp/help.out" "help lists commands" || return 1
  assert_contains "create-item --repo <org/repo> --workstream <name> --title <text> --type engineering|spec_pending_impl|wiki_ops" "$tmp/help.out" "help documents create-item" || return 1
  assert_contains "AI workflow:" "$tmp/help.out" "help includes AI workflow" || return 1
  assert_contains "links JSON:" "$tmp/help.out" "help documents links JSON" || return 1

  local commands=(list-repos create-repo list-items get-item summarize create-item update-item)
  local command
  for command in "${commands[@]}"; do
    BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" "$command" --help > "$tmp/$command.help.out" 2> "$tmp/$command.help.err" || {
      fail "backlog $command --help should succeed without database config; stderr was: $(<"$tmp/$command.help.err")"
      return 1
    }
    assert_eq '' "$(<"$tmp/$command.help.err")" "backlog $command --help stderr" || return 1
    assert_contains "Usage: backlog $command" "$tmp/$command.help.out" "$command help includes usage" || return 1
    assert_contains "Purpose:" "$tmp/$command.help.out" "$command help explains purpose" || return 1
    assert_contains "Examples:" "$tmp/$command.help.out" "$command help includes examples" || return 1
  done

  assert_contains "Usage: backlog list-repos" "$tmp/list-repos.help.out" "list-repos help usage" || return 1
  assert_contains "Shows repositories registered for backlog item ownership" "$tmp/list-repos.help.out" "list-repos help purpose" || return 1
  assert_contains "Usage: backlog create-repo --slug <org/repo> --short-slug <short> --display-name <name>" "$tmp/create-repo.help.out" "create-repo help usage" || return 1
  assert_contains "--color <#RRGGBB>" "$tmp/create-repo.help.out" "create-repo help documents color" || return 1
  assert_contains "Usage: backlog list-items [--repo <org/repo>] [--workstream <name>]" "$tmp/list-items.help.out" "list-items help usage" || return 1
  assert_contains "--status <queued,in_progress,blocked,done,abandoned>" "$tmp/list-items.help.out" "list-items help documents statuses" || return 1
  assert_contains "Usage: backlog get-item --id <item-id>" "$tmp/get-item.help.out" "get-item help usage" || return 1
  assert_contains "Includes a blocks array" "$tmp/get-item.help.out" "get-item help explains blocks" || return 1
  assert_contains "Usage: backlog summarize [--workstream <name>] [--repo <org/repo>]" "$tmp/summarize.help.out" "summarize help usage" || return 1
  assert_contains "Counts backlog items by workstream and status" "$tmp/summarize.help.out" "summarize help purpose" || return 1
  assert_contains "Usage: backlog create-item --repo <org/repo> --workstream <name> --title <text> --type engineering|spec_pending_impl|wiki_ops" "$tmp/create-item.help.out" "create-item help usage" || return 1
  assert_contains "--source-context <text>" "$tmp/create-item.help.out" "create-item help documents source context" || return 1
  assert_contains "Usage: backlog update-item --id <item-id> [--status queued|in_progress|blocked|done|abandoned]" "$tmp/update-item.help.out" "update-item help usage" || return 1
  assert_contains "status=blocked requires --blocked-reason" "$tmp/update-item.help.out" "update-item help documents blocked reason" || return 1

  BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" help update-item > "$tmp/help-command.out" 2> "$tmp/help-command.err" || {
    fail "backlog help update-item should succeed without database config; stderr was: $(<"$tmp/help-command.err")"
    return 1
  }
  assert_eq '' "$(<"$tmp/help-command.err")" "backlog help update-item stderr" || return 1
  assert_contains "Usage: backlog update-item" "$tmp/help-command.out" "help subcommand returns command docs" || return 1

  if BACKLOG_CONFIG="$tmp/missing.conf" BACKLOG_DATABASE_URL= "$ROOT/tools/backlog" > "$tmp/bare.out" 2> "$tmp/bare.err"; then
    fail "bare backlog should exit non-zero after printing usage"
    return 1
  fi
  assert_eq '' "$(<"$tmp/bare.out")" "bare backlog stdout" || return 1
  assert_contains "Purpose:" "$tmp/bare.err" "bare backlog includes docs on stderr" || return 1
  assert_contains "Try: backlog --help" "$tmp/bare.err" "bare backlog points to help" || return 1
  if grep -Fq "see header comment" "$tmp/bare.err"; then
    fail "bare backlog should not refer to source header comments"
    return 1
  fi
}

test_wt_installs_separately() {
  local tmp="$1"
  "$ROOT/install/wt" --bin-dir "$tmp/bin" > "$tmp/out" 2> "$tmp/err" || {
    fail "install/wt should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }
  [[ -L "$tmp/bin/wt" ]] || {
    fail "install/wt should create a wt symlink"
    return 1
  }
  local output
  output="$("$tmp/bin/wt" --help 2>&1)" || {
    fail "installed wt --help should exit 0; output was: $output"
    return 1
  }
  assert_eq 'Usage: wt <name> [--from <branch>] [--prompt "..."] [--tmux]' "$output" "installed wt help output"
}

test_backlog_installs_separately_and_writes_config() {
  local tmp="$1"
  "$ROOT/install/backlog" \
    --bin-dir "$tmp/bin" \
    --config "$tmp/config/backlog.conf" \
    --database-url "postgres://install.example/backlog" > "$tmp/out" 2> "$tmp/err" || {
      fail "install/backlog should succeed; stderr was: $(<"$tmp/err")"
      return 1
    }

  [[ -L "$tmp/bin/backlog" ]] || {
    fail "install/backlog should create a backlog symlink"
    return 1
  }
  assert_contains "DATABASE_URL='postgres://install.example/backlog'" "$tmp/config/backlog.conf" "installer database config" || return 1
}

test_backlog_installer_creates_blank_config_template() {
  local tmp="$1"
  "$ROOT/install/backlog" \
    --bin-dir "$tmp/bin" \
    --config "$tmp/config/backlog.conf" > "$tmp/out" 2> "$tmp/err" || {
      fail "install/backlog should create a blank config without --database-url; stderr was: $(<"$tmp/err")"
      return 1
    }

  [[ -L "$tmp/bin/backlog" ]] || {
    fail "install/backlog should create a backlog symlink"
    return 1
  }
  assert_contains "# postgres://user:pass@host/db" "$tmp/config/backlog.conf" "blank config example comment" || return 1
  assert_contains "DATABASE_URL=" "$tmp/config/backlog.conf" "blank config database key" || return 1
}

test_homebrew_wt_formula() {
  local formula="$ROOT/Formula/wt.rb"
  assert_file_exists "$formula" "wt Homebrew formula" || return 1
  assert_contains "class Wt < Formula" "$formula" "wt formula class" || return 1
  assert_contains 'url "https://github.com/GourmetPro/ai-tools.git",' "$formula" "wt formula GitHub source" || return 1
  assert_contains 'tag:      "v0.1.1",' "$formula" "wt formula source tag" || return 1
  assert_contains 'revision: "' "$formula" "wt formula source revision" || return 1
  assert_contains 'bin.install "tools/wt" => "wt"' "$formula" "wt formula installs executable" || return 1
  assert_contains 'depends_on "zsh"' "$formula" "wt formula zsh dependency" || return 1
  assert_contains 'system "#{bin}/wt", "--help"' "$formula" "wt formula test block" || return 1
  ruby -c "$formula" > /dev/null || {
    fail "wt formula should be valid Ruby"
    return 1
  }
}

test_homebrew_backlog_formula() {
  local formula="$ROOT/Formula/backlog.rb"
  assert_file_exists "$formula" "backlog Homebrew formula" || return 1
  assert_contains "class Backlog < Formula" "$formula" "backlog formula class" || return 1
  assert_contains 'url "https://github.com/GourmetPro/ai-tools.git",' "$formula" "backlog formula GitHub source" || return 1
  assert_contains 'tag:      "v0.1.1",' "$formula" "backlog formula source tag" || return 1
  assert_contains 'revision: "' "$formula" "backlog formula source revision" || return 1
  assert_contains 'libexec.install "tools/backlog" => "backlog"' "$formula" "backlog formula installs raw executable" || return 1
  assert_contains '(bin/"backlog").write' "$formula" "backlog formula writes command wrapper" || return 1
  assert_contains 'Formula["libpq"].opt_bin' "$formula" "backlog formula wrapper includes psql path" || return 1
  assert_contains 'depends_on "node"' "$formula" "backlog formula node dependency" || return 1
  assert_contains 'depends_on "libpq"' "$formula" "backlog formula psql dependency" || return 1
  assert_contains 'ENV["BACKLOG_DATABASE_URL"] = "postgres://example.invalid/backlog"' "$formula" "backlog formula test config override" || return 1
  assert_contains 'assert_match "Purpose:", shell_output("#{bin}/backlog --help")' "$formula" "backlog formula test uses help output" || return 1
  ruby -c "$formula" > /dev/null || {
    fail "backlog formula should be valid Ruby"
    return 1
  }
}

test_bump_homebrew_release_script_updates_formulae_and_tag() {
  local tmp="$1"
  mkdir -p "$tmp/Formula" "$tmp/scripts"
  cp "$ROOT/Formula/wt.rb" "$tmp/Formula/wt.rb"
  cp "$ROOT/Formula/backlog.rb" "$tmp/Formula/backlog.rb"
  cp "$ROOT/scripts/bump-homebrew-release" "$tmp/scripts/bump-homebrew-release"
  chmod +x "$tmp/scripts/bump-homebrew-release"

  git -C "$tmp" init -q || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp" config user.email "test@example.invalid"
  git -C "$tmp" config user.name "Test Runner"
  git -C "$tmp" add Formula scripts
  git -C "$tmp" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  local revision
  revision="$(git -C "$tmp" rev-parse HEAD)" || return 1

  (cd "$tmp" && scripts/bump-homebrew-release --version 9.8.7) > "$tmp/out" 2> "$tmp/err" || {
    fail "bump-homebrew-release should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }

  assert_eq "$revision" "$(git -C "$tmp" rev-parse v9.8.7^{commit})" "created release tag revision" || return 1
  assert_contains 'tag:      "v9.8.7",' "$tmp/Formula/wt.rb" "wt formula bumped tag" || return 1
  assert_contains "revision: \"$revision\"" "$tmp/Formula/wt.rb" "wt formula bumped revision" || return 1
  assert_contains 'version "9.8.7"' "$tmp/Formula/wt.rb" "wt formula bumped version" || return 1
  assert_contains 'tag:      "v9.8.7",' "$tmp/Formula/backlog.rb" "backlog formula bumped tag" || return 1
  assert_contains "revision: \"$revision\"" "$tmp/Formula/backlog.rb" "backlog formula bumped revision" || return 1
  assert_contains 'version "9.8.7"' "$tmp/Formula/backlog.rb" "backlog formula bumped version" || return 1
  assert_contains "Updated Homebrew formulae to v9.8.7" "$tmp/out" "script success output" || return 1
}

test_bump_homebrew_release_script_bumps_semver_levels() {
  local tmp="$1"
  mkdir -p "$tmp/Formula" "$tmp/scripts"
  cp "$ROOT/Formula/wt.rb" "$tmp/Formula/wt.rb"
  cp "$ROOT/Formula/backlog.rb" "$tmp/Formula/backlog.rb"
  cp "$ROOT/scripts/bump-homebrew-release" "$tmp/scripts/bump-homebrew-release"
  chmod +x "$tmp/scripts/bump-homebrew-release"

  git -C "$tmp" init -q || {
    fail "temp git init failed"
    return 1
  }
  git -C "$tmp" config user.email "test@example.invalid"
  git -C "$tmp" config user.name "Test Runner"
  git -C "$tmp" add Formula scripts
  git -C "$tmp" commit -q -m initial || {
    fail "temp git commit failed"
    return 1
  }

  (cd "$tmp" && scripts/bump-homebrew-release --minor) > "$tmp/out" 2> "$tmp/err" || {
    fail "minor bump should succeed; stderr was: $(<"$tmp/err")"
    return 1
  }
  assert_contains 'tag:      "v0.2.0",' "$tmp/Formula/wt.rb" "minor bump tag" || return 1
  assert_contains 'version "0.2.0"' "$tmp/Formula/backlog.rb" "minor bump version" || return 1

  (cd "$tmp" && scripts/bump-homebrew-release --major) > "$tmp/out2" 2> "$tmp/err2" || {
    fail "major bump should succeed; stderr was: $(<"$tmp/err2")"
    return 1
  }
  assert_contains 'tag:      "v1.0.0",' "$tmp/Formula/wt.rb" "major bump tag" || return 1
  assert_contains 'version "1.0.0"' "$tmp/Formula/backlog.rb" "major bump version" || return 1
}

run_test "wt runs as a standalone executable" test_wt_runs_as_executable
run_test "backlog reads DATABASE_URL from editable config" with_tmpdir test_backlog_reads_database_url_from_config
run_test "backlog explains missing config" with_tmpdir test_backlog_explains_missing_config
run_test "backlog documents CLI usage for agents" with_tmpdir test_backlog_documents_cli_for_agents
run_test "wt has its own installer" with_tmpdir test_wt_installs_separately
run_test "backlog has its own installer and config setup" with_tmpdir test_backlog_installs_separately_and_writes_config
run_test "backlog installer creates skippable blank config template" with_tmpdir test_backlog_installer_creates_blank_config_template
run_test "wt has a Homebrew formula" test_homebrew_wt_formula
run_test "backlog has a Homebrew formula" test_homebrew_backlog_formula
run_test "release helper bumps Homebrew formulae and tag" with_tmpdir test_bump_homebrew_release_script_updates_formulae_and_tag
run_test "release helper supports SemVer bump levels" with_tmpdir test_bump_homebrew_release_script_bumps_semver_levels

exit "$FAILED"
