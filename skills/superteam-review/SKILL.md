---
name: superteam-review
description: Review a fixed-base Git change independently for documented standards and contract fidelity without changing repository state.
---

# Superteam Review

Review one Repository's effective change from a caller-supplied fixed base through the current worktree. Review is read-only and remains independent of the Build controller. For a multi-Repository change, invoke this Skill once per Repository with that Repository's own fixed base; a commit ID is never reused across repositories.

## Prepare the evidence

1. Require the caller to identify the Repository and its `<fixed-base>`. If direct invocation omits either, ask for it before proceeding.
2. Resolve and verify that Repository through the Project Snapshot, then run `st-review-package.sh <fixed-base> WORKTREE` from its Git root and retain the resulting package in the review context. Stop if the base is invalid or the effective change is empty.
3. Read the Repository's `CONTEXT.md`, relevant ADRs, and documented standards such as `AGENTS.md` or `CONTRIBUTING.md`. Record the exact rule source supplied to the Standards axis.
4. Resolve the Spec evidence from the caller's requirements, the ticket and its feature-local `spec.md`, or another identified Current Contract. A Current Contract does not require an approval status.

Do not substitute workspace configuration, undocumented historical intent, or Build controller state for these sources.

## Run independent axes

Start two fresh reviewers in parallel when Spec evidence exists:

- Give the review package and standards sources to a Standards reviewer using [standards-reviewer-prompt.md](standards-reviewer-prompt.md).
- Give the same review package and only the identified requirements to a Spec reviewer using [spec-reviewer-prompt.md](spec-reviewer-prompt.md).

Neither reviewer receives the other reviewer's findings. If no ticket, feature contract, or caller requirement exists, do not invent one and do not start the Spec reviewer. Emit exactly: `No Spec available; Spec axis skipped.`

## Report

Return two preserved sections in this order:

1. `## Standards` with each finding's severity, file location, exact rule source, and explanation.
2. `## Spec` with each finding's severity, file location, requirement source, and explanation; or the explicit skip sentence.

Use `Critical`, `Important`, or `Minor` independently within each axis. End each section with its own finding count and highest severity. Do not combine, rerank, or collapse the two axes into one verdict.

## Side-effect boundary

Reviewers may inspect files and run at most a focused read-only check needed to resolve concrete uncertainty. Direct invocation must not modify task, knowledge, the Git index, commits, or remotes. Do not write review reports into a repository unless a separate caller explicitly authorizes that destination.
