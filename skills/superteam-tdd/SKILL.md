---
name: superteam-tdd
description: Develop a feature or fix test-first at an agreed public behavior seam using short red-green-refactor slices.
---

# Superteam TDD

Use TDD to change observable behavior without turning implementation details into compatibility promises.

## Establish the contract

1. Resolve the Project Snapshot through `st-project-snapshot.sh`; do not accept an arbitrary configuration query or infer paths from a checkout name.
2. Read the affected Repository's `CONTEXT.md` and relevant ADRs from the Snapshot's knowledge path. These are context, not permission to edit knowledge.
3. Read the ticket, feature `spec.md`, or user-supplied requirements as the Current Contract. A valid contract is current as written and does not need an approval status.
4. Name the public seam and observable behavior before changing a test. Project, Workflow, and Distribution are Superteam's public seams. For another project, use the seam named by its Current Contract. If a direct invocation has no agreed seam, ask the user to choose it before editing.

## Work one vertical slice at a time

For each behavior slice:

1. Write one focused test through the public seam.
2. Derive each independent expected value from the Current Contract, a worked example, or another source that does not reuse the implementation algorithm.
3. Run the focused test and record the expected red result. Confirm it fails because the behavior is absent, not because the fixture is broken.
4. Implement only enough observable behavior to reach green.
5. Run the focused test again. Refactor only while it remains green, then begin the next slice.

Use real local fixtures when they are practical. A test may replace an external system boundary such as time, randomness, a network service, or a process boundary. Do not mock an internal collaborator, call a private interface, assert internal call counts, or inspect private storage in place of public behavior.

## Boundaries and handoff

- Run focused tests during each slice; run the ticket's agreed verification before handoff.
- Report the seam, red evidence, green evidence, implementation files, and remaining risks.
- Direct invocation may edit tests and implementation files in the repositories explicitly placed in scope. It must not modify task, knowledge, the Git index, commits, or remotes.
- Do not create or revise a Current Contract from this Skill. Return a missing or contradictory contract to the caller.
