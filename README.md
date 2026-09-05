# Superteam

[中文文档](README.zh-CN.md)

**Build complex software with a coordinated team of AI agents — across one
repository or many.**

Superteam is a Git-native workflow plugin for Codex, Claude Code, and Qoder
CLI. It turns a product request into a shared contract, parallel delivery
tickets, independently reviewed changes, and an auditable result.

It is designed for large projects where one agent or one repository is not
enough. Product decisions, tasks, knowledge, and progress live in a root Git
repository; code can remain in any number of existing repositories.

Source: [github.com/5101good/superteam](https://github.com/5101good/superteam)

![Superteam capability map](.github/assets/superteam-capabilities.png)

## Why Superteam

- **Team delivery.** Independent tickets can run in parallel. Each ticket stays
  with one delivery unit through implementation, review, fixes, and local
  integration.
- **Multi-repository work.** One feature can change the root repository,
  submodules, sibling repositories, or repositories elsewhere on disk.
- **Shared memory.** Requirements, plans, decisions, and results are normal
  files tracked by Git, so people and agents can resume from the same state.
- **Human control.** Superteam works locally. It does not push code, create pull
  requests, or contact remote services unless you explicitly do so outside the
  workflow.

## Install

### Codex

```bash
codex plugin marketplace add 5101good/superteam
codex plugin add superteam@superteam
```

### Claude Code

```bash
claude plugin marketplace add 5101good/superteam
claude plugin install superteam@superteam
```

### Qoder CLI

```bash
qodercli plugin marketplace add 5101good/superteam
qodercli plugin install superteam@superteam
```

Start with `$superteam:using-superteam` in Codex, or
`/superteam:using-superteam` in Claude Code and Qoder CLI. Tell Superteam what
you want to do; it will select the matching workflow.

## Start a project

Open the directory that should hold the project's shared tasks and knowledge,
then ask:

```text
Set up Superteam for this project.
```

Superteam reuses the current Git repository when one exists. In an empty
directory, it can create the root repository after confirmation. It also asks
you to choose the task and knowledge directory names, so it never assumes that
`task/` or `knowledge/` is available.

The result is a small, Git-tracked project structure:

```text
superteam.yaml     Project paths and repository list
task/              Product contracts, plans, tickets, and results
knowledge/         Shared context and decisions
```

The directory names are configurable. `superteam.yaml` records the choices so
every agent sees the same project.

## Use one repository or many

A single repository and a monorepo both use the root repository directly. For
a multi-repository project, ask Superteam to add the repositories you already
have:

```text
Add ../api and ~/develop/mobile-app to this Superteam project.
```

Relative paths, absolute paths, and `~/` paths are accepted. Superteam keeps
each repository independent and stores only a normalized path in
`superteam.yaml`. Existing submodules keep their existing Git topology.

Every ticket names the repositories it needs. Independent tickets may run in
parallel; tickets that touch the same repository are coordinated to avoid
competing worktrees and branches.

## Deliver a feature

![Superteam development workflow](.github/assets/superteam-workflow.png)

Use natural language or invoke a workflow directly:

| What you want | Workflow |
| --- | --- |
| Define the product need | `superteam-prd` |
| Design the technical change | `superteam-spec` |
| Break the work into parallel tickets | `superteam-plan` |
| Build the complete feature | `superteam-build` |
| Implement one ready ticket | `superteam-implement` |
| See feature and ticket progress | `superteam-board` |

A typical feature moves through:

```text
PRD → Spec → Plan → Build → Result
```

PRD, Spec, and Plan are written directly. If something needs to change, discuss
the adjustment and run that workflow again. Plan never starts Build
automatically.

During Build, Superteam coordinates the ready tickets, gives each delivery unit
its complete repository set, keeps review and fixes inside that unit, and
records the final result in the root repository.

Completion requires a valid [Result summary](skills/superteam-implement/result-format.md)
and Git evidence. Existing Results without the summary need their evidence
checked and the summary added before they count as complete.

## Update project repositories

When you explicitly ask Superteam to pull the project, it checks the root first
and then every registered repository. Clean repositories use only
`git pull --ff-only`. Dirty, detached, missing, or upstream-less repositories
are skipped, and the final report explains what happened in each repository.

Superteam never stashes, rebases, force-updates, pushes, or recursively updates
submodules during this operation.

## Requirements

Superteam requires Git, Bash, and POSIX base utilities. It supports macOS,
Linux, and WSL. It does not require Python, Node.js, `jq`, or `yq` at runtime.

## Acknowledgements

Superteam draws inspiration from
[Matt Pocock's skills](https://github.com/mattpocock/skills) and
[Jesse Vincent's obra/superpowers](https://github.com/obra/superpowers).
Their approaches to reusable agent skills, test-driven development, and
iterative review workflows helped shape this project.

## Contributing and license

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Security reports follow
[SECURITY.md](SECURITY.md).

Superteam is licensed under [Apache-2.0](LICENSE).
