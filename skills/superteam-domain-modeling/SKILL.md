---
name: superteam-domain-modeling
description: Define or revise shared Project language and durable architectural decisions in Git-tracked knowledge.
---

# Superteam Domain Modeling

Use this skill when a request creates or changes domain terminology, a
Repository boundary, or a durable architectural decision. Ordinary code reading
does not require it.

## Resolve the Project first

Capture the target Project separately from the installed plugin bundle. Resolve
every knowledge location from the validated Project Snapshot:

```bash
project_path="$(pwd -P)"
plugin_root="${SUPERTEAM_PLUGIN_ROOT:-}"
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-knowledge.sh" context root "$project_path"
bash "$plugin_root/scripts/st-knowledge.sh" adrs root "$project_path"
bash "$plugin_root/scripts/st-knowledge.sh" decisions "$project_path"
```

`root` is a valid Repository ID. For another member, pass its Repository ID;
the member may be inside or outside the Root Repository. `st-knowledge.sh`
derives every result from the Project Snapshot, so knowledge remains under the
user-selected path tracked by the Root Repository.

Use these terms consistently:

- **Project**: the Git-backed engineering unit managed by Superteam.
- **Root Repository**: the one Repository that tracks `superteam.yaml`, task,
  knowledge, and Project policies.
- **Repository Set**: `root` followed by each registered Repository.
- **Repository ID**: the stable manifest identifier used by workflows.
- **Project Snapshot**: the validated, read-only view of those paths and IDs.

## Write only resolved knowledge

- Repository Context lives at the path returned by `st-knowledge.sh context`.
- A decision scoped to one Repository lives under the directory returned by
  `st-knowledge.sh adrs`.
- A decision spanning multiple Repositories lives under the directory returned
  by `st-knowledge.sh decisions`.
- Create a Context or ADR only when the session has resolved useful content.
  Read [references/CONTEXT-FORMAT.md](references/CONTEXT-FORMAT.md) or
  [references/ADR-FORMAT.md](references/ADR-FORMAT.md) only for that write.
- Challenge language that conflicts with the existing glossary and choose one
  precise canonical term for each concept.
- Test concrete scenarios that expose boundaries and overloaded terms, and
  verify factual claims against current code when relevant.
- When a term is resolved, update the owning `CONTEXT.md` immediately and
  incrementally. Keep implementation details, task state, and design prose out
  of glossary definitions.
- Write an ADR immediately only when the decision is hard to reverse, would
  surprise a future maintainer without context, and involved real alternatives.
- If ownership is not yet known, retain the vocabulary in the active PRD or Spec
  rather than guessing a Repository context.
- Keep feature PRDs and Specs in the configured task path. Do not duplicate
  them into knowledge.

Edit only the relevant knowledge files. Preserve existing relative links and
sibling `.assets/` directories. Report every Context or ADR path changed. Do
not commit, push, open a pull request, create a remote, or modify unrelated
knowledge documents.
