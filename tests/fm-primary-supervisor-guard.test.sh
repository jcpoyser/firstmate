#!/usr/bin/env bash
# Verify supervisor-only entrypoints trust only the checkout that contains
# them: linked worker worktrees are refused whatever root, home, or state
# overrides the caller supplies, including disposable test-fixture state and
# symlinks into it, and a secondmate marker alone never promotes a worker. Plain
# primaries and provisioned secondmate homes keep their startup behavior.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

fm_git_identity
unset FM_TEST_SEAM FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE

TMP_ROOT=$(fm_test_tmproot primary-supervisor-guard)
PRIMARY="$TMP_ROOT/primary"
git clone --quiet --shared "$ROOT" "$PRIMARY" || fail "could not create the plain-primary fixture"
cp -R "$ROOT/bin/." "$PRIMARY/bin/"
git -C "$PRIMARY" add -A bin
git -C "$PRIMARY" commit --quiet --allow-empty -m 'guard test: current supervisor copy' \
  || fail "could not commit the current supervisor copy into the primary fixture"

linked_worktree() {  # <name>
  local path
  path=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-supervisor-$1.XXXXXX") || return 1
  printf '%s\n' "$path" >> "$FM_TEST_CLEANUP_REGISTRY"
  rmdir "$path"
  git -C "$PRIMARY" worktree add --quiet --detach "$path" HEAD || return 1
  path=$(cd -P "$path" && pwd -P) || return 1
  [ "$(git -C "$path" rev-parse --git-dir)" != "$(git -C "$path" rev-parse --git-common-dir)" ] || return 1
  printf '%s\n' "$path"
}

outside_dir() {  # <name>
  local path
  path=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-supervisor-$1.XXXXXX") || return 1
  printf '%s\n' "$path" >> "$FM_TEST_CLEANUP_REGISTRY"
  cd -P "$path" && pwd -P
}

WORKER=$(linked_worktree worker) || fail "could not create the linked worker fixture"
WORKER_HOME=$(outside_dir worker-home) || fail "could not create an isolated worker home"

snapshot_tree() {
  {
    find "$1" -print
    find "$1" -type f -exec cksum {} \;
  } | LC_ALL=C sort
}

assert_refused() {  # <label> <err-file> <status>
  [ "$3" -eq 1 ] || fail "$1 was not refused (exit $3)"
  grep -Fq 'return to your own task' "$2" || fail "$1 refusal did not tell the worker to return to its task"
}

scripts=(
  fm-wake-drain.sh
  fm-watch-arm.sh
  fm-watch.sh
  fm-session-start.sh
  fm-lock.sh
  fm-bootstrap.sh
  fm-startup-network.sh
  fm-inactive-reconcile.sh
  fm-guard.sh
  fm-watch-checkpoint.sh
  fm-supervision-host.sh
  fm-afk-contract.sh
  fm-afk-launch.sh
  fm-afk-return.sh
  fm-afk-start.sh
  fm-supervise-daemon.sh
  fm-branch-outcome.sh
  fm-branch-report.sh
)
for script in "${scripts[@]}"; do
  args=(--help)
  case "$script" in
    fm-bootstrap.sh) args=(install __guard_test_unknown_tool__) ;;
    fm-afk-contract.sh) args=(enter --words worker-must-not-write) ;;
    fm-afk-launch.sh) args=(enter --words worker-must-not-write) ;;
    fm-afk-return.sh) args=(begin) ;;
    fm-branch-outcome.sh) args=(append --task guard-test --verdict routine --summary worker-must-not-write) ;;
    fm-branch-report.sh) args=(--task guard-test --verdict routine --summary worker-must-not-write) ;;
  esac
  before=$(snapshot_tree "$WORKER_HOME")
  status=0
  fm_run_timed 5 env \
    FM_ROOT_OVERRIDE="$PRIMARY" \
    FM_HOME="$WORKER_HOME" \
    FM_STATE_OVERRIDE="$WORKER_HOME/state" \
    FM_POLL=1 FM_ARM_CONFIRM_TIMEOUT=1 FM_SUPERVISION_HOST_PARK_SECONDS=1 \
    "$WORKER/bin/$script" "${args[@]}" > "$TMP_ROOT/$script.out" 2> "$TMP_ROOT/$script.err" || status=$?
  assert_refused "$script with a primary root override" "$TMP_ROOT/$script.err" "$status"
  [ "$before" = "$(snapshot_tree "$WORKER_HOME")" ] || fail "$script changed the worker home before refusing"
done

status=0
fm_run_timed 5 env FM_TEST_SEAM=1 \
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$WORKER_HOME" FM_STATE_OVERRIDE="$WORKER_HOME/state" \
  "$WORKER/bin/fm-wake-drain.sh" --help > "$TMP_ROOT/seam.out" 2> "$TMP_ROOT/seam.err" || status=$?
assert_refused "FM_TEST_SEAM" "$TMP_ROOT/seam.err" "$status"

# Fixture state under a live test-fixture marker grants no authority.
FIXTURE_STATE="$TMP_ROOT/fixture-home/state"
mkdir -p "$FIXTURE_STATE"
for root_override in '' "$PRIMARY"; do
  status=0
  fm_run_timed 5 env ${root_override:+FM_ROOT_OVERRIDE="$root_override"} \
    FM_HOME="$TMP_ROOT/fixture-home" FM_STATE_OVERRIDE="$FIXTURE_STATE" \
    "$WORKER/bin/fm-wake-drain.sh" > "$TMP_ROOT/fixture-state.out" 2> "$TMP_ROOT/fixture-state.err" || status=$?
  assert_refused "fixture-state override (root override '${root_override}')" "$TMP_ROOT/fixture-state.err" "$status"
  [ ! -e "$FIXTURE_STATE/.wake-queue" ] || fail "refused fixture-state drain initialized the fixture queue"
done

# A fixture path that is a symlink into live state grants no authority and
# leaves the live queue untouched.
LIVE_STATE=$(outside_dir live-state) || fail "could not create the live-state stand-in"
printf 'live wake that a worker must never drain\n' > "$LIVE_STATE/.wake-queue"
ln -s "$LIVE_STATE" "$TMP_ROOT/fixture-home/linked-state"
before=$(snapshot_tree "$LIVE_STATE")
status=0
fm_run_timed 5 env FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_HOME="$TMP_ROOT/fixture-home" FM_STATE_OVERRIDE="$TMP_ROOT/fixture-home/linked-state" \
  "$WORKER/bin/fm-wake-drain.sh" > "$TMP_ROOT/linked-state.out" 2> "$TMP_ROOT/linked-state.err" || status=$?
assert_refused "symlinked fixture state" "$TMP_ROOT/linked-state.err" "$status"
[ "$before" = "$(snapshot_tree "$LIVE_STATE")" ] || fail "symlinked fixture drain changed the live state"

# A secondmate marker alone, or with an unregistered parent binding, never
# promotes a linked worker.
PARENT_HOME="$TMP_ROOT/parent-home"
mkdir -p "$PARENT_HOME/data" "$PARENT_HOME/state"
MATE_HOME="$TMP_ROOT/mate-home"
mkdir -p "$MATE_HOME"
printf '%s\n' guard-test-mate > "$WORKER/.fm-secondmate-home"
status=0
fm_run_timed 5 env FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE="$MATE_HOME/state" \
  "$WORKER/bin/fm-lock.sh" status > "$TMP_ROOT/marker-only.out" 2> "$TMP_ROOT/marker-only.err" || status=$?
assert_refused "marker-only linked checkout" "$TMP_ROOT/marker-only.err" "$status"
[ ! -e "$MATE_HOME/state" ] || fail "marker-only checkout created state before refusing"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT_HOME" > "$WORKER/.fm-secondmate-parent"
status=0
fm_run_timed 5 env FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE="$MATE_HOME/state" \
  "$WORKER/bin/fm-lock.sh" status > "$TMP_ROOT/unregistered.out" 2> "$TMP_ROOT/unregistered.err" || status=$?
assert_refused "unregistered secondmate binding" "$TMP_ROOT/unregistered.err" "$status"
[ ! -e "$MATE_HOME/state" ] || fail "unregistered secondmate checkout created state before refusing"

# A provisioned secondmate home: marker, local parent binding, and the parent's
# registry entry naming this checkout as that mate's home.
MATE=$(linked_worktree secondmate) || fail "could not create the linked secondmate fixture"
printf '%s\n' guard-test-mate > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT_HOME" > "$MATE/.fm-secondmate-parent"
printf -- '- guard-test-mate - Guard test mate (home: %s; scope: guard tests; projects: none; added 2026-09-29)\n' \
  "$MATE" > "$PARENT_HOME/data/secondmates.md"
mate_output=$(env FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE="$MATE_HOME/state" \
  "$MATE/bin/fm-lock.sh" status 2>&1) || fail "provisioned secondmate lock status was refused: $mate_output"
assert_contains "$mate_output" 'lock: free' "provisioned secondmate invocation changed"
status=0
fm_run_timed 5 env FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE="$MATE_HOME/state" \
  "$WORKER/bin/fm-lock.sh" status > "$TMP_ROOT/other-home.out" 2> "$TMP_ROOT/other-home.err" || status=$?
assert_refused "worker binding to another mate's registry entry" "$TMP_ROOT/other-home.err" "$status"

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME"
primary_output=$(env FM_HOME="$PRIMARY_HOME" FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  "$PRIMARY/bin/fm-lock.sh" status 2>&1) || fail "plain primary lock status was refused: $primary_output"
assert_contains "$primary_output" 'lock: free' "plain primary invocation changed"
[ -d "$PRIMARY_HOME/state" ] || fail "primary lock invocation did not create its initial state directory"

pass "supervisor guard trusts only the executing checkout: overrides, fixture state, and bare markers never admit a worker"
