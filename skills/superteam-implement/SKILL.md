---
name: superteam-implement
description: Implement, independently review, fix, and locally integrate one ready Superteam ticket across its declared Repository Set.
---

# Superteam Implement

Own one ticket's complete Implement -> Review -> Fix -> Integrate loop. The
Build controller may schedule this Skill and validate its terminal evidence,
but it must not review code or adjudicate findings inside the loop.

## Establish the Repository unit

1. Resolve the ticket's feature, Root Repository, custom task path, custom
   knowledge path, and Repository Set from a validated Project Snapshot. Run
   `st-tickets.sh validate <feature>` and require every blocker to be resolved.
2. Treat the ticket's Repository IDs as the complete write boundary. Run
   `st-repository-workflow.sh repositories <ticket>` before mutation: it orders
   `root` first and other declared members by their `superteam.yaml` order,
   displays every current real Git root, and fails when a path is missing or no
   longer resolves to that exact root. Never substitute a nearby checkout or
   reinterpret a source directory or monorepo package as a Repository. A
   root-only ticket is the one-member case of this same flow.
3. In standalone mode, acquire the feature integration lease in `root` with
   `st-integrate.sh lease-acquire`; when called by Build, use the lease owned by
   that Build invocation. A lease coordinates local integration only and does
   not grant remote authority.
4. Use stable branch names derived from the feature ID, ticket ID, and each
   Repository ID:
   `superteam/<feature>-ticket-<ticket>-<repository>` for a ticket branch and
   `superteam/<feature>-integrate-<ticket>-<repository>` for its integration branch.
   Derive every absolute path with `st-worktree.sh stable-path` using the
   `ticket`, `integration`, `tracking-claim`, or `tracking-result` role. Paths
   are deterministic recovery facts and are recomputed rather than stored in
   ticket frontmatter.
5. Prepare the canonical root feature branch with
   `st-worktree.sh prepare-feature`. Create
   `superteam/<feature>-track-<ticket>-claim` at its recorded head in the stable
   root `tracking-claim` worktree. Run `st-tickets.sh claim` there, stage only
   the feature tracking directory, commit the claim, and compare-and-swap
   promote that tracking branch into the canonical root feature. If the head
   moved, prepare the claim commit against the new feature head in a stable
   `tracking-claim-integration` worktree and use the conflict workflow before
   retrying promotion.
6. Only after the claim commit is canonical, run
   `st-repository-workflow.sh start <ticket>`. It validates the complete set
   before mutation, prepares the same canonical feature branch in every member,
   and creates one stable isolated ticket branch and worktree per declared ID.
   If existing branches are resumed, recompute and verify every path, recorded
   base, and current head before continuing. Record the exact Repository ID,
   real root, fixed base, branch, worktree, and topology for every member.

## Start a fresh implementer

Fill [implementer-prompt.md](implementer-prompt.md) and start one fresh
implementer context. Supply only:

- invocation mode (`standalone` or `build`);
- the ticket and feature-local Spec, which are the Current Contract;
- every validated Repository ID, worktree, and fixed base in stable Project order;
- verification commands declared by that Current Contract or explicitly by the
  caller;
- each Repository Context and relevant ADRs resolved beneath the custom
  knowledge path; and
- a temporary Result output path outside every Repository worktree.

Do not give the implementer the Initialization Manifest, controller ledger, or
permission to modify task or knowledge. It owns TDD, precise local commits in
each declared Repository, two fresh independent review axes, fixes, and scoped
re-review. If its session ends without a terminal Result, one fresh recovery
implementer may resume from the same branches, worktrees, fixed bases, and
partial Result. A second incomplete session blocks the ticket with evidence.

## Validate and integrate

1. Validate the Result's [completion summary](result-format.md), focused and
   green verification, each Repository's ticket commit and changed-file list,
   clean worktrees, separate Standards and Spec verdicts, and every finding
   disposition. Standalone mode
   also requires the agreed full verification once; Build may defer
   feature-wide verification to its finalizer.
2. Create a state path outside every Repository worktree, then run
   `st-repository-workflow.sh prepare <ticket> <state>`. It prepares every
   integration branch before any canonical feature ref can advance. If any
   Repository conflicts or fails validation, no member is promoted. Start a
   fresh independent `superteam-resolving-merge-conflicts` agent for the exact
   active worktree, preserve both intents, rerun affected checks, and repeat
   prepare for the complete set.
3. Run `st-repository-workflow.sh promote <ticket> <state>`. It preflights every
   pending compare-and-swap before the first promotion, then promotes in stable
   Project order and atomically records each completed Repository. On
   interruption, rerun it with the same state: recorded heads plus real refs
   distinguish already-promoted members from pending members without duplicate
   commits. If a later CAS drifts after earlier members advanced, report the
   exact partial state, refresh only through the independent conflict workflow,
   rerun affected verification and both review axes against the effective diff,
   then resume; never overwrite a ref or conceal partial completion.
4. After every Repository code promotion, create
   `superteam/<feature>-track-<ticket>-result` from the promoted root feature
   head in the stable `tracking-result` worktree. There, record the supported
   branch fields (`base`, `feature_branch`, `ticket_branch`, `ticket_head`,
   `prepared_head`, and `integrated_head`) for every declared ID, write the
   validated Result, and call `st-tickets.sh resolve`. Stage only the feature
   tracking directory in `root` and commit it. The fresh code implementer never
   performs these coordinator-owned writes.
5. Compare-and-swap promote the result tracking commit into the same canonical
   root feature branch. On drift, prepare that commit against the new head in
   the stable `tracking-result-integration` worktree, use the independent
   conflict workflow, verify the tracking diff, and retry. A ticket is terminal
   only after the promoted root feature head contains its Result, per-Repository
   branch/head evidence, and `resolved` state. Otherwise it stays claimed or
   becomes blocked with recovery evidence.
6. After each phase, report Repository Set status. Existing submodules are
   ordinary declared members: never recurse into submodules, update their
   checked-out gitlink, or create a parent gitlink commit. If a submodule action
   leaves its superproject dirty, report that observed state exactly.
7. Remove clean integration and ticket worktrees in every member plus root
   tracking worktrees after the terminal tracking commit. In standalone mode,
   release the integration lease. Preserve dirty or blocked worktrees for
   recovery and report them explicitly.

Do not run documentation workflows as an implicit completion gate.
Do not run Project Pull implicitly.
Do not push, create a pull request, or send a message. Do not create, change, or delete
a remote.
