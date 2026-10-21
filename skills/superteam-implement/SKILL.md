---
name: superteam-implement
description: Implement, independently review, fix, and locally integrate one ready Superteam ticket across its declared Repository Set.
---

# Superteam Implement

Own one ticket's complete Implement -> Review -> Fix -> Integrate loop. Build
may schedule this Skill and check its terminal evidence; findings are decided
here.

## Set up the Repository unit

1. Resolve the feature, Root Repository, task and knowledge paths, and the
   ticket's Repository Set from a validated Project Snapshot. Run
   `st-tickets.sh validate <feature>`; every blocker must be resolved.
2. Run `st-repository-workflow.sh repositories <ticket>`. Its output (root
   first, then manifest order, each with its real Git root) is the complete
   write boundary. A root-only ticket is the one-member case.
3. Standalone, acquire the feature lease with `st-integrate.sh lease-acquire`;
   under Build, use Build's lease.
4. Branches are `superteam/<feature>-ticket-<ticket>-<repository>` and
   `superteam/<feature>-integrate-<ticket>-<repository>`. Derive every worktree
   path with `st-worktree.sh stable-path` (roles `ticket`, `integration`,
   `tracking-claim`, `tracking-result`) so a resumed run finds the same paths.
5. Claim the ticket: prepare the root feature branch with
   `st-worktree.sh prepare-feature`, run `st-tickets.sh claim` in the
   `tracking-claim` worktree on `superteam/<feature>-track-<ticket>-claim`,
   commit only the feature tracking directory, and compare-and-swap promote it
   into the root feature branch. If the head moved, prepare the claim against
   the new head in the `tracking-claim-integration` worktree and retry.
6. Run `st-repository-workflow.sh start <ticket>` to create one ticket branch
   and worktree per declared Repository from the feature head. On resume, check
   each recorded base and head before continuing.

## Implement and review

Fill [implementer-prompt.md](implementer-prompt.md) and start one fresh
implementer with an explicitly chosen model. Give it the mode (`standalone` or
`build`), the ticket and Spec, each Repository ID with its worktree and fixed
base, the verification commands, the relevant Repository Context and ADRs, any
Build rulings, and a Result path outside every worktree. It does not get the
controller ledger or write access to task or knowledge.

The implementer owns TDD, local commits, the two independent review axes,
fixes, and scoped re-review, and it chooses the reviewers' models. If its
session ends without a Result, start one recovery implementer from the same
branches and partial Result; a second incomplete session blocks the ticket.

## Integrate

1. Check the Result: its [completion summary](result-format.md), green
   verification, each Repository's commits and changed files, clean worktrees,
   separate Standards and Spec verdicts, and every finding's disposition.
   Standalone runs the agreed full verification once; Build leaves that to its
   finalizer.
2. Run `st-repository-workflow.sh prepare <ticket> <state>` with a state path
   outside every worktree. It prepares every integration branch before any
   feature ref moves. On conflict, start a fresh
   `superteam-resolving-merge-conflicts` agent for that worktree, rerun the
   affected checks, and prepare the whole set again.
3. Run `st-repository-workflow.sh promote <ticket> <state>`. Rerun it with the
   same state after an interruption. If a compare-and-swap drifts after some
   members advanced, report the partial state, refresh through the conflict
   workflow, rerun verification and both review axes on the effective diff,
   and resume.
4. After code promotion, on `superteam/<feature>-track-<ticket>-result` in the
   `tracking-result` worktree, record each Repository's `base`,
   `feature_branch`, `ticket_branch`, `ticket_head`, `prepared_head`, and
   `integrated_head`, write the Result, run `st-tickets.sh resolve`, commit the
   feature tracking directory, and compare-and-swap promote it (retrying
   through `tracking-result-integration` on drift). The ticket is done when the
   promoted root feature head holds its Result, branch evidence, and
   `resolved` state.
5. Remove clean worktrees, release a standalone lease, and report each
   Repository's status. Keep dirty or blocked worktrees for recovery. Declared
   submodules are ordinary members: report any parent dirty state instead of
   committing a gitlink.

All work stays local: no Project Pull, push, pull request, remote change, or
message.
