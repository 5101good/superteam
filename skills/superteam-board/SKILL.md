---
name: superteam-board
description: Show feature and ticket state from Current Contracts, ticket frontmatter, and Result evidence. Use for a read-only workflow status snapshot.
---

# Superteam Board

Capture `project_path="$(pwd -P)"`, resolve the installed bundle root through
the Host, then run:

```bash
bash "$plugin_root/scripts/st-plugin-root.sh" require &&
  bash "$plugin_root/scripts/st-board.sh" --project "$project_path"
```

Add `--repository <id>` only when the user asks to filter the view. Return the
table unchanged. On failure, report stderr and the exit status.

Board is strictly read-only. It derives `PRD`, `SPEC`, `READY`, `RUNNING`,
`BLOCKED`, `DONE`, or `INVALID` from files already tracked by the Project. It
does not claim tickets, repair data, change Git state, or invoke another
workflow.
