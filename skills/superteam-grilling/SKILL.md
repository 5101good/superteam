---
name: superteam-grilling
description: Resolve one consequential product or technical decision at a time when a Superteam contract cannot safely infer the answer.
---

# Superteam Grilling

Ask a question only when both conditions hold:

1. the answer cannot be safely inferred after reasonable discovery; and
2. the answer changes the contract's users, outcome, scope, behavior, public
   seams, compatibility, risk posture, or another material decision.

Explore the environment for facts instead of asking the user to retrieve them.
Read the relevant Current Contract, Project Snapshot, repository state, tests,
Context, and ADRs before escalating a decision. Do not ask about naming,
implementation detail, or preference when a reversible default is safe; state
the assumption instead.

Ask exactly one question at a time. Explain why it changes the contract, provide
a recommended answer with its trade-off, and wait for the user's decision before
following dependent branches. Record resolved domain language or qualifying
durable decisions immediately through `superteam-domain-modeling`.

When no material decisions remain, return the conclusions to the calling
workflow so it can write the Current Contract immediately. Do not add a final
sign-off step, ask the user to approve the completed document, or expand the
calling workflow's side-effect authority.
