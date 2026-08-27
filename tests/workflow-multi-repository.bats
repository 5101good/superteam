#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

ROOT="${BATS_TEST_DIRNAME}/.."
SNAPSHOT="$ROOT/scripts/st-project-snapshot.sh"
WORKTREE="$ROOT/scripts/st-worktree.sh"
MULTI="$ROOT/scripts/st-repository-workflow.sh"

init_repository() {
  repository=$1
  marker=$2
  mkdir -p "$repository"
  git -C "$repository" init -q
  git -C "$repository" config user.name "Fixture Contributor"
  git -C "$repository" config user.email "fixture@invalid"
  git -C "$repository" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"
  printf '%s\n' "$marker" > "$repository/tracked.txt"
  git -C "$repository" add tracked.txt
  git -C "$repository" commit -qm baseline
  git -C "$repository" branch -M main
}

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/no-hooks"
  PROJECT_ROOT="$BATS_TEST_TMPDIR/root project"
  NESTED_ROOT="$PROJECT_ROOT/services/api"
  EXTERNAL_ROOT="$BATS_TEST_TMPDIR/external worker"
  SUBMODULE_SOURCE="$BATS_TEST_TMPDIR/submodule source"
  SUBMODULE_ROOT="$PROJECT_ROOT/vendor/shared"

  init_repository "$PROJECT_ROOT" root
  init_repository "$NESTED_ROOT" nested
  init_repository "$EXTERNAL_ROOT" external
  init_repository "$SUBMODULE_SOURCE" submodule
  PROJECT_ROOT=$(cd -P -- "$PROJECT_ROOT" && pwd -P)
  NESTED_ROOT=$(cd -P -- "$NESTED_ROOT" && pwd -P)
  EXTERNAL_ROOT=$(cd -P -- "$EXTERNAL_ROOT" && pwd -P)
  SUBMODULE_SOURCE=$(cd -P -- "$SUBMODULE_SOURCE" && pwd -P)
  SUBMODULE_ROOT="$PROJECT_ROOT/vendor/shared"

  printf '%s\n' '/services/api/' >> "$PROJECT_ROOT/.gitignore"
  git -C "$PROJECT_ROOT" -c protocol.file.allow=always submodule add -q \
    "$SUBMODULE_SOURCE" vendor/shared
  git -C "$SUBMODULE_ROOT" config user.name "Fixture Contributor"
  git -C "$SUBMODULE_ROOT" config user.email "fixture@invalid"
  git -C "$SUBMODULE_ROOT" config core.hooksPath "$BATS_TEST_TMPDIR/no-hooks"

  mkdir -p "$PROJECT_ROOT/task/100-example/tickets" "$PROJECT_ROOT/knowledge"
  cat > "$PROJECT_ROOT/superteam.yaml" <<EOF
version: 1
paths:
  task: "task"
  knowledge: "knowledge"
repositories:
  - id: "api"
    path: "services/api"
  - id: "worker"
    path: "../external worker"
  - id: "shared"
    path: "vendor/shared"
EOF
  cat > "$PROJECT_ROOT/task/100-example/tickets/01-cross-repository.md" <<'EOF'
---
id: "01"
status: ready-for-agent
repositories:
  - root
  - api
  - worker
  - shared
blocked_by: []
claimed_by: ""
claimed_at: ""
branches: {}
---

# 01 - Cross repository change

**What to build:** Change every declared Repository.

## Acceptance criteria
- [ ] Every Repository records one local change.

## Result
EOF
  TICKET="$PROJECT_ROOT/task/100-example/tickets/01-cross-repository.md"
  git -C "$PROJECT_ROOT" add .gitignore .gitmodules superteam.yaml task knowledge vendor/shared
  git -C "$PROJECT_ROOT" commit -qm 'chore: configure project'
}

repository_path_for() {
  case "$1" in
    root) printf '%s\n' "$PROJECT_ROOT" ;;
    api) printf '%s\n' "$NESTED_ROOT" ;;
    worker) printf '%s\n' "$EXTERNAL_ROOT" ;;
    shared) printf '%s\n' "$SUBMODULE_ROOT" ;;
  esac
}

ticket_worktree_for() {
  repository=$(repository_path_for "$1")
  env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$WORKTREE" stable-path "$repository" 100-example 01 "$1" ticket
}

commit_ticket_changes() {
  for repository_id in root api worker shared; do
    worktree=$(ticket_worktree_for "$repository_id")
    printf '%s\n' "$repository_id change" > "$worktree/$repository_id.txt"
    git -C "$worktree" add "$repository_id.txt"
    git -C "$worktree" commit -qm "feat: change $repository_id"
  done
}

start_repository_set() {
  env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" start "$TICKET"
}

prepare_repository_set() {
  env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" prepare "$TICKET" "$BATS_TEST_TMPDIR/integration-state.tsv"
}

@test "Project Snapshot resolves a stable Repository ID to its current real Git root" {
  run bash "$SNAPSHOT" repository-root worker "$PROJECT_ROOT"

  [ "$status" -eq 0 ]
  [ "$output" = "$EXTERNAL_ROOT" ]

  mv "$EXTERNAL_ROOT/.git" "$EXTERNAL_ROOT/git-metadata"
  run bash "$SNAPSHOT" repository-root worker "$PROJECT_ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or mismatched Git root"* ]]
  mv "$EXTERNAL_ROOT/git-metadata" "$EXTERNAL_ROOT/.git"
}

@test "Repository reporting follows a submodule to its real non-Root superproject" {
  outside_parent="$BATS_TEST_TMPDIR/outside superproject"
  outside_source="$BATS_TEST_TMPDIR/outside source"
  outside_root="$outside_parent/component"
  init_repository "$outside_parent" outside-parent
  init_repository "$outside_source" outside-source
  printf '%s\n' second > "$outside_source/second.txt"
  git -C "$outside_source" add second.txt
  git -C "$outside_source" commit -qm second
  git -C "$outside_parent" -c protocol.file.allow=always submodule add -q \
    "$outside_source" component
  git -C "$outside_parent" add .gitmodules component
  git -C "$outside_parent" commit -qm 'chore: add component'
  outside_parent=$(cd -P -- "$outside_parent" && pwd -P)
  outside_root=$(cd -P -- "$outside_root" && pwd -P)

  printf '%s\n' '  - id: "outside"' '    path: "../outside superproject/component"' \
    >> "$PROJECT_ROOT/superteam.yaml"
  ticket_candidate="$BATS_TEST_TMPDIR/ticket-with-outside"
  awk '
    /^blocked_by:/ { print "  - outside" }
    { print }
  ' "$TICKET" > "$ticket_candidate"
  mv "$ticket_candidate" "$TICKET"
  git -C "$PROJECT_ROOT" add superteam.yaml "$TICKET"
  git -C "$PROJECT_ROOT" commit -qm 'chore: register outside submodule'
  git -C "$outside_root" checkout -q HEAD^

  run bash "$MULTI" repositories "$TICKET"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'REPOSITORY: outside\nREAL_GIT_ROOT: '"$outside_root"$'\nTOPOLOGY: SUBMODULE\nSUPERPROJECT: '"$outside_parent"$'\nSUPERPROJECT_WORKTREE: DIRTY'* ]]
}

@test "integration state target must be absent or a regular file" {
  state_directory="$BATS_TEST_TMPDIR/state-directory"
  mkdir "$state_directory"

  run bash "$MULTI" prepare "$TICKET" "$state_directory"

  [ "$status" -ne 0 ]
  [[ "$output" == *"state target must be absent or a regular file"* ]]
}

@test "Repository workflow creates independent branches and worktrees in stable Project order" {
  root_remotes=$(git -C "$PROJECT_ROOT" remote)
  api_remotes=$(git -C "$NESTED_ROOT" remote)
  worker_remotes=$(git -C "$EXTERNAL_ROOT" remote)
  shared_remotes=$(git -C "$SUBMODULE_ROOT" remote)

  run start_repository_set

  [ "$status" -eq 0 ]
  ids=$(printf '%s\n' "$output" | sed -n 's/^REPOSITORY: //p')
  [ "$ids" = $'root\napi\nworker\nshared' ]
  [[ "$output" == *$'REPOSITORY: root\nREAL_GIT_ROOT: '"$PROJECT_ROOT"* ]]
  [[ "$output" == *$'REPOSITORY: api\nREAL_GIT_ROOT: '"$NESTED_ROOT"* ]]
  [[ "$output" == *$'REPOSITORY: worker\nREAL_GIT_ROOT: '"$EXTERNAL_ROOT"* ]]
  [[ "$output" == *$'REPOSITORY: shared\nREAL_GIT_ROOT: '"$SUBMODULE_ROOT"* ]]
  [[ "$output" == *$'TOPOLOGY: SUBMODULE\nSUPERPROJECT: '"$PROJECT_ROOT"$'\nSUPERPROJECT_WORKTREE: CLEAN'* ]]

  for repository_id in root api worker shared; do
    repository=$(repository_path_for "$repository_id")
    worktree=$(ticket_worktree_for "$repository_id")
    [ -d "$worktree" ]
    [ "$(git -C "$worktree" symbolic-ref --short HEAD)" = \
      "superteam/100-example-ticket-01-$repository_id" ]
    git -C "$repository" show-ref --verify --quiet \
      "refs/heads/superteam/100-example"
  done

  [ "$(git -C "$PROJECT_ROOT" remote)" = "$root_remotes" ]
  [ "$(git -C "$NESTED_ROOT" remote)" = "$api_remotes" ]
  [ "$(git -C "$EXTERNAL_ROOT" remote)" = "$worker_remotes" ]
  [ "$(git -C "$SUBMODULE_ROOT" remote)" = "$shared_remotes" ]
  [ -z "$(git -C "$PROJECT_ROOT" status --porcelain=v1)" ]
}

@test "Repository workflow detects config-hidden dirtiness before creating any branch" {
  printf '%s\n' hidden > "$PROJECT_ROOT/hidden.txt"
  git -C "$PROJECT_ROOT" config status.showUntrackedFiles no
  [ -z "$(git -C "$PROJECT_ROOT" status --porcelain=v1)" ]

  run start_repository_set

  [ "$status" -eq 3 ]
  [[ "$output" == *"Repository baseline is dirty: id=root"* ]]
  for repository_id in root api worker shared; do
    repository=$(repository_path_for "$repository_id")
    ! git -C "$repository" show-ref --verify --quiet refs/heads/superteam/100-example
  done
}

@test "Repository workflow fails closed on a submodule parent status error" {
  shim_dir="$BATS_TEST_TMPDIR/parent-status-error-bin"
  sentinel="$BATS_TEST_TMPDIR/parent-status-error-seen"
  mkdir "$shim_dir"
  real_git=$(command -v git)
  cat > "$shim_dir/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  if [ "\$argument" = status ] && [ ! -e "$sentinel" ]; then
    : > "$sentinel"
    exit 96
  fi
done
exec "$real_git" "\$@"
EOF
  chmod +x "$shim_dir/git"

  run env PATH="$shim_dir:$PATH" SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" start "$TICKET"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not inspect submodule parent worktree"* ]]
  for repository_id in root api worker shared; do
    repository=$(repository_path_for "$repository_id")
    ! git -C "$repository" show-ref --verify --quiet refs/heads/superteam/100-example
  done
}

@test "all Repository integrations prepare before any feature branch is promoted" {
  start_repository_set >/dev/null
  commit_ticket_changes
  for repository_id in root api worker shared; do
    repository=$(repository_path_for "$repository_id")
    eval "before_$repository_id=\$(git -C \"$repository\" rev-parse refs/heads/superteam/100-example)"
  done

  worker_worktree=$(ticket_worktree_for worker)
  printf '%s\n' 'uncommitted' >> "$worker_worktree/worker.txt"

  run prepare_repository_set

  [ "$status" -ne 0 ]
  [[ "$output" == *"PREPARE_STATUS: FAILED"* ]]
  [[ "$output" == *"ticket worktree is dirty"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/integration-state.tsv" ]
  git -C "$PROJECT_ROOT" show-ref --verify --quiet \
    refs/heads/superteam/100-example-integrate-01-root
  for repository_id in root api worker shared; do
    repository=$(repository_path_for "$repository_id")
    eval "expected=\$before_$repository_id"
    [ "$(git -C "$repository" rev-parse refs/heads/superteam/100-example)" = "$expected" ]
  done
}

@test "a parent gitlink delta is rejected before Repository integration" {
  start_repository_set >/dev/null
  shared_worktree=$(ticket_worktree_for shared)
  printf '%s\n' 'shared change' > "$shared_worktree/shared.txt"
  git -C "$shared_worktree" add shared.txt
  git -C "$shared_worktree" commit -qm 'feat: change shared'
  shared_head=$(git -C "$shared_worktree" rev-parse HEAD)
  root_worktree=$(ticket_worktree_for root)
  git -C "$root_worktree" update-index --add --cacheinfo 160000 "$shared_head" vendor/shared
  git -C "$root_worktree" commit -qm 'feat: change parent gitlink'

  run prepare_repository_set

  [ "$status" -ne 0 ]
  [[ "$output" == *"parent gitlink delta is not allowed"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/integration-state.tsv" ]
  ! git -C "$PROJECT_ROOT" show-ref --verify --quiet \
    refs/heads/superteam/100-example-integrate-01-root
}

@test "partial promotion records progress and resumes without overwriting or duplicate commits" {
  start_repository_set >/dev/null
  commit_ticket_changes
  prepare_repository_set >/dev/null

  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir "$fake_bin"
  real_git=$(command -v git)
  cat > "$fake_bin/git" <<EOF
#!/usr/bin/env bash
arguments=("\$@")
repository=''
previous=''
for argument in "\$@"; do
  if [ "\$previous" = -C ]; then repository=\$argument; fi
  if [ "\$argument" = update-ref ] && [ "\$repository" = "$EXTERNAL_ROOT" ]; then
    exit 91
  fi
  previous=\$argument
done
exec "$real_git" "\${arguments[@]}"
EOF
  chmod +x "$fake_bin/git"

  run env PATH="$fake_bin:$PATH" SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" promote "$TICKET" "$BATS_TEST_TMPDIR/integration-state.tsv"

  [ "$status" -eq 3 ]
  [[ "$output" == *"PROMOTE_STATUS: PARTIAL"* ]]
  [ "$(awk -F '\t' '$1 == "root" { print $8 }' "$BATS_TEST_TMPDIR/integration-state.tsv")" = promoted ]
  [ "$(awk -F '\t' '$1 == "api" { print $8 }' "$BATS_TEST_TMPDIR/integration-state.tsv")" = promoted ]
  [ "$(awk -F '\t' '$1 == "worker" { print $8 }' "$BATS_TEST_TMPDIR/integration-state.tsv")" = pending ]
  root_promoted=$(git -C "$PROJECT_ROOT" rev-parse refs/heads/superteam/100-example)
  api_promoted=$(git -C "$NESTED_ROOT" rev-parse refs/heads/superteam/100-example)

  run env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" promote "$TICKET" "$BATS_TEST_TMPDIR/integration-state.tsv"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE_STATUS: COMPLETE"* ]]
  [ "$(cut -f8 "$BATS_TEST_TMPDIR/integration-state.tsv" | sort -u)" = promoted ]
  [ "$(git -C "$PROJECT_ROOT" rev-parse refs/heads/superteam/100-example)" = "$root_promoted" ]
  [ "$(git -C "$NESTED_ROOT" rev-parse refs/heads/superteam/100-example)" = "$api_promoted" ]
  [ -z "$(git -C "$PROJECT_ROOT" status --porcelain=v1)" ]

  git -C "$PROJECT_ROOT" diff --quiet HEAD -- vendor/shared
  [ -z "$(git -C "$PROJECT_ROOT" log -1 --format=%B -- vendor/shared)" ] || \
    [ "$(git -C "$PROJECT_ROOT" log -1 --format=%B -- vendor/shared)" = 'chore: configure project' ]
}

@test "state write failure after ref promotion is reported and recovered as partial" {
  start_repository_set >/dev/null
  commit_ticket_changes
  prepare_repository_set >/dev/null
  fake_bin="$BATS_TEST_TMPDIR/failing-state-bin"
  mkdir "$fake_bin"
  real_mv=$(command -v mv)
  cat > "$fake_bin/mv" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do
  case "\$argument" in */integration-state.tsv) exit 91 ;; esac
done
exec "$real_mv" "\$@"
EOF
  chmod +x "$fake_bin/mv"

  run env PATH="$fake_bin:$PATH" SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" promote "$TICKET" "$BATS_TEST_TMPDIR/integration-state.tsv"

  [ "$status" -eq 3 ]
  [[ "$output" == *"PROMOTE_STATUS: PARTIAL"* ]]
  [[ "$output" == *"STATE_WRITE_FAILED"* ]]
  [ "$(awk -F '\t' '$1 == "root" { print $8 }' "$BATS_TEST_TMPDIR/integration-state.tsv")" = pending ]
  root_prepared=$(awk -F '\t' '$1 == "root" { print $7 }' "$BATS_TEST_TMPDIR/integration-state.tsv")
  [ "$(git -C "$PROJECT_ROOT" rev-parse refs/heads/superteam/100-example)" = "$root_prepared" ]

  run env SUPERTEAM_WORKTREE_ROOT="$BATS_TEST_TMPDIR/worktrees" \
    bash "$MULTI" promote "$TICKET" "$BATS_TEST_TMPDIR/integration-state.tsv"

  [ "$status" -eq 0 ]
  [[ "$output" == *"RECOVERED_REPOSITORY: root"* ]]
  [[ "$output" == *"PROMOTE_STATUS: COMPLETE"* ]]
}
