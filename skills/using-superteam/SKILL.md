---
name: using-superteam
description: Route a request to one public Superteam Project, contract, planning, development, review, triage, status, domain, or documentation workflow.
---

# Using Superteam

The routing map below is the canonical Superteam 1.0 name vocabulary. Choose
exactly one candidate from the user's current intent, but route to it only after
verifying that `skills/<candidate>/SKILL.md` exists in this installed bundle and
that its frontmatter `name` matches the candidate. If it is absent, report the
desired workflow as unavailable and stop.
Do not fall back to another installed version or an older alias. After
availability is established, name the Skill and stop when its contract requires
explicit invocation. Do not silently continue into a downstream workflow.

## Public routing map

| Intent | Skill | Result |
|---|---|---|
| Initialize, inspect, or manage a Project and its Repository Set | `superteam-project` | An explicit Project action or read-only diagnosis |
| Write or revise product requirements | `superteam-prd` | A feature-local PRD written as the Current Contract |
| Write or revise a technical design | `superteam-spec` | A feature-local Spec written as the Current Contract |
| Break an established contract or bounded request into tickets | `superteam-plan` | A validated ready-for-agent ticket DAG, without starting Build |
| Build a complete planned feature | `superteam-build` | Controller-managed execution of the ticket DAG |
| Implement one ready ticket | `superteam-implement` | One ticket's implementation, independent review, fixes, and integration result |
| Verify an external bug, pull request, or enhancement | `superteam-triage` | A self-contained read-only Triage Brief |
| Show feature or ticket status | `superteam-board` | Read-only state derived from Current Contracts and tickets |
| Resolve one consequential unknown | `superteam-grilling` | One contract-changing decision at a time |
| Maintain vocabulary or a durable decision | `superteam-domain-modeling` | An immediate Repository Context or scoped ADR update |
| Develop agreed behavior test-first | `superteam-tdd` | Public-seam red-green-refactor slices |
| Review a fixed-base Repository change | `superteam-review` | Separate Standards and Spec reports |
| Resolve an active merge or rebase conflict | `superteam-resolving-merge-conflicts` | A verified conflict resolution preserving both intents |
| Audit and update selected documentation | `superteam-docs` | Explicit, diff-based knowledge maintenance |
| Generate first-pass documentation | `superteam-docgen` | Explicit, evidence-backed knowledge drafts |

Route an external claim to `superteam-triage`, but route an ordinary user intent
directly to the corresponding Project, Current Contract, Plan, Build, Review,
Board, domain, or documentation Skill. A request to review a known fixed-base
local change routes to `superteam-review`; the mere presence of an external pull
request does not bypass Triage verification. Every target remains subject to
the installed-bundle availability check above.

Project initialization has only the `superteam-project` route. Superteam does
not invent package-level project semantics or route engineering work through a
separate workspace orchestrator.

## Workflow boundaries

- `superteam-prd`, `superteam-spec`, and `superteam-plan` finish necessary fact
  finding and material decisions, then write the Current Contract directly.
  They do not pause for a separate approval status. A routed
  `superteam-plan` never invokes `superteam-build`; Build begins only from a
  separate explicit request.
- `superteam-triage`, `superteam-board`, and direct `superteam-review` requests
  are read-only. Read-only intents never create or modify files, the Git index,
  commits, worktrees, tracker state, or remotes.
- Docs and Docgen run only when the user explicitly requests their workflow.
  Domain Modeling writes only within its own explicitly selected contract; it
  is not an automatic follow-up or Build gate.
- A remote write requires both an explicit user request and a routed Skill
  whose own contract authorizes that exact remote effect. Routing alone never
  grants push, pull-request, issue, message, or other remote-write authority.
- Local code, ticket, Git, and Project changes remain bounded by the selected
  Skill. Do not infer implementation authority from diagnosis, design, status,
  or review intent.

## Runtime

- Before a bundled command runs, capture `project_path="$(pwd -P)"` in the
  target Project. Supply the separate bundle root through the explicit contract
  in `superteam-project`: a Host may pass `SUPERTEAM_PLUGIN_ROOT`; otherwise ask
  the user for the local bundle root. Do not infer either path from a fixed
  checkout directory name.
- Gate `doctor` with
  `bash "$plugin_root/scripts/st-plugin-root.sh" require && bash "$plugin_root/scripts/st-project.sh" doctor "$project_path"`;
  when validation is absent or invalid, stop without a filesystem change.
- Keep Project assets under the Root Repository so Git records their history.
- Create only local commits when the selected workflow explicitly authorizes
  them. Do not create remotes, push, or send messages implicitly.
