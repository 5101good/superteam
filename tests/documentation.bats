#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
PROJECT="$ROOT/scripts/st-project.sh"
KNOWLEDGE="$ROOT/scripts/st-knowledge.sh"
CONTEXT_SEED="$ROOT/scripts/st-context-seed.sh"
DOC_SCAN="$ROOT/scripts/st-doc-scan.sh"
FIXTURE="$ROOT/tests/fixtures/documentation"

configure_git() {
  git -C "$1" config user.name "Fixture Contributor"
  git -C "$1" config user.email "fixture@invalid"
}
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm "$2"
}

setup() {
  PROJECT_ROOT="$BATS_TEST_TMPDIR/project with space"
  EXTERNAL_ROOT="$BATS_TEST_TMPDIR/external api"
  mkdir -p "$PROJECT_ROOT" "$EXTERNAL_ROOT"
  git -C "$PROJECT_ROOT" init -q
  git -C "$EXTERNAL_ROOT" init -q
  configure_git "$PROJECT_ROOT"
  configure_git "$EXTERNAL_ROOT"

  mkdir -p "$PROJECT_ROOT/work items" "$PROJECT_ROOT/team knowledge" \
    "$PROJECT_ROOT/empty source"
  cp -R "$FIXTURE/common/." "$PROJECT_ROOT/"
  cp -R "$FIXTURE/unicode/." "$PROJECT_ROOT/"
  cp -R "$FIXTURE/external/." "$EXTERNAL_ROOT/"
  cat > "$PROJECT_ROOT/superteam.yaml" <<'EOF'
version: 1
paths:
  task: "work items"
  knowledge: "team knowledge"
repositories:
  - id: "api"
    path: "../external api"
EOF
  commit_all "$PROJECT_ROOT" baseline
  commit_all "$EXTERNAL_ROOT" baseline
  ROOT_BASE="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  API_BASE="$(git -C "$EXTERNAL_ROOT" rev-parse HEAD)"
}

@test "knowledge resolver uses the Project Snapshot and never creates targets" {
  expected_knowledge="$(cd -P -- "$PROJECT_ROOT/team knowledge" && pwd -P)"

  run bash "$KNOWLEDGE" root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_knowledge" ]

  run bash "$KNOWLEDGE" context root "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_knowledge/repositories/root/CONTEXT.md" ]

  run bash "$KNOWLEDGE" adrs api "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_knowledge/repositories/api/adr" ]

  run bash "$KNOWLEDGE" decisions "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_knowledge/decisions" ]

  run bash "$KNOWLEDGE" repository api "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_knowledge/repositories/api" ]

  [ ! -e "$expected_knowledge/repositories" ]
  [ ! -e "$expected_knowledge/decisions" ]
}

@test "knowledge resolver rejects unknown IDs and unsafe explicit paths without writes" {
  before="$(find "$PROJECT_ROOT/team knowledge" -print | LC_ALL=C sort)"

  run bash "$KNOWLEDGE" context missing "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown Repository ID"* ]]

  run bash "$KNOWLEDGE" path "../outside" "$PROJECT_ROOT"
  [ "$status" -eq 2 ]

  run bash "$KNOWLEDGE" path "/absolute" "$PROJECT_ROOT"
  [ "$status" -eq 2 ]

  after="$(find "$PROJECT_ROOT/team knowledge" -print | LC_ALL=C sort)"
  [ "$after" = "$before" ]
}

@test "knowledge resolver fails closed when the configured directory becomes a link" {
  outside_knowledge="$BATS_TEST_TMPDIR/outside knowledge"
  mv "$PROJECT_ROOT/team knowledge" "$outside_knowledge"
  ln -s "$outside_knowledge" "$PROJECT_ROOT/team knowledge"

  run bash "$KNOWLEDGE" root "$PROJECT_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"traverses a symbolic link"* ]]
  [ ! -e "$outside_knowledge/repositories" ]
}

@test "Context and ADR locations are created only by an explicit seed command" {
  run bash "$CONTEXT_SEED" context api "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CREATED:"* ]]
  context="$PROJECT_ROOT/team knowledge/repositories/api/CONTEXT.md"
  [ -f "$context" ]
  grep -q '^## Language$' "$context"
  grep -q 'Repository ID' "$context"
  ! grep -Eq '(^|/)(prd|spec)(/|$)' "$context"

  run bash "$CONTEXT_SEED" context api "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: OK"* ]]

  run bash "$CONTEXT_SEED" adr api "$PROJECT_ROOT"
  [ "$status" -eq 5 ]
  [[ "$output" == *"ADR_DIRECTORY: MISSING"* ]]

  run bash "$CONTEXT_SEED" map "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  grep -Fq '[CONTEXT.md](repositories/api/CONTEXT.md)' \
    "$PROJECT_ROOT/team knowledge/CONTEXT-MAP.md"
}

@test "repository scan classifies a real root diff with Unicode and documentation changes" {
  printf '%s\n' '# changed' >> "$PROJECT_ROOT/src/界面/入口.sh"
  printf '%s\n' '' 'Additional behavior.' >> "$PROJECT_ROOT/docs/reference.md"
  commit_all "$PROJECT_ROOT" change

  run bash "$DOC_SCAN" audit root "$ROOT_BASE" HEAD --project "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: COMPLETE"* ]]
  [[ "$output" == *"REPOSITORY: root"* ]]
  [[ "$output" == *"CHANGED: src/界面/入口.sh"* ]]
  [[ "$output" == *"IMPACT: repository:root"* ]]
  [[ "$output" == *"IMPACT: reference"* ]]
}

@test "external Repository diff is resolved from root plus the Snapshot path" {
  printf '%s\n' '  /orders:' >> "$EXTERNAL_ROOT/api/openapi.yaml"
  commit_all "$EXTERNAL_ROOT" api-change

  run bash "$DOC_SCAN" audit api "$API_BASE" HEAD --project "$PROJECT_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPOSITORY: api"* ]]
  [[ "$output" == *"CHANGED: api/openapi.yaml"* ]]
  [[ "$output" == *"IMPACT: repository:api"* ]]
  [[ "$output" == *"IMPACT: api"* ]]
  [[ "$output" == *"IMPACT: reference"* ]]
  [[ "$output" != *"$PROJECT_ROOT/src/orders/service.sh"* ]]
}

@test "empty diff is INCONCLUSIVE and an explicit knowledge path is validated" {
  run bash "$DOC_SCAN" audit root "$ROOT_BASE" "$ROOT_BASE" \
    --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATUS: INCONCLUSIVE"* ]]
  [[ "$output" == *"REASON: NO_CHANGED_PATHS"* ]]

  printf '%s\n' '# changed' >> "$PROJECT_ROOT/src/orders/service.sh"
  commit_all "$PROJECT_ROOT" source-change
  run bash "$DOC_SCAN" audit root "$ROOT_BASE" HEAD --project "$PROJECT_ROOT" \
    --target path --knowledge-path "guides/入门.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELECTED_TARGET: path"* ]]
  [[ "$output" == *"IMPACT: path:guides/入门.md"* ]]

  run bash "$DOC_SCAN" audit root "$ROOT_BASE" HEAD --project "$PROJECT_ROOT" \
    --target path --knowledge-path "../escape.md"
  [ "$status" -eq 2 ]
}

@test "first-pass scan compares committed source with an empty Git tree" {
  objects_before="$(git -C "$EXTERNAL_ROOT" count-objects -v)"
  refs_before="$(git -C "$EXTERNAL_ROOT" show-ref)"
  index_before="$(cksum "$EXTERNAL_ROOT/.git/index")"
  status_before="$(git -C "$EXTERNAL_ROOT" status --porcelain)"
  head_before="$(git -C "$EXTERNAL_ROOT" rev-parse HEAD)"

  run bash "$DOC_SCAN" scan api HEAD --project "$PROJECT_ROOT" --target api
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUS: COMPLETE"* ]]
  [[ "$output" == *"SELECTED_TARGET: api"* ]]
  [[ "$output" == *"CHANGED: api/openapi.yaml"* ]]
  [[ "$output" == *"IMPACT: api"* ]]

  [ "$(git -C "$EXTERNAL_ROOT" count-objects -v)" = "$objects_before" ]
  [ "$(git -C "$EXTERNAL_ROOT" show-ref)" = "$refs_before" ]
  [ "$(cksum "$EXTERNAL_ROOT/.git/index")" = "$index_before" ]
  [ "$(git -C "$EXTERNAL_ROOT" status --porcelain)" = "$status_before" ]
  [ "$(git -C "$EXTERNAL_ROOT" rev-parse HEAD)" = "$head_before" ]
}

@test "first-pass scan reports an unborn Repository without creating Git state" {
  unborn_root="$BATS_TEST_TMPDIR/unborn repository"
  mkdir "$unborn_root"
  git -C "$unborn_root" init -q
  cat >> "$PROJECT_ROOT/superteam.yaml" <<'EOF'
  - id: "empty"
    path: "../unborn repository"
EOF
  objects_before="$(git -C "$unborn_root" count-objects -v)"
  refs_before="$(git -C "$unborn_root" show-ref || true)"
  status_before="$(git -C "$unborn_root" status --porcelain)"

  run bash "$DOC_SCAN" scan empty --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATUS: INCONCLUSIVE"* ]]
  [[ "$output" == *"REASON: UNBORN_REPOSITORY"* ]]

  [ "$(git -C "$unborn_root" count-objects -v)" = "$objects_before" ]
  [ "$(git -C "$unborn_root" show-ref || true)" = "$refs_before" ]
  [ "$(git -C "$unborn_root" status --porcelain)" = "$status_before" ]
}

@test "audit fixes rename detection and classifies both rename endpoints" {
  printf '%s\n' 'opaque' > "$PROJECT_ROOT/mystery.payload"
  printf '%s\n' 'opaque' > "$PROJECT_ROOT/discard.payload"
  commit_all "$PROJECT_ROOT" rename-base
  rename_base="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  mv "$PROJECT_ROOT/mystery.payload" "$PROJECT_ROOT/docs/new-reference.md"
  rm "$PROJECT_ROOT/discard.payload"
  commit_all "$PROJECT_ROOT" rename-change

  git -C "$PROJECT_ROOT" config diff.renames true
  run bash "$DOC_SCAN" audit root "$rename_base" HEAD --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  output_with_renames=$output

  git -C "$PROJECT_ROOT" config diff.renames false
  run bash "$DOC_SCAN" audit root "$rename_base" HEAD --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  output_without_renames=$output

  [ "$output_with_renames" = "$output_without_renames" ]
  [[ "$output" == *"CHANGED: mystery.payload"* ]]
  [[ "$output" == *"CHANGED: docs/new-reference.md"* ]]
  [[ "$output" == *"CHANGED: discard.payload"* ]]
  [[ "$output" == *"UNCERTAIN: mystery.payload"* ]]
  [[ "$output" == *"UNCERTAIN: discard.payload"* ]]
  [[ "$output" == *"IMPACT: reference"* ]]
  [[ "$output" == *"STATUS: INCONCLUSIVE"* ]]
}

@test "uncategorizable diff is INCONCLUSIVE instead of claiming zero impact" {
  printf '%s\n' 'opaque' > "$PROJECT_ROOT/unknown.payload"
  commit_all "$PROJECT_ROOT" unknown-change

  run bash "$DOC_SCAN" audit root "$ROOT_BASE" HEAD --project "$PROJECT_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATUS: INCONCLUSIVE"* ]]
  [[ "$output" == *"UNCERTAIN: unknown.payload"* ]]
  [[ "$output" == *"IMPACT: repository:root"* ]]
}
