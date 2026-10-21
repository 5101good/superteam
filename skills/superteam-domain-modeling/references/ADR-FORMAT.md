# ADR Format

Use this shape for a durable decision:

```markdown
# NNNN - Decision title

Status: Accepted
Scope: Repository ID or Repository IDs
Decided: YYYY-MM-DD at <repository-id>@<short-commit>

## Context

State the durable pressure and considered alternatives.

## Decision

State the chosen rule.

## Consequences

Record benefits, costs, and follow-up constraints.
```

Use a Repository-specific ADR directory for one Repository ID. Use the shared
`decisions/` directory when the decision spans two or more Repository IDs.

An ADR is a dated record. When a decision changes, write a new ADR and set the
old one's status to `Superseded by NNNN` instead of rewriting it.
