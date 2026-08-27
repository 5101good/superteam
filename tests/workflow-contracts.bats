#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
CONTRACT="$ROOT/scripts/st-contract.sh"
PLAN="$ROOT/scripts/st-plan.sh"
FRONTMATTER="$ROOT/scripts/lib/frontmatter.sh"
TICKETS="$ROOT/scripts/st-tickets.sh"

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project with space"
  mkdir -p "$PROJECT_ROOT/work items" "$PROJECT_ROOT/team notes"
  git -C "$PROJECT_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.name "Fixture Contributor"
  git -C "$PROJECT_ROOT" config user.email "fixture@invalid"
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "work items"
  knowledge: "team notes"
EOF
  FEATURE="$(bash "$TICKETS" create-feature --id 100 --slug example --project "$PROJECT_ROOT")"
  CANDIDATE="$BATS_TEST_TMPDIR/candidate document"
  PLAN_CANDIDATE="$BATS_TEST_TMPDIR/plan candidate"
  mkdir "$PLAN_CANDIDATE"
}
write_candidate_ticket() {
  directory=$1
  id=$2
  title=$3
  blockers=${4:-}
  behavior=${5:-$title}
  slug=$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]' | \
    sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
  {
    printf '%s\n' '---'
    printf 'id: "%s"\n' "$id"
    printf '%s\n' 'status: "ready-for-agent"' 'repositories:' '  - "root"'
    if [ -n "$blockers" ]; then
      printf '%s\n' 'blocked_by:'
      printf '%s\n' "$blockers" | tr ',' '\n' | sed 's/^/  - "/; s/$/"/'
    else
      printf '%s\n' 'blocked_by: []'
    fi
    printf '%s\n' 'claimed_by: ""' 'claimed_at: ""' 'branches: {}' '---' ''
    printf '# %s - %s\n\n' "$id" "$title"
    printf '**What to build:** %s\n\n' "$behavior"
    printf '%s\n' '## Acceptance criteria' "- [ ] $behavior" '' '## Result'
  } > "$directory/$id-$slug.md"
}

ticket_for_id() {
  find "$FEATURE/tickets" -maxdepth 1 -type f -name "$1-*.md" -print
}

directory_digest() {
  directory=$1
  for entry in "$directory"/*.md; do
    [ -f "$entry" ] || continue
    printf '%s ' "$(basename "$entry")"
    cksum "$entry"
  done | LC_ALL=C sort
}

write_candidate() {
  kind=$1
  body=${2:-Initial contract}
  created_at=${3:-2026-08-25}
  cat > "$CANDIDATE" <<EOF
---
id: "100"
slug: "example"
repositories:
  - "root"
created_at: "$created_at"
supersedes: []
---

# Example $kind

$body
EOF
}

new_ticket() {
  body="$BATS_TEST_TMPDIR/ticket-body"
  cat > "$body" <<'EOF'
**What to build:** preserve downstream history

## Acceptance criteria
- [ ] history is preserved

## Result
EOF
  bash "$TICKETS" new "$FEATURE" --id 01 --title "Preserve history" \
    --repositories root --body-file "$body"
}

@test "contract writer atomically creates PRD and Spec in a custom task path" {
  before_index="$(git -C "$PROJECT_ROOT" diff --cached --name-only)"

  write_candidate PRD
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTRACT: PRD"* ]]
  [[ "$output" == *"PATH: $FEATURE/prd.md"* ]]
  bash "$FRONTMATTER" validate "$FEATURE/prd.md" prd

  write_candidate Spec
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTRACT: SPEC"* ]]
  bash "$FRONTMATTER" validate "$FEATURE/spec.md" spec

  ! grep -Eq '^(status|approval|approved):' "$FEATURE/prd.md" "$FEATURE/spec.md"
  [ "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" = "$before_index" ]
  [ -z "$(find "$FEATURE" -name '*.superteam-write.*' -print)" ]
}

@test "invalid or locked contract updates preserve the current document" {
  write_candidate PRD
  bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE" >/dev/null
  before="$(cksum "$FEATURE/prd.md")"

  awk 'NR == 2 { print "status: \"approved\"" } { print }' \
    "$CANDIDATE" > "$CANDIDATE.invalid"
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE.invalid"
  [ "$status" -ne 0 ]
  [ "$(cksum "$FEATURE/prd.md")" = "$before" ]

  write_candidate PRD "Replacement body" "not-a-date"
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ "$(cksum "$FEATURE/prd.md")" = "$before" ]

  write_candidate PRD "Replacement body" "2026-08-26"
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"created_at must match the Current Contract"* ]]
  [ "$(cksum "$FEATURE/prd.md")" = "$before" ]

  write_candidate PRD "Replacement body"
  lock="$(bash "$FRONTMATTER" lock-path "$FEATURE/prd.md")"
  mkdir -p "$(dirname "$lock")"
  mkdir "$lock"
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"another workflow data writer is active"* ]]
  [ "$(cksum "$FEATURE/prd.md")" = "$before" ]
  rmdir "$lock"
  [ -z "$(find "$FEATURE" -name '*.superteam-write.*' -print)" ]
}

@test "contract revision with tickets fails closed without a reconciled candidate plan" {
  write_candidate Spec
  bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE" >/dev/null
  ticket="$(new_ticket)"
  contract_before="$(cksum "$FEATURE/spec.md")"
  ticket_before="$(cksum "$ticket")"

  write_candidate Spec "Revised contract"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a reconciled candidate ticket set"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
  [ "$(cksum "$ticket")" = "$ticket_before" ]
}

@test "malformed Current Plan paths fail closed before revising the Contract" {
  write_candidate Spec
  bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE" >/dev/null
  contract_before="$(cksum "$FEATURE/spec.md")"
  write_candidate Spec "Revision must not bypass an invalid Current Plan"

  printf '%s\n' invalid > "$FEATURE/tickets"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Current Plan path exists but is invalid"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
  rm "$FEATURE/tickets"

  mkdir "$FEATURE/tickets"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Current Plan path exists but is invalid"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
  rmdir "$FEATURE/tickets"

  mkdir "$FEATURE/tickets"
  printf '%s\n' invalid > "$FEATURE/tickets/not-markdown.txt"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Current Plan path exists but is invalid"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
  rm "$FEATURE/tickets/not-markdown.txt"
  rmdir "$FEATURE/tickets"

  mkdir "$BATS_TEST_TMPDIR/linked tickets"
  ln -s "$BATS_TEST_TMPDIR/linked tickets" "$FEATURE/tickets"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Current Plan path exists but is invalid"* ]]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
}

@test "PRD and Spec revisions reconcile a ready plan in the same workflow" {
  write_candidate PRD
  bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE" >/dev/null
  write_candidate Spec
  bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE" >/dev/null
  write_candidate_ticket "$PLAN_CANDIDATE" 01 "Initial slice"
  bash "$PLAN" apply "$FEATURE" "$PLAN_CANDIDATE" >/dev/null

  rm "$PLAN_CANDIDATE"/*.md
  write_candidate_ticket "$PLAN_CANDIDATE" 01 "Revised product slice" '' \
    "deliver revised product behavior"
  write_candidate_ticket "$PLAN_CANDIDATE" 02 "Added product slice" 01
  write_candidate PRD "Revised product contract"
  run bash "$CONTRACT" write prd "$FEATURE" "$CANDIDATE" "$PLAN_CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTRACT: PRD"* ]]
  [[ "$output" == *"SYNCED: 01"* ]]
  [[ "$output" == *"ADDED: 02"* ]]
  grep -q 'Revised product contract' "$FEATURE/prd.md"
  grep -q 'deliver revised product behavior' "$(ticket_for_id 01)"

  rm "$PLAN_CANDIDATE"/*.md
  write_candidate_ticket "$PLAN_CANDIDATE" 03 "Replacement technical slice"
  write_candidate Spec "Revised technical contract"
  run bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE" "$PLAN_CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CONTRACT: SPEC"* ]]
  [[ "$output" == *"REMOVED: 01"* ]]
  [[ "$output" == *"REMOVED: 02"* ]]
  [[ "$output" == *"ADDED: 03"* ]]
  grep -q 'Revised technical contract' "$FEATURE/spec.md"
  bash "$TICKETS" validate "$FEATURE"
}

@test "plan installation failure rolls back the Current Contract and complete ticket set" {
  write_candidate Spec
  bash "$CONTRACT" write spec "$FEATURE" "$CANDIDATE" >/dev/null
  write_candidate_ticket "$PLAN_CANDIDATE" 01 "Baseline slice"
  bash "$PLAN" apply "$FEATURE" "$PLAN_CANDIDATE" >/dev/null
  contract_before="$(cksum "$FEATURE/spec.md")"
  plan_before="$(directory_digest "$FEATURE/tickets")"

  rm "$PLAN_CANDIDATE"/*.md
  write_candidate_ticket "$PLAN_CANDIDATE" 02 "Replacement slice"
  write_candidate Spec "Replacement contract"
  fake_bin="$BATS_TEST_TMPDIR/failing-bin"
  mkdir "$fake_bin"
  cat > "$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -- ]; then
  shift
fi
case "$1" in
  */.superteam-plan-stage.*/tickets) exit 73 ;;
esac
exec /bin/mv -- "$@"
EOF
  chmod +x "$fake_bin/mv"

  run env PATH="$fake_bin:$PATH" bash "$CONTRACT" write spec "$FEATURE" \
    "$CANDIDATE" "$PLAN_CANDIDATE"
  [ "$status" -eq 73 ]
  [ "$(cksum "$FEATURE/spec.md")" = "$contract_before" ]
  [ "$(directory_digest "$FEATURE/tickets")" = "$plan_before" ]
  [ -z "$(find "$FEATURE" -maxdepth 1 \( -name '.superteam-plan-*' -o -name '.*.superteam-reconcile.*' \) -print)" ]
}
