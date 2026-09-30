#!/usr/bin/env bash
# Verify supervisor-only entrypoints refuse linked worker worktrees before
# they touch the worker's home, while ordinary and marked secondmate primaries
# retain their existing startup behavior.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot primary-supervisor-guard)
PRIMARY="$TMP_ROOT/primary"
WORKER="$TMP_ROOT/worker"
mkdir -p "$TMP_ROOT"
git clone --quiet --shared "$ROOT" "$PRIMARY" || fail "could not create the plain-primary fixture"
git -C "$PRIMARY" worktree add --quiet --detach "$WORKER" HEAD || fail "could not create the linked worker fixture"

primary_git_dir=$(git -C "$PRIMARY" rev-parse --git-dir)
primary_common_dir=$(git -C "$PRIMARY" rev-parse --git-common-dir)
[ "$primary_git_dir" = "$primary_common_dir" ] || fail "primary fixture is not a plain checkout"
worker_git_dir=$(git -C "$WORKER" rev-parse --git-dir)
worker_common_dir=$(git -C "$WORKER" rev-parse --git-common-dir)
[ "$worker_git_dir" != "$worker_common_dir" ] || fail "worker fixture is not a linked worktree"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$ROOT/bin/fm-primary-scope-lib.sh"
unset FM_TEST_SEAM
fm_primary_checkout_matches "$PRIMARY" \
  || fail "plain primary checkout was not recognized"
if fm_primary_checkout_matches "$WORKER"; then
  fail "linked worker checkout was recognized as a primary"
fi
printf '%s\n' guard-test-mate > "$WORKER/.fm-secondmate-home"
fm_primary_checkout_matches "$WORKER" \
  || fail "valid linked secondmate primary was not recognized"
rm -f "$WORKER/.fm-secondmate-home"

WORKER_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-supervisor-worker-home.XXXXXX") \
  || fail "could not create an isolated worker home"
printf '%s\n' "$WORKER_HOME" >> "$FM_TEST_CLEANUP_REGISTRY"
snapshot_home() {
  {
    find "$1" -print
    find "$1" -type f -exec cksum {} \;
  } | LC_ALL=C sort
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
  before=$(snapshot_home "$WORKER_HOME")
  output="$TMP_ROOT/$script.out"
  error="$TMP_ROOT/$script.err"
  status=0
  fm_run_timed 5 env -u FM_TEST_SEAM \
    FM_ROOT_OVERRIDE="$PRIMARY" \
    FM_HOME="$WORKER_HOME" \
    FM_STATE_OVERRIDE="$WORKER_HOME/state" \
    FM_POLL=1 FM_ARM_CONFIRM_TIMEOUT=1 FM_SUPERVISION_HOST_PARK_SECONDS=1 \
    "$WORKER/bin/$script" "${args[@]}" > "$output" 2> "$error" || status=$?
  [ "$status" -eq 1 ] || fail "$script did not refuse the worker invocation (exit $status)"
  grep -Fq 'return to your own task' "$error" \
    || fail "$script refusal did not tell the worker to return to its task"
  after=$(snapshot_home "$WORKER_HOME")
  [ "$before" = "$after" ] || fail "$script changed the worker home before refusing"
done

STATE_ONLY="$TMP_ROOT/state-only/state"
mkdir -p "$STATE_ONLY"
before=$(snapshot_home "$WORKER")
status=0
env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_TEST_SEAM \
  FM_STATE_OVERRIDE="$STATE_ONLY" \
  "$WORKER/bin/fm-wake-drain.sh" > "$TMP_ROOT/state-only.out" 2> "$TMP_ROOT/state-only.err" || status=$?
[ "$status" -eq 0 ] || fail "state-override-only fixture invocation was refused (exit $status)"
[ -f "$STATE_ONLY/.wake-queue" ] \
  || fail "state-override-only invocation did not initialize the fixture queue"
after=$(snapshot_home "$WORKER")
[ "$before" = "$after" ] || fail "state-override-only drain changed the linked worker checkout"

before=$(snapshot_home "$WORKER_HOME")
status=0
fm_run_timed 5 env FM_TEST_SEAM=1 \
  FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_HOME="$WORKER_HOME" \
  FM_STATE_OVERRIDE="$WORKER_HOME/state" \
  "$WORKER/bin/fm-wake-drain.sh" --help > "$TMP_ROOT/seam.out" 2> "$TMP_ROOT/seam.err" || status=$?
[ "$status" -eq 1 ] || fail "FM_TEST_SEAM bypassed the worker guard (exit $status)"
grep -Fq 'return to your own task' "$TMP_ROOT/seam.err" \
  || fail "FM_TEST_SEAM refusal did not name the worker action"
after=$(snapshot_home "$WORKER_HOME")
[ "$before" = "$after" ] || fail "FM_TEST_SEAM invocation changed the worker home"

PRIMARY_HOME="$TMP_ROOT/primary-home"
mkdir -p "$PRIMARY_HOME"
status=0
env -u FM_STATE_OVERRIDE -u FM_TEST_SEAM \
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY_HOME" \
  "$WORKER/bin/fm-wake-drain.sh" > "$TMP_ROOT/no-state-override.out" 2> "$TMP_ROOT/no-state-override.err" || status=$?
[ "$status" -eq 1 ] || fail "fixture FM_HOME without explicit state override was accepted (exit $status)"
grep -Fq 'return to your own task' "$TMP_ROOT/no-state-override.err" \
  || fail "missing-state-override refusal did not name the worker action"
[ ! -d "$PRIMARY_HOME/state" ] || fail "missing-state-override invocation created default state"
primary_output=$(env -u FM_TEST_SEAM \
  FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_HOME="$PRIMARY_HOME" \
  FM_STATE_OVERRIDE="$PRIMARY_HOME/state" \
  "$PRIMARY/bin/fm-lock.sh" status 2>&1) || fail "plain primary lock status was refused: $primary_output"
assert_contains "$primary_output" 'lock: free' "plain primary invocation changed"
[ -d "$PRIMARY_HOME/state" ] || fail "primary lock invocation did not create its initial state directory"

MATE_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$MATE_HOME"
printf '%s\n' guard-test-mate > "$WORKER/.fm-secondmate-home"
mate_output=$(env -u FM_TEST_SEAM \
  FM_ROOT_OVERRIDE="$WORKER" \
  FM_HOME="$MATE_HOME" \
  FM_STATE_OVERRIDE="$MATE_HOME/state" \
  "$WORKER/bin/fm-lock.sh" status 2>&1) || fail "marked secondmate primary lock status was refused: $mate_output"
assert_contains "$mate_output" 'lock: free' "secondmate primary invocation changed"
rm -f "$WORKER/.fm-secondmate-home"

pass "primary supervisor guard refuses worker entrypoints without home changes and preserves primary scopes"
