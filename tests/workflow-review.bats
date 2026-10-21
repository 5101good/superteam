#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
PACKAGE="$ROOT/scripts/st-review-package.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/review-repository"
  mkdir "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config core.hooksPath /dev/null
  git -C "$REPO" config user.name "Test Contributor"
  git -C "$REPO" config user.email "contributor"
  printf '%s\n' 'base' > "$REPO/tracked.txt"
  git -C "$REPO" add tracked.txt
  git -C "$REPO" commit -q -m "base"
  BASE="$(git -C "$REPO" rev-parse HEAD)"
}

git_state() {
  git -C "$REPO" status --porcelain=v1
  git -C "$REPO" rev-parse HEAD
  git -C "$REPO" diff --cached --binary
}

@test "review package fixes the base and includes the complete current worktree" {
  printf '%s\n' 'committed' > "$REPO/committed.txt"
  git -C "$REPO" add committed.txt
  git -C "$REPO" commit -q -m "committed change"
  printf '%s\n' 'staged' > "$REPO/staged.txt"
  git -C "$REPO" add staged.txt
  printf '%s\n' 'unstaged' >> "$REPO/tracked.txt"
  printf '%s\n' 'untracked' > "$REPO/untracked.txt"
  before="$(git_state)"

  run bash -c 'cd "$1" && bash "$2" "$3" WORKTREE' _ "$REPO" "$PACKAGE" "$BASE"

  [ "$status" -eq 0 ]
  [[ "$output" == *"BASE: $BASE"* ]]
  [[ "$output" == *"MODE: WORKTREE"* ]]
  [[ "$output" == *"committed.txt"* ]]
  [[ "$output" == *"staged.txt"* ]]
  [[ "$output" == *"tracked.txt"* ]]
  [[ "$output" == *"untracked.txt"* ]]
  [ "$before" = "$(git_state)" ]
}

@test "review package rejects invalid bases and empty effective changes" {
  run bash -c 'cd "$1" && bash "$2" missing WORKTREE' _ "$REPO" "$PACKAGE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fixed base is not a commit"* ]]

  run bash -c 'cd "$1" && bash "$2" "$3" WORKTREE' _ "$REPO" "$PACKAGE" "$BASE"
  [ "$status" -eq 3 ]
  [[ "$output" == *"effective change is empty"* ]]
}
