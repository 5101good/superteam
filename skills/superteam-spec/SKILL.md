---
name: superteam-spec
description: Explore a technical change and write or revise its feature-local Spec as the current Superteam contract.
---

# Superteam Spec

Turn a request and the current repositories into a durable technical contract,
then write it directly as the feature's Current Contract. Use
`superteam-grilling` only for contract-changing decisions that remain unsafe to
infer after discovery. Use `superteam-domain-modeling` while terminology and
durable architectural decisions are resolved.

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
returned custom paths. For every affected Repository, resolve its declared path
with `bash "$plugin_root/scripts/st-project-snapshot.sh" repository-path "$repository" "$project_path"`
and verify facts in its current code, tests, and configuration. Do not treat an
arbitrary nested directory as a Repository.

## Write a New Spec

1. When a PRD is supplied or the request identifies a feature containing
   `prd.md`, use that same feature and treat the PRD's product outcomes and scope
   as authority. Otherwise select an existing named feature or create a new
   spec-only feature with
   `bash "$plugin_root/scripts/st-tickets.sh" create-feature`.
2. Discover relevant Context files, ADRs, cross-Repository decisions, related
   Current Contracts, current code, tests, configuration, and constraints.
   Separate verified facts, design decisions, assumptions, and unknowns.
3. Define the smallest stable public seams that prove the change. Resolve only
   questions that cannot be safely inferred and would materially change the
   technical contract.
4. Compose the complete document in a scratch candidate file, then atomically
   validate and install it with
   `bash "$plugin_root/scripts/st-contract.sh" write spec "$feature_path" "$candidate_path"`.
   The candidate is not the Current Contract unless this command succeeds. Do
   not display the full document and wait for approval. Report the installed
   path, decisions, seams, assumptions, and risks.

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
or revision counters. Read [references/spec-format.md](references/spec-format.md)
when composing the document.

## Revise the Current Contract

Preserve the existing stable identity and original `created_at`. Before writing,
inspect `tickets/`; when tickets exist, use
`bash "$plugin_root/scripts/st-tickets.sh" feature-status` and read their
validated statuses. Compose the revision as a complete candidate. When no
tickets exist, apply it through
`bash "$plugin_root/scripts/st-contract.sh" write spec "$feature_path" "$candidate_path"`.

When tickets exist, also compose the complete desired unstarted ticket set in a
separate candidate directory. If every current ticket is `ready-for-agent`, the
candidate may rewrite, add, remove, renumber, and reorder the whole plan. If any
ticket is `claimed`, `blocked`, or `resolved`, omit every protected ID and
represent the revision with new correction tickets; preserve dependencies on
delivered work where appropriate. Apply both candidates in the same workflow:

```bash
bash "$plugin_root/scripts/st-contract.sh" write spec "$feature_path" \
  "$candidate_path" "$candidate_ticket_directory"
```

This command uses the Plan reconciliation seam and either installs the Current
Contract plus complete ticket set together or rolls both back. A concurrent
ticket state change makes the revision fail closed. Report the downstream impact
with every `SYNCED`, `RETAINED`, `ADDED`, `REMOVED`, and `AFFECTED` line,
distinguish protected history from correction work, and state that Build was not
started.

Never silently continue with a stale ticket set after a material Spec change.
Never put a claimed, blocked, or resolved ticket ID in the candidate or rewrite
its file.

## Side-effect Boundary

Writing `spec.md`, or atomically reconciling its existing ticket plan during a
revision, is the only workflow mutation authorized by this skill, apart from
immediate domain-model updates explicitly covered by `superteam-domain-modeling`.
Do not create an initial ticket plan. Do not invoke the separate
`superteam-plan` workflow or `superteam-build`.
Do not commit, push, open a pull request, create a remote, or send messages.
