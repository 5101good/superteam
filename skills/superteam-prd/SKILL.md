---
name: superteam-prd
description: Explore a product request and write or revise its feature-local PRD as the current Superteam contract.
---

# Superteam PRD

Turn a product idea, problem, or requested change into a complete Product
Requirements Document and write it directly as the feature's Current Contract.
Use `superteam-grilling` only for contract-changing decisions that remain unsafe
to infer after discovery. Use `superteam-domain-modeling` when product language or
a durable decision is resolved during the discussion.

## Resolve the Project

Capture the target Project before resolving the separate plugin bundle. A Host
must provide `SUPERTEAM_PLUGIN_ROOT`; if it is absent, ask for the local bundle
path rather than guessing it. Validate the bundle and resolve the configured
task, knowledge, and Repository Set through named Project Snapshot queries:

```bash
project_path="$(pwd -P)"
plugin_root="${SUPERTEAM_PLUGIN_ROOT:-}"
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-project-snapshot.sh" task "$project_path"
bash "$plugin_root/scripts/st-project-snapshot.sh" knowledge "$project_path"
bash "$plugin_root/scripts/st-project-snapshot.sh" repositories "$project_path"
```

Stop without writing if the bundle or Project Snapshot is invalid. Use the
returned task and knowledge paths even when their names are not `task` and
`knowledge`. Select only Repository IDs returned by the Snapshot; do not infer
repositories from directory names.

## Write a New PRD

1. Explore the request, relevant product evidence, current journeys, existing
   Current Contracts, domain language, and code only where it establishes
   current behavior or constraints. Distinguish observed facts from assumptions.
2. Resolve the target users, problem, desired outcome, scope, core experience,
   product requirements, success evidence, risks, and unresolved questions.
   Ask the user only for decisions that cannot be safely inferred and would
   materially change that contract.
3. Choose an unused feature ID and a lowercase hyphenated slug. Create the
   feature with `bash "$plugin_root/scripts/st-tickets.sh" create-feature` under
   the configured task path.
4. Compose the complete document in a scratch candidate file, then atomically
   validate and install it with
   `bash "$plugin_root/scripts/st-contract.sh" write prd "$feature_path" "$candidate_path"`.
   The candidate is not the Current Contract unless this command succeeds. Do
   not display the full document and wait for approval. Report the installed
   path, a concise summary, assumptions, and any remaining open questions.

The frontmatter contains only these stable contract fields:

```markdown
---
id: "<stable-id>"
slug: "<slug>"
repositories:
  - "root"
created_at: "YYYY-MM-DD"
supersedes: []
---
```

Do not add approval, draft/current markers, delivery state, ticket state, owner,
or revision counters. Read [references/prd-format.md](references/prd-format.md)
when composing the document.

## Revise the Current Contract

Preserve the existing stable identity and original `created_at`. Before writing,
inspect the same feature for `spec.md` and `tickets/`; when tickets exist, use
`bash "$plugin_root/scripts/st-tickets.sh" feature-status` and read their
validated statuses. Compose the revision as a complete candidate. When no
tickets exist, apply it through
`bash "$plugin_root/scripts/st-contract.sh" write prd "$feature_path" "$candidate_path"`.

When tickets exist, also compose the complete desired unstarted ticket set in a
separate candidate directory. If every current ticket is `ready-for-agent`, the
candidate may rewrite, add, remove, renumber, and reorder the whole plan. If any
ticket is `claimed`, `blocked`, or `resolved`, omit every protected ID and
represent the revision with new correction tickets; preserve dependencies on
delivered work where appropriate. Apply both candidates in the same workflow:

```bash
bash "$plugin_root/scripts/st-contract.sh" write prd "$feature_path" \
  "$candidate_path" "$candidate_ticket_directory"
```

This command uses the Plan reconciliation seam and either installs the Current
Contract plus complete ticket set together or rolls both back. A concurrent
ticket state change makes the revision fail closed. Then report every `SYNCED`,
`RETAINED`, `ADDED`, `REMOVED`, and `AFFECTED` line and the downstream impact:

- identify an existing Spec that may now be stale;
- list affected ready, claimed, blocked, and resolved tickets;
- distinguish synchronized tickets from protected history and correction work;
- state that this skill did not start Build.

Never silently continue with an old Spec or ticket set after a material PRD
change. Never put a claimed, blocked, or resolved ticket ID in the candidate or
rewrite its file.

## Side-effect Boundary

Writing `prd.md`, or atomically reconciling its existing ticket plan during a
revision, is the only workflow mutation authorized by this skill, apart from
immediate domain-model updates explicitly covered by `superteam-domain-modeling`.
Do not create `spec.md` or an initial ticket plan. Do not invoke the separate
`superteam-plan` workflow or `superteam-build`.
Do not commit, push, open a pull request, create a remote, or send messages.
