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
