---
name: superteam-build
description: Run an unattended feature across its Repository Set by scheduling complete Implement units and finishing from auditable local evidence.
disable-model-invocation: true
---

# Superteam Build

Build is the unattended controller for one existing feature. It schedules work,
validates terminal evidence, and advances feature state. It does not implement,
review, repair, or integrate ticket code.

## Establish the executable feature

1. Resolve the Root Repository, custom task path, custom knowledge path, and
   feature directory from a validated Project Snapshot. Require an existing
   Current Contract and an existing `tickets/` directory. Do not create or
   revise a PRD, Spec, Plan, or ticket breakdown from Build.
2. Run `st-tickets.sh validate <feature>`. For every frontier ticket, run
   `st-repository-workflow.sh repositories <ticket>` and require every declared
   stable Repository ID to resolve again to its exact real Git root. The
   Project order is `root` first followed by manifest order; root-only is the
   one-member case. Never reinterpret a monorepo directory as a Repository.
3. Treat every schema-valid PRD or Spec as current as written, and every
   `ready-for-agent` ticket as schedulable when its blockers are resolved. Do
   not require a PRD, Spec, or Plan status gate.
4. Do not run Project Pull. Build starts from the local Repository and ticket
   facts the user explicitly placed in scope; it does not contact or update a remote.

## Own one controller lease and ledger

Derive one unique owner token for a new Build invocation. Acquire the feature
lease with:

```text
st-integrate.sh lease-acquire <root> <feature-key> --owner <owner>
```

The lease excludes a second owner. While Build runs, refresh its liveness at
least once per 60 seconds and before and after each dispatch round with:

```text
st-integrate.sh lease-heartbeat <root> <feature-key> --owner <owner>
```

A different owner receiving an active lease response reports `BUSY`, not `BLOCKED`.
The published expiry is 300 seconds. After the recorded heartbeat is
that old, a new invocation may use the ledger's last owner as an expected value
and atomically recover the expired lease:

```text
st-integrate.sh lease-recover <root> <feature-key> --owner <new-owner> --expected-owner <old-owner> --stale-after 300
```

Recovery rechecks the owner and heartbeat while holding the lease transition
guard. It fails when the owner changed or the prior controller is still live;
the old controller must stop if its next heartbeat reports a new owner. Release
the lease on normal `DONE` or evidence-backed `BLOCKED`; preserve its owner,
heartbeat, and ledger facts when the host interrupts the controller.

Maintain an append-only controller ledger beneath the Root Repository's real
Git common directory, never inside a Repository worktree. Derive its directory
from the feature key with a portable checksum, reject control characters, and
record one tab-separated transition at a time with these fields:

```text
sequence  owner  event  ticket  attempt  expected_head  observed_head  result
```

The supported events are `START`, `DISPATCH`, `REQUEUE`, `INTEGRATED`,
`FINALIZE`, `DONE`, and `BLOCKED`. Write a replacement file in the same
directory and rename it into place so an ordinary interruption leaves either
the prior record set or the complete next record set. The ledger is local
controller state, not a source-code commit and not an execution command.

On every start or resume, rebuild state in this order:

1. validate the Current Contract and tickets again;
2. read ticket status, branch evidence, and each Result;
3. compare every recorded base, ticket head, prepared head, and integrated head
   for every declared Repository with its real Git HEAD and ancestry; and
4. use the ledger only to recover the last attempted transition and retry
   count.

Ticket/Result content and observed Git history outrank a stale ledger entry. A
`resolved` label without its Result and reachable integrated head is invalid,
not completed. A promoted head whose tracking Result was interrupted is
resumed through the same `superteam-implement` tracking flow instead of being
implemented twice.

## Schedule the dependency frontier

For each controller round, compute the runnable set with
`st-tickets.sh frontier <feature>`. Dispatch only that complete snapshot of
ticket IDs, in stable ID order, up to the currently available agent capacity.
Independent frontier tickets may run in parallel; tickets with a blocker or
any shared active Repository worktree never do.

Every dispatch is one complete `superteam-implement` unit in `build` mode. The
unit owns the fixed-base Implement -> Review -> Fix -> Integrate sequence,
including fresh independent Standards and Spec reviewers, all finding
decisions, conflict resolution, verification, commits, and its structured
Result. The Build controller validates that terminal package but does not review code or adjudicate findings.
It also does not integrate ticket code or create claim, Result, or resolved
tracking commits on the Implement unit's behalf.

Validate completed units in stable ticket-ID order. After an Implement unit's
own all-prepare and recoverable stable-order promotion, observe every declared
canonical feature HEAD again and append `INTEGRATED` only when its ticket
Result, per-Repository branch/head fields, resolved state, and Git ancestry
agree. A partially promoted Repository Set remains inside that Implement unit;
the controller records its terminal evidence but does not adjudicate or finish
the integration. Recompute `st-tickets.sh frontier` after the complete round;
never schedule a dependent from an in-memory prediction.

## Retry and terminal classification

Use deterministic retry and requeue rules rather than treating every unsuccessful
turn as a feature failure:

- no current agent capacity leaves the ticket queued; append no failure and
  retry the same frontier when capacity returns;
- an incomplete worker session gets one fresh recovery implementer in the same
  stable worktree, branch, fixed base, and attempt;
- Review findings remain inside the same Implement unit until fixed, scoped
  re-review succeeds, or that unit reaches its documented five-round limit;
- a compare-and-swap drift refreshes from the observed Repository head,
  preserves both histories, reruns the affected verification and both review
  axes, then resumes the recorded stable-order promotion without re-promoting
  completed members;
- a transient controller or agent failure appends `REQUEUE` with the same
  ticket and incremented attempt, then returns it to the stable queue; and
- external authority, invalid or contradictory Current Contract state, an
  unresolved conflict after the independent conflict workflow, or a second
  incomplete implementer produces evidence-backed `BLOCKED`.

Never classify agent capacity, an active other controller, or a first
recoverable worker/CAS failure as `BLOCKED`. Continue independent frontier work
when one ticket is blocked, then report the blocked ticket and every dependant
that cannot become runnable.

## Finalize from evidence

Only when `st-tickets.sh feature-status <feature>` reports all tickets resolved,
fill `finalizer-prompt.md` and start one fresh feature finalizer. Supply the
Current Contract, every ticket and Result, each canonical Repository feature
branch with its base and current HEAD, the complete multi-Repository feature
diff package, declared full verification, and a report path outside every
Repository worktree.

The finalizer independently checks evidence and runs full verification; it does
not implement or review ticket code. Validate its report against the files and
real Git state yourself. A green log must not replace a missing Result,
unreachable integrated head, dirty canonical worktree, or incomplete
acceptance evidence.

If the finalizer proposes `REQUEUE`, resume the named Implement unit from its
stable recovery facts and return to the frontier loop. Do not write a terminal
feature Result for a recoverable evidence gap. Only `DONE` or an
evidence-backed `BLOCKED` proposal may continue to terminal tracking.

On success, create `result.md` in a stable tracking worktree with outcome
`DONE`, completion time, canonical root base and head, ticket Result summary,
full-verification evidence, finalizer report, retries, and remaining concerns.
Stage and commit exactly the feature tracking directory, then compare-and-swap
promote that tracking commit to the canonical feature branch. `DONE` exists
only after the promoted branch contains `result.md` and all recorded heads
still agree. On a terminal failure, write the same evidence with outcome
`BLOCKED` and the exact authority, contract, conflict, or repeated-failure
reason.

Remove only clean controller-owned temporary worktrees after terminal state.
Keep canonical feature branches and any dirty or blocked recovery worktree.
Release the controller lease only after the terminal tracking commit is
reachable.

## Side-effect boundary

Build may create local controller ledger entries, feature-finalization branches
and worktrees, and the terminal feature Result in `root`. Scheduled Implement
units own their exact ticket tracking and per-Repository implementation commits.
Build itself must not stage or commit those files, a submodule gitlink, another
task or knowledge path, unrelated Repository files, or a worker's dirty
worktree. Report any observed submodule parent dirty state. Do not clone, run
Project Pull, push, create a pull request, call a remote service, or send a message.
Do not create, change, or remove a remote.
