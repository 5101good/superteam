---
name: superteam-build
description: Run an unattended feature across its Repository Set by scheduling complete Implement units and finishing from auditable local evidence.
disable-model-invocation: true
---

# Superteam Build

Build is the unattended controller for one existing feature. It schedules
`superteam-implement` units, validates their terminal evidence, and advances
feature state. Each Implement unit owns its own implementation, review, fixes,
and integration; the controller does not review or integrate ticket code.

## Start or resume

1. Resolve the Root Repository, task path, knowledge path, and feature from a
   validated Project Snapshot. The feature must already have a Current Contract
   and `tickets/`; Build does not write a PRD, Spec, or Plan.
2. Run `st-tickets.sh validate <feature>`. For each frontier ticket, run
   `st-repository-workflow.sh repositories <ticket>` so every declared
   Repository ID resolves to its real Git root.
3. Acquire the feature lease with
   `st-integrate.sh lease-acquire <root> <feature-key> --owner <owner>` and
   refresh it with `lease-heartbeat` at least every 60 seconds and around each
   dispatch round. An active lease held by another owner means `BUSY`. A lease
   whose heartbeat is older than 300 seconds can be taken over with
   `lease-recover --expected-owner <old-owner> --stale-after 300`; a controller
   whose heartbeat reports a new owner stops.
4. On resume, trust ticket files, Results, and real Git history over the
   ledger: a `resolved` ticket without its Result and a reachable integrated
   head is not complete. A promoted head whose tracking Result was interrupted
   resumes through the same Implement unit rather than being implemented again.

## Controller ledger

Keep an append-only, tab-separated ledger beneath the Root Repository's Git
common directory, in a directory derived from a checksum of the feature key.
Write each transition by renaming a complete replacement file into place:

```text
sequence  owner  event  ticket  attempt  expected_head  observed_head  result
```

Events: `START`, `DISPATCH`, `REQUEUE`, `RULING`, `INTEGRATED`, `FINALIZE`,
`DONE`, `BLOCKED`. The ledger records retry counts and rulings; it is not
evidence of completion.

## Schedule the frontier

Each round, run `st-tickets.sh frontier <feature>` and dispatch that snapshot in
stable ID order up to available capacity. Tickets that share an active
Repository worktree do not run in parallel. Each dispatch is one complete
`superteam-implement` unit in `build` mode.

When a unit finishes, check that its Result, per-Repository branch and head
fields, `resolved` state, and Git ancestry agree before appending
`INTEGRATED`. Recompute the frontier from the files after every round.

Choose a model for every agent you start (implementer, recovery implementer,
finalizer) and pass it to `superteam-implement` and the finalizer prompt
explicitly. Match the model to the work rather than inheriting the session
default.

## Rulings, retries, and blocks

Keep the feature moving. When the Current Contract is ambiguous or two tickets
conflict, and a reasonable reading is reversible and stays within the
Repository Set, decide it, append a `RULING` with the decision and its basis,
pass the ruling to the affected unit, and continue. Every ruling is listed in
the feature Result.

- Missing capacity leaves a ticket queued. An incomplete unit gets one fresh
  recovery implementer from the same stable branches and attempt. A transient
  failure appends `REQUEUE` with an incremented attempt.
- A compare-and-swap drift is handled inside the Implement unit.
- `BLOCKED` is for what a ruling cannot settle: a destructive or irreversible
  choice, a need for authority outside the local Repository Set, a contradiction
  that changes what users get, a conflict the conflict workflow could not
  resolve, or a second incomplete implementer. Continue independent tickets and
  report each blocked ticket with the dependants it holds back.

## Finalize

When `st-tickets.sh feature-status <feature>` reports every ticket resolved,
fill [finalizer-prompt.md](finalizer-prompt.md) for one fresh finalizer with the
Current Contract, tickets and Results, each Repository's feature branch, base,
and HEAD, the feature diff, the declared full verification, and a report path
outside every worktree. Check its report against the files and Git state
yourself.

- `REQUEUE`: resume the named Implement unit and return to the frontier loop.
- `DONE` or evidence-backed `BLOCKED`: in a stable tracking worktree, write
  `result.md` starting with the [completion summary](../superteam-implement/result-format.md),
  then the root base and head, ticket summaries, verification, finalizer
  report, retries, rulings, and remaining concerns. Commit only the feature
  tracking directory and compare-and-swap promote it to the canonical feature
  branch. `DONE` exists once the promoted branch contains `result.md` and the
  recorded heads still agree.

Then remove clean controller-owned worktrees, keep canonical branches and any
dirty or blocked worktree, and release the lease.

Build works only locally: it does not run Project Pull, clone, push, open pull
requests, change remotes, or send messages.
