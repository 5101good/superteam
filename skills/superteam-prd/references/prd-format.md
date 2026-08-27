# PRD Format

Use the stable frontmatter defined in `SKILL.md`, followed by a product contract
that is complete for the decision at hand. Prefer this structure:

```markdown
# <Title>

## Context

## Problem and Evidence

## Users and Jobs

## Goals and Non-Goals

## Product Experience

## Product Requirements

## Success Evidence

## Risks and Open Questions
```

Give observable product requirements stable IDs such as `PR-1`. Keep technical
implementation choices out unless they are themselves product constraints. Add
sections such as business rules, rollout, compliance, localization,
accessibility, pricing, or support only when they materially shape the contract.
