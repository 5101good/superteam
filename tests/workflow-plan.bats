#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
PLAN="$ROOT/scripts/st-plan.sh"
TICKETS="$ROOT/scripts/st-tickets.sh"
FRONTMATTER="$ROOT/scripts/lib/frontmatter.sh"

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project with space"
  EXTERNAL_ROOT="$BATS_TEST_TMPDIR/external api"
  FEATURE="$PROJECT_ROOT/work items/100-example"
  CANDIDATE="$BATS_TEST_TMPDIR/plan candidate"
  mkdir -p "$PROJECT_ROOT/work items" "$PROJECT_ROOT/team notes" \
    "$EXTERNAL_ROOT" "$FEATURE" "$CANDIDATE" "$BATS_TEST_TMPDIR/no-hooks"
  git -C "$PROJECT_ROOT" init -q
  git -C "$EXTERNAL_ROOT" init -q
  git -C "$PROJECT_ROOT" config user.name "Fixture Contributor"
  git -C "$PROJECT_ROOT" config user.email "fixture@invalid"
  git -C "$PROJECT_ROOT" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"
  git -C "$EXTERNAL_ROOT" config user.name "Fixture Contributor"
  git -C "$EXTERNAL_ROOT" config user.email "fixture@invalid"
  git -C "$EXTERNAL_ROOT" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"
  printf '%s\n' root > "$PROJECT_ROOT/root.txt"
  printf '%s\n' api > "$EXTERNAL_ROOT/api.txt"
  git -C "$PROJECT_ROOT" add root.txt
  git -C "$PROJECT_ROOT" commit -qm baseline
  git -C "$EXTERNAL_ROOT" add api.txt
  git -C "$EXTERNAL_ROOT" commit -qm baseline
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "work items"
  knowledge: "team notes"
repositories:
  - id: "api"
    path: "../external api"
EOF
  cat > "$FEATURE/spec.md" <<'EOF'
---
id: "100"
slug: "example"
repositories:
  - "root"
  - "api"
created_at: "2026-08-25"
supersedes: []
---

# Example Spec

The Current Contract defines the delivery behavior.
EOF
}

write_candidate_ticket() {
  local directory=$1 id=$2 title=$3 repositories=$4 blockers=${5:-} behavior=${6:-$3}
  local slug
  slug=$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]' | \
    sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
  {
    printf '%s\n' '---'
    printf 'id: "%s"\n' "$id"
    printf '%s\n' 'status: "ready-for-agent"' 'repositories:'
    printf '%s\n' "$repositories" | tr ',' '\n' | sed 's/^/  - "/; s/$/"/'
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

configure_root_only() {
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "work items"
  knowledge: "team notes"
EOF
  bash "$FRONTMATTER" set-list "$FEATURE/spec.md" repositories root
}

ticket_for_id() {
  find "$FEATURE/tickets" -maxdepth 1 -type f -name "$1-*.md" -print
}

directory_digest() {
  local directory=$1 entry
  for entry in "$directory"/*.md; do
    [ -f "$entry" ] || continue
    printf '%s ' "$(basename "$entry")"
    cksum "$entry"
  done | LC_ALL=C sort
}

record_api_integration_evidence() {
  local ticket=$1 feature_branch=superteam/100-example
  local ticket_branch=superteam/100-example-ticket-02-api tree base ticket_head prepared
  base=$(git -C "$EXTERNAL_ROOT" rev-parse 'HEAD^{commit}')
  tree=$(git -C "$EXTERNAL_ROOT" rev-parse "$base^{tree}")
  ticket_head=$(printf '%s\n' 'ticket change' |
    git -C "$EXTERNAL_ROOT" commit-tree "$tree" -p "$base")
  prepared=$(printf '%s\n' 'prepare ticket integration' |
    git -C "$EXTERNAL_ROOT" commit-tree "$tree" -p "$base" -p "$ticket_head")
  git -C "$EXTERNAL_ROOT" update-ref "refs/heads/$ticket_branch" "$ticket_head"
  git -C "$EXTERNAL_ROOT" update-ref "refs/heads/$feature_branch" "$prepared"
  bash "$TICKETS" branch-set "$ticket" api base "$base" >/dev/null
  bash "$TICKETS" branch-set "$ticket" api feature_branch "$feature_branch" >/dev/null
  bash "$TICKETS" branch-set "$ticket" api ticket_branch "$ticket_branch" >/dev/null
  bash "$TICKETS" branch-set "$ticket" api ticket_head "$ticket_head" >/dev/null
  bash "$TICKETS" branch-set "$ticket" api prepared_head "$prepared" >/dev/null
  bash "$TICKETS" branch-set "$ticket" api integrated_head "$prepared" >/dev/null
}

@test "Plan atomically installs a root-only DAG in a custom task path" {
  configure_root_only
  write_candidate_ticket "$CANDIDATE" 01 "Root seam" root '' "deliver the root seam"

  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PLAN: APPLIED"* ]]
  [[ "$output" == *"ADDED: 01"* ]]
  [[ "$output" == *"SUMMARY: synced=0 retained=0 added=1 removed=0 affected=0"* ]]
  bash "$TICKETS" validate "$FEATURE"
  [ "$(bash "$FRONTMATTER" get "$(ticket_for_id 01)" status)" = ready-for-agent ]
  [ "$(bash "$TICKETS" repositories "$FEATURE")" = root ]
  [ -z "$(git -C "$PROJECT_ROOT" diff --cached --name-only)" ]
  [ ! -e "$FEATURE/result.md" ]
}

@test "Plan accepts a ticket spanning root and a registered Repository" {
  write_candidate_ticket "$CANDIDATE" 01 "Root seam" root
  write_candidate_ticket "$CANDIDATE" 02 "Cross repository seam" root,api 01 \
    "deliver the cross-Repository seam"

  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADDED: 02"* ]]
  [ "$(bash "$FRONTMATTER" get-list "$(ticket_for_id 02)" repositories)" = $'root\napi' ]
  [ "$(bash "$FRONTMATTER" get-list "$(ticket_for_id 02)" blocked_by)" = 01 ]
  bash "$TICKETS" validate "$FEATURE"
}

@test "a ready-only revision rewrites adds removes and renumbers the whole plan" {
  write_candidate_ticket "$CANDIDATE" 01 "First slice" root
  write_candidate_ticket "$CANDIDATE" 02 "Old slice" api 01
  bash "$PLAN" apply "$FEATURE" "$CANDIDATE" >/dev/null

  rm "$CANDIDATE"/*.md
  write_candidate_ticket "$CANDIDATE" 01 "Revised first slice" root '' "deliver revised behavior"
  write_candidate_ticket "$CANDIDATE" 03 "Renumbered final slice" root,api 01

  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYNCED: 01"* ]]
  [[ "$output" == *"REMOVED: 02"* ]]
  [[ "$output" == *"ADDED: 03"* ]]
  [ -z "$(ticket_for_id 02)" ]
  grep -q 'deliver revised behavior' "$(ticket_for_id 01)"
  [ -f "$(ticket_for_id 03)" ]
  bash "$TICKETS" validate "$FEATURE"
}

@test "claimed and resolved history stays byte-stable while a correction ticket is added" {
  write_candidate_ticket "$CANDIDATE" 01 "Active slice" root
  write_candidate_ticket "$CANDIDATE" 02 "Delivered slice" api
  bash "$PLAN" apply "$FEATURE" "$CANDIDATE" >/dev/null
  active="$(ticket_for_id 01)"
  delivered="$(ticket_for_id 02)"
  bash "$TICKETS" claim "$active" --owner worker >/dev/null
  bash "$TICKETS" claim "$delivered" --owner worker >/dev/null
  result="$BATS_TEST_TMPDIR/result.md"
  printf '%s\n' 'Outcome: delivered' 'Tests: passed' 'Reviews: passed' > "$result"
  bash "$TICKETS" write-result "$delivered" "$result" >/dev/null
  record_api_integration_evidence "$delivered"
  bash "$TICKETS" resolve "$delivered" >/dev/null
  active_before="$(cksum "$active")"
  delivered_before="$(cksum "$delivered")"

  rm "$CANDIDATE"/*.md
  write_candidate_ticket "$CANDIDATE" 03 "Correction slice" root,api 02 \
    "correct the delivered contract without rewriting history"
  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETAINED: 01 status=claimed"* ]]
  [[ "$output" == *"AFFECTED: 01 status=claimed"* ]]
  [[ "$output" == *"RETAINED: 02 status=resolved"* ]]
  [[ "$output" == *"ADDED: 03"* ]]
  [ "$(cksum "$active")" = "$active_before" ]
  [ "$(cksum "$delivered")" = "$delivered_before" ]
  grep -q 'Outcome: delivered' "$delivered"
  bash "$TICKETS" validate "$FEATURE"
}

@test "a candidate cannot overwrite protected history" {
  write_candidate_ticket "$CANDIDATE" 01 "Active slice" root
  bash "$PLAN" apply "$FEATURE" "$CANDIDATE" >/dev/null
  active="$(ticket_for_id 01)"
  bash "$TICKETS" claim "$active" --owner worker >/dev/null
  before="$(directory_digest "$FEATURE/tickets")"

  rm "$CANDIDATE"/*.md
  write_candidate_ticket "$CANDIDATE" 01 "Replacement slice" root
  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate collides with protected ticket 01"* ]]
  [ "$(directory_digest "$FEATURE/tickets")" = "$before" ]
}

@test "a cyclic candidate leaves the Current Plan unchanged" {
  write_candidate_ticket "$CANDIDATE" 01 "Baseline slice" root
  bash "$PLAN" apply "$FEATURE" "$CANDIDATE" >/dev/null
  before="$(directory_digest "$FEATURE/tickets")"

  rm "$CANDIDATE"/*.md
  write_candidate_ticket "$CANDIDATE" 01 "Cycle one" root 02
  write_candidate_ticket "$CANDIDATE" 02 "Cycle two" root 01
  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ "$(directory_digest "$FEATURE/tickets")" = "$before" ]
  [ -z "$(find "$FEATURE" -maxdepth 1 \( -name '.superteam-plan-stage.*' -o -name '.superteam-plan-backup.*' \) -print)" ]
}

@test "a normal installation failure restores the complete previous plan" {
  write_candidate_ticket "$CANDIDATE" 01 "Baseline slice" root
  bash "$PLAN" apply "$FEATURE" "$CANDIDATE" >/dev/null
  before="$(directory_digest "$FEATURE/tickets")"

  rm "$CANDIDATE"/*.md
  write_candidate_ticket "$CANDIDATE" 02 "Replacement slice" root
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

  run env PATH="$fake_bin:$PATH" bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ "$(directory_digest "$FEATURE/tickets")" = "$before" ]
  [ -z "$(find "$FEATURE" -maxdepth 1 \( -name '.superteam-plan-stage.*' -o -name '.superteam-plan-backup.*' \) -print)" ]
}

@test "candidate tickets require clean ready-for-agent planning state" {
  write_candidate_ticket "$CANDIDATE" 01 "Claimed candidate" root
  sed 's/status: "ready-for-agent"/status: "claimed"/; s/claimed_by: ""/claimed_by: "planner"/; s/claimed_at: ""/claimed_at: "now"/' \
    "$CANDIDATE/01-claimed-candidate.md" > "$CANDIDATE/01-claimed-candidate.next"
  mv "$CANDIDATE/01-claimed-candidate.next" "$CANDIDATE/01-claimed-candidate.md"

  run bash "$PLAN" apply "$FEATURE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate tickets must be ready-for-agent"* ]]
  [ ! -e "$FEATURE/tickets" ]
}
