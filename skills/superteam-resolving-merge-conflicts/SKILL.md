---
name: superteam-resolving-merge-conflicts
description: Resolve an active Git merge or rebase in a fresh independent agent while preserving both intents.
---

# Superteam Resolving Merge Conflicts

Use a fresh independent agent for one active merge or rebase conflict. The
implement unit supplies the integration goal, both source commits, the Current
Contract, and affected verification; the Build controller does not select a
side or adjudicate the resolution.

1. Confirm the exact Repository, worktree, active merge or rebase state, and
   unmerged paths. Stop if there is no active conflict.
2. Read both source commits, the Current Contract, and the history of every
   conflicted file. State each side's intent before editing.
3. Resolve every hunk to preserve both intents where they are compatible. When
   they are not compatible, follow the integration goal and record the explicit
   trade-off. Do not abort, discard one side wholesale, reset the worktree, or
   add unrelated behavior.
4. Run the focused checks covering the resolution, stage only the resolved
   paths, and complete the active merge or rebase. Continue until no operation
   or unmerged path remains.
5. Return the resulting head, changed paths, verification, and trade-offs to
   `superteam-implement` for review and CAS promotion. Do not push, create a pull
   request, send a message, or modify task or knowledge.
