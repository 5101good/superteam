# Superteam Release Status

- Version: `1.0.0`
- Native macOS: PENDING
- Containerized Ubuntu 24.04: PENDING
- Remote CI: NOT RUN

## Evidence boundary

Release evidence is produced by one command:

```bash
bash scripts/st-release-gate.sh .
```

The gate checks the Git diff, shell syntax, complete Bats suite, public release
contents, and plugin discovery for Codex, Claude Code, and Qoder CLI. Host
discovery is offline; model-backed invocation remains `SKIP` unless separately
verified and recorded. Local platform evidence and remote CI evidence remain
separate.

Record a candidate HEAD and platform details only after the complete gate runs
against that exact clean source. A later source change invalidates the recorded
platform evidence.

## Native macOS result

- Status: PENDING

## Containerized Ubuntu 24.04 result

- Status: PENDING

## Remote CI result

Remote CI: NOT RUN. A workflow definition is not execution evidence.
