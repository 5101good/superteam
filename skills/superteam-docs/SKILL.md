---
name: superteam-docs
description: Explicitly audit and update selected Git-tracked knowledge for a Repository change.
disable-model-invocation: true
---

# Superteam Docs

Run this skill only when the user explicitly requests a documentation audit or
update. It is independent from Spec, Plan, Implement, Review, TDD, and Build;
documentation freshness is not a hidden completion gate.

## Audit a real change

Capture `project_path` in the target Project, identify a Repository ID and Git
base/head, then run:

```bash
bash "$plugin_root/scripts/st-doc-scan.sh" audit root "$base" "$head" \
  --project "$project_path"
```

Use another Repository ID for a registered member, including an external
Repository. The scanner reconstructs its Git root from the Project Snapshot and
reports `repository`, `architecture`, `api`, and `reference` impacts. For a
user-selected knowledge destination, add:

```bash
--target path --knowledge-path "guides/topic.md"
```

`STATUS: INCONCLUSIVE` means manual inspection is required. Never translate it
to zero documentation impact.

## Update narrowly

- Resolve every target with `st-knowledge.sh`; do not assume `knowledge/` or a
  fixed Repository layout.
- Read the complete affected documents and relevant source before editing.
- Preserve relative links, embedded media references, and sibling `.assets/`
  directories.
- Make the smallest accurate edit that preserves useful authorship and
  structure.
- Keep PRDs and Specs in the configured task path.
- Report scanned Repository IDs, impacts, edits, and unresolved uncertainty.

Do not alter source Repositories, commit, or push unless separately requested.
