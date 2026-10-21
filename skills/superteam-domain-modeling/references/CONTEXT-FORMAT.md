# Repository Context Format

Use this compact shape and omit empty optional sections:

```markdown
# Repository Context: <Repository ID>

## Scope

Describe the Repository boundary and its relationships in the Project.

## Language

**Canonical term**: Definition. Avoid: ambiguous synonym.

## Relationships

Describe only stable relationships to other Repository IDs.
```

A statement that depends on code (a boundary, a relationship, where a concept
lives) ends with the date and commit it was checked at, for example
`(2026-10-21, api@1a2b3c4)`. When it changes, add the new statement with its
own date and commit and mark the old one superseded rather than rewriting it.

Use public Project terms. Keep implementation walkthroughs, feature contracts,
ticket state, and unresolved brainstorming out of Repository Context.
