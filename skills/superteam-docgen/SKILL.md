---
name: superteam-docgen
description: Explicitly generate first-pass Project knowledge from selected Repository evidence.
disable-model-invocation: true
---

# Superteam Docgen

Run this skill only when the user explicitly requests new documentation. It is
independent from Spec, Plan, Implement, Review, TDD, and Build and must not
become a hidden completion gate.

## Select evidence and destination

Identify the Repository ID and resolve its real Git root through the Project
Snapshot. For a first-pass view of committed source, run:

```bash
bash "$plugin_root/scripts/st-doc-scan.sh" scan root HEAD \
  --project "$project_path" --target repository
```

Select `architecture`, `api`, or `reference` only when the user's request calls
for that category. Use `--target path --knowledge-path <relative-path>` for an
explicit destination. Treat `STATUS: INCONCLUSIVE` as a requirement to inspect
the source manually, never as proof that no document is needed.

Generate only evidence-backed content under the custom knowledge path:

- Repository reference, how-to, tutorial, or explanation pages under the
  selected Repository knowledge directory.
- Requested system architecture under `architecture/`.
- Requested live interface documentation under `api/`.
- Requested cited material under `reference/`.
- Repository Context or ADR candidates through `superteam-domain-modeling`.

Keep PRDs and Specs in the configured task path. Preserve existing relative
links and sibling `.assets/` directories; do not delete or replace an asset
unless the requested document change requires it. Report the evidence, created
files, and remaining uncertainty. Do not commit or push unless separately
requested.
