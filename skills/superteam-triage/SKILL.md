---
name: superteam-triage
description: Verify an external bug, pull request, enhancement, or other claim and return a self-contained read-only brief for a Current Contract workflow.
disable-model-invocation: true
---

# Superteam Triage

Triage an external input only when the user explicitly asks for it. Verify the
input against available primary evidence and the current Project, then return a
self-contained brief that `superteam-prd`, `superteam-spec`, or
`superteam-plan` can consume without relying on a mutable remote description.

## Verify the input

1. Read the complete report, pull request, enhancement request, and every
   referenced artifact that is necessary to understand its claims. Record a
   stable identifier and the observed revision or timestamp when the source
   provides one. Preserve the material facts in the brief, but never reproduce
   credentials or other secrets.
2. When an initialized Project is involved, resolve its Project Snapshot and
   use Repository IDs rather than invented directory aliases. Inspect every
   affected Repository named by the evidence.
3. Check current behavior and trace the relevant public path. Use the smallest
   useful read-only command only when it cannot create caches, build artifacts,
   lock files, Git changes, or remote state. A failed reproduction is evidence,
   not proof that the claim is false.
4. Separate confirmed facts from inference and unknowns. Do not turn an
   enhancement preference into a defect or infer missing acceptance criteria.
5. Assign exactly one classification:

   - `CONFIRMED`: the observable claim is reproduced or independently verified.
   - `NEEDS_INFORMATION`: material evidence or reproduction details are missing.
   - `PRODUCT_DECISION`: the facts are sufficient, but product intent or a
     tradeoff must be decided before a technical contract can be established.
   - `DECLINED`: current evidence establishes a concrete reason not to proceed,
     such as an already-supported behavior, an exact duplicate, or an explicit
     Project boundary. Do not use this classification merely because a report
     could not be reproduced.

For a pull request, distinguish the problem or intent from the proposed patch:
verify both where possible, and do not treat the presence of code as proof that
the change is correct.

## Return the durable brief

Return the following Markdown structure in the response. Do not write it into
the Project unless a different, explicitly invoked workflow separately grants
that file write.

```markdown
# Triage Brief

- Classification: CONFIRMED | NEEDS_INFORMATION | PRODUCT_DECISION | DECLINED
- Input type: bug | pull request | enhancement | other
- Source snapshot: <stable identifier plus observed revision or timestamp>

## Observable problem or request
<what a user or maintainer can observe>

## Evidence
### Confirmed facts
<facts tied to source, code, or read-only verification>

### Reproduction or verification
<commands or inspection performed and their outcomes>

### Inference
<explicitly labeled interpretation>

### Unknowns
<missing information and why it matters>

## Affected repositories
<Project Repository IDs, or "Unknown" with the reason>

## Impact and likely scope
<affected behavior and bounded implementation surface>

## Decisions or information required
<remaining questions, or "None">

## Recommended next workflow
<one of superteam-prd, superteam-spec, superteam-plan, or no workflow, with reason>
```

Recommend `superteam-prd` when product intent must be established,
`superteam-spec` when product intent is known but the technical Current Contract
is missing, and `superteam-plan` only when the request is already bounded by a
sufficient Current Contract. Before naming a recommendation, verify that the
target Skill exists under `skills/` in the same installed bundle and that its
frontmatter name matches. When the desired target is absent, use `no workflow`
and add `Desired workflow unavailable in this bundle: <skill-name>` to the
reason. Do not fall back to another installed Superteam version or an older
contract. The recommendation does not invoke a workflow.

## Side-effect boundary

Triage is read-only. Do not create or modify files, tickets, tracker state, the
Git index, commits, branches, worktrees, remotes, or messages.
Do not comment on, label, close, or otherwise modify a remote item. A remote
write requires a new explicit user request and a separately invoked Skill whose
own contract grants that exact operation.
