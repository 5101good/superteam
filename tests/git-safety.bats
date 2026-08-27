#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
FRONTMATTER="$ROOT/scripts/lib/frontmatter.sh"
PLAN="$ROOT/scripts/st-plan.sh"
TICKETS="$ROOT/scripts/st-tickets.sh"
RELEASE_AUDIT="$ROOT/scripts/st-release-audit.sh"
REVIEW_PACKAGE="$ROOT/scripts/st-review-package.sh"
DOC_SCAN="$ROOT/scripts/st-doc-scan.sh"

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project"
  FEATURE="$PROJECT_ROOT/task/100-example"
  TICKET="$FEATURE/tickets/01-safe-git.md"
  FOREIGN="$BATS_TEST_TMPDIR/foreign"
  TRACE_FILE="$BATS_TEST_TMPDIR/git-trace"
  mkdir -p "$FEATURE/tickets" "$PROJECT_ROOT/knowledge" "$FOREIGN"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.name "Fixture Contributor"
  git -C "$PROJECT_ROOT" config user.email "fixture@invalid"
  git -C "$PROJECT_ROOT" config core.hooksPath /dev/null
  git -C "$FOREIGN" init -q
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "task"
  knowledge: "knowledge"
EOF
  cat > "$FEATURE/spec.md" <<'EOF'
---
id: "100"
slug: "example"
repositories:
  - "root"
created_at: "2026-08-26"
supersedes: []
---

# Example Spec

The Current Contract requires isolated local Git operations.
EOF
  write_ticket "$TICKET" "original behavior"
  printf '%s\n' base > "$PROJECT_ROOT/tracked.txt"
  git -C "$PROJECT_ROOT" add -- superteam.yaml task knowledge tracked.txt
  git -C "$PROJECT_ROOT" commit -qm baseline
  BASE=$(git -C "$PROJECT_ROOT" rev-parse HEAD)
  POLLUTED_GIT_ENV=(
    GIT_DIR="$FOREIGN/.git"
    GIT_WORK_TREE="$FOREIGN"
    GIT_COMMON_DIR="$BATS_TEST_TMPDIR/missing-common"
    GIT_INDEX_FILE="$FOREIGN/.git/foreign-index"
    GIT_OBJECT_DIRECTORY="$FOREIGN/.git/objects"
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$PROJECT_ROOT/.git/objects"
    GIT_CONFIG_COUNT=1
    GIT_CONFIG_KEY_0=status.showUntrackedFiles
    GIT_CONFIG_VALUE_0=no
    GIT_OPTIONAL_LOCKS=0
    GIT_TRACE="$TRACE_FILE"
    GIT_TRACE2="$BATS_TEST_TMPDIR/git-trace2"
    GIT_TRACE2_EVENT="$BATS_TEST_TMPDIR/git-trace2-event"
  )
}

write_ticket() {
  local target=$1 behavior=$2
  cat > "$target" <<EOF
---
id: "01"
status: ready-for-agent
repositories:
  - root
blocked_by: []
claimed_by: ""
claimed_at: ""
branches: {}
---

# 01 - Safe Git

**What to build:** $behavior

## Acceptance criteria
- [ ] $behavior

## Result
EOF
}

@test "frontmatter and Tickets ignore caller Git repository and trace environment" {
  scratch_ticket="$PROJECT_ROOT/scratch-ticket.md"
  cp "$TICKET" "$scratch_ticket"

  run env "${POLLUTED_GIT_ENV[@]}" bash "$FRONTMATTER" set \
    "$scratch_ticket" claimed_by worker
  [ "$status" -eq 0 ]
  [ "$(bash "$FRONTMATTER" get "$scratch_ticket" claimed_by ticket)" = worker ]
  [ ! -e "$TRACE_FILE" ]

  run env "${POLLUTED_GIT_ENV[@]}" bash "$TICKETS" claim "$TICKET" --owner worker
  [ "$status" -eq 0 ]
  [ "$(bash "$FRONTMATTER" get "$TICKET" status ticket)" = claimed ]
  [ ! -e "$FOREIGN/.git/foreign-index" ]
  [ ! -e "$TRACE_FILE" ]
}

@test "Plan ignores caller Git repository and trace environment" {
  candidate="$BATS_TEST_TMPDIR/candidate"
  mkdir "$candidate"
  write_ticket "$candidate/01-safe-git.md" "revised behavior"

  run env "${POLLUTED_GIT_ENV[@]}" bash "$PLAN" apply "$FEATURE" "$candidate"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN: APPLIED"* ]]
  grep -Fq "revised behavior" "$TICKET"
  [ ! -e "$FOREIGN/.git/foreign-index" ]
  [ ! -e "$TRACE_FILE" ]
}

@test "release audit and review package ignore caller Git repository and trace environment" {
  run env "${POLLUTED_GIT_ENV[@]}" bash "$RELEASE_AUDIT" "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: PASS"* ]]
  [ ! -e "$TRACE_FILE" ]

  printf '%s\n' changed >> "$PROJECT_ROOT/tracked.txt"
  run env "${POLLUTED_GIT_ENV[@]}" bash -c \
    'cd "$1" && bash "$2" "$3" WORKTREE' _ "$PROJECT_ROOT" "$REVIEW_PACKAGE" "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked.txt"* ]]
  [ ! -e "$FOREIGN/.git/foreign-index" ]
  [ ! -e "$TRACE_FILE" ]
}

@test "documentation Git scan shares caller environment and trace isolation" {
  printf '%s\n' changed >> "$PROJECT_ROOT/tracked.txt"
  git -C "$PROJECT_ROOT" add -- tracked.txt
  git -C "$PROJECT_ROOT" commit -qm change

  run env "${POLLUTED_GIT_ENV[@]}" bash "$DOC_SCAN" audit root "$BASE" HEAD \
    --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CHANGED: tracked.txt"* ]]
  [ ! -e "$FOREIGN/.git/foreign-index" ]
  [ ! -e "$TRACE_FILE" ]
  [ ! -e "$BATS_TEST_TMPDIR/git-trace2" ]
  [ ! -e "$BATS_TEST_TMPDIR/git-trace2-event" ]
}
