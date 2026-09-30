#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks and supervisor
# entrypoints scoped to a genuine firstmate primary home. This file is sourced
# without side effects.

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

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid secondmate marker force-includes a linked secondmate
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
}

fm_primary_checkout_matches() {
  fm_primary_root_matches "$1"
}

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

# Test suites may run supervisor entrypoints only with an explicit state
# override inside a self-cleaning fixture tree.
fm_primary_test_state_isolated() {
  local state=${FM_STATE_OVERRIDE:-}
  [ -n "$state" ] || return 1
  fm_test_fixture_root_for_path "$state" >/dev/null
}

# Refuse supervisor-only entrypoints outside the primary checkout containing
# this sourced library. Caller-supplied root overrides never establish authority.
fm_primary_supervisor_guard() {  # <entrypoint>
  local entrypoint=${1:-unknown} source_dir root
  source_dir=$(CDPATH='' cd -P "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || source_dir=
  root=
  [ -n "$source_dir" ] && root=$(CDPATH='' cd -P "$source_dir/.." 2>/dev/null && pwd -P) || root=
  if [ -n "$root" ]; then
    fm_primary_checkout_matches "$root" && return 0
    fm_primary_test_state_isolated && return 0
  fi
  printf 'error: refusing supervisor-only %s from a crew/scout worktree or non-primary checkout; return to your own task\n' "$entrypoint" >&2
  return 1
}
