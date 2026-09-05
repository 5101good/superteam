#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"
FRONTMATTER="$SCRIPT_DIR/lib/frontmatter.sh"
. "$SCRIPT_DIR/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-tickets.sh create-feature --id <id> --slug <slug> [--project <directory>]
  st-tickets.sh new <feature-directory> --id <NN> --title <title> --repositories <id,...> [--blocked-by <NN,...>] [--body-file <file>]
  st-tickets.sh validate <feature-directory>
  st-tickets.sh validate-set <feature-directory> <ticket-directory>
  st-tickets.sh frontier <feature-directory>
  st-tickets.sh repositories <feature-directory>
  st-tickets.sh claim <ticket-file> --owner <owner>
  st-tickets.sh write-result <ticket-file> <result-file>
  st-tickets.sh block <ticket-file> --reason <reason>
  st-tickets.sh resolve <ticket-file>
  st-tickets.sh branch-get <ticket-file> <repository> <field>
  st-tickets.sh branch-set <ticket-file> <repository> <field> <value>
  st-tickets.sh feature-status <feature-directory>

All paths and Repository IDs are validated against the named Project Snapshot.
Commands never evaluate configuration expressions or change the Git index.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

timestamp() {
  date +%Y-%m-%dT%H:%M:%S%z
}

reject_control_value() {
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) fail "$2 contains an unsupported control character."; return 1 ;;
  esac
}

absolute_directory() {
  (cd -P -- "$1" && pwd -P)
}

absolute_file() {
  local target=$1 directory parent leaf
  parent=$(dirname "$target")
  directory=$(cd -P -- "$parent" && pwd -P) || return 1
  leaf=$(basename "$target")
  printf '%s/%s\n' "$directory" "$leaf"
}

ticket_files() {
  local feature=$1
  [ -d "$feature/tickets" ] || return 0
  ticket_files_in "$feature/tickets"
}

ticket_files_in() {
  local directory=$1
  [ -d "$directory" ] || return 0
  find "$directory" -maxdepth 1 -type f -name '*.md' -print | LC_ALL=C sort
}

feature_has_tickets() {
  [ -d "$1/tickets" ] &&
    find "$1/tickets" -maxdepth 1 -type f -name '*.md' -print -quit | grep -q .
}

project_facts_for_feature() {
  local feature=$1
  FEATURE_ROOT=$(bash "$SNAPSHOT" root "$feature") || return 1
  FEATURE_TASK=$(bash "$SNAPSHOT" task "$feature") || return 1
  feature=$(absolute_directory "$feature") || return 1
  case "$feature" in
    "$FEATURE_TASK"/*) ;;
    *) fail 'feature directory is outside the configured task path.'; return 1 ;;
  esac
  FEATURE_PATH=$feature
}

repository_is_known() {
  local wanted=$1
  bash "$SNAPSHOT" repositories "$FEATURE_ROOT" | grep -qxF -- "$wanted"
}

validate_repository_list() {
  local document=$1 count=0 seen repository
  seen=$(mktemp "${TMPDIR:-/tmp}/superteam-repositories.XXXXXX") || return 1
  trap 'rm -f -- "$seen"' RETURN
  while IFS= read -r repository; do
    [ -n "$repository" ] || { fail "empty Repository ID in $document"; return 1; }
    printf '%s\n' "$repository" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]*$' || {
      fail "invalid Repository ID in $document: $repository"
      return 1
    }
    repository_is_known "$repository" || {
      fail "unknown Repository ID in $document: $repository"
      return 1
    }
    if grep -qxF -- "$repository" "$seen"; then
      fail "duplicate Repository ID in $document: $repository"
      return 1
    fi
    printf '%s\n' "$repository" >> "$seen"
    count=$((count + 1))
  done < <(bash "$FRONTMATTER" get-list "$document" repositories)
  [ "$count" -gt 0 ] || { fail "document has no repositories: $document"; return 1; }
  rm -f -- "$seen"
  trap - RETURN
}

validate_contract() {
  local document=$1 kind=$2 id slug created_at
  bash "$FRONTMATTER" validate "$document" "$kind" || return 1
  id=$(bash "$FRONTMATTER" get "$document" id) || return 1
  slug=$(bash "$FRONTMATTER" get "$document" slug) || return 1
  created_at=$(bash "$FRONTMATTER" get "$document" created_at) || return 1
  printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*$' || {
    fail "invalid $kind id in $document"
    return 1
  }
  printf '%s\n' "$slug" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*$' || {
    fail "invalid $kind slug in $document"
    return 1
  }
  feature_name=$(basename "$FEATURE_PATH")
  [ "$feature_name" = "$id-$slug" ] || {
    fail "$kind id and slug do not match feature directory: $document"
    return 1
  }
  [ -n "$created_at" ] || { fail "$kind created_at is required: $document"; return 1; }
  validate_repository_list "$document"
}

ticket_id() {
  bash "$FRONTMATTER" get "$1" id
}

ticket_status() {
  bash "$FRONTMATTER" get "$1" status
}

ticket_for_id() {
  local feature=$1 wanted=$2 ticket
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    current_id=$(ticket_id "$ticket")
    [ "$current_id" = "$wanted" ] && {
      printf '%s\n' "$ticket"
      return 0
    }
  done < <(ticket_files "$feature")
  return 1
}

validate_result_evidence() {
  local ticket=$1 status=$2
  if [ "$status" = resolved ]; then
    validate_successful_result "$ticket" ticket
    return $?
  fi
  awk '
    /^## Result[[:space:]]*$/ { active = 1; next }
    active && /[^[:space:]]/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$ticket" || {
    fail "$status ticket is missing Result evidence: $ticket"
    return 1
  }
}

validate_successful_result() {
  LC_ALL=C awk -v document="$2" -f "$SCRIPT_DIR/lib/result.awk" "$1"
}

validate_commit_evidence() {
  local repository_root=$1 repository_id=$2 field=$3 value=$4 actual
  printf '%s\n' "$value" | LC_ALL=C grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || {
    fail "invalid commit evidence: $repository_id.$field"
    return 1
  }
  actual=$(isolated_git -C "$repository_root" rev-parse --verify "$value^{commit}" 2>/dev/null) || {
    fail "unknown commit: $repository_id.$field"
    return 1
  }
  [ "$actual" = "$value" ] || {
    fail "non-canonical commit evidence: $repository_id.$field"
    return 1
  }
}

validate_branch_identity() {
  local ticket=$1 repository_id=$2 feature_branch=$3 ticket_branch=$4
  local feature_key id expected_ticket_branch
  feature_key=$(basename "$FEATURE_PATH")
  id=$(ticket_id "$ticket") || return 1
  if [ "$feature_branch" = "superteam/$feature_key" ]; then
    expected_ticket_branch="superteam/$feature_key-ticket-$id-$repository_id"
  elif [ "$repository_id" = root ] && [ "$feature_branch" = "codex/$feature_key" ]; then
    expected_ticket_branch="codex/$feature_key-$id"
  else
    fail "non-canonical feature branch: $repository_id.feature_branch"
    return 1
  fi
  [ "$ticket_branch" = "$expected_ticket_branch" ] || {
    fail "non-canonical ticket branch: $repository_id.ticket_branch"
    return 1
  }
}

validate_resolved_repository_evidence() {
  local ticket=$1 repository_id=$2 repository_root field value feature_head actual_ticket_head
  local base feature_branch ticket_branch ticket_head prepared_head integrated_head
  base=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" base) || return 1
  feature_branch=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" feature_branch) || return 1
  ticket_branch=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" ticket_branch) || return 1
  ticket_head=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" ticket_head) || return 1
  prepared_head=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" prepared_head) || return 1
  integrated_head=$(bash "$FRONTMATTER" branch-get "$ticket" "$repository_id" integrated_head) || return 1
  for field in base feature_branch ticket_branch ticket_head prepared_head integrated_head; do
    case "$field" in
      base) value=$base ;;
      feature_branch) value=$feature_branch ;;
      ticket_branch) value=$ticket_branch ;;
      ticket_head) value=$ticket_head ;;
      prepared_head) value=$prepared_head ;;
      integrated_head) value=$integrated_head ;;
    esac
    [ -n "$value" ] || {
      fail "resolved ticket is missing Git evidence: $repository_id.$field"
      return 1
    }
  done

  repository_root=$(bash "$SNAPSHOT" repository-root "$repository_id" "$FEATURE_ROOT") || return 1
  validate_commit_evidence "$repository_root" "$repository_id" base "$base" || return 1
  validate_commit_evidence "$repository_root" "$repository_id" ticket_head "$ticket_head" || return 1
  validate_commit_evidence "$repository_root" "$repository_id" prepared_head "$prepared_head" || return 1
  validate_commit_evidence "$repository_root" "$repository_id" integrated_head "$integrated_head" || return 1
  validate_branch_identity "$ticket" "$repository_id" "$feature_branch" "$ticket_branch" || return 1

  [ "$feature_branch" != "$ticket_branch" ] &&
    isolated_git -C "$repository_root" check-ref-format --branch "$feature_branch" >/dev/null 2>&1 &&
    isolated_git -C "$repository_root" check-ref-format --branch "$ticket_branch" >/dev/null 2>&1 || {
    fail "invalid branch evidence: $repository_id"
    return 1
  }
  feature_head=$(isolated_git -C "$repository_root" rev-parse --verify \
    "refs/heads/$feature_branch^{commit}" 2>/dev/null) || {
    fail "feature branch does not exist: $repository_id.feature_branch"
    return 1
  }
  actual_ticket_head=$(isolated_git -C "$repository_root" rev-parse --verify \
    "refs/heads/$ticket_branch^{commit}" 2>/dev/null) || {
    fail "ticket branch does not exist: $repository_id.ticket_branch"
    return 1
  }
  [ "$actual_ticket_head" = "$ticket_head" ] || {
    fail "ticket branch does not match ticket head: $repository_id"
    return 1
  }
  isolated_git -C "$repository_root" merge-base --is-ancestor "$base" "$ticket_head" || {
    fail "base is not an ancestor of ticket head: $repository_id"
    return 1
  }
  isolated_git -C "$repository_root" merge-base --is-ancestor "$base" "$prepared_head" || {
    fail "base is not an ancestor of prepared head: $repository_id"
    return 1
  }
  isolated_git -C "$repository_root" merge-base --is-ancestor "$ticket_head" "$prepared_head" || {
    fail "ticket head is not an ancestor of prepared head: $repository_id"
    return 1
  }
  isolated_git -C "$repository_root" merge-base --is-ancestor "$prepared_head" "$integrated_head" || {
    fail "prepared head is not an ancestor of integrated head: $repository_id"
    return 1
  }
  isolated_git -C "$repository_root" merge-base --is-ancestor "$integrated_head" "$feature_head" || {
    fail "integrated head is not reachable from feature branch: $repository_id"
    return 1
  }
}

validate_resolved_git_evidence() {
  local ticket=$1 repository
  while IFS= read -r repository; do
    validate_resolved_repository_evidence "$ticket" "$repository" || return 1
  done < <(bash "$FRONTMATTER" get-list "$ticket" repositories)
}

list_contains() {
  local wanted=$1 candidate
  shift
  for candidate in "$@"; do
    [ "$candidate" = "$wanted" ] && return 0
  done
  return 1
}

validate_ticket() {
  local ticket=$1 validate_name=${2:-true} validate_terminal=${3:-true}
  local id status repository claimed_by claimed_at leaf slug resolved_at
  local -a repositories
  bash "$FRONTMATTER" validate "$ticket" ticket || return 1
  id=$(ticket_id "$ticket") || return 1
  status=$(ticket_status "$ticket") || return 1
  printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || {
    fail "invalid ticket id in $ticket"
    return 1
  }
  if [ "$validate_name" = true ]; then
    leaf=$(basename "$ticket")
    case "$leaf" in
      "$id"-*.md) ;;
      *) fail "ticket filename must start with its two-digit ID: $ticket"; return 1 ;;
    esac
    slug=${leaf#"$id"-}
    slug=${slug%.md}
    printf '%s\n' "$slug" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*$' || {
      fail "ticket filename has an invalid slug: $ticket"
      return 1
    }
  fi
  case "$status" in
    ready-for-agent|claimed|resolved|blocked) ;;
    *) fail "invalid ticket status in $ticket: $status"; return 1 ;;
  esac
  validate_repository_list "$ticket" || return 1
  repositories=()
  while IFS= read -r repository; do repositories[${#repositories[@]}]=$repository; done \
    < <(bash "$FRONTMATTER" get-list "$ticket" repositories)
  while IFS= read -r repository; do
    [ -n "$repository" ] || continue
    list_contains "$repository" "${repositories[@]}" || {
      fail "Repository branch state is not declared by the ticket: $repository"
      return 1
    }
  done < <(bash "$FRONTMATTER" branch-repositories "$ticket")
  grep -qE "^# $id [-—] [^[:space:]]" "$ticket" || {
    fail "ticket title must be '# $id - title': $ticket"
    return 1
  }
  grep -qE '^\*\*What to build:\*\*[[:space:]]+[^[:space:]]' "$ticket" || {
    fail "ticket is missing What to build: $ticket"
    return 1
  }
  grep -q '^## Acceptance criteria[[:space:]]*$' "$ticket" || {
    fail "ticket is missing Acceptance criteria: $ticket"
    return 1
  }
  grep -qE '^- \[[ xX]\][[:space:]]+[^[:space:]]' "$ticket" || {
    fail "ticket has no acceptance criteria: $ticket"
    return 1
  }
  [ "$(grep -c '^## Result[[:space:]]*$' "$ticket" || true)" -eq 1 ] || {
    fail "ticket must contain exactly one Result section: $ticket"
    return 1
  }
  claimed_by=$(bash "$FRONTMATTER" get "$ticket" claimed_by)
  claimed_at=$(bash "$FRONTMATTER" get "$ticket" claimed_at)
  case "$status" in
    ready-for-agent)
      [ -z "$claimed_by" ] && [ -z "$claimed_at" ] || {
        fail "ready ticket contains claimant metadata: $ticket"
        return 1
      }
      ;;
    claimed)
      [ -n "$claimed_by" ] && [ -n "$claimed_at" ] || {
        fail "claimed ticket is missing claimant metadata: $ticket"
        return 1
      }
      ;;
    resolved)
      if [ "$validate_terminal" = true ]; then
        validate_result_evidence "$ticket" resolved || return 1
        resolved_at=$(bash "$FRONTMATTER" get "$ticket" resolved_at)
        [ -n "$resolved_at" ] || {
          fail "resolved ticket is missing resolved_at: $ticket"
          return 1
        }
        validate_resolved_git_evidence "$ticket" || return 1
      fi
      ;;
    blocked)
      [ "$validate_terminal" != true ] || validate_result_evidence "$ticket" blocked || return 1
      ;;
  esac
}

validate_feature() {
  local feature=$1 ticket_directory rows graph count ticket id duplicate dependencies blocker
  project_facts_for_feature "$feature" || return 1
  ticket_directory=${2:-$FEATURE_PATH/tickets}
  [ ! -f "$FEATURE_PATH/prd.md" ] || validate_contract "$FEATURE_PATH/prd.md" prd || return 1
  [ ! -f "$FEATURE_PATH/spec.md" ] || validate_contract "$FEATURE_PATH/spec.md" spec || return 1
  [ -d "$ticket_directory" ] && [ ! -L "$ticket_directory" ] || {
    fail "tickets directory not found or unsafe: $ticket_directory"
    return 1
  }

  rows=$(mktemp "${TMPDIR:-/tmp}/superteam-ticket-rows.XXXXXX") || return 1
  graph=$(mktemp "${TMPDIR:-/tmp}/superteam-ticket-graph.XXXXXX") || { rm -f -- "$rows"; return 1; }
  trap 'rm -f -- "$rows" "$graph"' RETURN
  count=0
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    validate_ticket "$ticket" || return 1
    id=$(ticket_id "$ticket")
    printf '%s\t%s\n' "$id" "$ticket" >> "$rows"
    count=$((count + 1))
  done < <(ticket_files_in "$ticket_directory")
  [ "$count" -gt 0 ] || { fail "feature has no tickets: $FEATURE_PATH"; return 1; }
  duplicate=$(cut -f1 "$rows" | LC_ALL=C sort | uniq -d | sed -n '1p')
  [ -z "$duplicate" ] || { fail "duplicate ticket id: $duplicate"; return 1; }

  while IFS=$'\t' read -r id ticket; do
    dependencies=''
    while IFS= read -r blocker; do
      [ -n "$blocker" ] || continue
      printf '%s\n' "$blocker" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || {
        fail "ticket $id has invalid blocker: $blocker"
        return 1
      }
      grep -q "^$blocker"$'\t' "$rows" || {
        fail "ticket $id references unknown blocker $blocker"
        return 1
      }
      [ "$blocker" != "$id" ] || { fail "ticket $id cannot block itself"; return 1; }
      if [ -n "$dependencies" ]; then
        dependencies=$dependencies,$blocker
      else
        dependencies=$blocker
      fi
    done < <(bash "$FRONTMATTER" get-list "$ticket" blocked_by)
    printf '%s\t%s\n' "$id" "$dependencies" >> "$graph"
  done < "$rows"

  awk -F '\t' '
    {
      vertex[$1] = 1
      count = split($2, dependency, ",")
      for (cursor = 1; cursor <= count; cursor++)
        if (dependency[cursor] != "") edge[$1, dependency[cursor]] = 1
    }
    function visit(current, key, pair) {
      if (active[current]) return 1
      if (complete[current]) return 0
      active[current] = 1
      for (key in edge) {
        split(key, pair, SUBSEP)
        if (pair[1] == current && visit(pair[2])) return 1
      }
      active[current] = 0
      complete[current] = 1
      return 0
    }
    END { for (current in vertex) if (visit(current)) exit 1 }
  ' "$graph" || { fail 'ticket dependency graph contains a cycle'; return 1; }
  rm -f -- "$rows" "$graph"
  trap - RETURN
}

ticket_feature() {
  absolute_directory "$(dirname "$(dirname "$1")")"
}

ticket_is_runnable() {
  local ticket=$1 feature=$2 blocker blocker_ticket
  while IFS= read -r blocker; do
    [ -n "$blocker" ] || continue
    blocker_ticket=$(ticket_for_id "$feature" "$blocker") || return 1
    blocker_status=$(ticket_status "$blocker_ticket")
    [ "$blocker_status" = resolved ] || return 1
  done < <(bash "$FRONTMATTER" get-list "$ticket" blocked_by)
}

make_operations_file() {
  mktemp "${TMPDIR:-/tmp}/superteam-ticket-operations.XXXXXX"
}

cleanup_ticket_creation() {
  [ -z "${NEW_TICKET_TEMP:-}" ] || rm -f -- "$NEW_TICKET_TEMP"
  [ -z "${TICKET_OPERATIONS_TEMP:-}" ] || rm -f -- "$TICKET_OPERATIONS_TEMP"
  [ -z "${TICKET_RESULT_TEMP:-}" ] || rm -f -- "$TICKET_RESULT_TEMP"
  if [ "${NEW_TICKETS_CREATED:-false}" = true ]; then
    rmdir -- "$FEATURE_PATH/tickets" 2>/dev/null || true
  fi
  if [ -n "${TRACKER_LOCK:-}" ]; then
    rmdir -- "$TRACKER_LOCK" 2>/dev/null || true
    tracker_lock_parent=$(dirname "$TRACKER_LOCK")
    rmdir -- "$tracker_lock_parent" 2>/dev/null || true
  fi
}

begin_ticket_mutation() {
  TRACKER_LOCK=''
  NEW_TICKET_TEMP=''
  NEW_TICKETS_CREATED=false
  TICKET_OPERATIONS_TEMP=''
  TICKET_RESULT_TEMP=''
  acquire_feature_lock
}

acquire_feature_lock() {
  local common tracker_lock_parent
  common=$(isolated_git -C "$FEATURE_ROOT" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in /*) ;; *) common=$FEATURE_ROOT/$common ;; esac
  common=$(cd -P -- "$common" && pwd -P) || return 1
  set -- $(printf '%s' "$FEATURE_PATH" | cksum)
  tracker_lock_parent=$common/superteam-tracker-locks
  TRACKER_LOCK=$tracker_lock_parent/$1-$2.lock
  mkdir -p -- "$tracker_lock_parent" || return 1
  if ! mkdir -- "$TRACKER_LOCK" 2>/dev/null; then
    fail 'another ticket writer is active for this feature.'
    return 1
  fi
  trap 'exit 130' HUP INT TERM
  trap cleanup_ticket_creation EXIT
}

release_feature_lock() {
  cleanup_ticket_creation
  TRACKER_LOCK=''
  NEW_TICKET_TEMP=''
  NEW_TICKETS_CREATED=false
  TICKET_OPERATIONS_TEMP=''
  TICKET_RESULT_TEMP=''
  trap - EXIT HUP INT TERM
}

feature_result_branch() {
  local ticket candidate selected=''
  while IFS= read -r ticket; do
    [ -n "$ticket" ] || continue
    if bash "$FRONTMATTER" get-list "$ticket" repositories | grep -qxF -- root; then
      candidate=$(bash "$FRONTMATTER" branch-get "$ticket" root feature_branch) || return 1
      [ -n "$candidate" ] || return 1
      if [ -n "$selected" ] && [ "$candidate" != "$selected" ]; then
        return 1
      fi
      selected=$candidate
    fi
  done < <(ticket_files "$FEATURE_PATH")
  [ -n "$selected" ] || return 1
  printf '%s\n' "$selected"
}

feature_result_is_terminal() {
  local result branch head relative blob current_blob blob_type
  result=$FEATURE_PATH/result.md
  [ ! -L "$result" ] && [ -f "$result" ] && [ -s "$result" ] || return 1
  branch=$(feature_result_branch) || return 1
  isolated_git -C "$FEATURE_ROOT" check-ref-format --branch "$branch" >/dev/null 2>&1 || return 1
  head=$(isolated_git -C "$FEATURE_ROOT" rev-parse --verify "refs/heads/$branch^{commit}" 2>/dev/null) || return 1
  case "$result" in
    "$FEATURE_ROOT"/*) relative=${result#"$FEATURE_ROOT"/} ;;
    *) return 1 ;;
  esac
  blob=$(isolated_git -C "$FEATURE_ROOT" rev-parse --verify "$head:$relative" 2>/dev/null) || return 1
  blob_type=$(isolated_git -C "$FEATURE_ROOT" cat-file -t "$blob" 2>/dev/null) || return 1
  [ "$blob_type" = blob ] || return 1
  current_blob=$(isolated_git -C "$FEATURE_ROOT" hash-object -- "$result" 2>/dev/null) || return 1
  [ "$current_blob" = "$blob" ] || return 1
  validate_successful_result "$result" feature
}

command=${1:-}
[ -n "$command" ] || usage
shift

case "$command" in
  create-feature)
    id=''; slug=''; project=.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --id) id=${2:-}; shift 2 ;;
        --slug) slug=${2:-}; shift 2 ;;
        --project) project=${2:-}; shift 2 ;;
        *) usage ;;
      esac
    done
    printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*$' || usage
    printf '%s\n' "$slug" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*$' || usage
    task=$(bash "$SNAPSHOT" task "$project") || exit 1
    feature=$task/$id-$slug
    mkdir -- "$feature" || { fail "feature already exists or cannot be created: $feature"; exit 1; }
    printf '%s\n' "$feature"
    ;;
  new)
    feature=${1:-}; [ -n "$feature" ] || usage; shift
    id=''
    title=''
    repository_values=''
    blockers=''
    body_file=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --id) id=${2:-}; shift 2 ;;
        --title) title=${2:-}; shift 2 ;;
        --repositories) repository_values=${2:-}; shift 2 ;;
        --blocked-by) blockers=${2:-}; shift 2 ;;
        --body-file) body_file=${2:-}; shift 2 ;;
        *) usage ;;
      esac
    done
    printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || usage
    [ -n "$title" ] && [ -n "$repository_values" ] || usage
    reject_control_value "$title" title || exit 1
    project_facts_for_feature "$feature" || exit 1
    TRACKER_LOCK=''
    NEW_TICKET_TEMP=''
    NEW_TICKETS_CREATED=false
    acquire_feature_lock
    if feature_has_tickets "$FEATURE_PATH"; then
      validate_feature "$FEATURE_PATH"
    else
      if [ -f "$FEATURE_PATH/prd.md" ]; then validate_contract "$FEATURE_PATH/prd.md" prd; fi
      if [ -f "$FEATURE_PATH/spec.md" ]; then validate_contract "$FEATURE_PATH/spec.md" spec; fi
    fi
    if existing_ticket=$(ticket_for_id "$FEATURE_PATH" "$id" 2>/dev/null); then
      fail "duplicate ticket id $id: $existing_ticket"
      exit 1
    fi
    if [ -n "$blockers" ]; then
      while IFS= read -r blocker; do
        [ -n "$blocker" ] || { fail 'blocked-by contains an empty ticket ID.'; exit 1; }
        printf '%s\n' "$blocker" | LC_ALL=C grep -Eq '^[0-9][0-9]$' || {
          fail "invalid blocker ticket ID: $blocker"
          exit 1
        }
        ticket_for_id "$FEATURE_PATH" "$blocker" >/dev/null || {
          fail "unknown blocker ticket ID: $blocker"
          exit 1
        }
      done < <(printf '%s\n' "$blockers" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    fi
    slug=$(printf '%s' "$title" | LC_ALL=C tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')
    [ -n "$slug" ] || slug=ticket
    ticket=$FEATURE_PATH/tickets/$id-$slug.md
    [ ! -e "$ticket" ] && [ ! -L "$ticket" ] || { fail "ticket already exists: $ticket"; exit 1; }
    NEW_TICKET_TEMP=$(mktemp "$FEATURE_PATH/.superteam-ticket.XXXXXX") || exit 1
    temporary=$NEW_TICKET_TEMP
    {
      printf '%s\n' '---'
      printf 'id: "%s"\n' "$id"
      printf '%s\n' 'status: "ready-for-agent"'
      printf '%s\n' 'repositories:'
      printf '%s\n' "$repository_values" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; /^$/d; s/^/  - "/; s/$/"/'
      if [ -n "$blockers" ]; then
        printf '%s\n' 'blocked_by:'
        printf '%s\n' "$blockers" | tr ',' '\n' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; /^$/d; s/^/  - "/; s/$/"/'
      else
        printf '%s\n' 'blocked_by: []'
      fi
      printf '%s\n' 'claimed_by: ""'
      printf '%s\n' 'claimed_at: ""'
      printf '%s\n' 'branches: {}'
      printf '%s\n' '---' ''
      printf '# %s - %s\n\n' "$id" "$title"
      if [ -n "$body_file" ]; then
        [ -f "$body_file" ] || exit 1
        sed -e '${/^$/d;}' "$body_file"
        final_byte=$(tail -c 1 "$body_file")
        [ -z "$final_byte" ] || printf '\n'
      else
        printf '%s\n\n' '**What to build:** <describe the complete end-to-end behavior>'
        printf '%s\n' '## Acceptance criteria'
        printf '%s\n\n' '- [ ] <observable result>'
        printf '%s\n' '## Result'
      fi
    } > "$temporary"
    validate_ticket "$temporary" false >/dev/null
    if [ ! -e "$FEATURE_PATH/tickets" ] && [ ! -L "$FEATURE_PATH/tickets" ]; then
      mkdir -- "$FEATURE_PATH/tickets"
      NEW_TICKETS_CREATED=true
    fi
    [ -d "$FEATURE_PATH/tickets" ] && [ ! -L "$FEATURE_PATH/tickets" ] || {
      fail 'tickets path must be a regular directory.'
      exit 1
    }
    ln -- "$temporary" "$ticket" || { fail "ticket appeared concurrently: $ticket"; exit 1; }
    rm -f -- "$temporary"
    NEW_TICKET_TEMP=''
    release_feature_lock
    printf '%s\n' "$ticket"
    ;;
  validate)
    feature=${1:-}; [ -n "$feature" ] && [ "$#" -eq 1 ] || usage
    validate_feature "$feature"
    printf '%s\n' OK
    ;;
  validate-set)
    feature=${1:-}; ticket_directory=${2:-}
    [ -n "$feature" ] && [ -n "$ticket_directory" ] && [ "$#" -eq 2 ] || usage
    validate_feature "$feature" "$ticket_directory"
    printf '%s\n' OK
    ;;
  frontier)
    feature=${1:-}; [ -n "$feature" ] && [ "$#" -eq 1 ] || usage
    validate_feature "$feature"
    while IFS= read -r ticket; do
      current_status=$(ticket_status "$ticket")
      [ "$current_status" = ready-for-agent ] || continue
      if ticket_is_runnable "$ticket" "$FEATURE_PATH"; then
        printf '%s\n' "$ticket"
      fi
    done < <(ticket_files "$FEATURE_PATH")
    ;;
  repositories)
    feature=${1:-}; [ -n "$feature" ] && [ "$#" -eq 1 ] || usage
    project_facts_for_feature "$feature"
    used=$(mktemp "${TMPDIR:-/tmp}/superteam-used-repositories.XXXXXX") || exit 1
    trap 'rm -f -- "$used"' EXIT HUP INT TERM
    if feature_has_tickets "$FEATURE_PATH"; then
      validate_feature "$FEATURE_PATH"
      while IFS= read -r ticket; do
        bash "$FRONTMATTER" get-list "$ticket" repositories
      done < <(ticket_files "$FEATURE_PATH") | LC_ALL=C sort -u > "$used"
    elif [ -f "$FEATURE_PATH/spec.md" ]; then
      validate_contract "$FEATURE_PATH/spec.md" spec
      bash "$FRONTMATTER" get-list "$FEATURE_PATH/spec.md" repositories > "$used"
    elif [ -f "$FEATURE_PATH/prd.md" ]; then
      validate_contract "$FEATURE_PATH/prd.md" prd
      bash "$FRONTMATTER" get-list "$FEATURE_PATH/prd.md" repositories > "$used"
    else
      fail "feature has no workflow contract: $FEATURE_PATH"
      exit 1
    fi
    while IFS= read -r repository; do
      grep -qxF -- "$repository" "$used" && printf '%s\n' "$repository"
    done < <(bash "$SNAPSHOT" repositories "$FEATURE_ROOT")
    rm -f -- "$used"
    trap - EXIT HUP INT TERM
    ;;
  claim)
    ticket=${1:-}; [ -n "$ticket" ] || usage; shift
    owner=''
    while [ "$#" -gt 0 ]; do case "$1" in --owner) owner=${2:-}; shift 2 ;; *) usage ;; esac; done
    [ -n "$owner" ] || usage
    reject_control_value "$owner" owner || exit 1
    feature=$(ticket_feature "$ticket")
    project_facts_for_feature "$feature"
    begin_ticket_mutation
    validate_feature "$FEATURE_PATH"
    current_status=$(ticket_status "$ticket")
    [ "$current_status" = ready-for-agent ] || { fail "ticket is not ready-for-agent: $ticket"; exit 3; }
    ticket_is_runnable "$ticket" "$FEATURE_PATH" || { fail "ticket blockers are not resolved: $ticket"; exit 3; }
    operations=$(make_operations_file)
    TICKET_OPERATIONS_TEMP=$operations
    printf 'set\tstatus\tclaimed\nset\tclaimed_by\t%s\nset\tclaimed_at\t%s\n' \
      "$owner" "$(timestamp)" > "$operations"
    bash "$FRONTMATTER" batch "$ticket" "$operations"
    rm -f -- "$operations"
    TICKET_OPERATIONS_TEMP=''
    release_feature_lock
    printf '%s\n' "$ticket"
    ;;
  write-result)
    ticket=${1:-}; result=${2:-}
    [ -n "$ticket" ] && [ -f "$result" ] && [ "$#" -eq 2 ] || usage
    feature=$(ticket_feature "$ticket")
    project_facts_for_feature "$feature"
    begin_ticket_mutation
    # Validate stable ticket facts without requiring the old Result to pass.
    # replace-result validates the assembled candidate under its writer lock.
    validate_ticket "$ticket" true false
    if [ "$(ticket_status "$ticket")" = resolved ]; then
      [ -n "$(bash "$FRONTMATTER" get "$ticket" resolved_at)" ] || {
        fail "resolved ticket is missing resolved_at: $ticket"
        exit 3
      }
      validate_resolved_git_evidence "$ticket" || exit 3
    fi
    bash "$FRONTMATTER" replace-result "$ticket" "$result"
    release_feature_lock
    printf '%s\n' "$ticket"
    ;;
  block)
    ticket=${1:-}; [ -n "$ticket" ] || usage; shift
    reason=''
    while [ "$#" -gt 0 ]; do case "$1" in --reason) reason=${2:-}; shift 2 ;; *) usage ;; esac; done
    [ -n "$reason" ] || usage
    reject_control_value "$reason" reason || exit 1
    feature=$(ticket_feature "$ticket")
    project_facts_for_feature "$feature"
    begin_ticket_mutation
    validate_feature "$FEATURE_PATH"
    current_status=$(ticket_status "$ticket")
    [ "$current_status" = claimed ] || { fail 'only a claimed ticket can be blocked.'; exit 3; }
    operations=$(make_operations_file)
    result=$(mktemp "${TMPDIR:-/tmp}/superteam-block-result.XXXXXX")
    TICKET_OPERATIONS_TEMP=$operations
    TICKET_RESULT_TEMP=$result
    blocked_at=$(timestamp)
    printf 'set\tstatus\tblocked\nset\tblocked_at\t%s\nset\tblocked_reason\t%s\n' \
      "$blocked_at" "$reason" > "$operations"
    printf 'Outcome: BLOCKED\nReason: %s\nBlocked at: %s\n' "$reason" "$blocked_at" > "$result"
    bash "$FRONTMATTER" batch-result "$ticket" "$operations" "$result"
    rm -f -- "$operations" "$result"
    TICKET_OPERATIONS_TEMP=''
    TICKET_RESULT_TEMP=''
    release_feature_lock
    printf '%s\n' "$ticket"
    ;;
  resolve)
    ticket=${1:-}; [ -n "$ticket" ] && [ "$#" -eq 1 ] || usage
    feature=$(ticket_feature "$ticket")
    project_facts_for_feature "$feature"
    begin_ticket_mutation
    validate_feature "$FEATURE_PATH"
    current_status=$(ticket_status "$ticket")
    case "$current_status" in claimed|blocked) ;; *) fail 'ticket cannot resolve from its current status.'; exit 3 ;; esac
    validate_result_evidence "$ticket" resolved
    validate_resolved_git_evidence "$ticket" || exit 3
    operations=$(make_operations_file)
    TICKET_OPERATIONS_TEMP=$operations
    printf 'set\tstatus\tresolved\nset\tresolved_at\t%s\n' "$(timestamp)" > "$operations"
    bash "$FRONTMATTER" batch "$ticket" "$operations"
    rm -f -- "$operations"
    TICKET_OPERATIONS_TEMP=''
    release_feature_lock
    printf '%s\n' "$ticket"
    ;;
  branch-get|branch-set)
    ticket=${1:-}; repository=${2:-}; field=${3:-}
    [ -n "$ticket" ] && [ -n "$repository" ] && [ -n "$field" ] || usage
    if [ "$command" = branch-set ]; then
      value=${4:-}
      [ "$#" -eq 4 ] || usage
      reject_control_value "$value" 'Repository branch value' || exit 1
    else
      [ "$#" -eq 3 ] || usage
    fi
    feature=$(ticket_feature "$ticket")
    project_facts_for_feature "$feature"
    if [ "$command" = branch-set ]; then
      begin_ticket_mutation
    fi
    validate_ticket "$ticket" true false
    bash "$FRONTMATTER" get-list "$ticket" repositories | grep -qxF -- "$repository" || {
      fail "ticket does not declare Repository: $repository"
      exit 1
    }
    if [ "$command" = branch-get ]; then
      bash "$FRONTMATTER" branch-get "$ticket" "$repository" "$field"
    else
      bash "$FRONTMATTER" branch-set "$ticket" "$repository" "$field" "$value"
      release_feature_lock
      printf '%s\n' "$ticket"
    fi
    ;;
  feature-status)
    feature=${1:-}; [ -n "$feature" ] && [ "$#" -eq 1 ] || usage
    project_facts_for_feature "$feature"
    if ! feature_has_tickets "$FEATURE_PATH"; then
      [ -f "$FEATURE_PATH/prd.md" ] || [ -f "$FEATURE_PATH/spec.md" ] || {
        fail "feature has no workflow contract: $FEATURE_PATH"
        exit 1
      }
      if [ -f "$FEATURE_PATH/prd.md" ]; then
        validate_contract "$FEATURE_PATH/prd.md" prd
      fi
      if [ -f "$FEATURE_PATH/spec.md" ]; then
        validate_contract "$FEATURE_PATH/spec.md" spec
        state=SPEC
      else
        state=PRD
      fi
      printf '%s total=0 ready=0 claimed=0 resolved=0 blocked=0\n' "$state"
      exit 0
    fi
    validate_feature "$FEATURE_PATH"
    total=0; ready=0; claimed=0; resolved=0; blocked=0
    while IFS= read -r ticket; do
      total=$((total + 1))
      current_status=$(ticket_status "$ticket")
      case "$current_status" in
        ready-for-agent) ready=$((ready + 1)) ;;
        claimed) claimed=$((claimed + 1)) ;;
        resolved) resolved=$((resolved + 1)) ;;
        blocked) blocked=$((blocked + 1)) ;;
      esac
    done < <(ticket_files "$FEATURE_PATH")
    if [ "$resolved" -eq "$total" ] && feature_result_is_terminal; then
      state=DONE
    elif [ "$blocked" -gt 0 ]; then
      state=BLOCKED
    elif [ "$claimed" -gt 0 ]; then
      state=RUNNING
    else
      state=READY
    fi
    printf '%s total=%s ready=%s claimed=%s resolved=%s blocked=%s\n' \
      "$state" "$total" "$ready" "$claimed" "$resolved" "$blocked"
    ;;
  *) usage ;;
esac
