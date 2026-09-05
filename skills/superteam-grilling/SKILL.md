---
name: superteam-grilling
description: Resolve consequential product or technical decisions when a Superteam contract cannot safely infer their answers.
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

Group questions whose prerequisites are settled into a round. Explain their
impact and recommend answers with trade-offs. Let the user's answers shape the
next round; questions that depend on an unanswered decision wait. Choose the
batch size, order, and format for the decisions and the user's effort.

Prefer the Host's available native question tool: `AskUserQuestion` in Claude
Code, or `request_user_input` / `request_user_input_async` in Codex. Follow its
question and option limits, splitting a batch when needed. If the tool is
unavailable or cannot express the question, use numbered text; keep the current
Host mode. A subagent without a question tool returns decisions to the main
conversation. Questions collected through a tool need no duplicate text prompt.

Skipped, cancelled, or missing answers remain unsettled; continue work that does
not depend on them. Record resolved domain language or qualifying durable
decisions through `superteam-domain-modeling`.

When no material decisions remain, return the conclusions to the calling
workflow so it can write the Current Contract immediately. Do not add a final
sign-off step, ask the user to approve the completed document, or expand the
calling workflow's side-effect authority.
