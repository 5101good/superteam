---
name: superteam-plan
description: Decompose a feature-local Current Contract into an atomic ready-for-agent ticket DAG, or reconcile its unstarted downstream plan.
---

# Superteam Plan

Turn a feature-local Spec into the smallest useful set of end-to-end delivery
tickets. Write the validated ticket DAG directly; do not pause for breakdown
approval and do not start Build.

## Resolve the Current Contract

Capture the target Project before resolving the separate plugin bundle. A Host
must provide `SUPERTEAM_PLUGIN_ROOT`; if it is absent, ask for the local bundle
path rather than guessing it. Validate the bundle and resolve Project paths and
Repository IDs through named Snapshot queries:

```bash
project_path="$(pwd -P)"
plugin_root="${SUPERTEAM_PLUGIN_ROOT:-}"
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-project-snapshot.sh" task "$project_path"
bash "$plugin_root/scripts/st-project-snapshot.sh" knowledge "$project_path"
bash "$plugin_root/scripts/st-project-snapshot.sh" repositories "$project_path"
```

Select a feature directly inside the configured task path and read its
`spec.md` as the Current Contract. Read `prd.md` when present for product
context. Resolve each affected Repository with
`st-project-snapshot.sh repository-path`; inspect current code, tests, Context,
and relevant ADRs before decomposing work. Repository directory names are not
Repository IDs.

## Create the Ticket DAG

1. Identify the smallest tracer-bullet slices that each deliver observable
   end-to-end behavior. Prefer a thin public seam over horizontal setup tasks.
2. Give every ticket a two-digit ID, a specific title, complete `What to build`
   behavior, observable acceptance criteria, the exact Repository IDs it may
   change, and explicit blocker IDs. The blockers must form an acyclic graph.
3. Compose the complete proposed ticket set in a separate scratch directory.
   Every file must use the public ticket schema with `status: "ready-for-agent"`,
   empty claimant fields, empty branch state, exactly one
   `Result` heading, and no approval or activation state.
4. Apply the complete candidate through:

```bash
bash "$plugin_root/scripts/st-plan.sh" apply "$feature_path" "$candidate_directory"
```

The command validates Repository IDs, filenames, required behavior, acceptance
criteria, blocker references, and the complete DAG before changing the Current
Plan. It installs the ticket set atomically for normal failures and handled
interruptions. Report the installed feature and every `SYNCED`, `RETAINED`,
`ADDED`, `REMOVED`, and `AFFECTED` line from the result.

## Revise an Existing Plan

Read validated ticket state with
`bash "$plugin_root/scripts/st-tickets.sh" feature-status "$feature_path"` and
inspect every current ticket before preparing the full candidate.

- When all related tickets are `ready-for-agent`, the candidate is the complete
  new plan. It may rewrite, add, remove, or renumber tickets; the final DAG must
  match the latest Current Contract.
- A `claimed` or `blocked` ticket is protected history. Do not put its ID in the
  candidate. The apply report retains it byte-for-byte and marks it `AFFECTED`;
  explicitly tell the user or Build controller to stop or reassess that active
  work before it continues.
- A `resolved` ticket and its Result are immutable. Do not put its ID in the
  candidate. Represent any contract difference with a new correction ticket
  that depends on the delivered work where appropriate.
- The candidate contains every desired unstarted ticket, including correction
  tickets. Protected tickets are carried into the final validated DAG by the
  atomic apply command.

If validation or installation fails, report the error and leave the existing
ticket set as the Current Plan. Do not fall back to incremental ticket edits.

## Side-effect Boundary

A Plan request authorizes only the feature-local `tickets/` update described
above. It does not authorize Build, implementation, worktrees, commits, pushes,
pull requests, remotes, messages, PRD/Spec changes, or knowledge updates. Never
invoke `superteam-build` automatically. The user can request Build separately
after reviewing the written tickets or ask for another Plan revision.
