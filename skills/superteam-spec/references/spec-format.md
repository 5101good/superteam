# Spec Format

Use the stable frontmatter defined in `SKILL.md`, followed by a technical
contract that is precise enough to plan and review without prescribing an
unnecessary file-by-file implementation. Prefer this structure:

```markdown
# <Title>

## Context

## Goals and Non-Goals

## Current System

## Design

## Decisions

## Public Seams and Testing

## Compatibility and Rollout

## Risks and Open Questions
```

Add interfaces, data model, state, concurrency, migration, security,
observability, performance, or capacity only when the design contains material
decisions in those areas. Record facts, decisions, and assumptions distinctly.
