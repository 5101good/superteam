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

Use public Project terms. Keep implementation walkthroughs, feature contracts,
ticket state, and unresolved brainstorming out of Repository Context.
