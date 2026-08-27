# Releasing Superteam

This checklist prepares a local `1.0.0` release candidate. It does not create
or modify a remote, push a branch, open a pull request, publish a marketplace
entry, or send a message.

## Local gate

Run from a clean candidate worktree with Git, Bash, POSIX base utilities,
Bats, `lsof` for the signal-boundary fixtures, and installed Codex, Claude
Code, and Qoder CLI builds that expose the
offline commands used below. The checked-in CI installs Codex CLI 0.144.5,
Claude Code 2.1.233, and Qoder CLI 1.1.14; local evidence records the actual
tool versions rather than implying the CI versions ran locally:

```bash
bash scripts/st-release-gate.sh .
```

This is the only complete release entry point. It runs `git diff --check`,
`bash -n` for every tracked shell script, the full Bats suite with real Git
fixtures, the release-tree audit, and the deterministic three-Host discovery
gate. The Host gate uses an isolated Codex home for its local marketplace
installer and registry, Claude Code's offline plugin validator, and Qoder
CLI's validator and plugin registry. It compares the complete discovered
Skill set and validates each namespaced selector. Codex and Claude Code do not
provide a credential-free selector resolver, so their selector syntax is
derived only from the installer- or validator-accepted Skill tree. Qoder
selector syntax is derived from its actual registry entries.

The same command is run without duplicated check logic on native macOS,
containerized Ubuntu 24.04, `macos-latest`, and `ubuntu-latest`. Node is used
only to install the pinned Host validation tools; it is not a Superteam
runtime dependency. The deterministic gate sends no model request and uses no
credentials. It therefore reports model-backed invocation as `SKIP`; it must
never turn a constructed selector into an invocation `PASS`. WSL follows the
tested Linux contract; native Windows shells are outside the support boundary.

## Evidence checklist

- All manifests and marketplace metadata say `superteam`, `1.0.0`, and
  `Superteam Contributors`; public project links point to
  `https://github.com/5101good/superteam`.
- `README.md` and `README.zh-CN.md` remain mutually linked and describe the
  same Project, workflow, runtime, platform, safety, and attribution contract.
- `LICENSE` and `NOTICE` match the release metadata.
- Public policies contain no personal contact, private organization, or
  placeholder reporting route.
- Runtime and release scans reject obsolete configuration paths, personal
  absolute paths, credential patterns, unsafe links, and unknown binaries.
- `RELEASE_REPORT.md` records the tested candidate HEAD, platform and tool
  versions, pass/skip/fail results, evidence, and limitations. Native macOS,
  containerized Ubuntu, and remote CI are three separate evidence states.
- If no hosted workflow has run, remote CI is recorded as `NOT RUN`; a local
  matrix definition is never reported as hosted success.

Pushing a release and publishing it to a marketplace require separate explicit
authorization.
