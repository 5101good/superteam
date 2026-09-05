#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
PROJECT="$ROOT/scripts/st-project.sh"
SNAPSHOT="$ROOT/scripts/st-project-snapshot.sh"
FRONTMATTER="$ROOT/scripts/lib/frontmatter.sh"
TICKETS="$ROOT/scripts/st-tickets.sh"
BOARD="$ROOT/scripts/st-board.sh"

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project with space"
  mkdir -p "$PROJECT_ROOT"
  PROJECT_ROOT="$(cd -P -- "$PROJECT_ROOT" && pwd -P)"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.name "Fixture Contributor"
  git -C "$PROJECT_ROOT" config user.email "fixture@invalid"
  mkdir -p "$PROJECT_ROOT/work items" "$PROJECT_ROOT/team notes"
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "work items"
  knowledge: "team notes"
EOF
  FEATURE="$PROJECT_ROOT/work items/100-example"
}
write_contract() {
  local target=$1
  local kind=$2
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
---
id: "100"
slug: "example"
repositories:
  - root
created_at: "2026-08-25"
supersedes: []
---

# Example $kind

Contract body stays byte-for-byte stable.
EOF
}

new_ticket() {
  local id=$1
  local title=$2
  local blockers=${3:-}
  local body="$BATS_TEST_TMPDIR/body-$id.md"
  cat > "$body" <<EOF
**What to build:** deliver $title

## Acceptance criteria
- [ ] $title works

## Result
EOF
  bash "$TICKETS" new "$FEATURE" --id "$id" --title "$title" \
    --repositories root --blocked-by "$blockers" --body-file "$body"
}

write_success_result() {
  printf '%s\n' 'Outcome: DONE' 'Verification: PASS' \
    'Verification exit codes: 0,0' '' 'Tests and independent reviews passed.' > "$1"
}

make_integration_history() {
  local repository=$1 feature_branch=$2 ticket_branch=$3 tree
  if ! git -C "$repository" rev-parse 'HEAD^{commit}' >/dev/null 2>&1; then
    git -C "$repository" commit --allow-empty -qm 'chore: establish fixture base'
  fi
  EVIDENCE_BASE=$(git -C "$repository" rev-parse 'HEAD^{commit}')
  tree=$(git -C "$repository" rev-parse "$EVIDENCE_BASE^{tree}")
  EVIDENCE_TICKET_HEAD=$(printf '%s\n' 'ticket change' |
    git -C "$repository" commit-tree "$tree" -p "$EVIDENCE_BASE")
  EVIDENCE_PREPARED_HEAD=$(printf '%s\n' 'prepare ticket integration' |
    git -C "$repository" commit-tree "$tree" -p "$EVIDENCE_BASE" -p "$EVIDENCE_TICKET_HEAD")
  EVIDENCE_INTEGRATED_HEAD=$EVIDENCE_PREPARED_HEAD
  git -C "$repository" update-ref "refs/heads/$ticket_branch" "$EVIDENCE_TICKET_HEAD"
  git -C "$repository" update-ref "refs/heads/$feature_branch" "$EVIDENCE_INTEGRATED_HEAD"
}

record_integration_evidence() {
  local ticket=$1 repository_id=$2 feature_branch=$3 ticket_branch=$4
  bash "$TICKETS" branch-set "$ticket" "$repository_id" base "$EVIDENCE_BASE" >/dev/null
  bash "$TICKETS" branch-set "$ticket" "$repository_id" feature_branch "$feature_branch" >/dev/null
  bash "$TICKETS" branch-set "$ticket" "$repository_id" ticket_branch "$ticket_branch" >/dev/null
  bash "$TICKETS" branch-set "$ticket" "$repository_id" ticket_head "$EVIDENCE_TICKET_HEAD" >/dev/null
  bash "$TICKETS" branch-set "$ticket" "$repository_id" prepared_head "$EVIDENCE_PREPARED_HEAD" >/dev/null
  bash "$TICKETS" branch-set "$ticket" "$repository_id" integrated_head "$EVIDENCE_INTEGRATED_HEAD" >/dev/null
}

record_root_integration_evidence() {
  local ticket=$1
  make_integration_history "$PROJECT_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root
  record_integration_evidence "$ticket" root superteam/100-example \
    superteam/100-example-ticket-01-root
}

record_terminal_feature_result() {
  local tree terminal
  git -C "$PROJECT_ROOT" add -- "work items/100-example"
  tree=$(git -C "$PROJECT_ROOT" write-tree)
  terminal=$(printf '%s\n' 'record terminal feature result' |
    git -C "$PROJECT_ROOT" commit-tree "$tree" -p "$EVIDENCE_INTEGRATED_HEAD")
  git -C "$PROJECT_ROOT" update-ref refs/heads/superteam/100-example "$terminal"
}

@test "named Project Snapshot queries custom paths and always includes root" {
  run bash "$SNAPSHOT" root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P -- "$PROJECT_ROOT" && pwd -P)" ]

  run bash "$SNAPSHOT" task "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P -- "$PROJECT_ROOT/work items" && pwd -P)" ]

  run bash "$SNAPSHOT" knowledge "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P -- "$PROJECT_ROOT/team notes" && pwd -P)" ]

  run bash "$SNAPSHOT" repositories "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = root ]

  run bash "$SNAPSHOT" repository-path root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = . ]

  external="$BATS_TEST_TMPDIR/api repository"
  mkdir "$external"
  git -C "$external" init -q
  cat >> "$PROJECT_ROOT/superteam.yaml" <<'EOF'
repositories:
  - id: "api"
    path: "../api repository"
EOF
  run bash "$SNAPSHOT" repositories "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = root ]
  [ "${lines[1]}" = api ]
  run bash "$SNAPSHOT" repository-path api "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "../api repository" ]
}

@test "strict frontmatter reads scalars and lists then atomically preserves the body" {
  write_contract "$FEATURE/spec.md" Spec
  body_before="$(awk '/^---$/ { delimiters++; next } delimiters == 2 { print }' "$FEATURE/spec.md")"

  run bash "$FRONTMATTER" get "$FEATURE/spec.md" slug
  [ "$status" -eq 0 ]
  [ "$output" = example ]
  run bash "$FRONTMATTER" get-list "$FEATURE/spec.md" repositories
  [ "$status" -eq 0 ]
  [ "$output" = root ]

  bash "$FRONTMATTER" set-list "$FEATURE/spec.md" supersedes "099, 098"
  body_after="$(awk '/^---$/ { delimiters++; next } delimiters == 2 { print }' "$FEATURE/spec.md")"
  [ "$body_after" = "$body_before" ]
  run bash "$FRONTMATTER" get-list "$FEATURE/spec.md" supersedes
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = 099 ]
  [ "${lines[1]}" = 098 ]
  bash "$FRONTMATTER" validate "$FEATURE/spec.md"

  [ -z "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" ]
  [ -z "$(find "$PROJECT_ROOT" -name '*.superteam-write.*' -o -name '*.superteam-lock')" ]
}

@test "ticket branch records support deterministic read and replacement" {
  mkdir -p "$FEATURE"
  ticket="$(new_ticket 01 "First slice")"

  bash "$FRONTMATTER" branch-set "$ticket" root base abc123
  bash "$FRONTMATTER" branch-set "$ticket" root integrated_head def456

  run bash "$FRONTMATTER" branch-get "$ticket" root base
  [ "$status" -eq 0 ]
  [ "$output" = abc123 ]
  run bash "$FRONTMATTER" branch-get "$ticket" root integrated_head
  [ "$status" -eq 0 ]
  [ "$output" = def456 ]
  [ "$(grep -c '^branches:$' "$ticket")" -eq 1 ]
  [ "$(grep -c '^  root:$' "$ticket")" -eq 1 ]
}

@test "tracker reads the canonical claimed-ticket branch shorthand" {
  mkdir -p "$FEATURE"
  ticket="$(new_ticket 01 "Claimed branch")"
  awk '
    $0 == "branches: {}" {
      print "branches:"
      print "  root: \"codex/example-01\""
      next
    }
    { print }
  ' "$ticket" > "$ticket.next"
  mv "$ticket.next" "$ticket"

  bash "$FRONTMATTER" validate "$ticket" ticket
  run bash "$FRONTMATTER" branch-get "$ticket" root ticket_branch
  [ "$status" -eq 0 ]
  [ "$output" = codex/example-01 ]
}

@test "unknown duplicate complex and malformed frontmatter fail closed" {
  write_contract "$FEATURE/spec.md" Spec

  cp "$FEATURE/spec.md" "$BATS_TEST_TMPDIR/unknown.md"
  awk 'NR == 2 { print "unknown: \"value\"" } { print }' \
    "$BATS_TEST_TMPDIR/unknown.md" > "$BATS_TEST_TMPDIR/unknown.next"
  mv "$BATS_TEST_TMPDIR/unknown.next" "$BATS_TEST_TMPDIR/unknown.md"
  run bash "$FRONTMATTER" validate "$BATS_TEST_TMPDIR/unknown.md" spec
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown frontmatter key"* ]]

  cp "$FEATURE/spec.md" "$BATS_TEST_TMPDIR/duplicate.md"
  awk 'NR == 3 { print "id: \"other\"" } { print }' \
    "$BATS_TEST_TMPDIR/duplicate.md" > "$BATS_TEST_TMPDIR/duplicate.next"
  mv "$BATS_TEST_TMPDIR/duplicate.next" "$BATS_TEST_TMPDIR/duplicate.md"
  run bash "$FRONTMATTER" validate "$BATS_TEST_TMPDIR/duplicate.md" spec
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate frontmatter key"* ]]

  cp "$FEATURE/spec.md" "$BATS_TEST_TMPDIR/complex.md"
  sed 's/id: "100"/id: \&shared "100"/' "$BATS_TEST_TMPDIR/complex.md" > "$BATS_TEST_TMPDIR/complex.next"
  mv "$BATS_TEST_TMPDIR/complex.next" "$BATS_TEST_TMPDIR/complex.md"
  run bash "$FRONTMATTER" validate "$BATS_TEST_TMPDIR/complex.md" spec
  [ "$status" -ne 0 ]

  printf '%s\n' '---' 'id: "100"' > "$BATS_TEST_TMPDIR/partial.md"
  run bash "$FRONTMATTER" validate "$BATS_TEST_TMPDIR/partial.md" spec
  [ "$status" -ne 0 ]

  before="$(cksum "$FEATURE/spec.md")"
  run bash "$FRONTMATTER" set "$FEATURE/spec.md" status approved
  [ "$status" -ne 0 ]
  [ "$(cksum "$FEATURE/spec.md")" = "$before" ]
}

@test "a held writer lock rejects a concurrent update without changing the document" {
  write_contract "$FEATURE/spec.md" Spec
  lock="$(bash "$FRONTMATTER" lock-path "$FEATURE/spec.md")"
  mkdir -p "$(dirname "$lock")"
  mkdir "$lock"
  before="$(cksum "$FEATURE/spec.md")"

  run bash "$FRONTMATTER" set "$FEATURE/spec.md" slug changed
  [ "$status" -ne 0 ]
  [[ "$output" == *"another workflow data writer is active"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$before" ]

  rmdir "$lock"
}

@test "failed frontmatter updates clean operation files and preserve the document" {
  write_contract "$FEATURE/spec.md" Spec
  operation_tmp="$BATS_TEST_TMPDIR/operation-temp"
  mkdir "$operation_tmp"
  before="$(cksum "$FEATURE/spec.md")"

  run env TMPDIR="$operation_tmp" bash "$FRONTMATTER" set "$FEATURE/spec.md" status approved
  [ "$status" -ne 0 ]
  [ "$(cksum "$FEATURE/spec.md")" = "$before" ]
  [ -z "$(find "$operation_tmp" -mindepth 1 -print)" ]
  [ -z "$(find "$FEATURE" -name '*.superteam-write.*' -print)" ]
}

@test "tracker creates and validates a feature in the configured task path" {
  run bash "$TICKETS" create-feature --id 100 --slug example --project "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$FEATURE" ]
  [ -d "$FEATURE" ]
  [ ! -e "$FEATURE/tickets" ]

  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "First slice")"
  second="$(new_ticket 02 "Second slice" 01)"

  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = OK ]
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]

  result="$BATS_TEST_TMPDIR/result.md"
  write_success_result "$result"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  [ "$(bash "$FRONTMATTER" get "$first" status)" = claimed ]
  [ "$(bash "$FRONTMATTER" get "$first" claimed_by)" = worker ]
  [ -n "$(bash "$FRONTMATTER" get "$first" claimed_at)" ]
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  record_root_integration_evidence "$first"
  bash "$TICKETS" resolve "$first" >/dev/null

  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
  [ "$(bash "$TICKETS" branch-get "$first" root integrated_head)" = \
    "$EVIDENCE_INTEGRATED_HEAD" ]
}

@test "resolved Git evidence fails closed and never unlocks a dependency" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Evidence source")"
  second="$(new_ticket 02 "Dependent slice" 01)"
  result="$BATS_TEST_TMPDIR/result.md"
  write_success_result "$result"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  bash "$TICKETS" write-result "$first" "$result" >/dev/null

  make_integration_history "$PROJECT_ROOT" superteam/100-example \
    superteam/100-example-ticket-01-root
  bash "$TICKETS" branch-set "$first" root feature_branch superteam/100-example >/dev/null
  bash "$TICKETS" branch-set "$first" root ticket_branch \
    superteam/100-example-ticket-01-root >/dev/null
  bash "$TICKETS" branch-set "$first" root ticket_head "$EVIDENCE_TICKET_HEAD" >/dev/null
  bash "$TICKETS" branch-set "$first" root prepared_head "$EVIDENCE_PREPARED_HEAD" >/dev/null
  bash "$TICKETS" branch-set "$first" root integrated_head "$EVIDENCE_INTEGRATED_HEAD" >/dev/null

  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing Git evidence: root.base"* ]]
  [ "$(bash "$FRONTMATTER" get "$first" status)" = claimed ]

  bash "$TICKETS" branch-set "$first" root base "$EVIDENCE_BASE" >/dev/null
  bash "$TICKETS" branch-set "$first" root ticket_head \
    0000000000000000000000000000000000000000 >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown commit: root.ticket_head"* ]]

  bash "$TICKETS" branch-set "$first" root ticket_head "$EVIDENCE_TICKET_HEAD" >/dev/null
  tree=$(git -C "$PROJECT_ROOT" rev-parse "$EVIDENCE_BASE^{tree}")
  unreachable=$(printf '%s\n' 'unreachable integration' |
    git -C "$PROJECT_ROOT" commit-tree "$tree" -p "$EVIDENCE_BASE")
  bash "$TICKETS" branch-set "$first" root prepared_head "$unreachable" >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ticket head is not an ancestor of prepared head"* ]]

  bash "$TICKETS" branch-set "$first" root prepared_head "$EVIDENCE_PREPARED_HEAD" >/dev/null
  git -C "$PROJECT_ROOT" update-ref refs/heads/superteam/wrong \
    "$EVIDENCE_INTEGRATED_HEAD"
  bash "$TICKETS" branch-set "$first" root feature_branch superteam/wrong >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-canonical feature branch"* ]]

  bash "$TICKETS" branch-set "$first" root feature_branch superteam/100-example >/dev/null
  git -C "$PROJECT_ROOT" update-ref refs/heads/superteam/wrong-ticket \
    "$EVIDENCE_TICKET_HEAD"
  bash "$TICKETS" branch-set "$first" root ticket_branch superteam/wrong-ticket >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-canonical ticket branch"* ]]

  bash "$TICKETS" branch-set "$first" root ticket_branch \
    superteam/100-example-ticket-01-root >/dev/null
  git -C "$PROJECT_ROOT" update-ref refs/heads/superteam/100-example "$EVIDENCE_BASE"
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"integrated head is not reachable from feature branch"* ]]
  git -C "$PROJECT_ROOT" update-ref refs/heads/superteam/100-example \
    "$EVIDENCE_INTEGRATED_HEAD"

  git -C "$PROJECT_ROOT" update-ref refs/heads/codex/100-example \
    "$EVIDENCE_INTEGRATED_HEAD"
  git -C "$PROJECT_ROOT" update-ref refs/heads/codex/100-example-01 \
    "$EVIDENCE_TICKET_HEAD"
  bash "$TICKETS" branch-set "$first" root feature_branch codex/100-example >/dev/null
  bash "$TICKETS" branch-set "$first" root ticket_branch codex/100-example-01 >/dev/null
  bash "$TICKETS" resolve "$first" >/dev/null
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]

  resolved_at=$(bash "$FRONTMATTER" get "$first" resolved_at)
  bash "$FRONTMATTER" set "$first" resolved_at ''
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing resolved_at"* ]]
  [[ "$output" != *"$second"* ]]
  bash "$FRONTMATTER" set "$first" resolved_at "$resolved_at"

  bash "$TICKETS" branch-set "$first" root integrated_head \
    0000000000000000000000000000000000000000 >/dev/null
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown commit: root.integrated_head"* ]]
  [[ "$output" != *"$second"* ]]

  run bash "$TICKETS" branch-set "$first" root integrated_head \
    "$EVIDENCE_INTEGRATED_HEAD"
  [ "$status" -eq 0 ]
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
}

@test "resolved evidence validates every Repository in a multi-Repository ticket" {
  api="$BATS_TEST_TMPDIR/api repository"
  mkdir -p "$api" "$FEATURE"
  git -C "$api" init -q
  git -C "$api" config user.name "Fixture Contributor"
  git -C "$api" config user.email "fixture@invalid"
  cat >> "$PROJECT_ROOT/superteam.yaml" <<'EOF'
repositories:
  - id: "api"
    path: "../api repository"
EOF
  write_contract "$FEATURE/spec.md" Spec
  body="$BATS_TEST_TMPDIR/multi-body.md"
  printf '%s\n' '**What to build:** deliver both Repositories' '' \
    '## Acceptance criteria' '- [ ] both Repositories are integrated' '' '## Result' > "$body"
  ticket=$(bash "$TICKETS" new "$FEATURE" --id 01 --title "Multi Repository" \
    --repositories root,api --body-file "$body")
  result="$BATS_TEST_TMPDIR/multi-result.md"
  write_success_result "$result"
  bash "$TICKETS" claim "$ticket" --owner worker >/dev/null
  bash "$TICKETS" write-result "$ticket" "$result" >/dev/null

  record_root_integration_evidence "$ticket"
  run bash "$TICKETS" resolve "$ticket"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing Git evidence: api.base"* ]]

  make_integration_history "$api" superteam/100-example \
    superteam/100-example-ticket-01-api
  record_integration_evidence "$ticket" api superteam/100-example \
    superteam/100-example-ticket-01-api
  run bash "$TICKETS" resolve "$ticket"
  [ "$status" -eq 0 ]
  [ -n "$(bash "$FRONTMATTER" get "$ticket" resolved_at)" ]
  bash "$TICKETS" validate "$FEATURE"
}

@test "ticket creation rejects duplicate IDs and unknown blockers without residue" {
  mkdir -p "$FEATURE"
  first="$(new_ticket 01 "First slice")"

  run new_ticket 01 "Duplicate slice"
  [ "$status" -ne 0 ]
  [ "$(find "$FEATURE/tickets" -type f -name '*.md' | wc -l | tr -d ' ')" -eq 1 ]

  run new_ticket 02 "Unknown dependency" 99
  [ "$status" -ne 0 ]
  [ ! -e "$FEATURE/tickets/02-unknown-dependency.md" ]
  [ -z "$(find "$FEATURE" -name '.superteam-ticket.*' -print)" ]

  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = OK ]
  [ -f "$first" ]
}

@test "write-result rejects a second Result heading without changing the ticket" {
  mkdir -p "$FEATURE"
  ticket="$(new_ticket 01 "Result boundary")"
  result="$BATS_TEST_TMPDIR/malformed-result.md"
  printf '%s\n' 'Outcome: delivered' '## Result' 'unexpected second section' > "$result"
  before="$(cksum "$ticket")"

  run bash "$TICKETS" write-result "$ticket" "$result"
  [ "$status" -ne 0 ]
  [ "$(cksum "$ticket")" = "$before" ]
  [ "$(grep -c '^## Result$' "$ticket")" -eq 1 ]
}

@test "tracker rejects ticket filenames whose ID and slug are not canonical" {
  mkdir -p "$FEATURE"
  ticket="$(new_ticket 01 "Canonical name")"
  mv "$ticket" "$FEATURE/tickets/not-a-ticket-name.md"

  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ticket filename"* ]]
}

@test "tracker rejects unknown repositories blockers duplicate IDs and cycles" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  new_ticket 01 First >/dev/null
  new_ticket 02 Second 01 >/dev/null
  bash "$FRONTMATTER" set-list "$FEATURE/tickets/02-second.md" blocked_by 99
  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown blocker"* ]]

  bash "$FRONTMATTER" set-list "$FEATURE/tickets/02-second.md" blocked_by 01
  bash "$FRONTMATTER" set-list "$FEATURE/tickets/01-first.md" blocked_by 02
  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *cycle* ]]

  bash "$FRONTMATTER" set-list "$FEATURE/tickets/01-first.md" blocked_by ""
  cp "$FEATURE/tickets/01-first.md" "$FEATURE/tickets/01-copy.md"
  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate ticket id"* ]]

  rm "$FEATURE/tickets/01-copy.md"
  bash "$FRONTMATTER" set-list "$FEATURE/tickets/01-first.md" repositories missing
  run bash "$TICKETS" validate "$FEATURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown Repository ID"* ]]
}

@test "feature status derives PRD SPEC READY RUNNING BLOCKED and DONE without approvals" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/prd.md" PRD
  ! grep -Eq '^(status|approved):' "$FEATURE/prd.md"
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == PRD* ]]

  write_contract "$FEATURE/spec.md" Spec
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == SPEC* ]]

  first="$(new_ticket 01 "Only slice")"
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == READY* ]]

  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == RUNNING* ]]

  bash "$TICKETS" block "$first" --reason "external decision" >/dev/null
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == BLOCKED* ]]

  result="$BATS_TEST_TMPDIR/result.md"
  write_success_result "$result"
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  record_root_integration_evidence "$first"
  bash "$TICKETS" resolve "$first" >/dev/null
  : > "$FEATURE/result.md"
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == READY* ]]

  printf '%s\n' '# Feature Result' '' 'Outcome: DONE' > "$FEATURE/result.md"
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == READY* ]]

  record_terminal_feature_result
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == *READY* ]]

  write_success_result "$FEATURE/result.md"
  record_terminal_feature_result
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == DONE* ]]

  printf '%s\n' 'uncommitted edit' >> "$FEATURE/result.md"
  run bash "$TICKETS" feature-status "$FEATURE"
  [[ "$output" == READY* ]]

  spec_only="$PROJECT_ROOT/work items/200-spec-only"
  mkdir "$spec_only"
  write_contract "$spec_only/spec.md" Spec
  bash "$FRONTMATTER" set "$spec_only/spec.md" id 200
  bash "$FRONTMATTER" set "$spec_only/spec.md" slug spec-only
  run bash "$TICKETS" feature-status "$spec_only"
  [ "$status" -eq 0 ]
  [[ "$output" == SPEC* ]]
}

@test "failed completion summaries preserve state and never unlock dependencies" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Summary source")"
  second="$(new_ticket 02 "Dependent slice" 01)"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  record_root_integration_evidence "$first"
  result="$BATS_TEST_TMPDIR/result.md"

  for summary in \
    $'Outcome: BLOCKED\nVerification: FAIL\nVerification exit codes: 1' \
    $'Outcome: DONE\nVerification: FAIL\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification: PASS\nVerification exit codes: 0,1' \
    $'Outcome: DONE\nVerification: NOT_RUN\nVerification exit codes: NONE' \
    $'Outcome: DONE\nVerification: UNKNOWN\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification: PASS\nVerification exit codes: NONE' \
    $'Outcome: DONE\nVerification: PASS\nVerification exit codes: 0,,0' \
    $'Verification: PASS\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification: PASS' \
    $'Outcome: DONE\nOutcome: BLOCKED\nVerification: PASS\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification: PASS\nVerification: FAIL\nVerification exit codes: 0' \
    $'Outcome: DONE\nVerification: PASS\nVerification exit codes: 0\nVerification exit codes: 1'; do
    printf '%s\n' "$summary" > "$result"
    bash "$TICKETS" write-result "$first" "$result" >/dev/null
    before="$(cksum "$first")"
    before_head="$(git -C "$PROJECT_ROOT" rev-parse refs/heads/superteam/100-example)"
    run bash "$TICKETS" resolve "$first"
    [ "$status" -ne 0 ]
    [[ "$output" == *"completion summary"* ]]
    [ "$(cksum "$first")" = "$before" ]
    [ "$(git -C "$PROJECT_ROOT" rev-parse refs/heads/superteam/100-example)" = "$before_head" ]
    run bash "$TICKETS" frontier "$FEATURE"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "successful final verification allows historical RED failures in free prose" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Historical evidence")"
  second="$(new_ticket 02 "Dependent slice" 01)"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  record_root_integration_evidence "$first"
  result="$BATS_TEST_TMPDIR/result.md"
  write_success_result "$result"
  printf '%s\n' '' '## Original RED observation' 'Outcome: BLOCKED' \
    'Verification: FAIL' 'Verification exit codes: 1' \
    'The regression failed before the fix; the final checks above passed.' >> "$result"
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -eq 0 ]
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
}

@test "not applicable verification requires NONE and an explanatory body" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Documentation decision")"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  record_root_integration_evidence "$first"
  result="$BATS_TEST_TMPDIR/result.md"
  printf '%s\n' 'Outcome: DONE' 'Verification: NOT_APPLICABLE' \
    'Verification exit codes: NONE' > "$result"
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"explanation"* ]]
  printf '\n%s\n' 'Only a manually checked decision record changed; no verification command applies.' >> "$result"
  sed 's/exit codes: NONE/exit codes: 0/' "$result" > "$result.invalid"
  bash "$TICKETS" write-result "$first" "$result.invalid" >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -ne 0 ]
  [[ "$output" == *"NONE"* ]]
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  run bash "$TICKETS" resolve "$first"
  [ "$status" -eq 0 ]
}

@test "forged resolved results fail closed and old results can be repaired atomically" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Legacy result")"
  second="$(new_ticket 02 "Dependent slice" 01)"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  record_root_integration_evidence "$first"
  result="$BATS_TEST_TMPDIR/result.md"
  printf '%s\n' 'Outcome: delivered' > "$result"
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  bash "$FRONTMATTER" set "$first" resolved_at '2026-09-05T12:00:00+0000'
  bash "$FRONTMATTER" set "$first" status resolved
  before="$(cksum "$first")"
  for command in validate frontier; do
    run bash "$TICKETS" "$command" "$FEATURE"
    [ "$status" -ne 0 ]
    [[ "$output" == *"completion summary"* ]]
    [[ "$output" != *"$second"* ]]
  done
  run bash "$BOARD" --project "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *INVALID* ]]
  [[ "$output" != *DONE* ]]
  [ "$(cksum "$first")" = "$before" ]

  printf '%s\n' 'Outcome: BLOCKED' 'Verification: FAIL' 'Verification exit codes: 1' > "$result"
  run bash "$TICKETS" write-result "$first" "$result"
  [ "$status" -ne 0 ]
  [ "$(cksum "$first")" = "$before" ]
  [ -z "$(find "$FEATURE" -name '*.superteam-write.*' -print)" ]

  write_success_result "$result"
  run bash "$TICKETS" write-result "$first" "$result"
  [ "$status" -eq 0 ]
  run bash "$TICKETS" frontier "$FEATURE"
  [ "$status" -eq 0 ]
  [ "$output" = "$second" ]
  before="$(cksum "$first")"
  printf '%s\n' 'Outcome: BLOCKED' > "$result"
  run bash "$FRONTMATTER" replace-result "$first" "$result"
  [ "$status" -ne 0 ]
  [ "$(cksum "$first")" = "$before" ]
}

@test "committed feature results require the same successful summary as tickets" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Feature verification")"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  record_root_integration_evidence "$first"
  result="$BATS_TEST_TMPDIR/result.md"
  write_success_result "$result"
  bash "$TICKETS" write-result "$first" "$result" >/dev/null
  bash "$TICKETS" resolve "$first" >/dev/null
  for summary in \
    'Outcome: DONE' \
    $'Outcome: BLOCKED\nVerification: FAIL\nVerification exit codes: 1' \
    $'Outcome: DONE\nVerification: PASS\nVerification exit codes: 1' \
    $'Outcome: DONE\nVerification: PASS\nVerification: FAIL\nVerification exit codes: 0'; do
    printf '%s\n' '# Feature Result' '' "$summary" > "$FEATURE/result.md"
    record_terminal_feature_result
    run bash "$TICKETS" feature-status "$FEATURE"
    [ "$status" -eq 0 ]
    [[ "$output" == *READY* ]]
    [[ "$output" != DONE* ]]
  done
  { printf '%s\n' '# Feature Result' ''; cat "$result"; } > "$FEATURE/result.md"
  record_terminal_feature_result
  run bash "$TICKETS" feature-status "$FEATURE"
  [ "$status" -eq 0 ]
  [[ "$output" == DONE* ]]
}

@test "Board reads custom task state without changing files or the Git index" {
  mkdir -p "$FEATURE"
  write_contract "$FEATURE/spec.md" Spec
  first="$(new_ticket 01 "Only slice")"
  bash "$TICKETS" claim "$first" --owner worker >/dev/null
  git -C "$PROJECT_ROOT" add -- superteam.yaml "work items" "team notes"
  git -C "$PROJECT_ROOT" commit -qm baseline
  before_head="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  before_status="$(git -C "$PROJECT_ROOT" status --porcelain)"

  run bash "$BOARD" --project "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *RUNNING*100-example*root* ]]
  [[ "$output" == *"01-only-slice:worker"* ]]
  [ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" = "$before_head" ]
  [ "$(git -C "$PROJECT_ROOT" status --porcelain)" = "$before_status" ]
}
