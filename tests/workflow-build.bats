#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
INTEGRATE="$ROOT/scripts/st-integrate.sh"

setup() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/root project"
  mkdir -p "$FIXTURE_ROOT" "$BATS_TEST_TMPDIR/no-hooks"
  git -C "$FIXTURE_ROOT" init -q
  git -C "$FIXTURE_ROOT" config user.name "Fixture Contributor"
  git -C "$FIXTURE_ROOT" config user.email "fixture@invalid"
  git -C "$FIXTURE_ROOT" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"
  printf '%s\n' base > "$FIXTURE_ROOT/tracked.txt"
  git -C "$FIXTURE_ROOT" add tracked.txt
  git -C "$FIXTURE_ROOT" commit -qm baseline
}

@test "controller lease heartbeats exclude an active Build and allow expired recovery" {
  run bash "$INTEGRATE" lease-acquire "$FIXTURE_ROOT" 100-example --owner build-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=acquired"* ]]
  lease=${output#lease=}
  lease=${lease%% owner=*}

  run bash "$INTEGRATE" lease-heartbeat "$FIXTURE_ROOT" 100-example --owner build-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=heartbeat"* ]]

  run bash "$INTEGRATE" lease-acquire "$FIXTURE_ROOT" 100-example --owner build-2
  [ "$status" -eq 3 ]
  [[ "$output" == *"integration lease is held"* ]]

  run bash "$INTEGRATE" lease-recover "$FIXTURE_ROOT" 100-example \
    --owner build-2 --expected-owner build-1 --stale-after 299
  [ "$status" -eq 2 ]
  [[ "$output" == *"stale-after must be at least 300 seconds"* ]]

  run bash "$INTEGRATE" lease-recover "$FIXTURE_ROOT" 100-example \
    --owner build-2 --expected-owner build-1 --stale-after 9999999999
  [ "$status" -eq 3 ]
  [[ "$output" == *"integration lease is active"* ]]

  printf '%s\n' 1 > "$lease/heartbeat"
  run bash "$INTEGRATE" lease-recover "$FIXTURE_ROOT" 100-example \
    --owner build-2 --expected-owner build-1 --stale-after 300
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=recovered"* ]]

  run bash "$INTEGRATE" lease-heartbeat "$FIXTURE_ROOT" 100-example --owner build-1
  [ "$status" -eq 3 ]
  [[ "$output" == *"integration lease is owned by build-2"* ]]

  run bash "$INTEGRATE" lease-heartbeat "$FIXTURE_ROOT" 100-example --owner build-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"action=heartbeat"* ]]

  bash "$INTEGRATE" lease-release "$FIXTURE_ROOT" 100-example --owner build-2 >/dev/null
}

@test "Build is a Repository Set evidence-driven controller rather than a reviewer" {
  skill="$ROOT/skills/superteam-build/SKILL.md"
  agent="$ROOT/skills/superteam-build/agents/openai.yaml"

  [ -f "$skill" ]
  [ -f "$agent" ]
  grep -q '^name: superteam-build$' "$skill"
  grep -q '^disable-model-invocation: true$' "$skill"
  grep -q '^  allow_implicit_invocation: false$' "$agent"
  grep -Fq 'root-only' "$skill"
  grep -Fq 'st-repository-workflow.sh repositories' "$skill"
  grep -Fq 'every declared Repository' "$skill"
  grep -Fq 'partially promoted Repository Set' "$skill"
  grep -Fq 'Current Contract' "$skill"
  grep -Fq 'st-tickets.sh validate' "$skill"
  grep -Fq 'st-tickets.sh frontier' "$skill"
  grep -Fq 'st-integrate.sh lease-acquire' "$skill"
  grep -Fq 'st-integrate.sh lease-heartbeat' "$skill"
  grep -Fq 'st-integrate.sh lease-recover' "$skill"
  grep -Fq 'controller ledger' "$skill"
  grep -Fq 'real Git HEAD' "$skill"
  grep -Fq 'BUSY' "$skill"
  grep -Fq 'not `BLOCKED`' "$skill"
  grep -Fq 'Implement -> Review -> Fix -> Integrate' "$skill"
  grep -Fq 'does not review code or adjudicate findings' "$skill"
  grep -Fq 'does not integrate ticket code' "$skill"
  grep -Fq 'capacity' "$skill"
  grep -Fq 'requeue' "$skill"
  grep -Fq 'compare-and-swap' "$skill"
  grep -Fq 'result.md' "$skill"
  grep -Fq 'DONE' "$skill"
  grep -Fq 'REQUEUE' "$skill"
  grep -Fq 'Do not run Project Pull' "$skill"
  grep -Fq 'Do not clone, run' "$skill"
  grep -Fq 'push, create a pull request, call a remote service, or send a message' "$skill"
  ! grep -Eiq 'approved|approval gate|python|yq|jq|node|ruby' "$skill"
  ! grep -Fq 'Integrate merge-ready units' "$skill"
}

@test "feature finalization verifies terminal evidence without bypassing ticket Implement" {
  prompt="$ROOT/skills/superteam-build/finalizer-prompt.md"

  [ -f "$prompt" ]
  grep -Fq 'fresh feature finalizer' "$prompt"
  grep -Fq 'resolved ticket and Result' "$prompt"
  grep -Fq 'recorded integrated head' "$prompt"
  grep -Fq 'canonical feature HEAD' "$prompt"
  grep -Fq 'full verification' "$prompt"
  grep -Fq 'must not replace missing evidence' "$prompt"
  grep -Fq 'Do not implement or fix code' "$prompt"
  grep -Fq 'Do not review ticket code again' "$prompt"
  grep -Fq 'proposed outcome `DONE`, `REQUEUE`, or `BLOCKED`' "$prompt"
  grep -Fq 'outside every Repository worktree' "$prompt"
  grep -Fq 'Do not modify task or knowledge files' "$prompt"
  grep -Fq 'Do not push, create a pull request, call a remote service, or send a message' "$prompt"
}

@test "public documentation exposes unattended Repository Set Build boundaries" {
  grep -Fq '`superteam-build`' "$ROOT/README.md"
  grep -Fq 'team of AI agents' "$ROOT/README.md"
  grep -Fq 'multi-repository' "$ROOT/README.md"
  grep -Fq 'implementation, review, fixes' "$ROOT/README.md"

  grep -Fq '`superteam-build`' "$ROOT/README.zh-CN.md"
  grep -Fq 'AI Agent 团队' "$ROOT/README.zh-CN.md"
  grep -Fq '多仓库' "$ROOT/README.zh-CN.md"
  grep -Fq '实现、审查、修复' "$ROOT/README.zh-CN.md"
}
