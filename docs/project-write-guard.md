# Primary-session project-write guard

This document owns the contract for the primary-session project-write PreToolUse guard.
`bin/fm-project-write-command-policy.mjs` owns classification and reuses `Lexer`, `splitProgram`, and `commandPosition` from `bin/fm-arm-command-policy.mjs`.
`bin/fm-project-write-pretool-check.sh` owns primary-checkout scoping, hook transport, and deny rendering.

## Purpose and scope

The guard enforces hard rule 1 in [`AGENTS.md`](../AGENTS.md) at the moment the primary firstmate attempts to change a project clone or worker copy.
It covers every directory under `FM_HOME/projects/` and `FM_ROOT/projects/`, plus absolute worktree paths read from `worktree=` fields in `state/*.meta`.

The guard runs only in a plain firstmate checkout where git-dir equals git-common-dir and the checkout has `AGENTS.md` and `bin/`.
It is inert in linked crew and scout worktrees, so worker sessions are not affected.
The Pi supervision branch uses the same Pi tool-call hook and policy when it runs tools through that extension.

The guard blocks state-changing Git commands aimed at a protected path, including fetch, pull, commit, checkout, switch, reset, restore, stash, merge, rebase, push, clean, tag creation, branch deletion, am, cherry-pick, clone destinations, init paths, worktree destinations, and submodule additions.
Unknown Git subcommands aimed at a protected path are blocked unless they are explicitly classified as read-only.
Read-only commands including status, log, diff, show, and rev-parse remain allowed, including with `git -C <dir>`.

The guard also blocks shell file changes aimed at protected paths, including rm, mv, cp into a protected path, output redirection, tee, sed -i, and common filesystem mutators.
Native file-write and file-edit tools are blocked when their target path is protected.
Guarded Firstmate scripts under `bin/` remain callable because this policy classifies the submitted tool command and never inspects script internals.

A denial says the change was blocked and directs the agent to delegate the change to a worker.
For Git review, the denial directs the agent to read GitHub instead of fetching.

## Captain-approved one-command exception

A concrete captain-approved project operation may be run with a one-command approval prefix, for example:

```sh
FM_PROJECT_WRITE_APPROVAL='Captain explicitly approved: git -C projects/example fetch origin' git -C projects/example fetch origin
```

The approval text must begin `Captain explicitly approved: ` and its remaining text must exactly match the command words that follow the assignment.
The checker only accepts this form for one simple shell command with no other environment assignments, wrappers, shell lists, groups, substitutions, or redirections.

Each accepted exception appends a JSON record containing the timestamp, approval statement, and exact command to `state/project-write-approvals.jsonl` before the command is allowed.
If the record cannot be written, the operation remains blocked.
This is not a standing switch; the approval prefix applies only to the single command carrying it.
Use the captain's concrete, current approval in the statement, and never infer approval from this documented mechanism.

## Harness wiring

The project-write checker is registered beside the cd guard for Claude, Codex, Grok, OpenCode, Pi, omp, and Cursor.
Claude, Codex, Grok, and Cursor register the checker for all PreToolUse tools so native file tools are covered as well as shell commands.
OpenCode, Pi, and omp forward each tool's name and input through their existing primary hook surface.
The checker renders the denial in the format expected by each adapter.

## Validation

`tests/fm-project-write-pretool-check.test.sh` owns the portable acceptance matrix for Git mutations and reads, shell writes, recorded worktree paths, native file tools, the one-command exception, worker-worktree inertness, and hook wiring parity.

Run:

```sh
bash -n bin/fm-project-write-pretool-check.sh
shellcheck bin/fm-project-write-pretool-check.sh tests/fm-project-write-pretool-check.test.sh
node --check bin/fm-project-write-command-policy.mjs
node --check bin/fm-arm-command-policy.mjs
tests/fm-project-write-pretool-check.test.sh
```

The portable test proves the policy and all adapter payload/configuration shapes without launching a vendor harness.
The prompt-submitting real-harness guard is opt-in and runs with `FM_PROJECT_WRITE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-project-write-pretool-check.test.sh tests/fm-project-write-live-e2e.test.sh`.
The dated Claude, Codex, and Pi results, along with adapters not installed during verification, are recorded in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md#primary-project-write-pretooluse-guard).
