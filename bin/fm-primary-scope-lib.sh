#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for entrypoints scoped to a genuine
# firstmate primary home.
# This file is sourced by hook and supervisor entrypoints and has no side effects.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary checkout, including a valid linked
# secondmate home, and reject ordinary linked crew/scout worktrees.
fm_primary_checkout_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ]
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# Hooks use this stricter scope; supervisor commands use the same checkout
# predicate before creating a first-time state directory.
fm_primary_scope_matches() {
  fm_primary_checkout_matches "$1" || return 1
  [ -d "$2" ]
}

# Return the nearest owned test-fixture root containing $1, if any. The
# fixture marker scopes this exception to disposable test homes; environment
# flags alone never authorize a supervisor entrypoint.
fm_test_fixture_root_for_path() {
  local path=$1 probe resolved marker
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  probe=$path
  [ -d "$probe" ] || probe=$(dirname "$probe")
  while [ -n "$probe" ] && [ "$probe" != / ]; do
    [ -d "$probe" ] && resolved=$(cd -P "$probe" 2>/dev/null && pwd -P) || resolved=
    if [ -n "$resolved" ]; then
      marker="$resolved/.fm-test-fixture"
      if [ -f "$marker" ] && [ ! -L "$marker" ]; then
        printf '%s\n' "$resolved"
        return 0
      fi
    fi
    probe=$(dirname "$probe")
  done
  return 1
}

# Test suites may run supervisor entrypoints only when both the home and state
# they can mutate are inside the same self-cleaning fixture tree.
fm_primary_test_home_isolated() {
  local home=${FM_HOME:-} state=${FM_STATE_OVERRIDE:-} home_root state_root
  [ -n "$home" ] || return 1
  [ -n "$state" ] || state="$home/state"
  home_root=$(fm_test_fixture_root_for_path "$home") || return 1
  state_root=$(fm_test_fixture_root_for_path "$state") || return 1
  [ "$home_root" = "$state_root" ]
}

# Refuse supervisor-only entrypoints outside a primary checkout. The sole test
# exception requires both effective writable roots to be under one disposable
# test fixture; FM_TEST_SEAM and other environment flags grant no authority.
fm_primary_supervisor_guard() {  # <root> <entrypoint>
  local root=$1 entrypoint=$2
  fm_primary_checkout_matches "$root" && return 0
  fm_primary_test_home_isolated && return 0
  printf 'error: refusing supervisor-only %s from a crew/scout worktree or non-primary checkout; return to your own task\n' "$entrypoint" >&2
  return 1
}
