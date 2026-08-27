#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"
TICKETS="$SCRIPT_DIR/st-tickets.sh"
FRONTMATTER="$SCRIPT_DIR/lib/frontmatter.sh"
CONTRACT="$SCRIPT_DIR/st-contract.sh"
. "$SCRIPT_DIR/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-plan.sh apply <feature-directory> <candidate-ticket-directory>
  st-plan.sh reconcile <prd|spec> <feature-directory> <candidate-contract-file> <candidate-ticket-directory>

Atomically installs a complete ready-for-agent ticket plan for a feature-local
Spec. Existing ready tickets are synchronized to the candidate. Claimed,
blocked, and resolved tickets are retained byte-for-byte and cannot be replaced;
contract corrections must use new ticket IDs. The command validates the final
Repository assignments and acyclic blocker graph, never starts Build, and does
not change the Git index or remotes. Reconcile installs a revised Current
Contract and its complete candidate plan as one rollback-safe transaction.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

absolute_directory() {
  (cd -P -- "$1" && pwd -P)
}

ticket_files_in() {
  find "$1" -maxdepth 1 -type f -name '*.md' -print | LC_ALL=C sort
}

ticket_id() {
  bash "$FRONTMATTER" get "$1" id ticket
}

ticket_status() {
  bash "$FRONTMATTER" get "$1" status ticket
}

ticket_for_id() {
  local directory=$1 wanted=$2 ticket current
  while IFS= read -r ticket; do
    current=$(ticket_id "$ticket") || return 1
    if [ "$current" = "$wanted" ]; then
      printf '%s\n' "$ticket"
      return 0
    fi
  done < <(ticket_files_in "$directory")
  return 1
}

directory_digest() {
  local directory=$1 ticket ticket_leaf
  [ -d "$directory" ] || {
    printf '%s\n' ABSENT
    return 0
  }
  while IFS= read -r ticket; do
    ticket_leaf=$(basename "$ticket")
    printf '%s ' "$ticket_leaf"
    cksum "$ticket"
  done < <(ticket_files_in "$directory")
}

file_identity() {
  local target=$1 inode
  if inode=$(stat -f '%d:%i' "$target" 2>/dev/null); then
    :
  else
    inode=$(stat -c '%d:%i' "$target") || return 1
  fi
  set -- $(cksum "$target")
  printf '%s:%s:%s\n' "$inode" "$1" "$2"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

remove_ticket_directory() {
  local directory=$1 ticket
  [ -e "$directory" ] || return 0
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  while IFS= read -r ticket; do
    rm -f -- "$ticket" || return 1
  done < <(ticket_files_in "$directory")
  rmdir -- "$directory"
}

cleanup_plan() {
  local contract_lock_parent displaced plan_lock_parent
  if [ "${PLAN_COMMITTED:-false}" != true ] && [ "${PLAN_INSTALLED:-false}" = true ]; then
    displaced=$PLAN_STAGE/tickets
    if [ -d "$PLAN_TARGET" ] && [ ! -L "$PLAN_TARGET" ] && [ ! -e "$displaced" ]; then
      mv -- "$PLAN_TARGET" "$displaced" 2>/dev/null || true
    fi
    PLAN_INSTALLED=false
  fi
  if [ "${PLAN_BACKUP_ACTIVE:-false}" = true ] && [ -d "${PLAN_BACKUP:-}" ]; then
    if [ "${PLAN_COMMITTED:-false}" = true ]; then
      remove_ticket_directory "$PLAN_BACKUP" 2>/dev/null || true
    elif [ ! -e "$PLAN_TARGET" ] && [ ! -L "$PLAN_TARGET" ]; then
      mv -- "$PLAN_BACKUP" "$PLAN_TARGET" 2>/dev/null || true
    fi
    PLAN_BACKUP_ACTIVE=false
  fi
  if [ "${CONTRACT_INSTALLED:-false}" = true ] && [ "${PLAN_COMMITTED:-false}" != true ]; then
    if [ -f "${CONTRACT_TARGET:-}" ] && [ ! -L "$CONTRACT_TARGET" ] &&
      [ ! -e "${CONTRACT_STAGE:-}" ] && [ ! -L "${CONTRACT_STAGE:-}" ]; then
      mv -- "$CONTRACT_TARGET" "$CONTRACT_STAGE" 2>/dev/null || true
    fi
    CONTRACT_INSTALLED=false
  fi
  if [ "${CONTRACT_BACKUP_ACTIVE:-false}" = true ] && [ -f "${CONTRACT_BACKUP:-}" ]; then
    if [ "${PLAN_COMMITTED:-false}" = true ]; then
      rm -f -- "$CONTRACT_BACKUP" 2>/dev/null || true
    elif [ ! -e "${CONTRACT_TARGET:-}" ] && [ ! -L "${CONTRACT_TARGET:-}" ]; then
      mv -- "$CONTRACT_BACKUP" "$CONTRACT_TARGET" 2>/dev/null || true
    fi
    CONTRACT_BACKUP_ACTIVE=false
  fi
  if [ -n "${CONTRACT_STAGE:-}" ]; then
    rm -f -- "$CONTRACT_STAGE"
  fi
  if [ "${CONTRACT_LOCK_ACTIVE:-false}" = true ] && [ -n "${CONTRACT_LOCK:-}" ]; then
    rmdir -- "$CONTRACT_LOCK" 2>/dev/null || true
    contract_lock_parent=$(dirname "$CONTRACT_LOCK")
    rmdir -- "$contract_lock_parent" 2>/dev/null || true
    CONTRACT_LOCK_ACTIVE=false
  fi
  if [ -n "${PLAN_STAGE:-}" ] && [ -d "$PLAN_STAGE/tickets" ]; then
    remove_ticket_directory "$PLAN_STAGE/tickets" 2>/dev/null || true
  fi
  if [ -n "${PLAN_STAGE:-}" ]; then
    rmdir -- "$PLAN_STAGE" 2>/dev/null || true
  fi
  if [ -n "${PLAN_REPORT:-}" ]; then
    rm -f -- "$PLAN_REPORT"
  fi
  if [ "${PLAN_LOCK_ACTIVE:-false}" = true ] && [ -n "${PLAN_LOCK:-}" ]; then
    rmdir -- "$PLAN_LOCK" 2>/dev/null || true
    plan_lock_parent=$(dirname "$PLAN_LOCK")
    rmdir -- "$plan_lock_parent" 2>/dev/null || true
    PLAN_LOCK_ACTIVE=false
  fi
}

command=${1:-}
case "$command" in
  apply)
    feature=${2:-}
    candidate=${3:-}
    [ "$#" -eq 3 ] || usage
    contract_kind=''
    contract_candidate=''
    ;;
  reconcile)
    contract_kind=${2:-}
    feature=${3:-}
    contract_candidate=${4:-}
    candidate=${5:-}
    [ "$#" -eq 5 ] || usage
    case "$contract_kind" in prd|spec) ;; *) usage ;; esac
    ;;
  *) usage ;;
esac
[ -n "$feature" ] && [ -n "$candidate" ] || usage

[ -d "$feature" ] && [ ! -L "$feature" ] || {
  fail 'feature path must be a regular directory.'
  exit 1
}
[ -d "$candidate" ] && [ ! -L "$candidate" ] || {
  fail 'candidate ticket path must be a regular directory.'
  exit 1
}
feature=$(absolute_directory "$feature") || exit 1
candidate=$(absolute_directory "$candidate") || exit 1
project_root=$(bash "$SNAPSHOT" root "$feature") || exit 1
task_root=$(bash "$SNAPSHOT" task "$feature") || exit 1
feature_parent=$(dirname "$feature")
[ "$feature_parent" = "$task_root" ] || {
  fail 'feature directory must be directly inside the configured task path.'
  exit 1
}
[ -f "$feature/spec.md" ] && [ ! -L "$feature/spec.md" ] || {
  fail 'Plan requires a feature-local Spec Current Contract.'
  exit 1
}
target=$feature/tickets
PLAN_TARGET=$target
[ "$candidate" != "$target" ] || {
  fail 'candidate ticket directory must be separate from the Current Plan.'
  exit 1
}

invalid_entry=$(find "$candidate" -mindepth 1 -maxdepth 1 ! -type f -print -quit)
[ -z "$invalid_entry" ] || {
  fail 'candidate ticket directory may contain only regular Markdown files.'
  exit 1
}
invalid_entry=$(find "$candidate" -mindepth 1 -maxdepth 1 -type f ! -name '*.md' -print -quit)
[ -z "$invalid_entry" ] || {
  fail 'candidate ticket directory may contain only regular Markdown files.'
  exit 1
}
find "$candidate" -maxdepth 1 -type f -name '*.md' -print -quit | grep -q . || {
  fail 'candidate ticket directory is empty.'
  exit 1
}

common=$(isolated_git -C "$project_root" rev-parse --git-common-dir 2>/dev/null) || exit 1
case "$common" in /*) ;; *) common=$project_root/$common ;; esac
common=$(absolute_directory "$common") || exit 1
set -- $(printf '%s' "$feature" | cksum)
lock_parent=$common/superteam-tracker-locks
PLAN_LOCK=$lock_parent/$1-$2.lock
mkdir -p -- "$lock_parent" || exit 1
if ! mkdir -- "$PLAN_LOCK" 2>/dev/null; then
  fail 'another ticket writer is active for this feature.'
  exit 1
fi
PLAN_LOCK_ACTIVE=true
PLAN_STAGE=$feature/.superteam-plan-stage.$$
PLAN_BACKUP=$feature/.superteam-plan-backup.$$
PLAN_REPORT=$(mktemp "${TMPDIR:-/tmp}/superteam-plan-report.XXXXXX") || exit 1
PLAN_INSTALLED=false
PLAN_BACKUP_ACTIVE=false
PLAN_COMMITTED=false
CONTRACT_TARGET=''
CONTRACT_STAGE=''
CONTRACT_BACKUP=''
CONTRACT_INSTALLED=false
CONTRACT_BACKUP_ACTIVE=false
CONTRACT_LOCK=''
CONTRACT_LOCK_ACTIVE=false
trap 'exit 130' HUP INT TERM
trap cleanup_plan EXIT
[ ! -e "$PLAN_STAGE" ] && [ ! -L "$PLAN_STAGE" ] &&
  [ ! -e "$PLAN_BACKUP" ] && [ ! -L "$PLAN_BACKUP" ] || {
  fail 'Plan staging path already exists.'
  exit 1
}
mkdir -- "$PLAN_STAGE"
mkdir -- "$PLAN_STAGE/tickets"

if [ "$command" = reconcile ]; then
  CONTRACT_TARGET=$feature/$contract_kind.md
  CONTRACT_STAGE=$feature/.$contract_kind.md.superteam-reconcile.$$
  CONTRACT_BACKUP=$feature/.$contract_kind.md.superteam-reconcile-backup.$$
  [ ! -e "$CONTRACT_STAGE" ] && [ ! -L "$CONTRACT_STAGE" ] &&
    [ ! -e "$CONTRACT_BACKUP" ] && [ ! -L "$CONTRACT_BACKUP" ] || {
    fail 'Contract reconciliation staging path already exists.'
    exit 1
  }
  [ -f "$CONTRACT_TARGET" ] && [ ! -L "$CONTRACT_TARGET" ] || {
    fail 'Contract reconciliation requires an existing Current Contract.'
    exit 1
  }
  CONTRACT_LOCK=$(bash "$FRONTMATTER" lock-path "$CONTRACT_TARGET") || exit 1
  CONTRACT_LOCK_PARENT=$(dirname "$CONTRACT_LOCK") || exit 1
  mkdir -p -- "$CONTRACT_LOCK_PARENT" || exit 1
  if ! mkdir -- "$CONTRACT_LOCK" 2>/dev/null; then
    fail 'another workflow data writer is active.'
    exit 1
  fi
  CONTRACT_LOCK_ACTIVE=true
  bash "$CONTRACT" validate "$contract_kind" "$feature" "$contract_candidate" || exit 1
  CONTRACT_BEFORE=$(file_identity "$CONTRACT_TARGET") || exit 1
  CONTRACT_CANDIDATE_BEFORE=$(file_identity "$contract_candidate") || exit 1
  CONTRACT_MODE=$(file_mode "$CONTRACT_TARGET") || exit 1
  cp -- "$contract_candidate" "$CONTRACT_STAGE" || exit 1
  CONTRACT_CANDIDATE_CURRENT=$(file_identity "$contract_candidate") || exit 1
  [ "$CONTRACT_CANDIDATE_CURRENT" = "$CONTRACT_CANDIDATE_BEFORE" ] || {
    fail 'contract candidate changed while it was being staged.'
    exit 1
  }
  bash "$FRONTMATTER" validate "$CONTRACT_STAGE" "$contract_kind" >/dev/null || exit 1
  chmod "$CONTRACT_MODE" "$CONTRACT_STAGE" || exit 1
fi

before_target=$(directory_digest "$target")
before_candidate=$(directory_digest "$candidate")
if [ -e "$target" ] || [ -L "$target" ]; then
  [ -d "$target" ] && [ ! -L "$target" ] || {
    fail 'Current tickets path must be a regular directory.'
    exit 1
  }
  bash "$TICKETS" validate "$feature" >/dev/null
fi

candidate_count=0
while IFS= read -r ticket; do
  bash "$FRONTMATTER" validate "$ticket" ticket >/dev/null || exit 1
  status=$(ticket_status "$ticket") || exit 1
  [ "$status" = ready-for-agent ] || {
    fail 'candidate tickets must be ready-for-agent.'
    exit 1
  }
  candidate_branches=$(bash "$FRONTMATTER" branch-repositories "$ticket") || exit 1
  [ -z "$(bash "$FRONTMATTER" get "$ticket" claimed_by ticket)" ] &&
    [ -z "$(bash "$FRONTMATTER" get "$ticket" claimed_at ticket)" ] &&
    [ -z "$candidate_branches" ] || {
    fail 'candidate tickets must not contain execution state.'
    exit 1
  }
  candidate_count=$((candidate_count + 1))
done < <(ticket_files_in "$candidate")
[ "$candidate_count" -gt 0 ] || {
  fail 'candidate ticket directory is empty.'
  exit 1
}

synced=0
retained=0
added=0
removed=0
affected=0
if [ -d "$target" ]; then
  while IFS= read -r current; do
    id=$(ticket_id "$current") || exit 1
    status=$(ticket_status "$current") || exit 1
    planned=''
    planned=$(ticket_for_id "$candidate" "$id" 2>/dev/null || true)
    case "$status" in
      ready-for-agent)
        if [ -n "$planned" ]; then
          printf 'SYNCED: %s\n' "$id" >> "$PLAN_REPORT"
          synced=$((synced + 1))
        else
          printf 'REMOVED: %s\n' "$id" >> "$PLAN_REPORT"
          removed=$((removed + 1))
        fi
        ;;
      claimed|blocked|resolved)
        [ -z "$planned" ] || {
          fail "candidate collides with protected ticket $id ($status)."
          exit 1
        }
        current_leaf=$(basename "$current")
        stage_ticket=$PLAN_STAGE/tickets/$current_leaf
        cp -- "$current" "$stage_ticket"
        printf 'RETAINED: %s status=%s\n' "$id" "$status" >> "$PLAN_REPORT"
        retained=$((retained + 1))
        if [ "$status" != resolved ]; then
          printf 'AFFECTED: %s status=%s\n' "$id" "$status" >> "$PLAN_REPORT"
          affected=$((affected + 1))
        fi
        ;;
      *)
        fail "unsupported Current ticket status: $status"
        exit 1
        ;;
    esac
  done < <(ticket_files_in "$target")
fi

while IFS= read -r planned; do
  id=$(ticket_id "$planned") || exit 1
  current=''
  if [ -d "$target" ]; then
    current=$(ticket_for_id "$target" "$id" 2>/dev/null || true)
  fi
  if [ -z "$current" ]; then
    printf 'ADDED: %s\n' "$id" >> "$PLAN_REPORT"
    added=$((added + 1))
  fi
  planned_leaf=$(basename "$planned")
  stage_ticket=$PLAN_STAGE/tickets/$planned_leaf
  cp -- "$planned" "$stage_ticket"
done < <(ticket_files_in "$candidate")

after_candidate=$(directory_digest "$candidate")
[ "$after_candidate" = "$before_candidate" ] || {
  fail 'candidate ticket set changed while Plan staged it.'
  exit 1
}
bash "$TICKETS" validate-set "$feature" "$PLAN_STAGE/tickets" >/dev/null
after_target=$(directory_digest "$target")
[ "$after_target" = "$before_target" ] || {
  fail 'Current ticket set changed before Plan could apply.'
  exit 1
}
if [ "$command" = reconcile ]; then
  CONTRACT_TARGET_CURRENT=$(file_identity "$CONTRACT_TARGET") || exit 1
  [ "$CONTRACT_TARGET_CURRENT" = "$CONTRACT_BEFORE" ] || {
    fail 'Current Contract changed before reconciliation could apply.'
    exit 1
  }
  CONTRACT_CANDIDATE_CURRENT=$(file_identity "$contract_candidate") || exit 1
  [ "$CONTRACT_CANDIDATE_CURRENT" = "$CONTRACT_CANDIDATE_BEFORE" ] || {
    fail 'contract candidate changed before reconciliation could apply.'
    exit 1
  }
  CONTRACT_BACKUP_ACTIVE=true
  mv -- "$CONTRACT_TARGET" "$CONTRACT_BACKUP"
  CONTRACT_INSTALLED=true
  mv -- "$CONTRACT_STAGE" "$CONTRACT_TARGET"
fi

if [ -d "$target" ]; then
  PLAN_BACKUP_ACTIVE=true
  mv -- "$target" "$PLAN_BACKUP"
fi
PLAN_INSTALLED=true
mv -- "$PLAN_STAGE/tickets" "$target"
PLAN_COMMITTED=true
if [ "$PLAN_BACKUP_ACTIVE" = true ]; then
  remove_ticket_directory "$PLAN_BACKUP"
  PLAN_BACKUP_ACTIVE=false
fi
if [ "$CONTRACT_BACKUP_ACTIVE" = true ]; then
  rm -f -- "$CONTRACT_BACKUP"
  CONTRACT_BACKUP_ACTIVE=false
fi

if [ "$command" = reconcile ]; then
  printf 'CONTRACT: %s\n' "$(printf '%s' "$contract_kind" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
  printf 'PATH: %s\n' "$CONTRACT_TARGET"
fi
printf '%s\n' 'PLAN: APPLIED'
cat "$PLAN_REPORT"
printf 'SUMMARY: synced=%s retained=%s added=%s removed=%s affected=%s\n' \
  "$synced" "$retained" "$added" "$removed" "$affected"
printf '%s\n' 'BUILD: NOT_STARTED'
