#!/usr/bin/env bash

set -eu
set -o pipefail

case "$0" in
  */*) SCRIPT_DIRECTORY=${0%/*} ;;
  *) SCRIPT_DIRECTORY=. ;;
esac
SCRIPT_DIRECTORY=$(cd "$SCRIPT_DIRECTORY" && pwd -P)
. "$SCRIPT_DIRECTORY/lib/git.sh"

LOCK_HELD=false
INIT_LOCK_ROOT_PHYSICAL=''
INIT_LOCK_ROOT_IDENTITY=''
INIT_STAGE=''
INIT_STAGE_IDENTITY=''
INIT_CREATED_GIT=false
INIT_MANIFEST_INSTALLED=false
INIT_GITIGNORE_INSTALLED=false
INIT_STAGE_OWNED=false
INIT_MANIFEST_NESTED_PATH=''
INIT_GITIGNORE_NESTED_PATH=''
INIT_OWNERSHIP_COUNT=0
INIT_CREATED_RECORDS=''
INIT_OWNED_ASSET_RECORDS=''
VERIFY_ROOT_STABLE=false
INIT_CONFIRMED_ROOT=''
INIT_CONFIRMED_ROOT_MODE=''
INIT_CONFIRMED_GIT_IDENTITY=''
INIT_GIT_IDENTITY=''
INIT_GIT_MARKER=''
INIT_GIT_MARKER_FINGERPRINT=''
INIT_GIT_SNAPSHOT=''
INIT_GIT_SNAPSHOT_READY=false
INIT_FINAL_GIT_SNAPSHOT=''
INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT=''
INIT_FINALIZATION_OWNERSHIP_READY=false
INIT_FINAL_CREATED_DIRECTORY_RECORDS=''
INIT_FINAL_OWNED_ASSET_RECORDS=''
INIT_FINAL_MANIFEST_INODE=''
INIT_FINAL_MANIFEST_FINGERPRINT=''
INIT_RUNTIME_GIT_IDENTITY=''
INIT_STAGE_OWNER_REFERENCE=''
INIT_STAGE_OWNER_FINGERPRINT=''
INIT_STAGE_SNAPSHOT=''
INIT_STAGE_SNAPSHOT_READY=false
INIT_MANIFEST_FINGERPRINT=''
INIT_MANIFEST_REFERENCE=''
INIT_GITIGNORE_FINGERPRINT=''
INIT_GITIGNORE_REFERENCE=''
INIT_TASK_README_FINGERPRINT=''
INIT_KNOWLEDGE_README_FINGERPRINT=''
INIT_TASK_README_REFERENCE=''
INIT_KNOWLEDGE_README_REFERENCE=''
INIT_GIT_TEMPLATE=''
INIT_GIT_BASELINE_WORKSPACE=''
INIT_GIT_CANDIDATE_WORKSPACE=''
INIT_GIT_CANDIDATE_SNAPSHOT=''
INIT_ROOT_PHYSICAL=''
INIT_ROOT_IDENTITY=''
INIT_CONFIRMED_ROOT_IDENTITY=''
INIT_ROOT_ANCHORED=false
INIT_ACTION=INIT
INIT_PROBE_DIRECTORIES=('__superteam_unset__')
INIT_PLANNED_DIRECTORIES=('__superteam_unset__')
TXN_STATE=IDLE
TXN_ABORTING=false
TXN_LOCK_PENDING=false
TXN_LEDGER_READY=false
TXN_LEDGER_RECORDING=true
TXN_LEDGER_PATH=''
TXN_LEDGER_FINGERPRINT=''
TXN_LEDGER_SEQUENCE=0
TXN_LEDGER_BOOTSTRAP_PENDING=false
TXN_LEDGER_BOOTSTRAP_FINGERPRINT=''
TXN_TRAP_ROOT_SUBSHELL=0
TXN_CRITICAL=false
TXN_DEFERRED_STATUS=''
MANIFEST_REPOSITORY_IDS=()
MANIFEST_REPOSITORY_PATHS=()
REPOSITORY_WRITE_LOCK=''
REPOSITORY_WRITE_ROOT=''
REPOSITORY_WRITE_MANIFEST_INSTALLED=false
REPOSITORY_WRITE_IGNORE_INSTALLED=false
REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE=false
REPOSITORY_IGNORE_PREVIOUS_EMPTY=false
INIT_PLAN_BODY=''
INIT_PLAN_FINGERPRINT=''
INIT_EXPECTED_PLAN_FINGERPRINT=''
REPOSITORY_PLAN_BODY=''
REPOSITORY_PLAN_FINGERPRINT=''
REPOSITORY_EXPECTED_PLAN_FINGERPRINT=''
INIT_COMMIT_AUTHOR_NAME=''
INIT_COMMIT_AUTHOR_EMAIL=''

usage() {
  cat <<'EOF'
Usage:
  st-project.sh inspect [directory]
  st-project.sh init [directory] --task <path> --knowledge <path> [--adopt-task] [--adopt-knowledge] [--plan-fingerprint <hex>] [--apply]
  st-project.sh adopt [directory] --task <path> --knowledge <path> [--adopt-task] [--adopt-knowledge] [--plan-fingerprint <hex>] [--apply]
  st-project.sh init-commit [directory] [--apply]
  st-project.sh repository add [directory] --id <id> --path <path> [--plan-fingerprint <hex>] [--apply]
  st-project.sh repository remove [directory] --id <id> [--plan-fingerprint <hex>] [--apply]
  st-project.sh status [directory]
  st-project.sh doctor [directory]
  st-project.sh pull [directory]

Initialization and Repository Set writes print a plan fingerprint. Apply that
exact plan with its printed --plan-fingerprint only after reviewing it.
Initialization commits keep their separately confirmed init-commit plan.
Pull runs only when explicitly invoked and always prints a final repository report.

Runtime: Git and Bash with POSIX base utilities.
EOF
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

reject_line_breaks() {
  case "$1" in
    *$'\n'*|*$'\r'*) fail "$2 contains an unsupported line break."; return 1 ;;
  esac
  if printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "$2 contains an unsupported control character."
    return 1
  fi
}

resolve_directory() {
  reject_line_breaks "$1" 'directory path' || return 1
  [ -d "$1" ] || { fail "directory does not exist: $1"; return 1; }
  location=$(cd -P -- "$1" && pwd -P) || return 1
  reject_line_breaks "$location" 'resolved directory path' || return 1
  printf '%s\n' "$location"
}

# Preserve the historical local name while routing every Project Git call
# through the shared isolation boundary.
safe_git() {
  isolated_git "$@"
}

directory_identity_for() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  directory_identity_physical=$(cd -P -- "$1" && pwd -P) || return 1
  reject_line_breaks "$directory_identity_physical" 'directory identity path' || return 1
  directory_identity_inode=$(LC_ALL=C ls -di "$directory_identity_physical" | sed 's/[[:space:]].*$//') || return 1
  [ -n "$directory_identity_inode" ] || return 1
  printf '%s:%s\n' "$directory_identity_physical" "$directory_identity_inode"
}

root_identity_is_current() {
  [ "$INIT_ROOT_ANCHORED" = true ] || return 1
  current_root_identity=$(directory_identity_for "$INIT_ROOT_PHYSICAL") || return 1
  [ "$current_root_identity" = "$INIT_CONFIRMED_ROOT_IDENTITY" ]
}

require_current_root() {
  root_identity_is_current || {
    fail 'Root Repository changed during initialization; no files were applied.'
    return 1
  }
}

root_relative_path() {
  case "$1" in
    .) printf '%s\n' '' ;;
    ./*) printf '%s\n' "${1#./}" ;;
    *) return 1 ;;
  esac
}

safe_leaf_name() {
  case "$1" in
    ''|.|..|*/*) return 1 ;;
  esac
}

root_physical_path_for() {
  case "$1" in
    .) printf '%s\n' "$INIT_ROOT_PHYSICAL" ;;
    ./*) printf '%s/%s\n' "$INIT_ROOT_PHYSICAL" "${1#./}" ;;
    *) return 1 ;;
  esac
}

root_relative_directory_is_safe() {
  root_relative=$1
  root_directory_physical=$INIT_ROOT_PHYSICAL
  root_expected_physical=$INIT_ROOT_PHYSICAL
  require_current_root || return 1
  if [ -z "$root_relative" ]; then
    [ "$(pwd -P)" = "$root_expected_physical" ] || return 1
    return 0
  fi
  root_expected_physical=$INIT_ROOT_PHYSICAL/$root_relative
  root_remaining=$root_relative
  while [ -n "$root_remaining" ]; do
    next_path_component "$root_remaining"
    [ -d "$NEXT_COMPONENT" ] && [ ! -L "$NEXT_COMPONENT" ] || return 1
    cd -P -- "$NEXT_COMPONENT" || return 1
    root_directory_physical=$(pwd -P) || return 1
    case "$root_directory_physical" in
      "$INIT_ROOT_PHYSICAL"/*) ;;
      *) return 1 ;;
    esac
    require_current_root || return 1
    root_remaining=$NEXT_REMAINING
  done
  [ "$root_directory_physical" = "$root_expected_physical" ]
}

root_parent_identity_is_current() {
  root_expected_parent_identity=$1
  require_current_root || return 1
  [ "$(directory_identity_for .)" = "$root_expected_parent_identity" ]
}

# The shell cannot make a journal append and a later filesystem syscall one
# atomic operation.  Keep a durable, append-only intent before every tracked
# root mutation instead.  A signal can therefore either find no target or a
# target with evidence; evidence that no longer matches is retained rather
# than guessed at during rollback.
transaction_tracks_root_writes() {
  [ "$TXN_LEDGER_READY" = true ] || return 1
  [ "$TXN_LEDGER_RECORDING" = true ] || return 1
  case "$TXN_STATE" in
    APPLYING|COMMITTING) return 0 ;;
    *) return 1 ;;
  esac
}

transaction_ledger_is_current() {
  [ "$TXN_LEDGER_READY" = true ] || return 1
  [ -n "$TXN_LEDGER_PATH" ] && [ -n "$TXN_LEDGER_FINGERPRINT" ] || return 1
  require_current_root || return 1
  [ ! -L "$TXN_LEDGER_PATH" ] && [ -f "$TXN_LEDGER_PATH" ] || return 1
  transaction_ledger_actual_fingerprint=$(file_fingerprint "$TXN_LEDGER_PATH") || return 1
  [ "$transaction_ledger_actual_fingerprint" = "$TXN_LEDGER_FINGERPRINT" ]
}

transaction_append_ledger_line() {
  transaction_ledger_line=$1
  # Most callers already hold the mutation critical section.  Intents are
  # also appended immediately before M/L/F/W root syscalls, however, so the
  # journal append and its refreshed fingerprint need their own short
  # critical section when no caller has one.  A signal can then never observe
  # a durable line together with the preceding fingerprint.
  transaction_append_started_critical=false
  if [ "$TXN_CRITICAL" = false ]; then
    transaction_begin_critical_section || return 1
    transaction_append_started_critical=true
  fi
  (
    root_relative_directory_is_safe "$PROJECT_LOCK" || exit 1
    transaction_ledger_parent_identity=$(directory_identity_for .) || exit 1
    [ ! -L .superteam-project-ledger ] && [ -f .superteam-project-ledger ] || exit 1
    [ "$(file_fingerprint ./.superteam-project-ledger)" = "$TXN_LEDGER_FINGERPRINT" ] || exit 1
    printf '%s\n' "$transaction_ledger_line" >> ./.superteam-project-ledger || exit 1
    [ ! -L .superteam-project-ledger ] && [ -f .superteam-project-ledger ] || exit 1
    root_parent_identity_is_current "$transaction_ledger_parent_identity"
  ) || {
    [ "$transaction_append_started_critical" = true ] && transaction_cancel_critical_section
    return 1
  }
  TXN_LEDGER_FINGERPRINT=$(file_fingerprint "$TXN_LEDGER_PATH") || {
    [ "$transaction_append_started_critical" = true ] && transaction_cancel_critical_section
    return 1
  }
  if [ "$transaction_append_started_critical" = true ]; then
    transaction_finish_critical_section || return 1
  fi
}

transaction_record_intent() {
  transaction_intent_kind=$1
  transaction_intent_target=$2
  transaction_intent_source=${3:-}
  transaction_intent_fingerprint=${4:-}
  transaction_tracks_root_writes || return 0
  root_relative_path "$transaction_intent_target" >/dev/null || return 1
  reject_line_breaks "$transaction_intent_target" 'transaction intent path' || return 1
  reject_line_breaks "$transaction_intent_source" 'transaction intent source' || return 1
  TXN_LEDGER_SEQUENCE=$((TXN_LEDGER_SEQUENCE + 1))
  printf -v transaction_intent_line 'I\t%s\t%s\t%s\t%s\t%s' \
    "$TXN_LEDGER_SEQUENCE" "$transaction_intent_kind" "$transaction_intent_target" "$transaction_intent_source" "$transaction_intent_fingerprint"
  transaction_append_ledger_line "$transaction_intent_line" || {
    return 1
  }
}

# Immediately after a regular file exists, record its inode proof before the
# first target-file checksum.  A signal delivered while cksum runs can then
# distinguish the just-created leaf from a later replacement during rollback.
# The ordinary pre-write I record remains the durable intent; this second I
# record is its ownership checkpoint and is deliberately not a completion.
transaction_record_pending_file_ownership() {
  transaction_pending_kind=$1
  transaction_pending_target=$2
  transaction_pending_parent_inode=$3
  transaction_pending_inode=$4
  transaction_pending_fingerprint=$5
  transaction_tracks_root_writes || return 0
  case "$transaction_pending_kind" in F|W) ;; *) return 1 ;; esac
  root_relative_path "$transaction_pending_target" >/dev/null || return 1
  reject_line_breaks "$transaction_pending_target" 'transaction pending path' || return 1
  [ -n "$transaction_pending_parent_inode" ] && [ -n "$transaction_pending_inode" ] || return 1
  [ -n "$transaction_pending_fingerprint" ] || return 1
  TXN_LEDGER_SEQUENCE=$((TXN_LEDGER_SEQUENCE + 1))
  printf -v transaction_pending_line 'I\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$TXN_LEDGER_SEQUENCE" "$transaction_pending_kind" "$transaction_pending_target" "$transaction_pending_parent_inode" "$transaction_pending_inode" "$transaction_pending_fingerprint"
  transaction_append_ledger_line "$transaction_pending_line"
}

# A pre-write intent alone is deliberately insufficient to remove a regular
# file: another writer could replace it with identical content before a signal
# reaches us.  Once the write has completed, retain the parent inode, leaf
# inode, and fingerprint in the ledger so rollback can remove only that exact
# object.  This is separate from an intent because the two filesystem actions
# cannot be made atomic in Bash/POSIX.
transaction_record_completed_file_intent() {
  transaction_completed_kind=$1
  transaction_completed_target=$2
  transaction_completed_parent_inode=$3
  transaction_completed_inode=$4
  transaction_completed_fingerprint=$5
  transaction_completed_expected_fingerprint=$6
  transaction_tracks_root_writes || return 0
  case "$transaction_completed_kind" in F|W) ;; *) return 1 ;; esac
  root_relative_path "$transaction_completed_target" >/dev/null || return 1
  reject_line_breaks "$transaction_completed_target" 'transaction completed path' || return 1
  [ -n "$transaction_completed_parent_inode" ] && [ -n "$transaction_completed_inode" ] || return 1
  [ "$transaction_completed_fingerprint" = "$transaction_completed_expected_fingerprint" ] || return 1
  TXN_LEDGER_SEQUENCE=$((TXN_LEDGER_SEQUENCE + 1))
  printf -v transaction_completed_line 'O\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$TXN_LEDGER_SEQUENCE" "$transaction_completed_kind" "$transaction_completed_target" "$transaction_completed_parent_inode" "$transaction_completed_inode" "$transaction_completed_fingerprint"
  transaction_append_ledger_line "$transaction_completed_line"
}

initialize_transaction_ledger() {
  [ "$LOCK_HELD" = true ] || return 1
  TXN_LEDGER_READY=false
  TXN_LEDGER_RECORDING=false
  TXN_LEDGER_PATH=./$PROJECT_LOCK/.superteam-project-ledger
  TXN_LEDGER_FINGERPRINT=''
  TXN_LEDGER_SEQUENCE=0
  # Before the ledger is available there is no place to append a normal
  # intent.  The bootstrap has a fixed non-empty fingerprint and is the sole
  # permitted entry in the lock, which lets signal rollback remove it only
  # when that narrow ownership proof still holds.
  TXN_LEDGER_BOOTSTRAP_FINGERPRINT=$(printf '%s\n' 'superteam-project-ledger-v1' | LC_ALL=C cksum) || return 1
  TXN_LEDGER_BOOTSTRAP_PENDING=true
  safe_root_write_new_file "./$PROJECT_LOCK" .superteam-project-ledger 'superteam-project-ledger-v1' || return 1
  TXN_LEDGER_FINGERPRINT=$TXN_LEDGER_BOOTSTRAP_FINGERPRINT
  TXN_LEDGER_READY=true
  TXN_LEDGER_RECORDING=true
  TXN_LEDGER_BOOTSTRAP_PENDING=false
}

cleanup_pending_project_lock() {
  [ "$TXN_LOCK_PENDING" = true ] || return 0
  [ -n "$INIT_ROOT_PHYSICAL" ] && [ -n "$INIT_CONFIRMED_ROOT_IDENTITY" ] || return 1
  require_current_root || return 1
  [ -d "./$PROJECT_LOCK" ] && [ ! -L "./$PROJECT_LOCK" ] || return 1
  # This is the one intentionally narrow bootstrap exception: only an empty
  # lock can be proved harmless before the ledger itself exists.
  safe_root_rmdir . "$PROJECT_LOCK" || return 1
  TXN_LOCK_PENDING=false
}

bootstrap_ledger_is_sole_lock_entry() {
  bootstrap_entry_directory=$1
  for bootstrap_entry in "$bootstrap_entry_directory"/* "$bootstrap_entry_directory"/.[!.]* "$bootstrap_entry_directory"/..?*; do
    [ -e "$bootstrap_entry" ] || [ -L "$bootstrap_entry" ] || continue
    [ "$bootstrap_entry" = "$bootstrap_entry_directory/.superteam-project-ledger" ] || return 1
  done
  return 0
}

cleanup_bootstrap_transaction_ledger() {
  [ "$TXN_LEDGER_BOOTSTRAP_PENDING" = true ] || return 0
  [ -n "$TXN_LEDGER_BOOTSTRAP_FINGERPRINT" ] || return 1
  bootstrap_ledger_ownership=$(
  (
    root_relative_directory_is_safe "$PROJECT_LOCK" || exit 1
    bootstrap_lock_inode=$(filesystem_inode_for .) || exit 1
    bootstrap_lock_physical=$(pwd -P) || exit 1
    bootstrap_ledger_is_sole_lock_entry "$bootstrap_lock_physical" || exit 1
    if [ ! -e .superteam-project-ledger ] && [ ! -L .superteam-project-ledger ]; then
      # A signal can arrive after bootstrap pending is durable in memory but
      # before the first ledger write.  The verified empty lock is safe for
      # release; any later concurrent entry makes safe_root_rmdir fail closed.
      printf '%s\n' ABSENT
      exit 0
    fi
    [ ! -L .superteam-project-ledger ] && [ -f .superteam-project-ledger ] || exit 1
    bootstrap_ledger_fingerprint=$(file_fingerprint ./.superteam-project-ledger) || exit 1
    [ "$bootstrap_ledger_fingerprint" = "$TXN_LEDGER_BOOTSTRAP_FINGERPRINT" ] || exit 1
    bootstrap_ledger_inode=$(filesystem_inode_for ./.superteam-project-ledger) || exit 1
    printf '%s\t%s\n' "$bootstrap_lock_inode" "$bootstrap_ledger_inode"
  )
  ) || return 1
  if [ "$bootstrap_ledger_ownership" = ABSENT ]; then
    TXN_LEDGER_BOOTSTRAP_PENDING=false
    TXN_LEDGER_BOOTSTRAP_FINGERPRINT=''
    return 0
  fi
  IFS=$'\t' read -r bootstrap_lock_inode bootstrap_ledger_inode <<EOF
$bootstrap_ledger_ownership
EOF
  safe_root_remove_owned_snapshot_file "./$PROJECT_LOCK" .superteam-project-ledger "$bootstrap_ledger_inode" "$TXN_LEDGER_BOOTSTRAP_FINGERPRINT" "$bootstrap_lock_inode" || return 1
  TXN_LEDGER_BOOTSTRAP_PENDING=false
  TXN_LEDGER_BOOTSTRAP_FINGERPRINT=''
}

cleanup_pending_transaction_intents() {
  [ "$TXN_LEDGER_READY" = true ] || return 0
  transaction_ledger_is_current || {
    report_rollback_problem
    return 1
  }
  TXN_LEDGER_RECORDING=false
  transaction_ledger_contents=$(cat "$TXN_LEDGER_PATH") || return 1
  # Reverse the durable sequence, rather than the leading record tag: a later
  # hard-link intent still needs its source before the earlier completed file
  # record is eligible for removal.
  printf '%s\n' "$transaction_ledger_contents" | LC_ALL=C sort -t $'\t' -k2,2nr | while IFS=$'\t' read -r transaction_tag transaction_id transaction_kind transaction_target transaction_value transaction_extra transaction_completed_fingerprint; do
    case "$transaction_kind" in
      M) [ "$transaction_tag" = I ] || continue
        [ -d "$transaction_target" ] && [ ! -L "$transaction_target" ] || continue
        split_internal_root_path "$transaction_target" || { report_rollback_problem; continue; }
        # An intent without a completed inode is still safe to remove only if
        # it remains empty.  Any concurrent content makes rmdir fail closed.
        safe_root_rmdir "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" || true
        ;;
      L) [ "$transaction_tag" = I ] || continue
        [ -n "$transaction_value" ] || continue
        [ -e "$transaction_target" ] || [ -L "$transaction_target" ] || continue
        split_internal_root_path "$transaction_target" || { report_rollback_problem; continue; }
        safe_root_remove_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$transaction_value" "$transaction_extra" || true
        ;;
      F|W)
        case "$transaction_tag" in
          O|I) ;;
          *) continue ;;
        esac
        # A plain F/W intent has no inode proof and must be retained.  The
        # post-create I checkpoint and O completion both carry the same
        # parent inode, file inode, and expected fingerprint layout.
        [ -n "$transaction_target" ] && [ -n "$transaction_value" ] && [ -n "$transaction_extra" ] && [ -n "$transaction_completed_fingerprint" ] || continue
        split_internal_root_path "$transaction_target" || { report_rollback_problem; continue; }
        safe_root_remove_owned_snapshot_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$transaction_extra" "$transaction_completed_fingerprint" "$transaction_value" || true
        ;;
    esac
  done
}

cleanup_transaction_ledger() {
  [ "$TXN_LEDGER_READY" = true ] || return 0
  TXN_LEDGER_RECORDING=false
  transaction_ledger_is_current || return 1
  safe_root_remove_file "./$PROJECT_LOCK" .superteam-project-ledger "$TXN_LEDGER_PATH" "$TXN_LEDGER_FINGERPRINT" || return 1
  TXN_LEDGER_READY=false
  TXN_LEDGER_PATH=''
  TXN_LEDGER_FINGERPRINT=''
}

safe_root_mkdir() {
  root_relative_path "$1" >/dev/null || return 1
  root_mkdir_relative=${1#./}
  case "$root_mkdir_relative" in
    */*) root_mkdir_parent=${root_mkdir_relative%/*}; root_mkdir_name=${root_mkdir_relative##*/} ;;
    *) root_mkdir_parent=''; root_mkdir_name=$root_mkdir_relative ;;
  esac
  safe_leaf_name "$root_mkdir_name" || return 1
  transaction_record_intent M "$1" || return 1
  transaction_begin_critical_section || return 1
  (
    root_relative_directory_is_safe "$root_mkdir_parent" || exit 1
    root_mkdir_parent_identity=$(directory_identity_for .) || exit 1
    [ ! -e "$root_mkdir_name" ] && [ ! -L "$root_mkdir_name" ] || exit 1
    mkdir "./$root_mkdir_name" || exit 1
    [ -d "./$root_mkdir_name" ] && [ ! -L "./$root_mkdir_name" ] || exit 1
    root_parent_identity_is_current "$root_mkdir_parent_identity"
  ) || { transaction_cancel_critical_section; return 1; }
  require_current_root || { transaction_cancel_critical_section; return 1; }
  transaction_finish_critical_section
}

safe_root_link() {
  root_link_source=$1
  root_link_directory=$2
  root_link_name=$3
  root_relative_path "$root_link_directory" >/dev/null || return 1
  safe_leaf_name "$root_link_name" || return 1
  require_current_root || return 1
  root_link_source_parent=${root_link_source%/*}
  root_link_source_base=${root_link_source##*/}
  [ "$root_link_source_parent" != "$root_link_source" ] || return 1
  root_link_source_parent=$(cd -P -- "$root_link_source_parent" && pwd -P) || return 1
  case "$root_link_source_parent" in
    "$INIT_ROOT_PHYSICAL") ;;
    "$INIT_ROOT_PHYSICAL"/*) ;;
    *) return 1 ;;
  esac
  root_link_source=$root_link_source_parent/$root_link_source_base
  [ ! -L "$root_link_source" ] && [ -f "$root_link_source" ] || return 1
  root_link_fingerprint=$(file_fingerprint "$root_link_source") || return 1
  root_link_relative_directory=${root_link_directory#./}
  [ "$root_link_directory" != . ] || root_link_relative_directory=''
  root_link_target=$root_link_directory/$root_link_name
  [ "$root_link_directory" != . ] || root_link_target=./$root_link_name
  transaction_record_intent L "$root_link_target" "$root_link_source" "$root_link_fingerprint" || return 1
  transaction_begin_critical_section || return 1
  (
    root_relative_directory_is_safe "$root_link_relative_directory" || exit 1
    root_link_parent_identity=$(directory_identity_for .) || exit 1
    root_link_parent_physical=$(pwd -P) || exit 1
    [ ! -e "$root_link_name" ] && [ ! -L "$root_link_name" ] || exit 1
    # -n makes a final symbolic link-to-directory an existing destination on
    # both BSD and GNU ln instead of following it into an external directory.
    ln -n "$root_link_source" "./$root_link_name" || exit 1
    if [ -d "./$root_link_name" ] && [ ! -L "./$root_link_name" ]; then
      (
        cd -P -- "./$root_link_name" || exit 1
        [ "$(pwd -P)" = "$root_link_parent_physical/$root_link_name" ] || exit 1
        root_link_nested_identity=$(directory_identity_for .) || exit 1
        [ ! -L "./$root_link_source_base" ] && [ -f "./$root_link_source_base" ] || exit 1
        [ "./$root_link_source_base" -ef "$root_link_source" ] || exit 1
        rm -f "./$root_link_source_base" || exit 1
        [ ! -e "./$root_link_source_base" ] && [ ! -L "./$root_link_source_base" ] || exit 1
        [ "$(directory_identity_for .)" = "$root_link_nested_identity" ] || exit 1
        require_current_root
      ) || exit 1
      exit 1
    fi
    [ ! -L "./$root_link_name" ] && [ -f "./$root_link_name" ] || exit 1
    [ "./$root_link_name" -ef "$root_link_source" ] || exit 1
    root_parent_identity_is_current "$root_link_parent_identity"
  ) || { transaction_cancel_critical_section; return 1; }
  require_current_root || { transaction_cancel_critical_section; return 1; }
  transaction_finish_critical_section
}

safe_root_remove_file() {
  root_remove_directory=$1
  root_remove_name=$2
  root_remove_reference=''
  root_remove_fingerprint=''
  root_remove_parent_expected_inode=''
  [ "$#" -lt 3 ] || root_remove_reference=$3
  [ "$#" -lt 4 ] || root_remove_fingerprint=$4
  [ "$#" -lt 5 ] || root_remove_parent_expected_inode=$5
  root_relative_path "$root_remove_directory" >/dev/null || return 1
  safe_leaf_name "$root_remove_name" || return 1
  if [ -n "$root_remove_reference" ]; then
    root_remove_source_parent=${root_remove_reference%/*}
    root_remove_source_base=${root_remove_reference##*/}
    [ "$root_remove_source_parent" != "$root_remove_reference" ] || return 1
    root_remove_source_parent=$(cd -P -- "$root_remove_source_parent" && pwd -P) || return 1
    case "$root_remove_source_parent" in
      "$INIT_ROOT_PHYSICAL") ;;
      "$INIT_ROOT_PHYSICAL"/*) ;;
      *) return 1 ;;
    esac
    root_remove_reference=$root_remove_source_parent/$root_remove_source_base
    [ ! -L "$root_remove_reference" ] && [ -f "$root_remove_reference" ] || return 1
  fi
  root_remove_relative_directory=${root_remove_directory#./}
  [ "$root_remove_directory" != . ] || root_remove_relative_directory=''
  # Removal is only reachable after the caller supplied immutable ownership
  # evidence.  It cannot introduce untracked state, so a pre-delete intent
  # would not improve rollback while it would extend the finalization window.
  (
    root_relative_directory_is_safe "$root_remove_relative_directory" || exit 1
    root_remove_parent_identity=$(directory_identity_for .) || exit 1
    if [ -n "$root_remove_parent_expected_inode" ]; then
      root_remove_actual_parent_inode=$(filesystem_inode_for .) || exit 1
      [ "$root_remove_actual_parent_inode" = "$root_remove_parent_expected_inode" ] || exit 1
    fi
    [ ! -L "$root_remove_name" ] && [ -f "$root_remove_name" ] || exit 1
    if [ -n "$root_remove_reference" ]; then
      owned_regular_file_matches "./$root_remove_name" "$root_remove_reference" "$root_remove_fingerprint" || exit 1
    fi
    rm -f "./$root_remove_name" || exit 1
    [ ! -e "./$root_remove_name" ] && [ ! -L "./$root_remove_name" ] || exit 1
    root_parent_identity_is_current "$root_remove_parent_identity"
  ) || return 1
  require_current_root
}

safe_root_create_empty_file() {
  root_create_directory=$1
  root_create_name=$2
  root_relative_path "$root_create_directory" >/dev/null || return 1
  safe_leaf_name "$root_create_name" || return 1
  root_create_relative_directory=${root_create_directory#./}
  [ "$root_create_directory" != . ] || root_create_relative_directory=''
  root_create_target=$root_create_directory/$root_create_name
  [ "$root_create_directory" != . ] || root_create_target=./$root_create_name
  root_create_fingerprint=$(printf '' | LC_ALL=C cksum) || return 1
  transaction_record_intent F "$root_create_target" '' "$root_create_fingerprint" || return 1
  transaction_begin_critical_section || return 1
  root_create_ownership=$(
  (
    root_relative_directory_is_safe "$root_create_relative_directory" || exit 1
    root_create_parent_identity=$(directory_identity_for .) || exit 1
    root_create_parent_inode=$(filesystem_inode_for .) || exit 1
    [ ! -e "$root_create_name" ] && [ ! -L "$root_create_name" ] || exit 1
    (set -C; : > "./$root_create_name") || exit 1
    [ ! -L "./$root_create_name" ] && [ -f "./$root_create_name" ] || exit 1
    root_create_inode=$(filesystem_inode_for "./$root_create_name") || exit 1
    root_parent_identity_is_current "$root_create_parent_identity"
    printf '%s\t%s\n' "$root_create_parent_inode" "$root_create_inode"
  )
  ) || { transaction_cancel_critical_section; return 1; }
  IFS=$'\t' read -r root_create_parent_inode root_create_inode <<EOF
$root_create_ownership
EOF
  require_current_root || { transaction_cancel_critical_section; return 1; }
  transaction_record_pending_file_ownership F "$root_create_target" "$root_create_parent_inode" "$root_create_inode" "$root_create_fingerprint" || { transaction_cancel_critical_section; return 1; }
  root_create_actual_fingerprint=$(file_fingerprint "$root_create_target") || { transaction_cancel_critical_section; return 1; }
  [ "$root_create_actual_fingerprint" = "$root_create_fingerprint" ] || { transaction_cancel_critical_section; return 1; }
  transaction_record_completed_file_intent F "$root_create_target" "$root_create_parent_inode" "$root_create_inode" "$root_create_actual_fingerprint" "$root_create_fingerprint" || { transaction_cancel_critical_section; return 1; }
  transaction_finish_critical_section
}

safe_root_write_new_file() {
  root_write_directory=$1
  root_write_name=$2
  root_write_contents=$3
  root_relative_path "$root_write_directory" >/dev/null || return 1
  safe_leaf_name "$root_write_name" || return 1
  root_write_relative_directory=${root_write_directory#./}
  [ "$root_write_directory" != . ] || root_write_relative_directory=''
  root_write_target=$root_write_directory/$root_write_name
  [ "$root_write_directory" != . ] || root_write_target=./$root_write_name
  root_write_fingerprint=$(printf '%s\n' "$root_write_contents" | LC_ALL=C cksum) || return 1
  transaction_record_intent W "$root_write_target" '' "$root_write_fingerprint" || return 1
  transaction_begin_critical_section || return 1
  root_write_ownership=$(
  (
    root_relative_directory_is_safe "$root_write_relative_directory" || exit 1
    root_write_parent_identity=$(directory_identity_for .) || exit 1
    root_write_parent_inode=$(filesystem_inode_for .) || exit 1
    [ ! -e "$root_write_name" ] && [ ! -L "$root_write_name" ] || exit 1
    (set -C; printf '%s\n' "$root_write_contents" > "./$root_write_name") || exit 1
    [ ! -L "./$root_write_name" ] && [ -f "./$root_write_name" ] || exit 1
    root_write_inode=$(filesystem_inode_for "./$root_write_name") || exit 1
    root_parent_identity_is_current "$root_write_parent_identity"
    printf '%s\t%s\n' "$root_write_parent_inode" "$root_write_inode"
  )
  ) || { transaction_cancel_critical_section; return 1; }
  IFS=$'\t' read -r root_write_parent_inode root_write_inode <<EOF
$root_write_ownership
EOF
  require_current_root || { transaction_cancel_critical_section; return 1; }
  transaction_record_pending_file_ownership W "$root_write_target" "$root_write_parent_inode" "$root_write_inode" "$root_write_fingerprint" || { transaction_cancel_critical_section; return 1; }
  root_write_actual_fingerprint=$(file_fingerprint "$root_write_target") || { transaction_cancel_critical_section; return 1; }
  [ "$root_write_actual_fingerprint" = "$root_write_fingerprint" ] || { transaction_cancel_critical_section; return 1; }
  transaction_record_completed_file_intent W "$root_write_target" "$root_write_parent_inode" "$root_write_inode" "$root_write_actual_fingerprint" "$root_write_fingerprint" || { transaction_cancel_critical_section; return 1; }
  transaction_finish_critical_section
}

split_internal_root_path() {
  case "$1" in
    .|./*) root_split_path=$1 ;;
    /*|..|../*|*/../*|*/..) return 1 ;;
    *) root_split_path=./$1 ;;
  esac
  root_relative_path "$root_split_path" >/dev/null || return 1
  root_split_relative=${root_split_path#./}
  case "$root_split_relative" in
    */*) ROOT_SPLIT_DIRECTORY=./${root_split_relative%/*}; ROOT_SPLIT_LEAF=${root_split_relative##*/} ;;
    *) ROOT_SPLIT_DIRECTORY=.; ROOT_SPLIT_LEAF=$root_split_relative ;;
  esac
  safe_leaf_name "$ROOT_SPLIT_LEAF"
}

safe_root_remove_path() {
  root_remove_path=$1
  root_remove_reference=$2
  root_remove_fingerprint=$3
  split_internal_root_path "$root_remove_path" || return 1
  safe_root_remove_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$root_remove_reference" "$root_remove_fingerprint"
}

safe_root_remove_snapshot_entry() {
  root_snapshot_directory=$1
  root_snapshot_name=$2
  root_snapshot_type=$3
  root_snapshot_expected=$4
  root_relative_path "$root_snapshot_directory" >/dev/null || return 1
  safe_leaf_name "$root_snapshot_name" || return 1
  root_snapshot_relative_directory=${root_snapshot_directory#./}
  [ "$root_snapshot_directory" != . ] || root_snapshot_relative_directory=''
  (
    root_relative_directory_is_safe "$root_snapshot_relative_directory" || exit 1
    root_snapshot_parent_identity=$(directory_identity_for .) || exit 1
    case "$root_snapshot_type" in
      R)
        [ ! -L "./$root_snapshot_name" ] && [ -f "./$root_snapshot_name" ] || exit 1
        root_snapshot_fingerprint=$(file_fingerprint "./$root_snapshot_name") || exit 1
        [ "$root_snapshot_fingerprint" = "$root_snapshot_expected" ] || exit 1
        ;;
      L)
        [ -L "./$root_snapshot_name" ] || exit 1
        root_snapshot_target=$(readlink "./$root_snapshot_name") || exit 1
        [ "$root_snapshot_target" = "$root_snapshot_expected" ] || exit 1
        ;;
      *) exit 1 ;;
    esac
    rm -f "./$root_snapshot_name" || exit 1
    [ ! -e "./$root_snapshot_name" ] && [ ! -L "./$root_snapshot_name" ] || exit 1
    root_parent_identity_is_current "$root_snapshot_parent_identity"
  ) || return 1
  require_current_root
}

safe_root_remove_owned_snapshot_file() {
  root_owned_directory=$1
  root_owned_name=$2
  root_owned_inode=$3
  root_owned_fingerprint=$4
  root_owned_parent_inode=''
  [ "$#" -lt 5 ] || root_owned_parent_inode=$5
  root_relative_path "$root_owned_directory" >/dev/null || return 1
  safe_leaf_name "$root_owned_name" || return 1
  root_owned_relative_directory=${root_owned_directory#./}
  [ "$root_owned_directory" != . ] || root_owned_relative_directory=''
  (
    root_relative_directory_is_safe "$root_owned_relative_directory" || exit 1
    root_owned_parent_identity=$(directory_identity_for .) || exit 1
    if [ -n "$root_owned_parent_inode" ]; then
      root_owned_actual_parent_inode=$(filesystem_inode_for .) || exit 1
      [ "$root_owned_actual_parent_inode" = "$root_owned_parent_inode" ] || exit 1
    fi
    [ ! -L "./$root_owned_name" ] && [ -f "./$root_owned_name" ] || exit 1
    root_owned_actual_inode=$(filesystem_inode_for "./$root_owned_name") || exit 1
    [ "$root_owned_actual_inode" = "$root_owned_inode" ] || exit 1
    root_owned_actual_fingerprint=$(file_fingerprint "./$root_owned_name") || exit 1
    [ "$root_owned_actual_fingerprint" = "$root_owned_fingerprint" ] || exit 1
    rm -f "./$root_owned_name" || exit 1
    [ ! -e "./$root_owned_name" ] && [ ! -L "./$root_owned_name" ] || exit 1
    root_parent_identity_is_current "$root_owned_parent_identity"
  ) || return 1
  require_current_root
}

safe_root_rmdir() {
  root_rmdir_directory=$1
  root_rmdir_name=$2
  root_relative_path "$root_rmdir_directory" >/dev/null || return 1
  safe_leaf_name "$root_rmdir_name" || return 1
  root_rmdir_relative_directory=${root_rmdir_directory#./}
  [ "$root_rmdir_directory" != . ] || root_rmdir_relative_directory=''
  (
    root_relative_directory_is_safe "$root_rmdir_relative_directory" || exit 1
    root_rmdir_parent_identity=$(directory_identity_for .) || exit 1
    [ -d "./$root_rmdir_name" ] && [ ! -L "./$root_rmdir_name" ] || exit 1
    rmdir "./$root_rmdir_name" || exit 1
    [ ! -e "./$root_rmdir_name" ] && [ ! -L "./$root_rmdir_name" ] || exit 1
    root_parent_identity_is_current "$root_rmdir_parent_identity"
  ) || return 1
  require_current_root
}

safe_root_rmdir_owned_snapshot() {
  root_owned_directory=$1
  root_owned_name=$2
  root_owned_inode=$3
  root_relative_path "$root_owned_directory" >/dev/null || return 1
  safe_leaf_name "$root_owned_name" || return 1
  root_owned_relative_directory=${root_owned_directory#./}
  [ "$root_owned_directory" != . ] || root_owned_relative_directory=''
  (
    root_relative_directory_is_safe "$root_owned_relative_directory" || exit 1
    root_owned_parent_identity=$(directory_identity_for .) || exit 1
    [ -d "./$root_owned_name" ] && [ ! -L "./$root_owned_name" ] || exit 1
    root_owned_actual_inode=$(filesystem_inode_for "./$root_owned_name") || exit 1
    [ "$root_owned_actual_inode" = "$root_owned_inode" ] || exit 1
    rmdir "./$root_owned_name" || exit 1
    [ ! -e "./$root_owned_name" ] && [ ! -L "./$root_owned_name" ] || exit 1
    root_parent_identity_is_current "$root_owned_parent_identity"
  ) || return 1
  require_current_root
}

git_root_for() {
  safe_git -C "$1" rev-parse --show-toplevel 2>/dev/null
}

git_identity_for() {
  git_identity_root=$1
  git_identity_path=$(safe_git -C "$git_identity_root" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  [ -d "$git_identity_path" ] || return 1
  git_identity_path=$(resolve_directory "$git_identity_path") || return 1
  git_identity_inode=$(LC_ALL=C ls -di "$git_identity_path" | sed 's/[[:space:]].*$//') || return 1
  [ -n "$git_identity_inode" ] || return 1
  printf '%s\n' "$git_identity_path:$git_identity_inode"
}

file_fingerprint() {
  [ ! -L "$1" ] && [ -f "$1" ] || return 1
  LC_ALL=C cksum < "$1"
}

plan_fingerprint() {
  safe_git hash-object --stdin
}

path_plan_state() {
  if [ -L "$1" ]; then
    printf '%s\n' SYMLINK
  elif [ -f "$1" ]; then
    printf 'FILE:%s\n' "$(file_fingerprint "$1")"
  elif [ -d "$1" ]; then
    printf 'DIRECTORY:%s\n' "$(directory_identity_for "$1")"
  elif [ -e "$1" ]; then
    printf '%s\n' OTHER
  else
    printf '%s\n' MISSING
  fi
}

validate_plan_fingerprint_option() {
  [ -n "$1" ] || { fail '--plan-fingerprint requires a value.'; return 1; }
  reject_line_breaks "$1" 'plan fingerprint' || return 1
  printf '%s\n' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]+$' || {
    fail '--plan-fingerprint must be the hexadecimal value printed by the reviewed plan.'
    return 1
  }
}

filesystem_inode_for() {
  [ ! -L "$1" ] && [ -e "$1" ] || return 1
  filesystem_inode=$(LC_ALL=C ls -di "$1" | sed 's/[[:space:]].*$//') || return 1
  [ -n "$filesystem_inode" ] || return 1
  printf '%s\n' "$filesystem_inode"
}

tree_snapshot() {
  snapshot_directory=$1
  [ -d "$snapshot_directory" ] && [ ! -L "$snapshot_directory" ] || return 1
  {
    LC_ALL=C find "$snapshot_directory" -print | LC_ALL=C sort | while IFS= read -r snapshot_entry || [ -n "$snapshot_entry" ]; do
      reject_line_breaks "$snapshot_entry" 'initialization ownership path' || return 1
      snapshot_relative=${snapshot_entry#"$snapshot_directory"}
      [ "$snapshot_relative" != "$snapshot_entry" ] || return 1
      [ -n "$snapshot_relative" ] || snapshot_relative=.
      if [ -L "$snapshot_entry" ]; then
        snapshot_target=$(readlink "$snapshot_entry") || return 1
        reject_line_breaks "$snapshot_target" 'initialization ownership link target' || return 1
        printf 'L\t%s\t%s\n' "$snapshot_relative" "$snapshot_target"
      elif [ -f "$snapshot_entry" ]; then
        snapshot_fingerprint=$(file_fingerprint "$snapshot_entry") || return 1
        printf 'R\t%s\t%s\n' "$snapshot_relative" "$snapshot_fingerprint"
      elif [ -d "$snapshot_entry" ]; then
        printf 'D\t%s\t-\n' "$snapshot_relative"
      else
        fail 'could not prove initialization ownership for a special filesystem entry.'
        return 1
      fi
    done
  } | LC_ALL=C sort
}

tree_snapshot_matches() {
  snapshot_directory=$1
  snapshot_expected=$2
  snapshot_actual=$(tree_snapshot "$snapshot_directory") || return 1
  [ "$snapshot_actual" = "$snapshot_expected" ]
}

# The ordinary tree snapshot is intentionally portable and content-oriented.
# Once the Git ownership marker is removed, rollback also needs the inode of
# every owned entry: a same-content replacement must remain external content.
tree_ownership_snapshot() {
  ownership_directory=$1
  [ -d "$ownership_directory" ] && [ ! -L "$ownership_directory" ] || return 1
  {
    LC_ALL=C find "$ownership_directory" -print | LC_ALL=C sort | while IFS= read -r ownership_entry || [ -n "$ownership_entry" ]; do
      reject_line_breaks "$ownership_entry" 'initialization ownership path' || return 1
      ownership_relative=${ownership_entry#"$ownership_directory"}
      [ "$ownership_relative" != "$ownership_entry" ] || return 1
      [ -n "$ownership_relative" ] || ownership_relative=.
      if [ -L "$ownership_entry" ]; then
        # Pristine Git metadata never needs symbolic links.  Treating one as
        # owned would make a post-finalization rollback less auditable.
        return 1
      elif [ -f "$ownership_entry" ]; then
        ownership_inode=$(filesystem_inode_for "$ownership_entry") || return 1
        ownership_fingerprint=$(file_fingerprint "$ownership_entry") || return 1
        printf 'R\t%s\t%s\t%s\n' "$ownership_relative" "$ownership_inode" "$ownership_fingerprint"
      elif [ -d "$ownership_entry" ]; then
        ownership_inode=$(filesystem_inode_for "$ownership_entry") || return 1
        printf 'D\t%s\t%s\t-\n' "$ownership_relative" "$ownership_inode"
      else
        fail 'could not prove initialization ownership for a special filesystem entry.'
        return 1
      fi
    done
  } | LC_ALL=C sort
}

tree_ownership_snapshot_matches() {
  ownership_directory=$1
  ownership_expected=$2
  ownership_actual=$(tree_ownership_snapshot "$ownership_directory") || return 1
  [ "$ownership_actual" = "$ownership_expected" ]
}

tree_ownership_snapshot_without_entry() {
  ownership_source=$1
  ownership_removed_relative=$2
  while IFS=$'\t' read -r ownership_type ownership_relative ownership_inode ownership_fingerprint || [ -n "$ownership_type" ]; do
    [ "$ownership_relative" = "$ownership_removed_relative" ] && continue
    printf '%s\t%s\t%s\t%s\n' "$ownership_type" "$ownership_relative" "$ownership_inode" "$ownership_fingerprint"
  done <<EOF
$ownership_source
EOF
}

tree_snapshot_entry_matches() {
  snapshot_directory=$1
  snapshot_type=$2
  snapshot_relative=$3
  snapshot_expected=$4
  snapshot_entry=$snapshot_directory
  [ "$snapshot_relative" = . ] || snapshot_entry=$(printf '%s/%s' "$snapshot_directory" "${snapshot_relative#/}")
  case "$snapshot_type" in
    R)
      snapshot_actual=$(file_fingerprint "$snapshot_entry") || return 1
      [ "$snapshot_actual" = "$snapshot_expected" ]
      ;;
    L)
      [ -L "$snapshot_entry" ] || return 1
      snapshot_actual=$(readlink "$snapshot_entry") || return 1
      [ "$snapshot_actual" = "$snapshot_expected" ]
      ;;
    D) [ -d "$snapshot_entry" ] && [ ! -L "$snapshot_entry" ] ;;
    *) return 1 ;;
  esac
}

tree_snapshot_without_entry() {
  snapshot_source=$1
  snapshot_removed_relative=$2
  while IFS=$'\t' read -r snapshot_type snapshot_relative snapshot_expected || [ -n "$snapshot_type" ]; do
    [ "$snapshot_relative" = "$snapshot_removed_relative" ] && continue
    printf '%s\t%s\t%s\n' "$snapshot_type" "$snapshot_relative" "$snapshot_expected"
  done <<EOF
$snapshot_source
EOF
}

tree_snapshot_with_regular_entry() {
  snapshot_source=$1
  snapshot_relative=$2
  snapshot_fingerprint=$3
  {
    printf '%s\n' "$snapshot_source"
    printf 'R\t%s\t%s\n' "$snapshot_relative" "$snapshot_fingerprint"
  } | LC_ALL=C sort
}

tree_snapshot_with_entry() {
  snapshot_source=$1
  snapshot_type=$2
  snapshot_relative=$3
  snapshot_expected=$4
  {
    [ -z "$snapshot_source" ] || printf '%s\n' "$snapshot_source"
    printf '%s\t%s\t%s\n' "$snapshot_type" "$snapshot_relative" "$snapshot_expected"
  } | LC_ALL=C sort
}

verify_snapshot_root() {
  snapshot_root=$1
  snapshot_physical=$(resolve_directory "$snapshot_root") || {
    fail 'invalid Canonical Superteam YAML: Root Repository cannot be resolved.'
    return 1
  }
  snapshot_git_root=$(git_root_for "$snapshot_physical" 2>/dev/null || true)
  [ -n "$snapshot_git_root" ] || {
    fail 'invalid Canonical Superteam YAML: Root Repository is not a Git repository.'
    return 1
  }
  snapshot_git_physical=$(resolve_directory "$snapshot_git_root") || {
    fail 'invalid Canonical Superteam YAML: Root Repository cannot be resolved.'
    return 1
  }
  [ "$snapshot_git_physical" = "$snapshot_physical" ] || {
    fail 'invalid Canonical Superteam YAML: Root Repository changed during Snapshot.'
    return 1
  }
}

directory_is_empty() {
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$1/.superteam-project.lock" ] && continue
    return 1
  done
  return 0
}

next_path_component() {
  NEXT_COMPONENT=$(printf '%s\n' "$1" | sed 's,/.*,,')
  case "$1" in
    */*) NEXT_REMAINING=$(printf '%s\n' "$1" | sed 's,^[^/]*/,,') ;;
    *) NEXT_REMAINING='' ;;
  esac
}

validate_asset_path() {
  value=$1
  label=$2
  reject_line_breaks "$value" "$label path" || return 1
  case "$value" in
    ''|/*|~*|*/|*//*) fail "$label path must be a non-empty relative directory inside the Root Repository."; return 1 ;;
  esac
  remaining=$value
  while :; do
    next_path_component "$remaining"
    asset_component_lower=$(printf '%s' "$NEXT_COMPONENT" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$asset_component_lower" in
      '.') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '..') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.git') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.superteam-project.lock') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.superteam-project-probe') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.superteam-project-probe-owner') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.superteam-project-owner') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      '.superteam-project-stage') fail "$label path must not contain reserved or traversal components."; return 1 ;;
      .superteam-project-stage.*) fail "$label path must not contain reserved or traversal components."; return 1 ;;
    esac
    remaining=$NEXT_REMAINING
    [ -n "$remaining" ] || break
  done
}

asset_path_crosses_independent_git_root() {
  root=$1
  relative=$2
  label=$3
  canonical=false
  [ "$#" -lt 4 ] || canonical=$4
  comparison_root=$root
  if [ "$INIT_ROOT_ANCHORED" = true ] && [ "$root" = . ]; then
    comparison_root=$INIT_ROOT_PHYSICAL
  fi
  remaining=$relative
  current=$root
  while :; do
    next_path_component "$remaining"
    current=$current/$NEXT_COMPONENT
    if [ -d "$current" ]; then
      physical=$(cd -P -- "$current" && pwd -P) || {
        if [ "$canonical" = true ]; then
          fail "invalid Canonical Superteam YAML: $label directory must not be inside an independent Git Repository."
        else
          fail "$label path must not be inside an independent Git Repository."
        fi
        return 1
      }
      candidate_root=$(git_root_for "$physical" 2>/dev/null || true)
      if [ -n "$candidate_root" ] && [ "$candidate_root" != "$comparison_root" ]; then
        if [ "$canonical" = true ]; then
          fail "invalid Canonical Superteam YAML: $label directory must not be inside an independent Git Repository."
        else
          fail "$label path must not be inside an independent Git Repository."
        fi
        return 1
      fi
    fi
    remaining=$NEXT_REMAINING
    [ -n "$remaining" ] || break
  done
}

asset_path_has_symlink() {
  root=$1
  remaining=$2
  label=$3
  current=$root
  while :; do
    next_path_component "$remaining"
    current=$current/$NEXT_COMPONENT
    if [ -L "$current" ]; then
      fail "$label path traverses a symbolic link."
      return 0
    fi
    remaining=$NEXT_REMAINING
    [ -n "$remaining" ] || break
  done
  return 1
}

check_asset_destination() {
  root=$1
  relative=$2
  label=$3
  adopt=$4
  destination=$root/$relative
  validate_asset_ancestors "$root" "$relative" "$label" || return 1
  asset_path_has_symlink "$root" "$relative" "$label" && return 1
  asset_path_crosses_independent_git_root "$root" "$relative" "$label" || return 1
  if [ -e "$destination" ]; then
    [ -d "$destination" ] || { fail "$label path already exists and is not a directory: $relative"; return 1; }
    [ "$adopt" = true ] || { fail "$label path already exists; pass --adopt-$label after confirming that directory."; return 1; }
  fi
}

validate_asset_ancestors() {
  root=$1
  remaining=$2
  label=$3
  prefix=''
  [ "$#" -lt 4 ] || prefix=$4
  current=$root
  while :; do
    next_path_component "$remaining"
    current=$current/$NEXT_COMPONENT
    if [ -L "$current" ]; then
      if [ "$prefix" = true ]; then
        case "$label" in
          task) fail 'invalid Canonical Superteam YAML: task path traverses a symbolic link.' ;;
          knowledge) fail 'invalid Canonical Superteam YAML: knowledge path traverses a symbolic link.' ;;
        esac
      else
        fail "$label path traverses a symbolic link."
      fi
      return 1
    fi
    if [ -e "$current" ] && [ ! -d "$current" ]; then
      if [ "$prefix" = true ]; then
        case "$label" in
          task) fail 'invalid Canonical Superteam YAML: task path has a non-directory ancestor.' ;;
          knowledge) fail 'invalid Canonical Superteam YAML: knowledge path has a non-directory ancestor.' ;;
        esac
      else
        fail "$label path has a non-directory ancestor."
      fi
      return 1
    fi
    remaining=$NEXT_REMAINING
    [ -n "$remaining" ] || break
  done
}

validate_snapshot_asset() {
  root=$1
  relative=$2
  label=$3
  destination=$root/$relative
  snapshot_comparison_root=$root
  if [ "$INIT_ROOT_ANCHORED" = true ] && [ "$root" = . ]; then
    snapshot_comparison_root=$INIT_ROOT_PHYSICAL
  fi
  validate_asset_ancestors "$root" "$relative" "$label" true || return 1
  if [ ! -d "$destination" ]; then
    fail "invalid Canonical Superteam YAML: $label directory is missing or is not a directory."
    return 1
  fi
  physical=$(cd -P -- "$destination" && pwd -P) || {
    fail "invalid Canonical Superteam YAML: $label directory cannot be resolved."
    return 1
  }
  case "$physical" in
    "$snapshot_comparison_root"/*) ;;
    *)
      fail "invalid Canonical Superteam YAML: $label directory resolves outside the Root Repository."
      return 1
      ;;
  esac
  asset_path_crosses_independent_git_root "$root" "$relative" "$label" true || return 1
}

yaml_quote() {
  YAML_QUOTED=$(printf '%s' "$1" | sed 's/[\\"]/\\&/g; 1s/^/"/; $s/$/"/')
}

parse_yaml_value() {
  input=$1
  YAML_VALUE=$(printf '%s\n' "$input" | awk '
    {
      quote = sprintf("%c", 34)
      slash = sprintf("%c", 92)
      if (substr($0, 1, 1) != quote || substr($0, length($0), 1) != quote) exit 1
      body = substr($0, 2, length($0) - 2)
      output = ""
      for (position = 1; position <= length(body); position++) {
        character = substr(body, position, 1)
        if (character == slash) {
          position++
          if (position > length(body)) exit 1
          escaped = substr(body, position, 1)
          if (escaped != slash && escaped != quote) exit 1
          output = output escaped
        } else {
          if (character == quote) exit 1
          output = output character
        }
      }
      print output
    }') || return 1
  yaml_quote "$YAML_VALUE"
  [ "$YAML_QUOTED" = "$input" ]
}

manifest_has_no_nul_bytes() {
  if LC_ALL=C tr -d '\n\r\t' < "$1" | LC_ALL=C grep -a '[[:cntrl:]]' >/dev/null; then
    return 1
  fi
}

validate_repository_id() {
  repository_id=$1
  reject_line_breaks "$repository_id" 'repository ID' || return 1
  [ "$repository_id" != root ] || { fail 'repository ID root is reserved.'; return 1; }
  printf '%s\n' "$repository_id" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]*$' || {
    fail 'repository ID must start with a lowercase letter or digit and contain only lowercase letters, digits, dots, underscores, or hyphens.'
    return 1
  }
}

validate_manifest_repository_path() {
  repository_path=$1
  reject_line_breaks "$repository_path" 'repository path' || return 1
  case "$repository_path" in
    ''|.|/*|~*|*/|*//*|./*|*/./*|*/.)
      fail 'invalid Canonical Superteam YAML: repository path must be a normalized Root-relative path.'
      return 1
      ;;
  esac
  repository_remaining=$repository_path
  repository_seen_name=false
  while :; do
    next_path_component "$repository_remaining"
    case "$NEXT_COMPONENT" in
      ''|.) fail 'invalid Canonical Superteam YAML: repository path is not normalized.'; return 1 ;;
      ..)
        [ "$repository_seen_name" = false ] || {
          fail 'invalid Canonical Superteam YAML: repository path contains non-leading traversal.'
          return 1
        }
        ;;
      *) repository_seen_name=true ;;
    esac
    repository_remaining=$NEXT_REMAINING
    [ -n "$repository_remaining" ] || break
  done
  [ "$repository_seen_name" = true ] || {
    fail 'invalid Canonical Superteam YAML: repository path must not resolve to the Root Repository.'
    return 1
  }
}

render_manifest() {
  yaml_quote "$MANIFEST_TASK"
  rendered_task=$YAML_QUOTED
  yaml_quote "$MANIFEST_KNOWLEDGE"
  rendered_knowledge=$YAML_QUOTED
  printf '%s\n' 'version: 1' 'paths:' "  task: $rendered_task" "  knowledge: $rendered_knowledge"
  if [ "${#MANIFEST_REPOSITORY_IDS[@]}" -gt 0 ]; then
    printf '%s\n' 'repositories:'
    rendered_index=0
    while [ "$rendered_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
      yaml_quote "${MANIFEST_REPOSITORY_IDS[$rendered_index]}"
      rendered_id=$YAML_QUOTED
      yaml_quote "${MANIFEST_REPOSITORY_PATHS[$rendered_index]}"
      rendered_path=$YAML_QUOTED
      printf '%s\n' "  - id: $rendered_id" "    path: $rendered_path"
      rendered_index=$((rendered_index + 1))
    done
  fi
}

parse_manifest() {
  root=$1
  manifest=$root/superteam.yaml
  MANIFEST_TASK=''
  MANIFEST_KNOWLEDGE=''
  MANIFEST_REPOSITORY_IDS=()
  MANIFEST_REPOSITORY_PATHS=()
  verify_snapshot_root "$root" || return 1
  [ ! -L "$manifest" ] && [ -f "$manifest" ] || { fail 'invalid Canonical Superteam YAML: superteam.yaml must be a regular file.'; return 1; }
  manifest_has_no_nul_bytes "$manifest" || { fail 'invalid Canonical Superteam YAML: superteam.yaml contains a NUL byte.'; return 1; }
  manifest_lines=()
  while IFS= read -r line || [ -n "$line" ]; do
    manifest_lines[${#manifest_lines[@]}]=$line
  done < "$manifest"
  newline_count=$(wc -l < "$manifest" | tr -d ' ')
  [ "$newline_count" -eq "${#manifest_lines[@]}" ] || { fail 'invalid Canonical Superteam YAML: every canonical line must end with a newline.'; return 1; }
  [ "${#manifest_lines[@]}" -ge 4 ] || { fail 'invalid Canonical Superteam YAML: expected at least four canonical lines.'; return 1; }
  [ "${manifest_lines[0]}" = 'version: 1' ] && [ "${manifest_lines[1]}" = 'paths:' ] || { fail 'invalid Canonical Superteam YAML: expected version and paths keys.'; return 1; }
  case "${manifest_lines[2]}" in
    '  task: '*) task_value=${manifest_lines[2]#'  task: '} ;;
    *) fail 'invalid Canonical Superteam YAML: expected a task path.'; return 1 ;;
  esac
  parse_yaml_value "$task_value" || { fail 'invalid Canonical Superteam YAML: task must use a canonical quoted scalar.'; return 1; }
  MANIFEST_TASK=$YAML_VALUE
  case "${manifest_lines[3]}" in
    '  knowledge: '*) knowledge_value=${manifest_lines[3]#'  knowledge: '} ;;
    *) fail 'invalid Canonical Superteam YAML: expected a knowledge path.'; return 1 ;;
  esac
  parse_yaml_value "$knowledge_value" || { fail 'invalid Canonical Superteam YAML: knowledge must use a canonical quoted scalar.'; return 1; }
  MANIFEST_KNOWLEDGE=$YAML_VALUE

  if [ "${#manifest_lines[@]}" -gt 4 ]; then
    [ "${manifest_lines[4]}" = repositories: ] || { fail 'invalid Canonical Superteam YAML: expected repositories key after paths.'; return 1; }
    repository_line_index=5
    [ $(( (${#manifest_lines[@]} - 5) % 2 )) -eq 0 ] || { fail 'invalid Canonical Superteam YAML: each repository requires id and path lines.'; return 1; }
    while [ "$repository_line_index" -lt "${#manifest_lines[@]}" ]; do
      repository_id_line=${manifest_lines[$repository_line_index]}
      repository_path_line=${manifest_lines[$((repository_line_index + 1))]}
      case "$repository_id_line" in
        '  - id: '*) repository_id_value=${repository_id_line#'  - id: '} ;;
        *) fail 'invalid Canonical Superteam YAML: expected a repository id.'; return 1 ;;
      esac
      parse_yaml_value "$repository_id_value" || { fail 'invalid Canonical Superteam YAML: repository id must use a canonical quoted scalar.'; return 1; }
      repository_parsed_id=$YAML_VALUE
      validate_repository_id "$repository_parsed_id" || { fail 'invalid Canonical Superteam YAML: repository id is invalid.'; return 1; }
      case "$repository_path_line" in
        '    path: '*) repository_path_value=${repository_path_line#'    path: '} ;;
        *) fail 'invalid Canonical Superteam YAML: expected a repository path.'; return 1 ;;
      esac
      parse_yaml_value "$repository_path_value" || { fail 'invalid Canonical Superteam YAML: repository path must use a canonical quoted scalar.'; return 1; }
      repository_parsed_path=$YAML_VALUE
      validate_manifest_repository_path "$repository_parsed_path" || return 1
      repository_existing_index=0
      while [ "$repository_existing_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
        [ "${MANIFEST_REPOSITORY_IDS[$repository_existing_index]}" != "$repository_parsed_id" ] || { fail 'invalid Canonical Superteam YAML: repository IDs must be unique.'; return 1; }
        [ "${MANIFEST_REPOSITORY_PATHS[$repository_existing_index]}" != "$repository_parsed_path" ] || { fail 'invalid Canonical Superteam YAML: repository paths must be unique.'; return 1; }
        repository_existing_index=$((repository_existing_index + 1))
      done
      MANIFEST_REPOSITORY_IDS[${#MANIFEST_REPOSITORY_IDS[@]}]=$repository_parsed_id
      MANIFEST_REPOSITORY_PATHS[${#MANIFEST_REPOSITORY_PATHS[@]}]=$repository_parsed_path
      repository_line_index=$((repository_line_index + 2))
    done
  fi

  validate_asset_path "$MANIFEST_TASK" task || { fail 'invalid Canonical Superteam YAML: task path is unsafe.'; return 1; }
  validate_asset_path "$MANIFEST_KNOWLEDGE" knowledge || { fail 'invalid Canonical Superteam YAML: knowledge path is unsafe.'; return 1; }
  [ "$MANIFEST_TASK" != "$MANIFEST_KNOWLEDGE" ] || { fail 'invalid Canonical Superteam YAML: task and knowledge paths must differ.'; return 1; }
  case "$MANIFEST_TASK" in "$MANIFEST_KNOWLEDGE"/*) fail 'invalid Canonical Superteam YAML: paths must not be nested.'; return 1 ;; esac
  case "$MANIFEST_KNOWLEDGE" in "$MANIFEST_TASK"/*) fail 'invalid Canonical Superteam YAML: paths must not be nested.'; return 1 ;; esac
  validate_snapshot_asset "$root" "$MANIFEST_TASK" task || return 1
  validate_snapshot_asset "$root" "$MANIFEST_KNOWLEDGE" knowledge || return 1
  expected=$(render_manifest)
  actual=$(cat "$manifest")
  [ "$actual" = "$expected" ] || { fail 'invalid Canonical Superteam YAML: input is not normalized.'; return 1; }
}

repository_path_from_root() {
  repository_relative_root=$1
  repository_relative_target=$2
  repository_from_parts=()
  repository_to_parts=()
  IFS=/ read -r -a repository_from_parts <<< "${repository_relative_root#/}"
  IFS=/ read -r -a repository_to_parts <<< "${repository_relative_target#/}"
  repository_common=0
  while [ "$repository_common" -lt "${#repository_from_parts[@]}" ] &&
        [ "$repository_common" -lt "${#repository_to_parts[@]}" ] &&
        [ "${repository_from_parts[$repository_common]}" = "${repository_to_parts[$repository_common]}" ]; do
    repository_common=$((repository_common + 1))
  done
  repository_relative=''
  repository_index=$repository_common
  while [ "$repository_index" -lt "${#repository_from_parts[@]}" ]; do
    if [ -n "$repository_relative" ]; then repository_relative=$repository_relative/..; else repository_relative=..; fi
    repository_index=$((repository_index + 1))
  done
  repository_index=$repository_common
  while [ "$repository_index" -lt "${#repository_to_parts[@]}" ]; do
    if [ -n "$repository_relative" ]; then
      repository_relative=$repository_relative/${repository_to_parts[$repository_index]}
    else
      repository_relative=${repository_to_parts[$repository_index]}
    fi
    repository_index=$((repository_index + 1))
  done
  [ -n "$repository_relative" ] || return 1
  printf '%s\n' "$repository_relative"
}

resolve_repository_input() {
  repository_input_root=$1
  repository_input=$2
  reject_line_breaks "$repository_input" 'repository path' || return 1
  case "$repository_input" in
    '') fail 'repository path must not be empty.'; return 1 ;;
    \~) repository_expanded=${HOME:-} ;;
    \~/*)
      [ -n "${HOME:-}" ] || { fail 'HOME is required to expand a repository path beginning with ~/.'; return 1; }
      repository_expanded=$HOME/${repository_input#\~/}
      ;;
    \~*) fail 'repository path supports only ~ or ~/ expansion, not named-user expansion.'; return 1 ;;
    /*) repository_expanded=$repository_input ;;
    *) repository_expanded=$repository_input_root/$repository_input ;;
  esac
  REPOSITORY_REAL_PATH=$(resolve_directory "$repository_expanded") || return 1
  repository_detected_root=$(git_root_for "$REPOSITORY_REAL_PATH" 2>/dev/null || true)
  [ -n "$repository_detected_root" ] || { fail "repository path is not inside a Git repository: $repository_input"; return 1; }
  repository_detected_root=$(resolve_directory "$repository_detected_root") || return 1
  [ "$repository_detected_root" = "$REPOSITORY_REAL_PATH" ] || {
    fail "repository path must resolve to the Git root itself: $repository_input"
    return 1
  }
  REPOSITORY_GIT_IDENTITY=$(git_identity_for "$REPOSITORY_REAL_PATH") || {
    fail 'could not identify the repository Git directory.'
    return 1
  }
}

resolve_manifest_repository() {
  repository_manifest_root=$1
  repository_manifest_path=$2
  repository_manifest_candidate=$repository_manifest_root/$repository_manifest_path
  if [ ! -d "$repository_manifest_candidate" ]; then
    REPOSITORY_STATE=MISSING
    REPOSITORY_STATE_PATH=''
    return 0
  fi
  REPOSITORY_STATE_PATH=$(resolve_directory "$repository_manifest_candidate" 2>/dev/null || true)
  if [ -z "$REPOSITORY_STATE_PATH" ]; then
    REPOSITORY_STATE=MISMATCH
    return 0
  fi
  if ! git_toplevel_state "$REPOSITORY_STATE_PATH"; then
    REPOSITORY_STATE=ERROR
    return 0
  fi
  if [ "$GIT_TOPLEVEL_STATE" = NONE ]; then
    REPOSITORY_STATE=MISMATCH
    return 0
  fi
  repository_manifest_git_root=$GIT_TOPLEVEL
  reject_line_breaks "$repository_manifest_git_root" 'Git root' >/dev/null 2>&1 || {
    REPOSITORY_STATE=ERROR
    return 0
  }
  repository_manifest_git_root=$(resolve_directory "$repository_manifest_git_root" 2>/dev/null || true)
  if [ -z "$repository_manifest_git_root" ]; then
    REPOSITORY_STATE=ERROR
    return 0
  fi
  if [ "$repository_manifest_git_root" != "$REPOSITORY_STATE_PATH" ]; then
    REPOSITORY_STATE=MISMATCH
    return 0
  fi
  REPOSITORY_STATE=MATCH
}

validate_registered_repository_roots() {
  repository_validation_root=$1
  repository_excluded_id=${2:-}
  repository_seen_paths=$repository_validation_root
  repository_validation_index=0
  while [ "$repository_validation_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    repository_validation_id=${MANIFEST_REPOSITORY_IDS[$repository_validation_index]}
    repository_validation_path=${MANIFEST_REPOSITORY_PATHS[$repository_validation_index]}
    repository_validation_index=$((repository_validation_index + 1))
    [ "$repository_validation_id" != "$repository_excluded_id" ] || continue
    resolve_manifest_repository "$repository_validation_root" "$repository_validation_path"
    [ "$REPOSITORY_STATE" = MATCH ] || {
      fail "registered repository $repository_validation_id has a missing or mismatched Git root: $repository_validation_path"
      return 1
    }
    if printf '%s\n' "$repository_seen_paths" | LC_ALL=C grep -Fqx -- "$REPOSITORY_STATE_PATH"; then
      fail "registered repository $repository_validation_id resolves to a duplicate Git root."
      return 1
    fi
    repository_seen_paths=$(printf '%s\n%s' "$repository_seen_paths" "$REPOSITORY_STATE_PATH")
  done
}

repository_is_inside_root() {
  case "$2" in "$1"/*) return 0 ;; *) return 1 ;; esac
}

repository_is_submodule() {
  repository_submodule_root=$1
  repository_submodule_path=$2
  repository_submodule_real=$3
  repository_superproject=$(safe_git -C "$repository_submodule_real" rev-parse --show-superproject-working-tree 2>/dev/null || true)
  [ -n "$repository_superproject" ] || return 1
  repository_superproject=$(resolve_directory "$repository_superproject" 2>/dev/null || true)
  [ "$repository_superproject" = "$repository_submodule_root" ] || return 1
  safe_git --literal-pathspecs -C "$repository_submodule_root" \
    ls-files --stage -- "$repository_submodule_path" | \
    LC_ALL=C grep -Eq '^160000 [0-9a-f]+ [0-9]+[[:space:]]'
}

repository_is_ignored() {
  safe_git --no-optional-locks -C "$1" check-ignore -q --no-index -- "$2"
}

managed_ignore_marker() {
  printf '%s\n' "# superteam-managed repository: $1"
}

managed_ignore_no_newline_marker() {
  printf '%s\n' "# superteam-managed repository: $1; previous-eof=no-newline"
}

managed_ignore_empty_file_marker() {
  printf '%s\n' "# superteam-managed repository: $1; previous-file=empty"
}

managed_ignore_rule() {
  gitignore_escape_path "$1" || return 1
  printf '/%s/\n' "$GITIGNORE_ESCAPED"
}

managed_ignore_pair_exists() {
  repository_ignore_file=$1
  repository_ignore_marker=$2
  repository_ignore_rule=$3
  [ ! -L "$repository_ignore_file" ] && [ -f "$repository_ignore_file" ] || return 1
  LC_ALL=C awk -v marker="$repository_ignore_marker" -v rule="$repository_ignore_rule" '
    previous == marker && $0 == rule { found = 1 }
    { previous = $0 }
    END { exit(found ? 0 : 1) }
  ' "$repository_ignore_file"
}

managed_ignore_marker_exists() {
  [ ! -L "$1" ] && [ -f "$1" ] || return 1
  LC_ALL=C grep -Fqx -- "$2" "$1"
}

stage_repository_ignore() {
  repository_ignore_stage=$1
  case "$REPOSITORY_IGNORE_ACTION" in
    UNCHANGED) return 0 ;;
    ADD)
      if [ -e "$REPOSITORY_WRITE_ROOT/.gitignore" ] || [ -L "$REPOSITORY_WRITE_ROOT/.gitignore" ]; then
        [ ! -L "$REPOSITORY_WRITE_ROOT/.gitignore" ] && [ -f "$REPOSITORY_WRITE_ROOT/.gitignore" ] || {
          fail '.gitignore must be a regular file before a managed repository rule can be added.'
          return 1
        }
        cp -p -- "$REPOSITORY_WRITE_ROOT/.gitignore" "$repository_ignore_stage" || return 1
        if [ -s "$repository_ignore_stage" ] && [ "$(tail -c 1 "$repository_ignore_stage" | wc -l | tr -d ' ')" -eq 0 ]; then
          printf '\n' >> "$repository_ignore_stage" || return 1
        fi
      else
        : > "$repository_ignore_stage" || return 1
      fi
      printf '%s\n%s\n' "$REPOSITORY_IGNORE_MARKER" "$REPOSITORY_IGNORE_RULE" >> "$repository_ignore_stage"
      ;;
    REMOVE)
      [ ! -L "$REPOSITORY_WRITE_ROOT/.gitignore" ] && [ -f "$REPOSITORY_WRITE_ROOT/.gitignore" ] || return 1
      cp -p -- "$REPOSITORY_WRITE_ROOT/.gitignore" "$repository_ignore_stage" || return 1
      LC_ALL=C awk -v marker="$REPOSITORY_IGNORE_MARKER" -v rule="$REPOSITORY_IGNORE_RULE" '
        pending {
          if ($0 == rule) { pending = 0; next }
          print marker
          pending = 0
        }
        $0 == marker { pending = 1; next }
        { print }
        END { if (pending) print marker }
      ' "$REPOSITORY_WRITE_ROOT/.gitignore" > "$repository_ignore_stage.output" || return 1
      cat "$repository_ignore_stage.output" > "$repository_ignore_stage" || return 1
      rm -- "$repository_ignore_stage.output" || return 1
      if [ "$REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE" = true ]; then
        repository_ignore_size=$(wc -c < "$repository_ignore_stage" | tr -d ' ') || return 1
        [ "$repository_ignore_size" -gt 0 ] || return 1
        dd if="$repository_ignore_stage" of="$repository_ignore_stage.output" bs=1 count=$((repository_ignore_size - 1)) 2>/dev/null || return 1
        cat "$repository_ignore_stage.output" > "$repository_ignore_stage" || return 1
        rm -- "$repository_ignore_stage.output" || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

cleanup_repository_write_lock() {
  [ -n "$REPOSITORY_WRITE_LOCK" ] || return 0
  for repository_lock_entry in "$REPOSITORY_WRITE_LOCK"/* "$REPOSITORY_WRITE_LOCK"/.[!.]* "$REPOSITORY_WRITE_LOCK"/..?*; do
    [ -e "$repository_lock_entry" ] || [ -L "$repository_lock_entry" ] || continue
    [ -f "$repository_lock_entry" ] && [ ! -L "$repository_lock_entry" ] || return 1
    rm -- "$repository_lock_entry" || return 1
  done
  rmdir -- "$REPOSITORY_WRITE_LOCK" || return 1
  REPOSITORY_WRITE_LOCK=''
}

rollback_repository_write() {
  if [ "$REPOSITORY_WRITE_MANIFEST_INSTALLED" = true ]; then
    cp -p -- "$REPOSITORY_WRITE_LOCK/manifest.old" "$REPOSITORY_WRITE_ROOT/superteam.yaml" || return 1
    REPOSITORY_WRITE_MANIFEST_INSTALLED=false
  fi
  if [ "$REPOSITORY_WRITE_IGNORE_INSTALLED" = true ]; then
    if [ -f "$REPOSITORY_WRITE_LOCK/ignore.old" ]; then
      cp -p -- "$REPOSITORY_WRITE_LOCK/ignore.old" "$REPOSITORY_WRITE_ROOT/.gitignore" || return 1
    else
      rm -f -- "$REPOSITORY_WRITE_ROOT/.gitignore" || return 1
    fi
    REPOSITORY_WRITE_IGNORE_INSTALLED=false
  fi
}

abort_repository_write() {
  repository_abort_status=$1
  trap - EXIT HUP INT TERM
  rollback_repository_write || true
  cleanup_repository_write_lock || true
  exit "$repository_abort_status"
}

acquire_repository_write_lock() {
  REPOSITORY_WRITE_ROOT=$1
  REPOSITORY_WRITE_LOCK=$REPOSITORY_WRITE_ROOT/.superteam-project.lock
  REPOSITORY_WRITE_MANIFEST_INSTALLED=false
  REPOSITORY_WRITE_IGNORE_INSTALLED=false
  if ! mkdir -- "$REPOSITORY_WRITE_LOCK" 2>/dev/null; then
    fail 'another Project write is in progress; retry after it completes.'
    REPOSITORY_WRITE_LOCK=''
    return 1
  fi
  [ -d "$REPOSITORY_WRITE_LOCK" ] && [ ! -L "$REPOSITORY_WRITE_LOCK" ] || return 1
  trap 'abort_repository_write 1' EXIT
  trap 'abort_repository_write 129' HUP
  trap 'abort_repository_write 130' INT
  trap 'abort_repository_write 143' TERM
}

apply_repository_files() {
  repository_desired_manifest=$1
  cp -p -- "$REPOSITORY_WRITE_ROOT/superteam.yaml" "$REPOSITORY_WRITE_LOCK/manifest.old" || return 1
  cp -p -- "$REPOSITORY_WRITE_ROOT/superteam.yaml" "$REPOSITORY_WRITE_LOCK/manifest.new" || return 1
  printf '%s\n' "$repository_desired_manifest" > "$REPOSITORY_WRITE_LOCK/manifest.new" || return 1
  if [ -e "$REPOSITORY_WRITE_ROOT/.gitignore" ] || [ -L "$REPOSITORY_WRITE_ROOT/.gitignore" ]; then
    [ ! -L "$REPOSITORY_WRITE_ROOT/.gitignore" ] && [ -f "$REPOSITORY_WRITE_ROOT/.gitignore" ] || {
      fail '.gitignore must be a regular file for a managed repository update.'
      return 1
    }
    cp -p -- "$REPOSITORY_WRITE_ROOT/.gitignore" "$REPOSITORY_WRITE_LOCK/ignore.old" || return 1
  fi
  if [ "$REPOSITORY_IGNORE_ACTION" != UNCHANGED ]; then
    stage_repository_ignore "$REPOSITORY_WRITE_LOCK/ignore.new" || return 1
    if [ "$REPOSITORY_IGNORE_ACTION" = REMOVE ] && [ ! -s "$REPOSITORY_WRITE_LOCK/ignore.new" ] && [ "$REPOSITORY_IGNORE_PREVIOUS_EMPTY" = false ]; then
      rm -- "$REPOSITORY_WRITE_ROOT/.gitignore" || return 1
    else
      mv -- "$REPOSITORY_WRITE_LOCK/ignore.new" "$REPOSITORY_WRITE_ROOT/.gitignore" || return 1
    fi
    REPOSITORY_WRITE_IGNORE_INSTALLED=true
  fi
  mv -- "$REPOSITORY_WRITE_LOCK/manifest.new" "$REPOSITORY_WRITE_ROOT/superteam.yaml" || {
    rollback_repository_write || true
    fail 'could not atomically install the Repository Set manifest.'
    return 1
  }
  REPOSITORY_WRITE_MANIFEST_INSTALLED=true
  REPOSITORY_WRITE_MANIFEST_INSTALLED=false
  REPOSITORY_WRITE_IGNORE_INSTALLED=false
  trap - EXIT HUP INT TERM
  cleanup_repository_write_lock || {
    fail 'Repository Set was updated but its write lock could not be removed.'
    return 1
  }
}

resolve_repository_command_root() {
  repository_command_location=$(resolve_directory "$1") || return 1
  REPOSITORY_ROOT=$(git_root_for "$repository_command_location" 2>/dev/null || true)
  [ -n "$REPOSITORY_ROOT" ] || { fail "repository $2 requires an initialized Root Repository."; return 1; }
  REPOSITORY_ROOT=$(resolve_directory "$REPOSITORY_ROOT") || return 1
}
capture_repository_plan_state() {
  REPOSITORY_DESIRED_MANIFEST=$(render_manifest)
  REPOSITORY_MANIFEST_FINGERPRINT=$(file_fingerprint "$REPOSITORY_ROOT/superteam.yaml") || return 1
  REPOSITORY_ROOT_IDENTITY=$(directory_identity_for "$REPOSITORY_ROOT") || return 1
  REPOSITORY_IGNORE_PLAN_STATE=$(path_plan_state "$REPOSITORY_ROOT/.gitignore") || return 1
}
preflight_repository_add() {
  repository_add_directory=$1
  repository_add_id=$2
  repository_add_input=$3
  resolve_repository_command_root "$repository_add_directory" add || return 1
  [ -e "$REPOSITORY_ROOT/superteam.yaml" ] || { fail 'Project is not initialized; run superteam-project init first.'; return 1; }
  parse_manifest "$REPOSITORY_ROOT" || return 1
  validate_registered_repository_roots "$REPOSITORY_ROOT" || return 1
  validate_repository_id "$repository_add_id" || return 1
  repository_add_index=0
  while [ "$repository_add_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    [ "${MANIFEST_REPOSITORY_IDS[$repository_add_index]}" != "$repository_add_id" ] || { fail "repository ID is already registered: $repository_add_id"; return 1; }
    repository_add_index=$((repository_add_index + 1))
  done
  resolve_repository_input "$REPOSITORY_ROOT" "$repository_add_input" || return 1
  [ "$REPOSITORY_REAL_PATH" != "$REPOSITORY_ROOT" ] || { fail 'the Root Repository is already present as repository ID root.'; return 1; }
  repository_add_index=0
  while [ "$repository_add_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    resolve_manifest_repository "$REPOSITORY_ROOT" "${MANIFEST_REPOSITORY_PATHS[$repository_add_index]}"
    [ "$REPOSITORY_STATE_PATH" != "$REPOSITORY_REAL_PATH" ] || { fail "Git root is already registered as ${MANIFEST_REPOSITORY_IDS[$repository_add_index]}."; return 1; }
    repository_add_index=$((repository_add_index + 1))
  done
  REPOSITORY_MANIFEST_PATH=$(repository_path_from_root "$REPOSITORY_ROOT" "$REPOSITORY_REAL_PATH") || {
    fail 'could not normalize the repository path relative to the Root Repository.'
    return 1
  }
  validate_manifest_repository_path "$REPOSITORY_MANIFEST_PATH" || return 1
  REPOSITORY_TOPOLOGY=EXTERNAL
  REPOSITORY_IGNORE_ACTION=UNCHANGED
  REPOSITORY_IGNORE_STATE=NONE
  REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE=false
  REPOSITORY_IGNORE_PREVIOUS_EMPTY=false
  REPOSITORY_IGNORE_MARKER=$(managed_ignore_marker "$repository_add_id")
  REPOSITORY_IGNORE_RULE=''
  if repository_is_inside_root "$REPOSITORY_ROOT" "$REPOSITORY_REAL_PATH"; then
    if repository_is_submodule "$REPOSITORY_ROOT" "$REPOSITORY_MANIFEST_PATH" "$REPOSITORY_REAL_PATH"; then
      REPOSITORY_TOPOLOGY=SUBMODULE
    else
      REPOSITORY_TOPOLOGY=NESTED
      if repository_is_ignored "$REPOSITORY_ROOT" "$REPOSITORY_MANIFEST_PATH"; then
        REPOSITORY_IGNORE_STATE=EXISTING
      else
        if [ -e "$REPOSITORY_ROOT/.gitignore" ] || [ -L "$REPOSITORY_ROOT/.gitignore" ]; then
          [ ! -L "$REPOSITORY_ROOT/.gitignore" ] && [ -f "$REPOSITORY_ROOT/.gitignore" ] || { fail '.gitignore must be a regular file before adding a managed ignore rule.'; return 1; }
          repository_no_eof_marker=$(managed_ignore_no_newline_marker "$repository_add_id")
          repository_empty_file_marker=$(managed_ignore_empty_file_marker "$repository_add_id")
          for repository_existing_marker in "$REPOSITORY_IGNORE_MARKER" "$repository_no_eof_marker" "$repository_empty_file_marker"; do
            managed_ignore_marker_exists "$REPOSITORY_ROOT/.gitignore" "$repository_existing_marker" && { fail 'the managed .gitignore marker already exists without a matching repository binding.'; return 1; }
          done
          if [ ! -s "$REPOSITORY_ROOT/.gitignore" ]; then
            REPOSITORY_IGNORE_PREVIOUS_EMPTY=true
            REPOSITORY_IGNORE_MARKER=$repository_empty_file_marker
          elif [ "$(tail -c 1 "$REPOSITORY_ROOT/.gitignore" | wc -l | tr -d ' ')" -eq 0 ]; then
            REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE=true
            REPOSITORY_IGNORE_MARKER=$repository_no_eof_marker
          fi
        fi
        REPOSITORY_IGNORE_ACTION=ADD
        REPOSITORY_IGNORE_STATE=MANAGED
        REPOSITORY_IGNORE_RULE=$(managed_ignore_rule "$REPOSITORY_MANIFEST_PATH") || return 1
      fi
    fi
  fi
  MANIFEST_REPOSITORY_IDS[${#MANIFEST_REPOSITORY_IDS[@]}]=$repository_add_id
  MANIFEST_REPOSITORY_PATHS[${#MANIFEST_REPOSITORY_PATHS[@]}]=$REPOSITORY_MANIFEST_PATH
  capture_repository_plan_state || return 1
  prepare_repository_add_plan "$repository_add_id" "$repository_add_input" || return 1
}

render_repository_add_plan_body() {
  printf '%s\n' 'ACTION: REPOSITORY_ADD'
  printf '%s\n' "ROOT: $REPOSITORY_ROOT"
  printf '%s\n' "ID: $1"
  printf '%s\n' "INPUT_PATH: $2"
  printf '%s\n' "REAL_GIT_ROOT: $REPOSITORY_REAL_PATH"
  printf '%s\n' "MANIFEST_PATH: $REPOSITORY_MANIFEST_PATH"
  printf '%s\n' "TOPOLOGY: $REPOSITORY_TOPOLOGY"
  case "$REPOSITORY_IGNORE_STATE" in
    MANAGED) printf '%s\n' "MANAGED_IGNORE: $REPOSITORY_MANIFEST_PATH" ;;
    EXISTING) printf '%s\n' 'IGNORE: EXISTING' ;;
    NONE) printf '%s\n' 'IGNORE: NONE' ;;
  esac
}

prepare_repository_add_plan() {
  REPOSITORY_PLAN_BODY=$(render_repository_add_plan_body "$1" "$2") || return 1
  REPOSITORY_PLAN_FINGERPRINT=$({
    printf '%s\n' "$REPOSITORY_PLAN_BODY"
    printf 'ROOT_IDENTITY:%s\n' "$REPOSITORY_ROOT_IDENTITY"
    printf 'MANIFEST_FINGERPRINT:%s\n' "$REPOSITORY_MANIFEST_FINGERPRINT"
    printf 'REPOSITORY_GIT_IDENTITY:%s\n' "$REPOSITORY_GIT_IDENTITY"
    printf 'IGNORE_STATE:%s\n' "$REPOSITORY_IGNORE_PLAN_STATE"
  } | plan_fingerprint) || return 1
}

print_repository_add_plan() {
  printf '%s\n' "$REPOSITORY_PLAN_BODY"
  printf '%s\n' "PLAN_FINGERPRINT: $REPOSITORY_PLAN_FINGERPRINT"
  [ "$1" = true ] || printf '%s\n' "NEXT: Re-run with --apply --plan-fingerprint $REPOSITORY_PLAN_FINGERPRINT to update the Repository Set."
}

repository_add() {
  repository_add_directory=.
  repository_add_directory_seen=false
  repository_add_id=''
  repository_add_path=''
  repository_add_apply=false
  REPOSITORY_EXPECTED_PLAN_FINGERPRINT=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) [ "$#" -ge 2 ] || { fail '--id requires a value.'; return 1; }; repository_add_id=$2; shift 2 ;;
      --path) [ "$#" -ge 2 ] || { fail '--path requires a value.'; return 1; }; repository_add_path=$2; shift 2 ;;
      --plan-fingerprint) [ "$#" -ge 2 ] || { fail '--plan-fingerprint requires a value.'; return 1; }; REPOSITORY_EXPECTED_PLAN_FINGERPRINT=$2; shift 2 ;;
      --apply) repository_add_apply=true; shift ;;
      --*) fail "unknown option: $1"; return 1 ;;
      *) [ "$repository_add_directory_seen" = false ] || { fail 'only one target directory may be supplied.'; return 1; }; repository_add_directory=$1; repository_add_directory_seen=true; shift ;;
    esac
  done
  [ -n "$repository_add_id" ] || { fail '--id is required.'; return 1; }
  [ -n "$repository_add_path" ] || { fail '--path is required.'; return 1; }
  if [ "$repository_add_apply" = true ]; then
    validate_plan_fingerprint_option "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" || return 1
  elif [ -n "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" ]; then
    fail '--plan-fingerprint is only accepted together with --apply.'
    return 1
  fi
  preflight_repository_add "$repository_add_directory" "$repository_add_id" "$repository_add_path" || return 1
  print_repository_add_plan "$repository_add_apply"
  [ "$repository_add_apply" = true ] || return 0
  [ "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" = "$REPOSITORY_PLAN_FINGERPRINT" ] || {
    fail 'the reviewed Repository Set plan no longer matches the current target; no files were applied.'
    return 1
  }
  repository_expected_root=$REPOSITORY_ROOT
  repository_expected_root_identity=$REPOSITORY_ROOT_IDENTITY
  repository_expected_manifest_fingerprint=$REPOSITORY_MANIFEST_FINGERPRINT
  repository_expected_real=$REPOSITORY_REAL_PATH
  repository_expected_git_identity=$REPOSITORY_GIT_IDENTITY
  acquire_repository_write_lock "$REPOSITORY_ROOT" || return 1
  if ! preflight_repository_add "$repository_add_directory" "$repository_add_id" "$repository_add_path" ||
     [ "$REPOSITORY_PLAN_FINGERPRINT" != "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" ] ||
     [ "$REPOSITORY_ROOT" != "$repository_expected_root" ] ||
     [ "$REPOSITORY_ROOT_IDENTITY" != "$repository_expected_root_identity" ] ||
     [ "$REPOSITORY_MANIFEST_FINGERPRINT" != "$repository_expected_manifest_fingerprint" ] ||
     [ "$REPOSITORY_REAL_PATH" != "$repository_expected_real" ] ||
     [ "$REPOSITORY_GIT_IDENTITY" != "$repository_expected_git_identity" ]; then
    fail 'Repository Set changed after the plan; no files were applied.'
    trap - EXIT HUP INT TERM
    cleanup_repository_write_lock || true
    return 1
  fi
  apply_repository_files "$REPOSITORY_DESIRED_MANIFEST" || return 1
  printf '%s\n' 'RESULT: REPOSITORY_ADDED'
  printf '%s\n' "REPOSITORY: $repository_add_id"
  printf '%s\n' "PATH: $REPOSITORY_MANIFEST_PATH"
  printf '%s\n' 'GIT_DATA: UNCHANGED'
}

preflight_repository_remove() {
  repository_remove_directory=$1
  repository_remove_id=$2
  resolve_repository_command_root "$repository_remove_directory" remove || return 1
  parse_manifest "$REPOSITORY_ROOT" || return 1
  validate_repository_id "$repository_remove_id" || return 1
  repository_remove_found=false
  repository_remove_index=0
  repository_remaining_ids=()
  repository_remaining_paths=()
  while [ "$repository_remove_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    if [ "${MANIFEST_REPOSITORY_IDS[$repository_remove_index]}" = "$repository_remove_id" ]; then
      repository_remove_found=true
      REPOSITORY_MANIFEST_PATH=${MANIFEST_REPOSITORY_PATHS[$repository_remove_index]}
    else
      repository_remaining_ids[${#repository_remaining_ids[@]}]=${MANIFEST_REPOSITORY_IDS[$repository_remove_index]}
      repository_remaining_paths[${#repository_remaining_paths[@]}]=${MANIFEST_REPOSITORY_PATHS[$repository_remove_index]}
    fi
    repository_remove_index=$((repository_remove_index + 1))
  done
  [ "$repository_remove_found" = true ] || { fail "repository ID is not registered: $repository_remove_id"; return 1; }
  validate_registered_repository_roots "$REPOSITORY_ROOT" "$repository_remove_id" || return 1
  resolve_manifest_repository "$REPOSITORY_ROOT" "$REPOSITORY_MANIFEST_PATH"
  REPOSITORY_REMOVE_REAL_STATE=$REPOSITORY_STATE
  REPOSITORY_REMOVE_REAL_PATH=$REPOSITORY_STATE_PATH
  if [ "$REPOSITORY_REMOVE_REAL_STATE" = MATCH ]; then
    REPOSITORY_REMOVE_GIT_IDENTITY=$(git_identity_for "$REPOSITORY_REMOVE_REAL_PATH") || {
      fail 'could not identify the registered repository Git directory.'
      return 1
    }
  else
    REPOSITORY_REMOVE_GIT_IDENTITY=$REPOSITORY_REMOVE_REAL_STATE
  fi
  REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE=false
  REPOSITORY_IGNORE_PREVIOUS_EMPTY=false
  REPOSITORY_IGNORE_MARKER=$(managed_ignore_marker "$repository_remove_id")
  REPOSITORY_IGNORE_RULE=$(managed_ignore_rule "$REPOSITORY_MANIFEST_PATH") || return 1
  REPOSITORY_IGNORE_ACTION=UNCHANGED
  if managed_ignore_pair_exists "$REPOSITORY_ROOT/.gitignore" "$REPOSITORY_IGNORE_MARKER" "$REPOSITORY_IGNORE_RULE"; then
    REPOSITORY_IGNORE_ACTION=REMOVE
  else
    repository_no_eof_marker=$(managed_ignore_no_newline_marker "$repository_remove_id")
    if managed_ignore_pair_exists "$REPOSITORY_ROOT/.gitignore" "$repository_no_eof_marker" "$REPOSITORY_IGNORE_RULE"; then
      REPOSITORY_IGNORE_MARKER=$repository_no_eof_marker
      REPOSITORY_IGNORE_PREVIOUS_NO_NEWLINE=true
      REPOSITORY_IGNORE_ACTION=REMOVE
    else
      repository_empty_file_marker=$(managed_ignore_empty_file_marker "$repository_remove_id")
      if managed_ignore_pair_exists "$REPOSITORY_ROOT/.gitignore" "$repository_empty_file_marker" "$REPOSITORY_IGNORE_RULE"; then
        REPOSITORY_IGNORE_MARKER=$repository_empty_file_marker
        REPOSITORY_IGNORE_PREVIOUS_EMPTY=true
        REPOSITORY_IGNORE_ACTION=REMOVE
      fi
    fi
  fi
  MANIFEST_REPOSITORY_IDS=()
  MANIFEST_REPOSITORY_PATHS=()
  repository_remaining_index=0
  while [ "$repository_remaining_index" -lt "${#repository_remaining_ids[@]}" ]; do
    MANIFEST_REPOSITORY_IDS[${#MANIFEST_REPOSITORY_IDS[@]}]=${repository_remaining_ids[$repository_remaining_index]}
    MANIFEST_REPOSITORY_PATHS[${#MANIFEST_REPOSITORY_PATHS[@]}]=${repository_remaining_paths[$repository_remaining_index]}
    repository_remaining_index=$((repository_remaining_index + 1))
  done
  capture_repository_plan_state || return 1
  prepare_repository_remove_plan "$repository_remove_id" || return 1
}

render_repository_remove_plan_body() {
  printf '%s\n' 'ACTION: REPOSITORY_REMOVE'
  printf '%s\n' "ROOT: $REPOSITORY_ROOT"
  printf '%s\n' "ID: $1"
  printf '%s\n' "MANIFEST_PATH: $REPOSITORY_MANIFEST_PATH"
  if [ "$REPOSITORY_REMOVE_REAL_STATE" = MATCH ]; then
    printf '%s\n' "REAL_GIT_ROOT: $REPOSITORY_REMOVE_REAL_PATH"
  else
    printf '%s\n' "REAL_GIT_ROOT: $REPOSITORY_REMOVE_REAL_STATE"
  fi
  [ "$REPOSITORY_IGNORE_ACTION" != REMOVE ] || printf '%s\n' "REMOVE_MANAGED_IGNORE: $REPOSITORY_MANIFEST_PATH"
  printf '%s\n' 'GIT_DATA: UNCHANGED'
}

prepare_repository_remove_plan() {
  REPOSITORY_PLAN_BODY=$(render_repository_remove_plan_body "$1") || return 1
  REPOSITORY_PLAN_FINGERPRINT=$({
    printf '%s\n' "$REPOSITORY_PLAN_BODY"
    printf 'ROOT_IDENTITY:%s\n' "$REPOSITORY_ROOT_IDENTITY"
    printf 'MANIFEST_FINGERPRINT:%s\n' "$REPOSITORY_MANIFEST_FINGERPRINT"
    printf 'REPOSITORY_GIT_IDENTITY:%s\n' "$REPOSITORY_REMOVE_GIT_IDENTITY"
    printf 'IGNORE_STATE:%s\n' "$REPOSITORY_IGNORE_PLAN_STATE"
  } | plan_fingerprint) || return 1
}

print_repository_remove_plan() {
  printf '%s\n' "$REPOSITORY_PLAN_BODY"
  printf '%s\n' "PLAN_FINGERPRINT: $REPOSITORY_PLAN_FINGERPRINT"
  [ "$1" = true ] || printf '%s\n' "NEXT: Re-run with --apply --plan-fingerprint $REPOSITORY_PLAN_FINGERPRINT to update the Repository Set."
}

repository_remove() {
  repository_remove_directory=.
  repository_remove_directory_seen=false
  repository_remove_id=''
  repository_remove_apply=false
  REPOSITORY_EXPECTED_PLAN_FINGERPRINT=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) [ "$#" -ge 2 ] || { fail '--id requires a value.'; return 1; }; repository_remove_id=$2; shift 2 ;;
      --plan-fingerprint) [ "$#" -ge 2 ] || { fail '--plan-fingerprint requires a value.'; return 1; }; REPOSITORY_EXPECTED_PLAN_FINGERPRINT=$2; shift 2 ;;
      --apply) repository_remove_apply=true; shift ;;
      --*) fail "unknown option: $1"; return 1 ;;
      *) [ "$repository_remove_directory_seen" = false ] || { fail 'only one target directory may be supplied.'; return 1; }; repository_remove_directory=$1; repository_remove_directory_seen=true; shift ;;
    esac
  done
  [ -n "$repository_remove_id" ] || { fail '--id is required.'; return 1; }
  if [ "$repository_remove_apply" = true ]; then
    validate_plan_fingerprint_option "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" || return 1
  elif [ -n "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" ]; then
    fail '--plan-fingerprint is only accepted together with --apply.'
    return 1
  fi
  preflight_repository_remove "$repository_remove_directory" "$repository_remove_id" || return 1
  print_repository_remove_plan "$repository_remove_apply"
  [ "$repository_remove_apply" = true ] || return 0
  [ "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" = "$REPOSITORY_PLAN_FINGERPRINT" ] || {
    fail 'the reviewed Repository Set plan no longer matches the current target; no files were applied.'
    return 1
  }
  repository_expected_root=$REPOSITORY_ROOT
  repository_expected_root_identity=$REPOSITORY_ROOT_IDENTITY
  repository_expected_manifest_fingerprint=$REPOSITORY_MANIFEST_FINGERPRINT
  acquire_repository_write_lock "$REPOSITORY_ROOT" || return 1
  if ! preflight_repository_remove "$repository_remove_directory" "$repository_remove_id" ||
     [ "$REPOSITORY_PLAN_FINGERPRINT" != "$REPOSITORY_EXPECTED_PLAN_FINGERPRINT" ] ||
     [ "$REPOSITORY_ROOT" != "$repository_expected_root" ] ||
     [ "$REPOSITORY_ROOT_IDENTITY" != "$repository_expected_root_identity" ] ||
     [ "$REPOSITORY_MANIFEST_FINGERPRINT" != "$repository_expected_manifest_fingerprint" ]; then
    fail 'Repository Set changed after the plan; no files were applied.'
    trap - EXIT HUP INT TERM
    cleanup_repository_write_lock || true
    return 1
  fi
  apply_repository_files "$REPOSITORY_DESIRED_MANIFEST" || return 1
  printf '%s\n' 'RESULT: REPOSITORY_REMOVED'
  printf '%s\n' "REPOSITORY: $repository_remove_id"
  printf '%s\n' 'GIT_DATA: UNCHANGED'
}

repository_command() {
  repository_action=${1:-}
  [ -n "$repository_action" ] || { fail 'repository requires add or remove.'; return 1; }
  shift
  case "$repository_action" in
    add) repository_add "$@" ;;
    remove) repository_remove "$@" ;;
    *) fail "unknown repository action: $repository_action"; return 1 ;;
  esac
}

print_uninitialized() {
  location=$1
  root=''
  [ "$#" -gt 1 ] && root=$2
  printf '%s\n' 'STATUS: UNINITIALIZED'
  if [ -n "$root" ]; then
    printf '%s\n' "ROOT: $root"
    printf '%s\n' 'NEXT: Run superteam-project init to create a tracked project manifest.'
  else
    printf '%s\n' "DIRECTORY: $location"
    printf '%s\n' 'NEXT: Run superteam-project init to review and create a root repository.'
  fi
}

print_snapshot() {
  printf '%s\n' 'STATUS: CONFIGURED'
  printf '%s\n' "ROOT: $1"
  printf '%s\n' 'REPOSITORY: root'
  printf '%s\n' "TASK: $1/$2"
  printf '%s\n' "KNOWLEDGE: $1/$3"
  printf '%s\n' "MANIFEST_TRACKING: $(asset_tracking_state "$1" superteam.yaml)"
  printf '%s\n' "TASK_TRACKING: $(asset_tracking_state "$1" "$2")"
  printf '%s\n' "KNOWLEDGE_TRACKING: $(asset_tracking_state "$1" "$3")"
}

print_repository_git_facts() {
  repository_fact_id=$1
  repository_fact_path=$2
  repository_fact_real=$3
  repository_fact_header=$4
  [ "$repository_fact_header" != true ] || printf '%s\n' "REPOSITORY: $repository_fact_id"
  printf '%s\n' "REPOSITORY_PATH: $repository_fact_path"
  printf '%s\n' "REAL_PATH: $repository_fact_real"
  printf '%s\n' 'GIT_ROOT: MATCH'
  if repository_fact_head=$(safe_git -C "$repository_fact_real" rev-parse --verify HEAD 2>/dev/null); then
    printf '%s\n' "HEAD: $repository_fact_head"
  else
    printf '%s\n' 'HEAD: UNBORN'
  fi
  if repository_fact_branch=$(safe_git -C "$repository_fact_real" symbolic-ref --quiet --short HEAD 2>/dev/null); then
    printf '%s\n' "BRANCH: $repository_fact_branch"
  else
    printf '%s\n' 'BRANCH: DETACHED'
  fi
  if repository_fact_upstream=$(safe_git -C "$repository_fact_real" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    printf '%s\n' "UPSTREAM: $repository_fact_upstream"
  else
    printf '%s\n' 'UPSTREAM: NONE'
  fi
  if ! repository_fact_worktree=$(git_worktree_state "$repository_fact_real"); then
    printf '%s\n' 'WORKTREE: ERROR'
    return 1
  fi
  printf '%s\n' "WORKTREE: $repository_fact_worktree"
}

print_repository_set_status() {
  repository_status_root=$1
  repository_status_failed=false
  print_repository_git_facts root . "$repository_status_root" false || repository_status_failed=true
  repository_status_seen=$repository_status_root
  repository_status_index=0
  while [ "$repository_status_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    repository_status_id=${MANIFEST_REPOSITORY_IDS[$repository_status_index]}
    repository_status_path=${MANIFEST_REPOSITORY_PATHS[$repository_status_index]}
    repository_status_index=$((repository_status_index + 1))
    resolve_manifest_repository "$repository_status_root" "$repository_status_path"
    if [ "$REPOSITORY_STATE" != MATCH ]; then
      printf '%s\n' "REPOSITORY: $repository_status_id"
      printf '%s\n' "REPOSITORY_PATH: $repository_status_path"
      if [ "$REPOSITORY_STATE" = MISSING ]; then printf '%s\n' 'REAL_PATH: MISSING'; else printf '%s\n' "REAL_PATH: ${REPOSITORY_STATE_PATH:-UNRESOLVED}"; fi
      printf '%s\n' "GIT_ROOT: $REPOSITORY_STATE"
      [ "$REPOSITORY_STATE" != ERROR ] || repository_status_failed=true
      continue
    fi
    if printf '%s\n' "$repository_status_seen" | LC_ALL=C grep -Fqx -- "$REPOSITORY_STATE_PATH"; then
      printf '%s\n' "REPOSITORY: $repository_status_id"
      printf '%s\n' "REPOSITORY_PATH: $repository_status_path"
      printf '%s\n' "REAL_PATH: $REPOSITORY_STATE_PATH"
      printf '%s\n' 'GIT_ROOT: DUPLICATE'
      continue
    fi
    repository_status_seen=$(printf '%s\n%s' "$repository_status_seen" "$REPOSITORY_STATE_PATH")
    print_repository_git_facts "$repository_status_id" "$repository_status_path" "$REPOSITORY_STATE_PATH" true || repository_status_failed=true
  done
  [ "$repository_status_failed" = false ]
}

asset_tracking_state() {
  root=$1
  relative=$2
  tracking_status=0
  if ! safe_git --literal-pathspecs -C "$root" \
      ls-files --error-unmatch -- "$relative" >/dev/null 2>&1; then
    printf '%s\n' UNTRACKED
    return 0
  fi
  if safe_git --literal-pathspecs -C "$root" \
      diff --cached --quiet -- "$relative"; then
    :
  else
    tracking_status=$?
    [ "$tracking_status" -eq 1 ] || return "$tracking_status"
    printf '%s\n' STAGED
    return 0
  fi
  if safe_git --literal-pathspecs -C "$root" \
      diff --quiet -- "$relative"; then
    printf '%s\n' COMMITTED
  else
    tracking_status=$?
    [ "$tracking_status" -eq 1 ] || return "$tracking_status"
    printf '%s\n' UNCOMMITTED
  fi
}

project_git_root_state() {
  local directory=$1 label=${2:-path} resolved
  PROJECT_GIT_ROOT_STATE=ERROR
  PROJECT_GIT_ROOT=''
  if ! git_toplevel_state "$directory"; then
    fail "Git could not inspect the $label; repair the local Git command or repository metadata and retry."
    return 1
  fi
  if [ "$GIT_TOPLEVEL_STATE" = NONE ]; then
    PROJECT_GIT_ROOT_STATE=NONE
    return 0
  fi
  reject_line_breaks "$GIT_TOPLEVEL" 'Git root' || return 1
  resolved=$(resolve_directory "$GIT_TOPLEVEL") || {
    fail "Git returned an unavailable root while inspecting the $label."
    return 1
  }
  PROJECT_GIT_ROOT_STATE=ROOT
  PROJECT_GIT_ROOT=$resolved
}

direct_child_directories() {
  local directory=$1 entry
  {
    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
      [ ! -L "$entry" ] || continue
      [ -e "$entry" ] || continue
      [ -d "$entry" ] || continue
      case "${entry##*/}" in .git|.superteam-project.*) continue ;; esac
      reject_line_breaks "$entry" 'candidate path' >/dev/null 2>&1 || continue
      printf '%s\n' "$entry"
    done
  } | LC_ALL=C sort
}

inspect_root_is_configured() {
  local candidate=$1 configured
  [ "${INSPECT_CONFIGURED_ROOTS_COUNT:-0}" -gt 0 ] || return 1
  for configured in "${INSPECT_CONFIGURED_ROOTS[@]}"; do
    [ "$candidate" != "$configured" ] || return 0
  done
  return 1
}

inspect_candidates() {
  local directory=$1 entry physical
  while IFS= read -r entry || [ -n "$entry" ]; do
    physical=$(cd -P -- "$entry" && pwd -P) || {
      fail 'a direct child candidate could not be resolved safely.'
      return 1
    }
    case "$physical" in
      "$directory"/*) ;;
      *) fail 'a direct child candidate resolved outside the inspected directory.'; return 1 ;;
    esac
    project_git_root_state "$physical" 'direct child candidate' || return 1
    if [ "$PROJECT_GIT_ROOT_STATE" = ROOT ] &&
        [ "$PROJECT_GIT_ROOT" = "$physical" ] &&
        ! inspect_root_is_configured "$physical"; then
      printf '%s\n' "CANDIDATE_ROOT: $physical"
    fi
  done < <(direct_child_directories "$directory")
}

inspect_asset_candidate() {
  local root=$1 label=$2 candidate suffix=2
  candidate=$label
  while [ -e "$root/$candidate" ] || [ -L "$root/$candidate" ]; do
    candidate=$label-$suffix
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$root/$candidate"
}

print_inspect_candidates() {
  local root=$1 task_candidate knowledge_candidate
  task_candidate=$(inspect_asset_candidate "$root" task) || return 1
  knowledge_candidate=$(inspect_asset_candidate "$root" knowledge) || return 1
  printf '%s\n' "TASK_CANDIDATE: $task_candidate"
  printf '%s\n' "KNOWLEDGE_CANDIDATE: $knowledge_candidate"
  inspect_candidates "$root"
}

print_unconfigured_manifest() {
  local root=$1 manifest=$1/superteam.yaml
  if [ -L "$manifest" ]; then
    printf '%s\n' 'MANIFEST: UNSAFE_SYMLINK'
  elif [ -f "$manifest" ]; then
    printf '%s\n' "MANIFEST_CANDIDATE: $manifest"
  elif [ -e "$manifest" ]; then
    printf '%s\n' 'MANIFEST: COLLISION'
  else
    printf '%s\n' 'MANIFEST: NONE'
  fi
}

inspect() {
  local directory=. location root repository_inspect_index
  [ "$#" -eq 0 ] || directory=$1
  location=$(resolve_directory "$directory") || return 1
  project_git_root_state "$location" 'requested directory' || return 1
  INSPECT_CONFIGURED_ROOTS=()
  INSPECT_CONFIGURED_ROOTS_COUNT=0
  if [ "$PROJECT_GIT_ROOT_STATE" = NONE ]; then
    print_uninitialized "$location"
    printf '%s\n' 'GIT_ROOT: NONE'
    print_unconfigured_manifest "$location"
    print_inspect_candidates "$location"
    return 0
  fi
  root=$PROJECT_GIT_ROOT
  INSPECT_CONFIGURED_ROOTS[0]=$root
  INSPECT_CONFIGURED_ROOTS_COUNT=1
  if [ ! -e "$root/superteam.yaml" ] && [ ! -L "$root/superteam.yaml" ]; then
    print_uninitialized "$location" "$root"
    printf '%s\n' "GIT_ROOT: $root"
    print_unconfigured_manifest "$root"
    print_inspect_candidates "$root"
    return 0
  fi
  parse_manifest "$root" || return 1
  print_snapshot "$root" "$MANIFEST_TASK" "$MANIFEST_KNOWLEDGE"
  printf '%s\n' "GIT_ROOT: $root"
  printf '%s\n' "MANIFEST: $root/superteam.yaml"
  printf '%s\n' "CONFIGURED_TASK: $root/$MANIFEST_TASK"
  printf '%s\n' "CONFIGURED_KNOWLEDGE: $root/$MANIFEST_KNOWLEDGE"
  repository_inspect_index=0
  while [ "$repository_inspect_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    printf '%s\n' "REPOSITORY: ${MANIFEST_REPOSITORY_IDS[$repository_inspect_index]}"
    printf '%s\n' "REPOSITORY_PATH: ${MANIFEST_REPOSITORY_PATHS[$repository_inspect_index]}"
    resolve_manifest_repository "$root" "${MANIFEST_REPOSITORY_PATHS[$repository_inspect_index]}"
    if [ "$REPOSITORY_STATE" = ERROR ]; then
      fail "Git could not inspect configured repository ${MANIFEST_REPOSITORY_IDS[$repository_inspect_index]}; repair the local Git command or repository metadata and retry."
      return 1
    fi
    if [ "$REPOSITORY_STATE" = MATCH ]; then
      INSPECT_CONFIGURED_ROOTS[$INSPECT_CONFIGURED_ROOTS_COUNT]=$REPOSITORY_STATE_PATH
      INSPECT_CONFIGURED_ROOTS_COUNT=$((INSPECT_CONFIGURED_ROOTS_COUNT + 1))
    fi
    repository_inspect_index=$((repository_inspect_index + 1))
  done
  print_inspect_candidates "$root"
}

status() {
  directory=.
  [ "$#" -eq 0 ] || directory=$1
  location=$(resolve_directory "$directory") || return 1
  root=$(git_root_for "$location" 2>/dev/null || true)
  if [ -z "$root" ] || { [ ! -e "$root/superteam.yaml" ] && [ ! -L "$root/superteam.yaml" ]; }; then
    fail 'Project is not initialized; run superteam-project init first.'
    return 1
  fi
  parse_manifest "$root" || return 1
  print_snapshot "$root" "$MANIFEST_TASK" "$MANIFEST_KNOWLEDGE"
  print_repository_set_status "$root"
}

doctor_record_check() {
  local name=$1 status=$2 detail=$3
  printf '%s\n' "CHECK_$name: $status" "CHECK_${name}_DETAIL: $detail"
  case "$status" in
    FAIL) DOCTOR_HAS_FAIL=true ;;
    INCONCLUSIVE) DOCTOR_HAS_INCONCLUSIVE=true ;;
  esac
}

doctor_check_git() {
  if ! command -v git >/dev/null 2>&1; then
    doctor_record_check GIT FAIL 'Install Git and ensure git is on PATH.'
  elif ! isolated_git --version >/dev/null 2>&1; then
    doctor_record_check GIT INCONCLUSIVE 'Git is on PATH but git --version failed; repair the Git installation and retry.'
  else
    doctor_record_check GIT PASS 'Git is available and executable.'
  fi
}

doctor_check_bash() {
  local detected major minor
  if [ "${BASH_VERSINFO[0]}" -lt 3 ] ||
      { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    doctor_record_check BASH FAIL 'Install Bash 3.2 or newer and rerun this command with that Bash.'
    return
  fi
  if ! command -v bash >/dev/null 2>&1; then
    doctor_record_check BASH FAIL 'Install Bash 3.2 or newer and ensure bash is on PATH.'
    return
  fi
  if ! detected=$(command bash -c 'printf "%s.%s\n" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null); then
    doctor_record_check BASH INCONCLUSIVE 'Bash is on PATH but its version probe failed; repair the Bash installation and retry.'
    return
  fi
  major=${detected%%.*}
  minor=${detected#*.}
  minor=${minor%%.*}
  case "$major:$minor" in
    *[!0-9:]*|:*|*:) doctor_record_check BASH INCONCLUSIVE 'Bash returned an unreadable version; repair PATH or select Bash 3.2 or newer.'; return ;;
  esac
  if [ "$major" -lt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -lt 2 ]; }; then
    doctor_record_check BASH FAIL 'Install Bash 3.2 or newer and rerun this command with that Bash.'
  else
    doctor_record_check BASH PASS "Bash $major.$minor satisfies the 3.2+ requirement."
  fi
}

doctor_check_platform() {
  local system release
  if ! command -v uname >/dev/null 2>&1; then
    doctor_record_check PLATFORM FAIL 'Install the POSIX uname command; supported platforms are macOS, Linux, and WSL.'
    return
  fi
  if ! system=$(command uname -s 2>/dev/null); then
    doctor_record_check PLATFORM INCONCLUSIVE 'uname -s failed; repair the platform utilities and retry.'
    return
  fi
  case "$system" in
    Darwin) doctor_record_check PLATFORM PASS 'macOS.' ;;
    Linux)
      if ! release=$(command uname -r 2>/dev/null); then
        doctor_record_check PLATFORM INCONCLUSIVE 'uname -r failed, so Linux versus WSL could not be determined.'
      else
        case "$release" in
          *[Mm][Ii][Cc][Rr][Oo][Ss][Oo][Ff][Tt]*|*[Ww][Ss][Ll]*)
            doctor_record_check PLATFORM PASS 'WSL (Linux contract).'
            ;;
          *) doctor_record_check PLATFORM PASS 'Linux.' ;;
        esac
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      doctor_record_check PLATFORM FAIL 'Use macOS, Linux, or WSL; native Windows shells are unsupported.'
      ;;
    *) doctor_record_check PLATFORM FAIL 'Use a supported platform: macOS, Linux, or WSL.' ;;
  esac
}

doctor_prepare_probe_directory() {
  local probe_name=$1
  DOCTOR_PROBE_DIRECTORY="/tmp/.superteam-doctor-probe-$$-$probe_name"
  { [ ! -e "$DOCTOR_PROBE_DIRECTORY" ] && [ ! -L "$DOCTOR_PROBE_DIRECTORY" ]; } || return 1
  (umask 077 && command -p mkdir -- "$DOCTOR_PROBE_DIRECTORY") >/dev/null 2>&1 || return 1
  [ -d "$DOCTOR_PROBE_DIRECTORY" ] && [ ! -L "$DOCTOR_PROBE_DIRECTORY" ]
}

doctor_cleanup_probe_directory() {
  local probe_directory=$1
  (command -p rm -f -- \
    "$probe_directory/source" \
    "$probe_directory/result") >/dev/null 2>&1 || :
  (command -p rmdir -- "$probe_directory/child") >/dev/null 2>&1 || :
  (command -p rmdir -- "$probe_directory") >/dev/null 2>&1 || :
  [ ! -e "$probe_directory" ] && [ ! -L "$probe_directory" ]
}

doctor_probe_filesystem_command() {
  local probe_command=$1 probe_directory probe_output probe_value
  local probe_succeeded=false
  doctor_prepare_probe_directory "$probe_command" || return 1
  probe_directory=$DOCTOR_PROBE_DIRECTORY
  case "$probe_command" in
    cp)
      printf '%s\n' superteam-doctor-probe > "$probe_directory/source" || :
      if command cp -p -- "$probe_directory/source" "$probe_directory/result" >/dev/null 2>&1 &&
          IFS= read -r probe_value < "$probe_directory/result" &&
          [ "$probe_value" = superteam-doctor-probe ]; then
        probe_succeeded=true
      fi
      ;;
    ln)
      printf '%s\n' superteam-doctor-probe > "$probe_directory/source" || :
      if command ln -- "$probe_directory/source" "$probe_directory/result" >/dev/null 2>&1 &&
          [ "$probe_directory/source" -ef "$probe_directory/result" ]; then
        probe_succeeded=true
      fi
      ;;
    mkdir)
      if command mkdir -- "$probe_directory/child" >/dev/null 2>&1 &&
          [ -d "$probe_directory/child" ] && [ ! -L "$probe_directory/child" ]; then
        probe_succeeded=true
      fi
      ;;
    mv)
      printf '%s\n' superteam-doctor-probe > "$probe_directory/source" || :
      if command mv -- "$probe_directory/source" "$probe_directory/result" >/dev/null 2>&1 &&
          [ ! -e "$probe_directory/source" ] && [ ! -L "$probe_directory/source" ] &&
          IFS= read -r probe_value < "$probe_directory/result" &&
          [ "$probe_value" = superteam-doctor-probe ]; then
        probe_succeeded=true
      fi
      ;;
    readlink)
      if (command -p ln -s source "$probe_directory/result") >/dev/null 2>&1 &&
          probe_output=$(command readlink "$probe_directory/result" 2>/dev/null) &&
          [ "$probe_output" = source ]; then
        probe_succeeded=true
      fi
      ;;
    rm)
      printf '%s\n' superteam-doctor-probe > "$probe_directory/source" || :
      if command rm -- "$probe_directory/source" >/dev/null 2>&1 &&
          [ ! -e "$probe_directory/source" ] && [ ! -L "$probe_directory/source" ]; then
        probe_succeeded=true
      fi
      ;;
    rmdir)
      if (command -p mkdir -- "$probe_directory/child") >/dev/null 2>&1 &&
          command rmdir -- "$probe_directory/child" >/dev/null 2>&1 &&
          [ ! -e "$probe_directory/child" ] && [ ! -L "$probe_directory/child" ]; then
        probe_succeeded=true
      fi
      ;;
  esac
  doctor_cleanup_probe_directory "$probe_directory" || probe_succeeded=false
  [ "$probe_succeeded" = true ]
}

doctor_probe_command() {
  case "$1" in
    awk) command awk 'BEGIN { exit 0 }' </dev/null >/dev/null 2>&1 ;;
    basename) command basename / >/dev/null 2>&1 ;;
    cat) command cat /dev/null >/dev/null 2>&1 ;;
    cksum) command cksum </dev/null >/dev/null 2>&1 ;;
    cp|ln|mkdir|mv|readlink|rm|rmdir) doctor_probe_filesystem_command "$1" ;;
    find) command find /dev/null -prune >/dev/null 2>&1 ;;
    grep) printf '\n' | LC_ALL=C command grep -q '^$' ;;
    ls) command ls -d / >/dev/null 2>&1 ;;
    sed) command sed -n '1p' /dev/null >/dev/null 2>&1 ;;
    sort) command sort /dev/null >/dev/null 2>&1 ;;
    tail) command tail -n 0 /dev/null >/dev/null 2>&1 ;;
    tr) command tr a a </dev/null >/dev/null 2>&1 ;;
    wc) command wc -l </dev/null >/dev/null 2>&1 ;;
    *) return 0 ;;
  esac
}

doctor_check_commands() {
  local runtime_command
  for runtime_command in awk basename cat cksum cp find grep ln ls mkdir mv readlink rm rmdir sed sort tail tr wc; do
    if ! command -v "$runtime_command" >/dev/null 2>&1; then
      doctor_record_check "COMMAND_$runtime_command" FAIL "Install a POSIX implementation of $runtime_command and ensure it is on PATH."
    elif ! doctor_probe_command "$runtime_command"; then
      doctor_record_check "COMMAND_$runtime_command" INCONCLUSIVE "$runtime_command is on PATH but its isolated worktree-safe probe failed; repair the tool installation and retry."
    else
      doctor_record_check "COMMAND_$runtime_command" PASS "$runtime_command is available."
    fi
  done
}

doctor_print_runtime_result() {
  if [ "$DOCTOR_HAS_FAIL" = true ]; then
    printf '%s\n' 'DOCTOR_RESULT: FAIL'
  elif [ "$DOCTOR_HAS_INCONCLUSIVE" = true ]; then
    printf '%s\n' 'DOCTOR_RESULT: INCONCLUSIVE'
  else
    printf '%s\n' 'DOCTOR_RESULT: PASS'
  fi
}

doctor() {
  local directory=. location root
  [ "$#" -eq 0 ] || directory=$1
  DOCTOR_HAS_FAIL=false
  DOCTOR_HAS_INCONCLUSIVE=false
  doctor_check_git
  doctor_check_bash
  doctor_check_platform
  doctor_check_commands
  if [ "$DOCTOR_HAS_FAIL" = true ] || [ "$DOCTOR_HAS_INCONCLUSIVE" = true ]; then
    doctor_record_check PROJECT INCONCLUSIVE 'Project inspection was skipped until the runtime diagnostics are repaired.'
    doctor_record_check MANIFEST INCONCLUSIVE 'Manifest inspection was skipped until the runtime diagnostics are repaired.'
    doctor_print_runtime_result
    return 1
  fi

  if ! location=$(resolve_directory "$directory"); then
    doctor_record_check PROJECT FAIL 'The requested Project directory does not exist or cannot be resolved.'
    doctor_record_check MANIFEST INCONCLUSIVE 'Manifest inspection requires a resolvable Project directory.'
    doctor_print_runtime_result
    return 1
  fi
  if ! project_git_root_state "$location" 'requested directory'; then
    doctor_record_check PROJECT INCONCLUSIVE 'Git could not classify the requested Project directory.'
    doctor_record_check MANIFEST INCONCLUSIVE 'Manifest inspection requires a conclusive Git root.'
    doctor_print_runtime_result
    return 1
  fi
  if [ "$PROJECT_GIT_ROOT_STATE" = NONE ]; then
    print_uninitialized "$location"
    doctor_record_check PROJECT INCONCLUSIVE 'No Git root was found; review superteam-project init before writing.'
    doctor_record_check MANIFEST INCONCLUSIVE 'No Root Repository exists, so no canonical manifest can be validated.'
    doctor_print_runtime_result
    return 0
  fi
  root=$PROJECT_GIT_ROOT
  if [ ! -e "$root/superteam.yaml" ] && [ ! -L "$root/superteam.yaml" ]; then
    print_uninitialized "$location" "$root"
    doctor_record_check PROJECT PASS 'The Root Repository is readable.'
    doctor_record_check MANIFEST INCONCLUSIVE 'superteam.yaml is absent; review superteam-project init before writing.'
    doctor_print_runtime_result
    return 0
  fi
  if ! parse_manifest "$root"; then
    doctor_record_check PROJECT PASS 'The Root Repository is readable.'
    doctor_record_check MANIFEST FAIL 'Repair superteam.yaml as Canonical Superteam YAML and retry.'
    doctor_print_runtime_result
    return 1
  fi
  print_snapshot "$root" "$MANIFEST_TASK" "$MANIFEST_KNOWLEDGE"
  if ! print_repository_set_status "$root"; then
    doctor_record_check PROJECT INCONCLUSIVE 'Repository status inspection failed; repair local Git state and retry.'
    doctor_record_check MANIFEST PASS 'Canonical Superteam YAML is valid.'
    doctor_print_runtime_result
    return 1
  fi
  printf '%s\n' 'MANIFEST: VALID'
  printf '%s\n' 'RUNTIME: Git and Bash with POSIX base utilities'
  doctor_record_check PROJECT PASS 'The configured Repository Set was inspected.'
  doctor_record_check MANIFEST PASS 'Canonical Superteam YAML is valid.'
  doctor_print_runtime_result
}

print_pull_summary() {
  printf '%s\n' "PULLED: $PULL_COUNT_PULLED"
  printf '%s\n' "UP_TO_DATE: $PULL_COUNT_UP_TO_DATE"
  printf '%s\n' "SKIPPED: $PULL_COUNT_SKIPPED"
  printf '%s\n' "FAILED: $PULL_COUNT_FAILED"
  printf '%s\n' "RESULT: $1"
}

print_pull_repository_result() {
  printf '%s\n' "REPOSITORY: $1"
  printf '%s\n' "REPOSITORY_PATH: $2"
  printf '%s\n' "REAL_PATH: $3"
  printf '%s\n' "PULL_STATUS: $4"
  printf '%s\n' "BEFORE: $5"
  printf '%s\n' "AFTER: $6"
  printf '%s\n' "REASON: $7"
}

pull_repository_root_matches() {
  local candidate=$1
  local expected=$2
  local resolved_candidate detected_root
  resolved_candidate=$(resolve_directory "$candidate" 2>/dev/null || true)
  [ "$resolved_candidate" = "$expected" ] || return 1
  detected_root=$(git_root_for "$resolved_candidate" 2>/dev/null || true)
  [ -n "$detected_root" ] || return 1
  detected_root=$(resolve_directory "$detected_root" 2>/dev/null || true)
  [ "$detected_root" = "$expected" ]
}

pull_skip_repository() {
  PULL_COUNT_SKIPPED=$((PULL_COUNT_SKIPPED + 1))
  print_pull_repository_result "$1" "$2" "$3" skipped "$4" "$4" "$5"
}

pull_one_repository() {
  local repository_id=$1
  local repository_path=$2
  local repository_declared=$3
  local repository_real=$4
  local repository_before repository_after repository_status

  if ! pull_repository_root_matches "$repository_declared" "$repository_real"; then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" UNAVAILABLE GIT_ROOT_MISMATCH
    return 0
  fi

  repository_before=$(safe_git -C "$repository_real" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' UNBORN)
  if ! repository_status=$(git_worktree_state "$repository_real"); then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" "$repository_before" WORKTREE_STATUS_UNAVAILABLE
    return 0
  fi
  if [ "$repository_status" = DIRTY ]; then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" "$repository_before" DIRTY_WORKTREE
    return 0
  fi
  if ! safe_git -C "$repository_real" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" "$repository_before" DETACHED_HEAD
    return 0
  fi
  if ! safe_git -C "$repository_real" rev-parse --verify '@{upstream}' >/dev/null 2>&1; then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" "$repository_before" NO_UPSTREAM
    return 0
  fi
  if ! pull_repository_root_matches "$repository_declared" "$repository_real"; then
    pull_skip_repository "$repository_id" "$repository_path" "$repository_real" "$repository_before" GIT_ROOT_MISMATCH
    return 0
  fi

  if ! safe_git -c submodule.recurse=false -C "$repository_real" pull --ff-only >/dev/null 2>&1; then
    repository_after=$(safe_git -C "$repository_real" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' UNAVAILABLE)
    PULL_COUNT_FAILED=$((PULL_COUNT_FAILED + 1))
    print_pull_repository_result "$repository_id" "$repository_path" "$repository_real" failed "$repository_before" "$repository_after" FAST_FORWARD_PULL_FAILED
    return 0
  fi

  repository_after=$(safe_git -C "$repository_real" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' UNAVAILABLE)
  if [ "$repository_after" = "$repository_before" ]; then
    PULL_COUNT_UP_TO_DATE=$((PULL_COUNT_UP_TO_DATE + 1))
    print_pull_repository_result "$repository_id" "$repository_path" "$repository_real" up-to-date "$repository_before" "$repository_after" ALREADY_UP_TO_DATE
  else
    PULL_COUNT_PULLED=$((PULL_COUNT_PULLED + 1))
    print_pull_repository_result "$repository_id" "$repository_path" "$repository_real" pulled "$repository_before" "$repository_after" FAST_FORWARD
  fi
}

project_pull() {
  local directory=. location root repository_index repository_id repository_path
  local repository_seen repository_real
  [ "$#" -eq 0 ] || directory=$1
  PULL_COUNT_PULLED=0
  PULL_COUNT_UP_TO_DATE=0
  PULL_COUNT_SKIPPED=0
  PULL_COUNT_FAILED=0

  if ! command -v git >/dev/null 2>&1; then
    fail 'Git is required but was not found on PATH.'
    print_pull_summary FAILED
    return 1
  fi
  if ! location=$(resolve_directory "$directory"); then
    print_pull_summary FAILED
    return 1
  fi
  root=$(git_root_for "$location" 2>/dev/null || true)
  if [ -z "$root" ] || { [ ! -e "$root/superteam.yaml" ] && [ ! -L "$root/superteam.yaml" ]; }; then
    fail 'Project is not initialized; run superteam-project init first.' || true
    print_pull_summary FAILED
    return 1
  fi
  root=$(resolve_directory "$root") || {
    print_pull_summary FAILED
    return 1
  }
  if ! parse_manifest "$root"; then
    print_pull_summary FAILED
    return 1
  fi

  printf '%s\n' 'ACTION: PULL'
  printf '%s\n' "ROOT: $root"
  pull_one_repository root . "$root" "$root"
  repository_seen=$root
  repository_index=0
  while [ "$repository_index" -lt "${#MANIFEST_REPOSITORY_IDS[@]}" ]; do
    repository_id=${MANIFEST_REPOSITORY_IDS[$repository_index]}
    repository_path=${MANIFEST_REPOSITORY_PATHS[$repository_index]}
    repository_index=$((repository_index + 1))
    resolve_manifest_repository "$root" "$repository_path"
    case "$REPOSITORY_STATE" in
      MISSING)
        pull_skip_repository "$repository_id" "$repository_path" MISSING UNAVAILABLE MISSING_PATH
        continue
        ;;
      MISMATCH)
        pull_skip_repository "$repository_id" "$repository_path" "${REPOSITORY_STATE_PATH:-UNRESOLVED}" UNAVAILABLE GIT_ROOT_MISMATCH
        continue
        ;;
      MATCH) repository_real=$REPOSITORY_STATE_PATH ;;
      *)
        pull_skip_repository "$repository_id" "$repository_path" UNRESOLVED UNAVAILABLE GIT_ROOT_MISMATCH
        continue
        ;;
    esac
    if printf '%s\n' "$repository_seen" | LC_ALL=C grep -Fqx -- "$repository_real"; then
      pull_skip_repository "$repository_id" "$repository_path" "$repository_real" UNAVAILABLE DUPLICATE_GIT_ROOT
      continue
    fi
    repository_seen=$(printf '%s\n%s' "$repository_seen" "$repository_real")
    pull_one_repository "$repository_id" "$repository_path" "$root/$repository_path" "$repository_real"
  done

  if [ "$PULL_COUNT_SKIPPED" -eq 0 ] && [ "$PULL_COUNT_FAILED" -eq 0 ]; then
    print_pull_summary COMPLETE
    return 0
  fi
  print_pull_summary PARTIAL
  return 2
}

print_planned_directory_once() {
  planned_directory=$1
  for recorded_directory in "${INIT_PLANNED_DIRECTORIES[@]}"; do
    [ "$recorded_directory" != "$planned_directory" ] || return 0
  done
  INIT_PLANNED_DIRECTORIES[${#INIT_PLANNED_DIRECTORIES[@]}]=$planned_directory
  printf '%s\n' "CREATE_DIRECTORY: $planned_directory"
}

print_new_asset_plan() {
  planning_remaining=$1
  planning_current=$INIT_ROOT
  while :; do
    next_path_component "$planning_remaining"
    planning_current=$planning_current/$NEXT_COMPONENT
    [ -d "$planning_current" ] || print_planned_directory_once "$planning_current"
    planning_remaining=$NEXT_REMAINING
    [ -n "$planning_remaining" ] || break
  done
}

render_init_plan_body() {
  INIT_PLANNED_DIRECTORIES=('__superteam_unset__')
  printf '%s\n' "ACTION: $INIT_ACTION"
  printf '%s\n' "ROOT: $INIT_ROOT"
  printf '%s\n' "ROOT_MODE: $INIT_ROOT_MODE"
  printf '%s\n' "TASK: $INIT_ROOT/$INIT_TASK"
  printf '%s\n' "KNOWLEDGE: $INIT_ROOT/$INIT_KNOWLEDGE"
  if [ "$INIT_TASK_EXISTING" = true ]; then
    printf '%s\n' "ADOPT_DIRECTORY: $INIT_ROOT/$INIT_TASK"
  else
    print_new_asset_plan "$INIT_TASK"
    printf '%s\n' "WRITE: $INIT_ROOT/$INIT_TASK/README.md"
  fi
  if [ "$INIT_KNOWLEDGE_EXISTING" = true ]; then
    printf '%s\n' "ADOPT_DIRECTORY: $INIT_ROOT/$INIT_KNOWLEDGE"
  else
    print_new_asset_plan "$INIT_KNOWLEDGE"
    printf '%s\n' "WRITE: $INIT_ROOT/$INIT_KNOWLEDGE/README.md"
  fi
  printf '%s\n' "WRITE: $INIT_ROOT/superteam.yaml"
  if [ "$INIT_ROOT_MODE" = METADATA_ONLY ]; then
    printf '%s\n' "WRITE: $INIT_ROOT/.gitignore"
    inspect_candidates "$INIT_ROOT"
  fi
  [ "$INIT_ROOT_MODE" = EXISTING ] || printf '%s\n' "INIT_GIT: $INIT_ROOT"
  printf '%s\n' 'GIT_STAGE: NONE'
  printf '%s\n' 'GIT_COMMIT: NONE'
}

prepare_init_plan() {
  INIT_PLAN_BODY=$(render_init_plan_body) || return 1
  INIT_PLAN_FINGERPRINT=$({
    printf '%s\n' "$INIT_PLAN_BODY"
    printf 'ROOT_IDENTITY:%s\n' "$INIT_ROOT_IDENTITY"
    printf 'GIT_IDENTITY:%s\n' "$INIT_GIT_IDENTITY"
  } | plan_fingerprint) || return 1
}

print_init_plan() {
  printf '%s\n' "$INIT_PLAN_BODY"
  printf '%s\n' "PLAN_FINGERPRINT: $INIT_PLAN_FINGERPRINT"
  [ "$INIT_APPLY" = true ] || printf '%s\n' "NEXT: Re-run with --apply --plan-fingerprint $INIT_PLAN_FINGERPRINT to write this exact plan."
}

preflight_init() {
  action=$1
  location=$2
  task=$3
  knowledge=$4
  adopt_task=$5
  adopt_knowledge=$6
  case "$action" in
    init) INIT_ACTION=INIT ;;
    adopt) INIT_ACTION=ADOPT ;;
    *) fail 'unknown initialization action.'; return 1 ;;
  esac
  INIT_ROOT=$(resolve_directory "$location") || return 1
  existing_root=$(git_root_for "$INIT_ROOT" 2>/dev/null || true)
  if [ -n "$existing_root" ]; then
    INIT_ROOT=$(resolve_directory "$existing_root") || return 1
    INIT_ROOT_MODE=EXISTING
    if ! INIT_GIT_IDENTITY=$(git_identity_for "$INIT_ROOT"); then
      fail 'could not identify the existing Root Repository.'
      return 1
    fi
  else
    if directory_is_empty "$INIT_ROOT"; then
      INIT_ROOT_MODE=NEW
    else
      INIT_ROOT_MODE=METADATA_ONLY
    fi
    INIT_GIT_IDENTITY=NEW
  fi
  INIT_ROOT_PHYSICAL=$INIT_ROOT
  if ! INIT_ROOT_IDENTITY=$(directory_identity_for "$INIT_ROOT"); then
    fail 'could not identify the Root Repository directory.'
    return 1
  fi
  if [ "$VERIFY_ROOT_STABLE" = true ]; then
    if [ "$INIT_ROOT" != "$INIT_CONFIRMED_ROOT" ]; then
      fail 'Root Repository changed after the initialization plan; no files were applied.'
      return 1
    fi
    if [ "$INIT_ROOT_MODE" != "$INIT_CONFIRMED_ROOT_MODE" ]; then
      fail 'Root Repository mode changed after the initialization plan; no files were applied.'
      return 1
    fi
    if [ "$INIT_GIT_IDENTITY" != "$INIT_CONFIRMED_GIT_IDENTITY" ]; then
      fail 'Root Repository identity changed after the initialization plan; no files were applied.'
      return 1
    fi
    if [ "$INIT_ROOT_IDENTITY" != "$INIT_CONFIRMED_ROOT_IDENTITY" ]; then
      fail 'Root Repository directory changed after the initialization plan; no files were applied.'
      return 1
    fi
  fi
  if [ "$INIT_ROOT_MODE" != EXISTING ]; then
    [ "$action" != adopt ] || { fail 'adopt requires the target directory to be inside an existing Git repository.'; return 1; }
  fi
  validate_asset_path "$task" task || return 1
  validate_asset_path "$knowledge" knowledge || return 1
  [ "$task" != "$knowledge" ] || { fail 'task and knowledge paths must differ.'; return 1; }
  case "$task" in "$knowledge"/*) fail 'task and knowledge paths must not be nested.'; return 1 ;; esac
  case "$knowledge" in "$task"/*) fail 'task and knowledge paths must not be nested.'; return 1 ;; esac
  [ ! -e "$INIT_ROOT/superteam.yaml" ] && [ ! -L "$INIT_ROOT/superteam.yaml" ] || { fail 'superteam.yaml already exists; inspect or repair the existing Project instead.'; return 1; }
  if [ "$INIT_ROOT_MODE" = METADATA_ONLY ] && { [ -e "$INIT_ROOT/.gitignore" ] || [ -L "$INIT_ROOT/.gitignore" ]; }; then
    fail '.gitignore already exists; metadata-only initialization will not overwrite parent ignore rules.'
    return 1
  fi
  check_asset_destination "$INIT_ROOT" "$task" task "$adopt_task" || return 1
  check_asset_destination "$INIT_ROOT" "$knowledge" knowledge "$adopt_knowledge" || return 1
  if [ -d "$INIT_ROOT/$task" ]; then INIT_TASK_EXISTING=true; else INIT_TASK_EXISTING=false; fi
  if [ -d "$INIT_ROOT/$knowledge" ]; then INIT_KNOWLEDGE_EXISTING=true; else INIT_KNOWLEDGE_EXISTING=false; fi
  INIT_TASK=$task
  INIT_KNOWLEDGE=$knowledge
  prepare_init_plan || return 1
}

acquire_project_lock() {
  [ "$(directory_identity_for "$1")" = "$INIT_CONFIRMED_ROOT_IDENTITY" ] || {
    fail 'Root Repository directory changed after the initialization plan; no files were applied.'
    return 1
  }
  cd -P -- "$1" || {
    fail 'could not enter the planned Root Repository.'
    return 1
  }
  [ "$(pwd -P)" = "$INIT_ROOT_PHYSICAL" ] && [ "$(directory_identity_for .)" = "$INIT_CONFIRMED_ROOT_IDENTITY" ] || {
    fail 'Root Repository directory changed after the initialization plan; no files were applied.'
    return 1
  }
  INIT_ROOT_ANCHORED=true
  PROJECT_LOCK=.superteam-project.lock
  TXN_STATE=LOCK_PENDING
  TXN_LOCK_PENDING=true
  if ! safe_root_mkdir "./$PROJECT_LOCK" 2>/dev/null; then
    TXN_LOCK_PENDING=false
    fail 'another Project write is in progress; retry after it completes.'
    return 1
  fi
  require_current_root || {
    return 1
  }
  [ -d "./$PROJECT_LOCK" ] && [ ! -L "./$PROJECT_LOCK" ] || {
    fail 'the Project write lock changed during initialization.'
    return 1
  }
  INIT_LOCK_ROOT_PHYSICAL=$INIT_ROOT_PHYSICAL
  INIT_LOCK_ROOT_IDENTITY=$INIT_CONFIRMED_ROOT_IDENTITY
  LOCK_HELD=true
  TXN_LOCK_PENDING=false
  TXN_STATE=LOCKED
  initialize_transaction_ledger || {
    fail 'could not prepare the Project transaction ledger.'
    return 1
  }
  TXN_STATE=APPLYING
}

release_project_lock() {
  [ "$LOCK_HELD" = true ] || return 0
  # A failed second preflight can resolve a caller-supplied symlink to a
  # different directory.  The lock still belongs to the physical directory
  # that created it, so release only through that frozen identity; never
  # follow the newly resolved target.
  [ -n "$INIT_LOCK_ROOT_PHYSICAL" ] && [ -n "$INIT_LOCK_ROOT_IDENTITY" ] || {
    fail 'could not release the Project write lock.'
    return 1
  }
  lock_current_identity=$(directory_identity_for "$INIT_LOCK_ROOT_PHYSICAL") || {
    fail 'could not release the Project write lock.'
    return 1
  }
  [ "$lock_current_identity" = "$INIT_LOCK_ROOT_IDENTITY" ] || {
    fail 'could not release the Project write lock.'
    return 1
  }
  cd -P -- "$INIT_LOCK_ROOT_PHYSICAL" || {
    fail 'could not release the Project write lock.'
    return 1
  }
  [ "$(pwd -P)" = "$INIT_LOCK_ROOT_PHYSICAL" ] || {
    fail 'could not release the Project write lock.'
    return 1
  }
  INIT_ROOT_PHYSICAL=$INIT_LOCK_ROOT_PHYSICAL
  INIT_CONFIRMED_ROOT_IDENTITY=$INIT_LOCK_ROOT_IDENTITY
  INIT_ROOT_ANCHORED=true
  # Ledger removal, the in-memory transaction-state commit, and the final
  # rmdir are one release transition.  A signal in between must see either a
  # usable ledger or a lock state already known to be empty; never the former
  # state paired with a deleted journal.
  transaction_begin_critical_section || {
    fail 'could not release the Project write lock.'
    return 1
  }
  if [ "$TXN_LEDGER_READY" = true ]; then
    cleanup_transaction_ledger || {
      transaction_cancel_critical_section
      fail 'could not release the Project write lock.'
      return 1
    }
  else
    cleanup_bootstrap_transaction_ledger || {
      transaction_cancel_critical_section
      fail 'could not release the Project write lock.'
      return 1
    }
  fi
  safe_root_rmdir . "$PROJECT_LOCK" || {
    transaction_cancel_critical_section
    fail 'could not release the Project write lock.'
    return 1
  }
  LOCK_HELD=false
  TXN_LOCK_PENDING=false
  INIT_LOCK_ROOT_PHYSICAL=''
  INIT_LOCK_ROOT_IDENTITY=''
  transaction_finish_critical_section
}

clear_project_trap() {
  trap - EXIT HUP INT TERM
}

transaction_begin_critical_section() {
  [ "$TXN_CRITICAL" = false ] || return 1
  TXN_CRITICAL=true
}

transaction_finish_critical_section() {
  [ "$TXN_CRITICAL" = true ] || return 1
  TXN_CRITICAL=false
  if [ -n "$TXN_DEFERRED_STATUS" ]; then
    transaction_deferred_status=$TXN_DEFERRED_STATUS
    TXN_DEFERRED_STATUS=''
    abort_project_transaction "$transaction_deferred_status"
  fi
}

transaction_cancel_critical_section() {
  [ "$TXN_CRITICAL" = true ] || return 0
  TXN_CRITICAL=false
  if [ -n "$TXN_DEFERRED_STATUS" ]; then
    transaction_deferred_status=$TXN_DEFERRED_STATUS
    TXN_DEFERRED_STATUS=''
    abort_project_transaction "$transaction_deferred_status"
  fi
}

record_project_signal() {
  project_signal_status=$1
  # Cleanup is already driven by the first signal.  A second signal must not
  # interrupt it half-way through and strand its lock, stage, or assets.
  [ "$TXN_ABORTING" = true ] && return 0
  if [ "$TXN_CRITICAL" = true ]; then
    [ -n "$TXN_DEFERRED_STATUS" ] || TXN_DEFERRED_STATUS=$project_signal_status
    return 0
  fi
  abort_project_transaction "$project_signal_status"
}

arm_project_transaction() {
  TXN_STATE=ARMED
  TXN_ABORTING=false
  TXN_LOCK_PENDING=false
  TXN_CRITICAL=false
  TXN_DEFERRED_STATUS=''
  TXN_TRAP_ROOT_SUBSHELL=${BASH_SUBSHELL:-0}
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then abort_project_transaction 1; fi' EXIT
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 129; fi' HUP
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 130; fi' INT
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 143; fi' TERM
}

finish_failed_project_transaction() {
  TXN_CRITICAL=false
  TXN_DEFERRED_STATUS=''
  TXN_LEDGER_RECORDING=false
  rollback_init || true
  if [ "$LOCK_HELD" = true ]; then
    release_project_lock || true
  else
    cleanup_pending_project_lock || true
  fi
  clear_project_trap
  TXN_STATE=IDLE
}

abort_project_transaction() {
  abort_status=$1
  [ "$TXN_ABORTING" = true ] && return 0
  TXN_ABORTING=true
  # The EXIT trap would recursively invoke this function, but HUP/INT/TERM
  # remain armed while cleanup is in flight.  record_project_signal consumes
  # later signals once TXN_ABORTING is set and preserves the first status.
  trap - EXIT
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 129; fi' HUP
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 130; fi' INT
  trap 'if [ "${BASH_SUBSHELL:-0}" -eq "${TXN_TRAP_ROOT_SUBSHELL:-0}" ]; then record_project_signal 143; fi' TERM
  TXN_CRITICAL=false
  TXN_DEFERRED_STATUS=''
  case "$TXN_STATE" in
    RELEASING|FINISHED)
      release_project_lock || true
      ;;
    *)
      TXN_LEDGER_RECORDING=false
      rollback_init || true
      if [ "$LOCK_HELD" = true ]; then
        release_project_lock || true
      else
        cleanup_pending_project_lock || true
      fi
      ;;
  esac
  clear_project_trap
  TXN_STATE=ABORTED
  exit "$abort_status"
}

write_staged_manifest() {
  manifest=$1
  yaml_quote "$INIT_TASK"
  task_quoted=$YAML_QUOTED
  yaml_quote "$INIT_KNOWLEDGE"
  knowledge_quoted=$YAML_QUOTED
  split_internal_root_path "$manifest" || {
    fail 'could not write the staged manifest.'
    return 1
  }
  staged_manifest_contents=$(printf '%s\n' 'version: 1' 'paths:' "  task: $task_quoted" "  knowledge: $knowledge_quoted")
  safe_root_write_new_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$staged_manifest_contents" || {
    fail 'could not write the staged manifest.'
    return 1
  }
}

gitignore_escape_path() {
  GITIGNORE_ESCAPED=$(printf '%s\n' "$1" | LC_ALL=C awk '
    {
      escaped = ""
      for (position = 1; position <= length($0); position++) {
        character = substr($0, position, 1)
        if (character == "\\" || character == "*" || character == "?" ||
            character == "[" || character == "]" || character == " " ||
            character == "#" || character == "!") {
          escaped = escaped "\\"
        }
        escaped = escaped character
      }
      print escaped
    }') || return 1
}

render_metadata_gitignore() {
  metadata_seen=''
  printf '%s\n' '*' '!/.gitignore' '!/superteam.yaml'
  for metadata_path in "$1" "$2"; do
    metadata_remaining=$metadata_path
    metadata_prefix=''
    while :; do
      next_path_component "$metadata_remaining"
      if [ -n "$metadata_prefix" ]; then
        metadata_prefix=$metadata_prefix/$NEXT_COMPONENT
      else
        metadata_prefix=$NEXT_COMPONENT
      fi
      gitignore_escape_path "$metadata_prefix" || return 1
      metadata_rule=!/$GITIGNORE_ESCAPED/
      if ! printf '%s\n' "$metadata_seen" | LC_ALL=C grep -Fqx -- "$metadata_rule"; then
        printf '%s\n' "$metadata_rule"
        metadata_seen=$(printf '%s\n%s' "$metadata_seen" "$metadata_rule")
      fi
      metadata_remaining=$NEXT_REMAINING
      [ -n "$metadata_remaining" ] || break
    done
    gitignore_escape_path "$metadata_path" || return 1
    printf '%s\n' "!/$GITIGNORE_ESCAPED/**"
  done
}

write_staged_gitignore() {
  staged_gitignore=$1
  split_internal_root_path "$staged_gitignore" || {
    fail 'could not write the staged metadata-only allowlist.'
    return 1
  }
  metadata_gitignore_contents=$(render_metadata_gitignore "$INIT_TASK" "$INIT_KNOWLEDGE") || return 1
  safe_root_write_new_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$metadata_gitignore_contents" || {
    fail 'could not write the staged metadata-only allowlist.'
    return 1
  }
}

stage_is_current() {
  [ -n "$INIT_STAGE" ] && [ -n "$INIT_STAGE_IDENTITY" ] || return 1
  require_current_root || return 1
  [ -d "$INIT_STAGE" ] && [ ! -L "$INIT_STAGE" ] || return 1
  stage_physical=$(cd -P -- "$INIT_STAGE" && pwd -P) || return 1
  stage_expected=$(root_physical_path_for "$INIT_STAGE") || return 1
  [ "$stage_physical" = "$stage_expected" ] || return 1
  stage_current_identity=$(directory_identity_for "$INIT_STAGE") || return 1
  [ "$stage_current_identity" = "$INIT_STAGE_IDENTITY" ]
}

checkpoint_stage_snapshot() {
  stage_is_current || {
    fail 'initialization staging directory changed before completion.'
    return 1
  }
  INIT_STAGE_SNAPSHOT=$(tree_snapshot "$INIT_STAGE") || {
    fail 'could not record initialization staging ownership.'
    return 1
  }
  INIT_STAGE_SNAPSHOT_READY=true
}

verify_stage_snapshot() {
  [ "$INIT_STAGE_SNAPSHOT_READY" = true ] || return 0
  stage_is_current || {
    fail 'initialization staging directory changed before completion.'
    return 1
  }
  tree_snapshot_matches "$INIT_STAGE" "$INIT_STAGE_SNAPSHOT" || {
    fail 'initialization staging content changed before completion.'
    return 1
  }
}

probe_directory_matches() {
  probe_directory=$1
  [ ! -L "$probe_directory" ] && [ -d "$probe_directory" ] || return 1
  probe_physical=$(cd -P -- "$probe_directory" && pwd -P) || return 1
  probe_expected=$(root_physical_path_for "$probe_directory") || return 1
  [ "$probe_physical" = "$probe_expected" ] || return 1
  owned_regular_file_matches "$probe_directory/.superteam-project-probe-owner" "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT"
}

probe_directory_has_only_marker() {
  probe_directory=$1
  for probe_entry in "$probe_directory"/* "$probe_directory"/.[!.]* "$probe_directory"/..?*; do
    [ -e "$probe_entry" ] || [ -L "$probe_entry" ] || continue
    [ "$probe_entry" = "$probe_directory/.superteam-project-probe-owner" ] && continue
    return 1
  done
  return 0
}

claim_probe_directory() {
  probe_directory=$1
  [ ! -e "$probe_directory" ] && [ ! -L "$probe_directory" ] || {
    fail 'the initialization probe changed before a directory could be reserved.'
    return 1
  }
  stage_is_current || {
    fail 'the initialization staging directory changed before a directory could be reserved.'
    return 1
  }
  safe_root_mkdir "$probe_directory" || {
    fail 'could not prepare the initialization probe.'
    return 1
  }
  safe_root_link "$INIT_STAGE_OWNER_REFERENCE" "$probe_directory" .superteam-project-probe-owner || {
    fail 'could not mark an initialization probe directory.'
    return 1
  }
  stage_is_current || {
    fail 'the initialization staging directory changed before a directory could be reserved.'
    return 1
  }
  INIT_PROBE_DIRECTORIES[${#INIT_PROBE_DIRECTORIES[@]}]=$probe_directory
}

reserve_probe_path() {
  probe_remaining=$1
  probe_current=$INIT_STAGE/probe
  while :; do
    next_path_component "$probe_remaining"
    probe_current=$probe_current/$NEXT_COMPONENT
    if [ -e "$probe_current" ] || [ -L "$probe_current" ]; then
      probe_directory_matches "$probe_current" || {
        fail 'the initialization probe contains an unowned directory.'
        return 1
      }
    else
      claim_probe_directory "$probe_current" || return 1
    fi
    probe_remaining=$NEXT_REMAINING
    [ -n "$probe_remaining" ] || break
  done
}

clear_initialization_probe() {
  probe_index=${#INIT_PROBE_DIRECTORIES[@]}
  while [ "$probe_index" -gt 1 ]; do
    probe_index=$((probe_index - 1))
    probe_directory=${INIT_PROBE_DIRECTORIES[$probe_index]}
    probe_directory_matches "$probe_directory" && probe_directory_has_only_marker "$probe_directory" || {
      fail 'could not clear the initialization probe safely.'
      return 1
    }
    safe_root_remove_file "$probe_directory" .superteam-project-probe-owner "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT" || {
      fail 'could not clear the initialization probe safely.'
      return 1
    }
    split_internal_root_path "$probe_directory" || {
      fail 'could not clear the initialization probe safely.'
      return 1
    }
    safe_root_rmdir "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" || {
      fail 'could not clear the initialization probe safely.'
      return 1
    }
  done
}

prepare_stage() {
  require_current_root || return 1
  stage_suffix=${SUPERTEAM_PROJECT_STAGE_SUFFIX:-$$}
  case "$stage_suffix" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) fail 'could not reserve the initialization staging directory.'; return 1 ;;
  esac
  INIT_STAGE=$INIT_ROOT/.superteam-project-stage.$stage_suffix
  INIT_STAGE_OWNED=false
  INIT_STAGE_IDENTITY=''
  INIT_STAGE_SNAPSHOT=''
  INIT_STAGE_SNAPSHOT_READY=false
  INIT_CREATED_RECORDS=''
  INIT_OWNED_ASSET_RECORDS=''
  INIT_PROBE_DIRECTORIES=('__superteam_unset__')
  if ! safe_root_mkdir "$INIT_STAGE" 2>/dev/null; then
    fail 'could not reserve the initialization staging directory.'
    return 1
  fi
  require_current_root || return 1
  INIT_STAGE_IDENTITY=$(directory_identity_for "$INIT_STAGE") || {
    fail 'could not identify the initialization staging directory.'
    return 1
  }
  stage_is_current || {
    fail 'could not identify the initialization staging directory.'
    return 1
  }
  INIT_STAGE_OWNED=true
  INIT_STAGE_OWNER_REFERENCE=$PROJECT_LOCK/stage-owner
  safe_root_create_empty_file "./$PROJECT_LOCK" stage-owner || { fail 'could not mark the initialization staging directory.'; return 1; }
  INIT_STAGE_OWNER_FINGERPRINT=$(file_fingerprint "$INIT_STAGE_OWNER_REFERENCE") || { fail 'could not mark the initialization staging directory.'; return 1; }
  safe_root_link "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE" .superteam-project-owner || { fail 'could not mark the initialization staging directory.'; return 1; }
  safe_root_mkdir "$INIT_STAGE/ownership" || { fail 'could not prepare initialization ownership markers.'; return 1; }
  claim_probe_directory "$INIT_STAGE/probe" || return 1
  if [ "$INIT_TASK_EXISTING" = false ]; then
    reserve_probe_path "$INIT_TASK" || { fail 'task path cannot be created.'; return 1; }
    safe_root_mkdir "$INIT_STAGE/task" || { fail 'could not stage the task directory.'; return 1; }
    empty_line=''
    task_skeleton=$(printf '%s\n' '# Superteam task workspace' "$empty_line" 'Store project task artifacts in this directory.')
    safe_root_write_new_file "$INIT_STAGE/task" README.md "$task_skeleton" || {
      fail 'could not stage the task skeleton.'
      return 1
    }
    INIT_TASK_README_REFERENCE=$PROJECT_LOCK/task_asset_reference
    safe_root_link "$INIT_STAGE/task/README.md" "./$PROJECT_LOCK" task_asset_reference || {
      fail 'could not preserve the task skeleton reference.'
      return 1
    }
    INIT_TASK_README_FINGERPRINT=$(file_fingerprint "$INIT_TASK_README_REFERENCE") || {
      fail 'could not record the task skeleton reference.'
      return 1
    }
  fi
  if [ "$INIT_KNOWLEDGE_EXISTING" = false ]; then
    reserve_probe_path "$INIT_KNOWLEDGE" || { fail 'knowledge path cannot be created.'; return 1; }
    safe_root_mkdir "$INIT_STAGE/knowledge" || { fail 'could not stage the knowledge directory.'; return 1; }
    empty_line=''
    knowledge_skeleton=$(printf '%s\n' '# Knowledge' "$empty_line" 'Project knowledge maintained by Superteam.')
    safe_root_write_new_file "$INIT_STAGE/knowledge" README.md "$knowledge_skeleton" || {
      fail 'could not stage the knowledge skeleton.'
      return 1
    }
    INIT_KNOWLEDGE_README_REFERENCE=$PROJECT_LOCK/knowledge-readme-reference
    safe_root_link "$INIT_STAGE/knowledge/README.md" "./$PROJECT_LOCK" knowledge-readme-reference || {
      fail 'could not preserve the knowledge skeleton reference.'
      return 1
    }
    INIT_KNOWLEDGE_README_FINGERPRINT=$(file_fingerprint "$INIT_KNOWLEDGE_README_REFERENCE") || {
      fail 'could not record the knowledge skeleton reference.'
      return 1
    }
  fi
  clear_initialization_probe || return 1
  write_staged_manifest "$INIT_STAGE/superteam.yaml"
  checkpoint_stage_snapshot || return 1
  INIT_MANIFEST_REFERENCE=$PROJECT_LOCK/manifest-reference
  safe_root_link "$INIT_STAGE/superteam.yaml" "./$PROJECT_LOCK" manifest-reference || { fail 'could not preserve the staged manifest reference.'; return 1; }
  INIT_MANIFEST_FINGERPRINT=$(file_fingerprint "$INIT_MANIFEST_REFERENCE") || { fail 'could not record the staged manifest.'; return 1; }
  checkpoint_stage_snapshot || return 1
  if [ "$INIT_ROOT_MODE" = METADATA_ONLY ]; then
    write_staged_gitignore "$INIT_STAGE/.gitignore" || return 1
    checkpoint_stage_snapshot || return 1
    INIT_GITIGNORE_REFERENCE=$PROJECT_LOCK/gitignore-reference
    safe_root_link "$INIT_STAGE/.gitignore" "./$PROJECT_LOCK" gitignore-reference || { fail 'could not preserve the staged metadata-only allowlist.'; return 1; }
    INIT_GITIGNORE_FINGERPRINT=$(file_fingerprint "$INIT_GITIGNORE_REFERENCE") || { fail 'could not record the staged metadata-only allowlist.'; return 1; }
    checkpoint_stage_snapshot || return 1
  fi
  checkpoint_stage_snapshot
}

owned_new_git_is_unchanged() {
  [ "$INIT_CREATED_GIT" = true ] || return 1
  [ "$INIT_GIT_SNAPSHOT_READY" = true ] || return 1
  require_current_root || return 1
  [ -d "$INIT_ROOT/.git" ] && [ ! -L "$INIT_ROOT/.git" ] || return 1
  owned_regular_file_matches "$INIT_ROOT/.git/.superteam-project-owner" "$INIT_GIT_MARKER" "$INIT_GIT_MARKER_FINGERPRINT" || return 1
  tree_snapshot_matches "$INIT_ROOT/.git" "$INIT_GIT_SNAPSHOT"
}

final_new_git_is_unchanged() {
  [ "$INIT_CREATED_GIT" = true ] || return 0
  [ -n "$INIT_FINAL_GIT_SNAPSHOT" ] || return 1
  require_current_root || return 1
  [ -d "$INIT_ROOT/.git" ] && [ ! -L "$INIT_ROOT/.git" ] || return 1
  tree_snapshot_matches "$INIT_ROOT/.git" "$INIT_FINAL_GIT_SNAPSHOT" || return 1
  [ -z "$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT" ] || tree_ownership_snapshot_matches "$INIT_ROOT/.git" "$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT"
}

isolated_git_workspace_matches() {
  workspace=$1
  require_current_root || return 1
  [ ! -L "$workspace" ] && [ -d "$workspace" ] || return 1
  workspace_physical=$(cd -P -- "$workspace" && pwd -P) || return 1
  case "$workspace_physical" in "$INIT_ROOT_PHYSICAL"/*) ;; *) return 1 ;; esac
  owned_regular_file_matches "$workspace/.superteam-project-owner" "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT"
}

# A stage snapshot is rollback authority, never just a convenient directory
# listing.  Before recording one around an isolated `git init`, accept only
# the marker-only workspace or Git's known pristine metadata.  Concurrent
# entries are therefore retained rather than accidentally becoming ours.
isolated_git_stage_is_safe_for_snapshot() {
  stage_is_current || return 1
  empty_git_template_is_safe || return 1
  for isolated_workspace in "$INIT_GIT_BASELINE_WORKSPACE" "$INIT_GIT_CANDIDATE_WORKSPACE"; do
    isolated_git_workspace_matches "$isolated_workspace" || return 1
    if [ -e "$isolated_workspace/.git" ] || [ -L "$isolated_workspace/.git" ]; then
      [ -d "$isolated_workspace/.git" ] && [ ! -L "$isolated_workspace/.git" ] || return 1
      pristine_git_metadata_is_valid "$isolated_workspace/.git" || return 1
    else
      directory_has_only_owner_marker "$isolated_workspace" || return 1
    fi
  done
}

claim_isolated_git_workspace() {
  workspace=$1
  [ ! -e "$workspace" ] && [ ! -L "$workspace" ] || return 1
  safe_root_mkdir "$workspace" || return 1
  workspace_physical=$(cd -P -- "$workspace" && pwd -P) || return 1
  case "$workspace_physical" in "$INIT_ROOT_PHYSICAL"/*) ;; *) return 1 ;; esac
  safe_root_link "$INIT_STAGE_OWNER_REFERENCE" "$workspace" .superteam-project-owner || return 1
  isolated_git_workspace_matches "$workspace"
}

empty_git_template_is_safe() {
  require_current_root || return 1
  [ ! -L "$INIT_GIT_TEMPLATE" ] && [ -d "$INIT_GIT_TEMPLATE" ] || return 1
  template_physical=$(cd -P -- "$INIT_GIT_TEMPLATE" && pwd -P) || return 1
  case "$template_physical" in "$INIT_ROOT_PHYSICAL"/*) ;; *) return 1 ;; esac
  directory_is_empty "$template_physical"
}

pristine_git_metadata_is_valid() {
  metadata=$1
  metadata_snapshot=$(tree_snapshot "$metadata") || return 1
  seen_root=false
  seen_objects=false
  seen_objects_info=false
  seen_objects_pack=false
  seen_refs=false
  seen_refs_heads=false
  seen_refs_tags=false
  seen_head=false
  seen_config=false
  while IFS=$'\t' read -r metadata_type metadata_relative metadata_value || [ -n "$metadata_type" ]; do
    case "$metadata_type:$metadata_relative" in
      D:.) seen_root=true ;;
      D:/objects) seen_objects=true ;;
      D:/objects/info) seen_objects_info=true ;;
      D:/objects/pack) seen_objects_pack=true ;;
      D:/refs) seen_refs=true ;;
      D:/refs/heads) seen_refs_heads=true ;;
      D:/refs/tags) seen_refs_tags=true ;;
      R:/HEAD) seen_head=true ;;
      R:/config) seen_config=true ;;
      *) return 1 ;;
    esac
  done <<EOF
$metadata_snapshot
EOF
  [ "$seen_root" = true ] && [ "$seen_objects" = true ] && [ "$seen_objects_info" = true ] && [ "$seen_objects_pack" = true ] || return 1
  [ "$seen_refs" = true ] && [ "$seen_refs_heads" = true ] && [ "$seen_refs_tags" = true ] && [ "$seen_head" = true ] && [ "$seen_config" = true ] || return 1
  # Git before 2.28 does not support init.defaultBranch.  The branch name is
  # not Project state, but the symbolic HEAD must remain a normal local ref.
  metadata_head=$(cat "$metadata/HEAD") || return 1
  case "$metadata_head" in
    'ref: refs/heads/'*) ;;
    *) return 1 ;;
  esac
  metadata_branch=${metadata_head#'ref: refs/heads/'}
  [ -n "$metadata_branch" ] || return 1
  reject_line_breaks "$metadata_branch" 'Git initial branch' || return 1
  case "$metadata_branch" in *'..'*|*'//'|*/.|./*|.*|*'@{'*|*'\\'*|*'?'*|*'['*|*' '*|*$'\t'*) return 1 ;; esac
  config_names=$(safe_git config --file "$metadata/config" --name-only --list) || return 1
  seen_repositoryformatversion=false
  seen_filemode=false
  seen_bare=false
  seen_logallrefupdates=false
  seen_ignorecase=false
  seen_precomposeunicode=false
  while IFS= read -r config_name || [ -n "$config_name" ]; do
    case "$config_name" in
      core.repositoryformatversion) [ "$seen_repositoryformatversion" = false ] || return 1; seen_repositoryformatversion=true ;;
      core.filemode) [ "$seen_filemode" = false ] || return 1; seen_filemode=true ;;
      core.bare) [ "$seen_bare" = false ] || return 1; seen_bare=true ;;
      core.logallrefupdates) [ "$seen_logallrefupdates" = false ] || return 1; seen_logallrefupdates=true ;;
      core.ignorecase) [ "$seen_ignorecase" = false ] || return 1; seen_ignorecase=true ;;
      core.precomposeunicode) [ "$seen_precomposeunicode" = false ] || return 1; seen_precomposeunicode=true ;;
      *) return 1 ;;
    esac
  done <<EOF
$config_names
EOF
  [ "$seen_repositoryformatversion" = true ] && [ "$seen_filemode" = true ] && [ "$seen_bare" = true ] && [ "$seen_logallrefupdates" = true ] || return 1
  [ "$(safe_git config --file "$metadata/config" --get core.repositoryformatversion)" = 0 ] || return 1
  case "$(safe_git config --file "$metadata/config" --get core.filemode)" in true|false) ;; *) return 1 ;; esac
  [ "$(safe_git config --file "$metadata/config" --get core.bare)" = false ] || return 1
  [ "$(safe_git config --file "$metadata/config" --get core.logallrefupdates)" = true ] || return 1
  if [ "$seen_ignorecase" = true ]; then
    case "$(safe_git config --file "$metadata/config" --get core.ignorecase)" in true|false) ;; *) return 1 ;; esac
  fi
  if [ "$seen_precomposeunicode" = true ]; then
    case "$(safe_git config --file "$metadata/config" --get core.precomposeunicode)" in true|false) ;; *) return 1 ;; esac
  fi
}

initialize_isolated_git_workspace() {
  initialize_git_workspace=$1
  stage_is_current || return 1
  isolated_git_workspace_matches "$initialize_git_workspace" || return 1
  empty_git_template_is_safe || return 1
  root_relative_path "$initialize_git_workspace" >/dev/null || return 1
  initialize_git_workspace_relative=${initialize_git_workspace#./}
  # The pre-init snapshot is a durable rollback intent for a normal, empty
  # Git workspace.  It is only recorded after every sibling workspace has a
  # known safe shape, so it never grants removal authority over injected
  # stage content.
  if isolated_git_stage_is_safe_for_snapshot; then
    checkpoint_stage_snapshot || return 1
  fi
  # The stage verifier intentionally walks both workspaces, so refresh these
  # per-workspace physical values only after it has returned.
  initialize_git_workspace_physical=$(cd -P -- "$initialize_git_workspace" && pwd -P) || return 1
  initialize_git_template_physical=$(cd -P -- "$INIT_GIT_TEMPLATE" && pwd -P) || return 1
  transaction_begin_critical_section || return 1
  (
    root_relative_directory_is_safe "$initialize_git_workspace_relative" || exit 1
    [ "$(pwd -P)" = "$initialize_git_workspace_physical" ] || exit 1
    safe_git init -q --template="$initialize_git_template_physical" .
  ) || { transaction_cancel_critical_section; return 1; }
  isolated_git_workspace_matches "$initialize_git_workspace" || { transaction_cancel_critical_section; return 1; }
  stage_is_current || { transaction_cancel_critical_section; return 1; }
  require_current_root || { transaction_cancel_critical_section; return 1; }
  [ -d "$initialize_git_workspace/.git" ] && [ ! -L "$initialize_git_workspace/.git" ] || { transaction_cancel_critical_section; return 1; }
  initialize_git_metadata_physical=$(cd -P -- "$initialize_git_workspace/.git" && pwd -P) || { transaction_cancel_critical_section; return 1; }
  initialize_git_workspace_expected=$(root_physical_path_for "$initialize_git_workspace") || { transaction_cancel_critical_section; return 1; }
  [ "$initialize_git_metadata_physical" = "$initialize_git_workspace_expected/.git" ] || { transaction_cancel_critical_section; return 1; }
  # Do not snapshot partial or polluted metadata: that would make unknown
  # `.git` entries eligible for a later rollback.  The second checkpoint is
  # the post-init ownership proof that makes a deferred signal removable.
  if isolated_git_stage_is_safe_for_snapshot; then
    checkpoint_stage_snapshot || { transaction_cancel_critical_section; return 1; }
    transaction_finish_critical_section
    return 0
  fi
  # Preserve the existing symmetric-pollution behavior: initialize both
  # isolated workspaces, then reject them together.  Crucially, no polluted
  # tree is snapshotted as owned; a signal during this branch therefore rolls
  # back only to the last trusted snapshot and retains the stage.
  transaction_finish_critical_section
  return 2
}

install_isolated_git_metadata_entry() {
  install_type=$1
  install_relative=$2
  install_value=$3
  [ "$install_relative" = . ] && return 0
  owned_new_git_is_unchanged || return 1
  isolated_git_workspace_matches "$INIT_GIT_CANDIDATE_WORKSPACE" || return 1
  tree_snapshot_matches "$INIT_GIT_CANDIDATE_WORKSPACE/.git" "$INIT_GIT_CANDIDATE_SNAPSHOT" || return 1
  require_current_root || return 1
  destination=$INIT_ROOT/.git
  install_path=${install_relative#/}
  next_git_snapshot=$(tree_snapshot_with_entry "$INIT_GIT_SNAPSHOT" "$install_type" "$install_relative" "$install_value") || return 1
  case "$install_type" in
    D)
      safe_root_mkdir "$destination/$install_path" || return 1
      ;;
    R)
      install_source=$INIT_GIT_CANDIDATE_WORKSPACE/.git/$install_path
      [ ! -L "$install_source" ] && [ -f "$install_source" ] || return 1
      case "$install_path" in
        */*) install_parent=$destination/${install_path%/*}; install_name=${install_path##*/} ;;
        *) install_parent=$destination; install_name=$install_path ;;
      esac
      safe_root_link "$install_source" "$install_parent" "$install_name" || return 1
      ;;
    *) return 1 ;;
  esac
  INIT_GIT_SNAPSHOT=$next_git_snapshot
  owned_new_git_is_unchanged
}

install_isolated_git_metadata() {
  candidate_snapshot=$1
  INIT_GIT_CANDIDATE_SNAPSHOT=$candidate_snapshot
  destination=$INIT_ROOT/.git
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
  isolated_git_workspace_matches "$INIT_GIT_CANDIDATE_WORKSPACE" || return 1
  tree_snapshot_matches "$INIT_GIT_CANDIDATE_WORKSPACE/.git" "$candidate_snapshot" || return 1
  pristine_git_metadata_is_valid "$INIT_GIT_CANDIDATE_WORKSPACE/.git" || return 1
  safe_root_mkdir "$destination" || return 1
  safe_root_link "$INIT_GIT_MARKER" "$destination" .superteam-project-owner || return 1
  INIT_CREATED_GIT=true
  INIT_GIT_SNAPSHOT=$(tree_snapshot_with_entry '' D . -) || return 1
  INIT_GIT_SNAPSHOT=$(tree_snapshot_with_regular_entry "$INIT_GIT_SNAPSHOT" '/.superteam-project-owner' "$INIT_GIT_MARKER_FINGERPRINT") || return 1
  INIT_GIT_SNAPSHOT_READY=true
  owned_new_git_is_unchanged || return 1
  while IFS=$'\t' read -r install_type install_relative install_value || [ -n "$install_type" ]; do
    install_isolated_git_metadata_entry "$install_type" "$install_relative" "$install_value" || return 1
  done <<EOF
$candidate_snapshot
EOF
  owned_new_git_is_unchanged
}

create_new_root_repository() {
  require_current_root || return 1
  stage_is_current || {
    fail 'initialization staging directory changed before Root Repository metadata could be created.'
    return 1
  }
  INIT_CREATED_GIT=false
  INIT_GIT_SNAPSHOT_READY=false
  INIT_GIT_SNAPSHOT=''
  INIT_FINAL_GIT_SNAPSHOT=''
  INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT=''
  INIT_GIT_MARKER=$INIT_STAGE/git-owner
  INIT_GIT_MARKER_FINGERPRINT=''
  [ ! -e "$INIT_ROOT/.git" ] && [ ! -L "$INIT_ROOT/.git" ] || {
    fail 'Root Repository metadata appeared during initialization; no files were applied.'
    return 1
  }
  verify_stage_snapshot || return 1
  INIT_GIT_TEMPLATE=$INIT_STAGE/git-template
  INIT_GIT_BASELINE_WORKSPACE=$INIT_STAGE/git-baseline
  INIT_GIT_CANDIDATE_WORKSPACE=$INIT_STAGE/git-root
  safe_root_mkdir "$INIT_GIT_TEMPLATE" || {
    fail 'could not prepare isolated Root Repository metadata.'
    return 1
  }
  empty_git_template_is_safe || {
    fail 'could not prepare isolated Root Repository metadata.'
    return 1
  }
  claim_isolated_git_workspace "$INIT_GIT_BASELINE_WORKSPACE" && claim_isolated_git_workspace "$INIT_GIT_CANDIDATE_WORKSPACE" || {
    fail 'could not prepare isolated Root Repository metadata.'
    return 1
  }
  git_workspace_unsafe=false
  if initialize_isolated_git_workspace "$INIT_GIT_BASELINE_WORKSPACE"; then
    git_baseline_init_status=0
  else
    git_baseline_init_status=$?
  fi
  case "$git_baseline_init_status" in
    0) ;;
    2) git_workspace_unsafe=true ;;
    *) fail 'could not record isolated Root Repository metadata.'; return 1 ;;
  esac
  if initialize_isolated_git_workspace "$INIT_GIT_CANDIDATE_WORKSPACE"; then
    git_candidate_init_status=0
  else
    git_candidate_init_status=$?
  fi
  case "$git_candidate_init_status" in
    0) ;;
    2) git_workspace_unsafe=true ;;
    *) fail 'could not record isolated Root Repository metadata.'; return 1 ;;
  esac
  [ "$git_workspace_unsafe" = false ] || {
    fail 'isolated Root Repository metadata changed during initialization; no files were applied.'
    return 1
  }
  git_baseline_snapshot=$(tree_snapshot "$INIT_GIT_BASELINE_WORKSPACE/.git") || return 1
  git_candidate_snapshot=$(tree_snapshot "$INIT_GIT_CANDIDATE_WORKSPACE/.git") || return 1
  pristine_git_metadata_is_valid "$INIT_GIT_BASELINE_WORKSPACE/.git" && pristine_git_metadata_is_valid "$INIT_GIT_CANDIDATE_WORKSPACE/.git" || {
    fail 'isolated Root Repository metadata changed during initialization; no files were applied.'
    return 1
  }
  [ "$git_candidate_snapshot" = "$git_baseline_snapshot" ] || {
    fail 'isolated Root Repository metadata changed during initialization; no files were applied.'
    return 1
  }
  safe_root_create_empty_file "$INIT_STAGE" git-owner || {
    fail 'could not mark the new Root Repository metadata directory.'
    return 1
  }
  INIT_GIT_MARKER_FINGERPRINT=$(file_fingerprint "$INIT_GIT_MARKER") || {
    fail 'could not mark the new Root Repository metadata directory.'
    return 1
  }
  checkpoint_stage_snapshot || return 1
  install_isolated_git_metadata "$git_candidate_snapshot" || {
    fail 'could not install the new Root Repository metadata.'
    return 1
  }
  owned_new_git_is_unchanged || {
    fail 'new Root Repository metadata changed during initialization.'
    return 1
  }
  INIT_RUNTIME_GIT_IDENTITY=$(git_identity_for "$INIT_ROOT") || {
    fail 'could not identify the new Root Repository.'
    return 1
  }
}

finalize_new_root_repository() {
  [ "$INIT_CREATED_GIT" = true ] || return 0
  owned_new_git_is_unchanged || {
    fail 'new Root Repository metadata changed before completion.'
    return 1
  }
  INIT_FINAL_GIT_SNAPSHOT=$(tree_snapshot_without_entry "$INIT_GIT_SNAPSHOT" '/.superteam-project-owner') || {
    fail 'could not record the finalized Root Repository metadata.'
    return 1
  }
  git_ownership_before_finalize=$(tree_ownership_snapshot "$INIT_ROOT/.git") || {
    fail 'could not record finalized Root Repository metadata ownership.'
    return 1
  }
  INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT=$(tree_ownership_snapshot_without_entry "$git_ownership_before_finalize" '/.superteam-project-owner') || {
    fail 'could not record finalized Root Repository metadata ownership.'
    return 1
  }
  safe_root_remove_file "$INIT_ROOT/.git" .superteam-project-owner "$INIT_GIT_MARKER" "$INIT_GIT_MARKER_FINGERPRINT" || {
    fail 'could not finalize the new Root Repository metadata.'
    return 1
  }
  [ ! -e "$INIT_ROOT/.git/.superteam-project-owner" ] && [ ! -L "$INIT_ROOT/.git/.superteam-project-owner" ] || {
    fail 'new Root Repository metadata changed during finalization.'
    return 1
  }
  final_new_git_is_unchanged || {
    fail 'new Root Repository metadata changed during finalization.'
    return 1
  }
  final_new_git_is_unchanged || {
    fail 'new Root Repository metadata changed during finalization.'
    return 1
  }
}

record_created_directory() {
  verify_stage_snapshot || return 1
  INIT_CREATED_RECORDS+="$1"
  INIT_CREATED_RECORDS+=$'\t'
  INIT_CREATED_RECORDS+="$2"
  INIT_CREATED_RECORDS+=$'\t'
  INIT_CREATED_RECORDS+="$3"
  INIT_CREATED_RECORDS+=$'\n'
}

record_owned_asset() {
  verify_stage_snapshot || return 1
  INIT_OWNED_ASSET_RECORDS+="$1"
  INIT_OWNED_ASSET_RECORDS+=$'\t'
  INIT_OWNED_ASSET_RECORDS+="$2"
  INIT_OWNED_ASSET_RECORDS+=$'\t'
  INIT_OWNED_ASSET_RECORDS+="$3"
  INIT_OWNED_ASSET_RECORDS+=$'\t'
  INIT_OWNED_ASSET_RECORDS+="$4"
  INIT_OWNED_ASSET_RECORDS+=$'\t'
  INIT_OWNED_ASSET_RECORDS+="$5"
  INIT_OWNED_ASSET_RECORDS+=$'\n'
}

claim_owned_directory() {
  claimed_directory=$1
  INIT_OWNERSHIP_COUNT=$((INIT_OWNERSHIP_COUNT + 1))
  claimed_marker=$INIT_STAGE/ownership/$INIT_OWNERSHIP_COUNT
  verify_stage_snapshot || return 1
  safe_root_create_empty_file "$INIT_STAGE/ownership" "$INIT_OWNERSHIP_COUNT" || { fail 'could not create an initialization ownership marker.'; return 1; }
  claimed_marker_fingerprint=$(file_fingerprint "$claimed_marker") || { fail 'could not create an initialization ownership marker.'; return 1; }
  checkpoint_stage_snapshot || return 1
  safe_root_mkdir "$claimed_directory" || { fail 'could not claim an initialization directory.'; return 1; }
  record_created_directory "$claimed_directory" "$claimed_marker" "$claimed_marker_fingerprint" || {
    report_rollback_problem
    fail 'could not record an initialization directory as owned.'
    return 1
  }
  safe_root_link "$claimed_marker" "$claimed_directory" .superteam-project-owner || {
    fail 'could not mark an initialization directory as owned.'
    return 1
  }
  CLAIMED_DIRECTORY_MARKER=$claimed_marker
  CLAIMED_DIRECTORY_MARKER_FINGERPRINT=$claimed_marker_fingerprint
}

ensure_destination_parents() {
  remaining=$1
  current=$INIT_ROOT
  while :; do
    next_path_component "$remaining"
    [ -n "$NEXT_REMAINING" ] || break
    current=$current/$NEXT_COMPONENT
    if [ -L "$current" ]; then
      fail 'a destination parent changed to a symbolic link during initialization.'
      return 1
    fi
    if [ -e "$current" ]; then
      [ -d "$current" ] || { fail 'a destination parent changed to a non-directory during initialization.'; return 1; }
    else
      claim_owned_directory "$current" || return 1
    fi
    remaining=$NEXT_REMAINING
  done
}

install_new_asset() {
  relative=$1
  staged=$2
  destination=$INIT_ROOT/$relative
  ensure_destination_parents "$relative" || return 1
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    fail 'an asset destination appeared during initialization.'
    return 1
  fi
  claim_owned_directory "$destination" || { fail 'could not claim the asset destination.'; return 1; }
  if [ -f "$staged/README.md" ]; then
    staged_reference=$staged/README.md
    if [ "$relative" = "$INIT_TASK" ]; then
      staged_reference=$INIT_TASK_README_REFERENCE
    elif [ "$relative" = "$INIT_KNOWLEDGE" ]; then
      staged_reference=$INIT_KNOWLEDGE_README_REFERENCE
    fi
    staged_fingerprint=$(file_fingerprint "$staged_reference") || { fail 'could not record the asset skeleton.'; return 1; }
    if [ "$relative" = "$INIT_TASK" ]; then
      INIT_TASK_README_FINGERPRINT=$staged_fingerprint
    elif [ "$relative" = "$INIT_KNOWLEDGE" ]; then
      INIT_KNOWLEDGE_README_FINGERPRINT=$staged_fingerprint
    fi
    if ! record_owned_asset "$destination" "$CLAIMED_DIRECTORY_MARKER" "$CLAIMED_DIRECTORY_MARKER_FINGERPRINT" "$staged_reference" "$staged_fingerprint"; then
      fail 'could not record an owned asset.'
      return 1
    fi
    safe_root_link "$staged_reference" "$destination" README.md || { fail 'could not install the asset skeleton.'; return 1; }
    owned_regular_file_matches "$destination/README.md" "$staged_reference" "$staged_fingerprint" || {
      fail 'the asset skeleton changed during installation.'
      return 1
    }
  fi
}

verify_adopted_asset() {
  require_current_root || return 1
  relative=$1
  label=$2
  remaining=$relative
  current=$INIT_ROOT
  while :; do
    next_path_component "$remaining"
    current=$current/$NEXT_COMPONENT
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      fail "adopted $label directory changed before superteam.yaml could be written."
      return 1
    fi
    remaining=$NEXT_REMAINING
    [ -n "$remaining" ] || break
  done
  if [ ! -d "$current" ]; then
    fail "adopted $label directory changed before superteam.yaml could be written."
    return 1
  fi
  physical=$(cd -P -- "$current" && pwd -P) || {
    fail "adopted $label directory changed before superteam.yaml could be written."
    return 1
  }
  case "$physical" in
    "$INIT_ROOT_PHYSICAL"/*) ;;
    *) fail "adopted $label directory changed before superteam.yaml could be written."; return 1 ;;
  esac
}

verify_adopted_assets() {
  [ "$INIT_TASK_EXISTING" != true ] || verify_adopted_asset "$INIT_TASK" task || return 1
  [ "$INIT_KNOWLEDGE_EXISTING" != true ] || verify_adopted_asset "$INIT_KNOWLEDGE" knowledge || return 1
}

verify_final_asset_boundary() {
  relative=$1
  label=$2
  destination=$INIT_ROOT/$relative
  require_current_root || return 1
  validate_asset_ancestors "$INIT_ROOT" "$relative" "$label" || return 1
  if asset_path_has_symlink "$INIT_ROOT" "$relative" "$label"; then
    return 1
  fi
  [ -d "$destination" ] || {
    fail "${label} directory changed before superteam.yaml could be written."
    return 1
  }
  physical=$(cd -P -- "$destination" && pwd -P) || {
    fail "${label} directory changed before superteam.yaml could be written."
    return 1
  }
  case "$physical" in
    "$INIT_ROOT_PHYSICAL"/*) ;;
    *) fail "${label} directory changed before superteam.yaml could be written."; return 1 ;;
  esac
  asset_path_crosses_independent_git_root "$INIT_ROOT" "$relative" "$label" || return 1
}

verify_owned_asset_readme() {
  relative=$1
  label=$2
  existing=$3
  [ "$existing" = false ] || return 0
  destination=$INIT_ROOT/$relative
  skeleton_reference=''
  expected_fingerprint=''
  if [ "$relative" = "$INIT_TASK" ]; then
    skeleton_reference=$INIT_TASK_README_REFERENCE
    expected_fingerprint=$INIT_TASK_README_FINGERPRINT
  elif [ "$relative" = "$INIT_KNOWLEDGE" ]; then
    skeleton_reference=$INIT_KNOWLEDGE_README_REFERENCE
    expected_fingerprint=$INIT_KNOWLEDGE_README_FINGERPRINT
  fi
  [ -n "$skeleton_reference" ] && [ -n "$expected_fingerprint" ] || {
    fail "could not prove ownership of the new $label README."
    return 1
  }
  require_current_root || return 1
  owned_regular_file_matches "$destination/README.md" "$skeleton_reference" "$expected_fingerprint" || {
    fail "$label README changed before completion."
    return 1
  }
}

verify_final_asset_boundaries() {
  verify_final_asset_boundary "$INIT_TASK" task || return 1
  verify_final_asset_boundary "$INIT_KNOWLEDGE" knowledge || return 1
  verify_owned_asset_readme "$INIT_TASK" task "$INIT_TASK_EXISTING" || return 1
  verify_owned_asset_readme "$INIT_KNOWLEDGE" knowledge "$INIT_KNOWLEDGE_EXISTING" || return 1
}

metadata_gitignore_is_current() {
  [ "$INIT_ROOT_MODE" = METADATA_ONLY ] || return 0
  gitignore=$INIT_ROOT/.gitignore
  require_current_root || return 1
  owned_regular_file_matches "$gitignore" "$INIT_GITIGNORE_REFERENCE" "$INIT_GITIGNORE_FINGERPRINT" || return 1
  expected_gitignore=$(render_metadata_gitignore "$INIT_TASK" "$INIT_KNOWLEDGE") || return 1
  actual_gitignore=$(cat "$gitignore") || return 1
  [ "$actual_gitignore" = "$expected_gitignore" ]
}

install_metadata_gitignore() {
  [ "$INIT_ROOT_MODE" = METADATA_ONLY ] || return 0
  gitignore=$INIT_ROOT/.gitignore
  staged_gitignore=$INIT_GITIGNORE_REFERENCE
  require_current_root || return 1
  [ ! -e "$gitignore" ] && [ ! -L "$gitignore" ] || {
    fail '.gitignore appeared during metadata-only initialization; no files were applied.'
    return 1
  }
  safe_root_link "$staged_gitignore" "$INIT_ROOT" .gitignore || {
    fail 'could not atomically install the metadata-only .gitignore.'
    return 1
  }
  INIT_GITIGNORE_INSTALLED=true
  if [ -L "$gitignore" ] || [ ! -f "$gitignore" ]; then
    INIT_GITIGNORE_NESTED_PATH=$gitignore/$(basename "$staged_gitignore")
    fail '.gitignore changed type during metadata-only initialization; no files were applied.'
    return 1
  fi
  if [ ! "$gitignore" -ef "$staged_gitignore" ]; then
    fail '.gitignore changed during metadata-only initialization; no files were applied.'
    return 1
  fi
  metadata_gitignore_is_current || {
    fail '.gitignore changed during metadata-only initialization; no files were applied.'
    return 1
  }
}

install_manifest() {
  manifest=$INIT_ROOT/superteam.yaml
  staged_manifest=$INIT_MANIFEST_REFERENCE
  require_current_root || return 1
  [ ! -e "$manifest" ] && [ ! -L "$manifest" ] || {
    fail 'superteam.yaml appeared during initialization; no files were applied.'
    return 1
  }
  safe_root_link "$staged_manifest" "$INIT_ROOT" superteam.yaml || {
    if [ -L "$manifest" ] || { [ -e "$manifest" ] && [ ! -f "$manifest" ]; }; then
      fail 'superteam.yaml changed type during initialization; no files were applied.'
      return 1
    fi
    fail 'could not atomically install superteam.yaml.'
    return 1
  }
  INIT_MANIFEST_INSTALLED=true
  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
    INIT_MANIFEST_NESTED_PATH=$manifest/$(basename "$staged_manifest")
    fail 'superteam.yaml changed type during initialization; no files were applied.'
    return 1
  fi
  if [ ! "$manifest" -ef "$staged_manifest" ]; then
    fail 'superteam.yaml changed during initialization; no files were applied.'
    return 1
  fi
  manifest_is_current || {
    fail 'superteam.yaml changed during initialization; no files were applied.'
    return 1
  }
  require_current_root || {
    fail 'Root Repository changed during manifest installation; no files were applied.'
    return 1
  }
}

manifest_is_current() {
  manifest=$INIT_ROOT/superteam.yaml
  staged_manifest=$INIT_MANIFEST_REFERENCE
  require_current_root || return 1
  owned_regular_file_matches "$manifest" "$staged_manifest" "$INIT_MANIFEST_FINGERPRINT" || return 1
  parse_manifest "$INIT_ROOT" || return 1
  [ "$MANIFEST_TASK" = "$INIT_TASK" ] && [ "$MANIFEST_KNOWLEDGE" = "$INIT_KNOWLEDGE" ]
}

verify_final_root_repository() {
  require_current_root || return 1
  final_root=$(git_root_for "$INIT_ROOT" 2>/dev/null || true)
  [ -n "$final_root" ] || {
    fail 'Root Repository mode changed during initialization; no files were applied.'
    return 1
  }
  final_root=$(resolve_directory "$final_root") || return 1
  [ "$final_root" = "$INIT_ROOT_PHYSICAL" ] || {
    fail 'Root Repository changed during initialization; no files were applied.'
    return 1
  }
  final_identity=$(git_identity_for "$INIT_ROOT") || {
    fail 'could not identify the Root Repository during initialization.'
    return 1
  }
  if [ "$INIT_CONFIRMED_ROOT_MODE" = EXISTING ]; then
    [ "$final_identity" = "$INIT_CONFIRMED_GIT_IDENTITY" ] || {
      fail 'Root Repository identity changed during initialization; no files were applied.'
      return 1
    }
  else
    [ "$final_identity" = "$INIT_RUNTIME_GIT_IDENTITY" ] || {
      fail 'new Root Repository identity changed during initialization; no files were applied.'
      return 1
    }
  fi
}

verify_final_transaction_state() {
  verify_stage_snapshot || return 1
  verify_final_asset_boundaries || return 1
  manifest_is_current || {
    fail 'superteam.yaml changed during initialization; no files were applied.'
    return 1
  }
  metadata_gitignore_is_current || {
    fail '.gitignore changed during metadata-only initialization; no files were applied.'
    return 1
  }
  verify_final_root_repository || return 1
  if [ "$INIT_CREATED_GIT" = true ]; then
    if [ -n "$INIT_FINAL_GIT_SNAPSHOT" ]; then
      final_new_git_is_unchanged || {
        fail 'new Root Repository metadata changed during finalization.'
        return 1
      }
    else
      owned_new_git_is_unchanged || {
        fail 'new Root Repository metadata changed before completion.'
        return 1
      }
    fi
  fi
}

published_manifest_is_current() {
  manifest=$INIT_ROOT/superteam.yaml
  owned_regular_file_matches "$manifest" "$INIT_MANIFEST_REFERENCE" "$INIT_MANIFEST_FINGERPRINT" || return 1
  parse_manifest "$INIT_ROOT" || return 1
  [ "$MANIFEST_TASK" = "$INIT_TASK" ] && [ "$MANIFEST_KNOWLEDGE" = "$INIT_KNOWLEDGE" ]
}

verify_published_result_state() {
  verify_final_asset_boundaries || return 1
  published_manifest_is_current || {
    fail 'superteam.yaml changed during finalization; no successful result was reported.'
    return 1
  }
  metadata_gitignore_is_current || {
    fail '.gitignore changed during finalization; no successful result was reported.'
    return 1
  }
  verify_final_root_repository || return 1
  final_new_git_is_unchanged
}

owned_regular_file_matches() {
  owned_file=$1
  owned_reference=$2
  owned_fingerprint=''
  [ "$#" -lt 3 ] || owned_fingerprint=$3
  [ ! -L "$owned_file" ] && [ -f "$owned_file" ] && [ ! -L "$owned_reference" ] && [ -f "$owned_reference" ] && [ "$owned_file" -ef "$owned_reference" ] || return 1
  if [ -n "$owned_fingerprint" ]; then
    owned_actual_fingerprint=$(file_fingerprint "$owned_file") || return 1
    [ "$owned_actual_fingerprint" = "$owned_fingerprint" ] || return 1
    owned_reference_fingerprint=$(file_fingerprint "$owned_reference") || return 1
    [ "$owned_reference_fingerprint" = "$owned_fingerprint" ] || return 1
  fi
}

owned_directory_matches() {
  owned_directory=$1
  marker_reference=$2
  marker_fingerprint=$3
  [ ! -L "$owned_directory" ] && [ -d "$owned_directory" ] || return 1
  owned_physical=$(cd -P -- "$owned_directory" && pwd -P) || return 1
  owned_expected=$(root_physical_path_for "$owned_directory") || return 1
  [ "$owned_physical" = "$owned_expected" ] || return 1
  owned_regular_file_matches "$owned_directory/.superteam-project-owner" "$marker_reference" "$marker_fingerprint"
}

directory_has_only_owner_marker() {
  directory=$1
  for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "$entry" = "$directory/.superteam-project-owner" ] && continue
    return 1
  done
  return 0
}

report_rollback_problem() {
  printf '%s\n' 'ERROR: could not complete initialization rollback safely; concurrent content was retained.' >&2
}

remove_owned_tree() {
  removal_directory=$1
  removal_snapshot=$2
  removal_marker=$3
  removal_reference=$4
  removal_marker_fingerprint=$5
  tree_snapshot_matches "$removal_directory" "$removal_snapshot" || return 1
  owned_regular_file_matches "$removal_marker" "$removal_reference" "$removal_marker_fingerprint" || return 1
  while IFS=$'\t' read -r removal_type removal_relative removal_expected || [ -n "$removal_type" ]; do
    case "$removal_type" in
      R|L)
        removal_path=$removal_directory
        [ "$removal_relative" = . ] || removal_path=$(printf '%s/%s' "$removal_directory" "${removal_relative#/}")
        split_internal_root_path "$removal_path" || return 1
        if [ "$removal_marker" = "$removal_path" ]; then
          safe_root_remove_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$removal_reference" "$removal_marker_fingerprint" || return 1
        else
          safe_root_remove_snapshot_entry "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$removal_type" "$removal_expected" || return 1
        fi
        ;;
    esac
  done <<EOF
$removal_snapshot
EOF
  while IFS=$'\t' read -r removal_type removal_relative removal_expected || [ -n "$removal_type" ]; do
    [ "$removal_type" = D ] || continue
    tree_snapshot_entry_matches "$removal_directory" "$removal_type" "$removal_relative" "$removal_expected" || return 1
    removal_path=$removal_directory
    [ "$removal_relative" = . ] || removal_path=$(printf '%s/%s' "$removal_directory" "${removal_relative#/}")
    split_internal_root_path "$removal_path" || return 1
    safe_root_rmdir "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" || return 1
  done <<EOF
$(printf '%s\n' "$removal_snapshot" | LC_ALL=C sort -r)
EOF
}

remove_finalized_new_git_tree() {
  [ "$INIT_CREATED_GIT" = true ] || return 1
  [ -n "$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT" ] || return 1
  final_new_git_is_unchanged || return 1
  while IFS=$'\t' read -r finalized_type finalized_relative finalized_inode finalized_fingerprint || [ -n "$finalized_type" ]; do
    [ "$finalized_type" = R ] || continue
    finalized_path=$INIT_ROOT/.git/${finalized_relative#/}
    split_internal_root_path "$finalized_path" || return 1
    safe_root_remove_owned_snapshot_file "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$finalized_inode" "$finalized_fingerprint" || return 1
  done <<EOF
$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT
EOF
  while IFS=$'\t' read -r finalized_type finalized_relative finalized_inode finalized_fingerprint || [ -n "$finalized_type" ]; do
    [ "$finalized_type" = D ] || continue
    finalized_path=$INIT_ROOT/.git
    [ "$finalized_relative" = . ] || finalized_path=$INIT_ROOT/.git/${finalized_relative#/}
    split_internal_root_path "$finalized_path" || return 1
    safe_root_rmdir_owned_snapshot "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$finalized_inode" || return 1
  done <<EOF
$(printf '%s\n' "$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT" | LC_ALL=C sort -r)
EOF
}

cleanup_owned_stage() {
  [ "$INIT_STAGE_OWNED" = true ] || return 0
  [ "$INIT_STAGE_SNAPSHOT_READY" = true ] || {
    report_rollback_problem
    return 1
  }
  remove_owned_tree "$INIT_STAGE" "$INIT_STAGE_SNAPSHOT" "$INIT_STAGE/.superteam-project-owner" "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT" || {
    report_rollback_problem
    return 1
  }
  safe_root_remove_path "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT" || {
    report_rollback_problem
    return 1
  }
  INIT_STAGE=''
  INIT_STAGE_IDENTITY=''
  INIT_STAGE_OWNED=false
  INIT_STAGE_SNAPSHOT=''
  INIT_STAGE_SNAPSHOT_READY=false
}

cleanup_owned_assets() {
  [ -n "$INIT_OWNED_ASSET_RECORDS" ] || return 0
  while IFS=$'\t' read -r owned_asset owned_marker owned_marker_fingerprint owned_skeleton owned_skeleton_fingerprint || [ -n "$owned_asset" ]; do
    [ -n "$owned_asset" ] || continue
    if ! owned_directory_matches "$owned_asset" "$owned_marker" "$owned_marker_fingerprint"; then
      report_rollback_problem
      continue
    fi
    if [ -e "$owned_asset/README.md" ] || [ -L "$owned_asset/README.md" ]; then
      if owned_regular_file_matches "$owned_asset/README.md" "$owned_skeleton" "$owned_skeleton_fingerprint"; then
        safe_root_remove_file "$owned_asset" README.md "$owned_skeleton" "$owned_skeleton_fingerprint" || report_rollback_problem
      else
        report_rollback_problem
      fi
    fi
  done <<EOF
$INIT_OWNED_ASSET_RECORDS
EOF
}

cleanup_created_directories() {
  [ -n "$INIT_CREATED_RECORDS" ] || return 0
  while :; do
    removed=false
    while IFS=$'\t' read -r created created_marker created_marker_fingerprint || [ -n "$created" ]; do
      if owned_directory_matches "$created" "$created_marker" "$created_marker_fingerprint" && directory_has_only_owner_marker "$created"; then
        if safe_root_remove_file "$created" .superteam-project-owner "$created_marker" "$created_marker_fingerprint" && split_internal_root_path "$created" && safe_root_rmdir "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF"; then
          removed=true
        else
          report_rollback_problem
        fi
      fi
    done <<EOF
$INIT_CREATED_RECORDS
EOF
    [ "$removed" = true ] || break
  done
  while IFS=$'\t' read -r created created_marker created_marker_fingerprint || [ -n "$created" ]; do
    [ -n "$created" ] || continue
    [ ! -e "$created" ] && [ ! -L "$created" ] && continue
    if owned_directory_matches "$created" "$created_marker" "$created_marker_fingerprint"; then
      safe_root_remove_file "$created" .superteam-project-owner "$created_marker" "$created_marker_fingerprint" || true
    fi
    report_rollback_problem
  done <<EOF
$INIT_CREATED_RECORDS
EOF
}

cleanup_manifest() {
  staged_manifest=$INIT_MANIFEST_REFERENCE
  if [ "$INIT_FINALIZATION_OWNERSHIP_READY" = true ] && [ "$INIT_MANIFEST_INSTALLED" = true ]; then
    if [ -n "$INIT_FINAL_MANIFEST_INODE" ] && [ -n "$INIT_FINAL_MANIFEST_FINGERPRINT" ]; then
      safe_root_remove_owned_snapshot_file . superteam.yaml "$INIT_FINAL_MANIFEST_INODE" "$INIT_FINAL_MANIFEST_FINGERPRINT" || report_rollback_problem
    else
      report_rollback_problem
    fi
    return 0
  fi
  if [ -n "$INIT_MANIFEST_NESTED_PATH" ] && [ -f "$staged_manifest" ]; then
    if owned_regular_file_matches "$INIT_MANIFEST_NESTED_PATH" "$staged_manifest" "$INIT_MANIFEST_FINGERPRINT"; then
      safe_root_remove_path "$INIT_MANIFEST_NESTED_PATH" "$staged_manifest" "$INIT_MANIFEST_FINGERPRINT" || report_rollback_problem
    elif [ -e "$INIT_MANIFEST_NESTED_PATH" ] || [ -L "$INIT_MANIFEST_NESTED_PATH" ]; then
      report_rollback_problem
    fi
  fi
  if [ "$INIT_MANIFEST_INSTALLED" = true ]; then
    manifest=$INIT_ROOT/superteam.yaml
    if owned_regular_file_matches "$manifest" "$staged_manifest" "$INIT_MANIFEST_FINGERPRINT"; then
      safe_root_remove_path "$manifest" "$staged_manifest" "$INIT_MANIFEST_FINGERPRINT" || report_rollback_problem
    else
      report_rollback_problem
    fi
  fi
}

cleanup_metadata_gitignore() {
  [ "$INIT_GITIGNORE_INSTALLED" = true ] || return 0
  staged_gitignore=$INIT_GITIGNORE_REFERENCE
  if [ -n "$INIT_GITIGNORE_NESTED_PATH" ] && [ -f "$staged_gitignore" ]; then
    if owned_regular_file_matches "$INIT_GITIGNORE_NESTED_PATH" "$staged_gitignore" "$INIT_GITIGNORE_FINGERPRINT"; then
      safe_root_remove_path "$INIT_GITIGNORE_NESTED_PATH" "$staged_gitignore" "$INIT_GITIGNORE_FINGERPRINT" || report_rollback_problem
    elif [ -e "$INIT_GITIGNORE_NESTED_PATH" ] || [ -L "$INIT_GITIGNORE_NESTED_PATH" ]; then
      report_rollback_problem
    fi
  fi
  gitignore=$INIT_ROOT/.gitignore
  if owned_regular_file_matches "$gitignore" "$staged_gitignore" "$INIT_GITIGNORE_FINGERPRINT"; then
    safe_root_remove_path "$gitignore" "$staged_gitignore" "$INIT_GITIGNORE_FINGERPRINT" || report_rollback_problem
  elif [ -e "$gitignore" ] || [ -L "$gitignore" ]; then
    report_rollback_problem
  fi
}

remove_retained_reference() {
  retained_reference=$1
  retained_fingerprint=$2
  [ -n "$retained_reference" ] || return 0
  [ ! -e "$retained_reference" ] && [ ! -L "$retained_reference" ] && return 0
  [ ! -L "$retained_reference" ] && [ -f "$retained_reference" ] || return 1
  retained_actual_fingerprint=$(file_fingerprint "$retained_reference") || return 1
  [ "$retained_actual_fingerprint" = "$retained_fingerprint" ] || return 1
  safe_root_remove_path "$retained_reference" "$retained_reference" "$retained_fingerprint"
}

cleanup_retained_references() {
  remove_retained_reference "$INIT_TASK_README_REFERENCE" "$INIT_TASK_README_FINGERPRINT" || return 1
  remove_retained_reference "$INIT_KNOWLEDGE_README_REFERENCE" "$INIT_KNOWLEDGE_README_FINGERPRINT" || return 1
  remove_retained_reference "$INIT_MANIFEST_REFERENCE" "$INIT_MANIFEST_FINGERPRINT" || return 1
  remove_retained_reference "$INIT_GITIGNORE_REFERENCE" "$INIT_GITIGNORE_FINGERPRINT"
}

verify_owned_directories() {
  while IFS=$'\t' read -r created created_marker created_marker_fingerprint || [ -n "$created" ]; do
    [ -n "$created" ] || continue
    owned_directory_matches "$created" "$created_marker" "$created_marker_fingerprint" || {
      fail 'an initialization directory changed before completion.'
      return 1
    }
  done <<EOF
$INIT_CREATED_RECORDS
EOF
}

capture_finalization_ownership() {
  final_manifest=$INIT_ROOT/superteam.yaml
  INIT_FINALIZATION_OWNERSHIP_READY=false
  INIT_FINAL_CREATED_DIRECTORY_RECORDS=''
  INIT_FINAL_OWNED_ASSET_RECORDS=''
  INIT_FINAL_MANIFEST_INODE=''
  INIT_FINAL_MANIFEST_FINGERPRINT=''
  owned_regular_file_matches "$final_manifest" "$INIT_MANIFEST_REFERENCE" "$INIT_MANIFEST_FINGERPRINT" || {
    fail 'superteam.yaml changed before finalization ownership could be recorded.'
    return 1
  }
  INIT_FINAL_MANIFEST_INODE=$(filesystem_inode_for "$final_manifest") || {
    fail 'could not record finalized superteam.yaml ownership.'
    return 1
  }
  INIT_FINAL_MANIFEST_FINGERPRINT=$(file_fingerprint "$final_manifest") || {
    fail 'could not record finalized superteam.yaml ownership.'
    return 1
  }
  while IFS=$'\t' read -r final_created final_created_marker final_created_marker_fingerprint || [ -n "$final_created" ]; do
    [ -n "$final_created" ] || continue
    owned_directory_matches "$final_created" "$final_created_marker" "$final_created_marker_fingerprint" || {
      fail 'an initialization directory changed before finalization ownership could be recorded.'
      return 1
    }
    final_created_inode=$(filesystem_inode_for "$final_created") || {
      fail 'could not record finalized initialization directory ownership.'
      return 1
    }
    INIT_FINAL_CREATED_DIRECTORY_RECORDS+="$final_created"
    INIT_FINAL_CREATED_DIRECTORY_RECORDS+=$'\t'
    INIT_FINAL_CREATED_DIRECTORY_RECORDS+="$final_created_inode"
    INIT_FINAL_CREATED_DIRECTORY_RECORDS+=$'\n'
  done <<EOF
$INIT_CREATED_RECORDS
EOF
  while IFS=$'\t' read -r final_asset final_asset_marker final_asset_marker_fingerprint final_asset_reference final_asset_fingerprint || [ -n "$final_asset" ]; do
    [ -n "$final_asset" ] || continue
    owned_directory_matches "$final_asset" "$final_asset_marker" "$final_asset_marker_fingerprint" || {
      fail 'an initialization asset directory changed before finalization ownership could be recorded.'
      return 1
    }
    owned_regular_file_matches "$final_asset/README.md" "$final_asset_reference" "$final_asset_fingerprint" || {
      fail 'an initialization asset README changed before finalization ownership could be recorded.'
      return 1
    }
    final_asset_directory_inode=$(filesystem_inode_for "$final_asset") || {
      fail 'could not record finalized initialization asset ownership.'
      return 1
    }
    final_asset_readme_inode=$(filesystem_inode_for "$final_asset/README.md") || {
      fail 'could not record finalized initialization asset ownership.'
      return 1
    }
    final_asset_readme_fingerprint=$(file_fingerprint "$final_asset/README.md") || {
      fail 'could not record finalized initialization asset ownership.'
      return 1
    }
    INIT_FINAL_OWNED_ASSET_RECORDS+="$final_asset"
    INIT_FINAL_OWNED_ASSET_RECORDS+=$'\t'
    INIT_FINAL_OWNED_ASSET_RECORDS+="$final_asset_directory_inode"
    INIT_FINAL_OWNED_ASSET_RECORDS+=$'\t'
    INIT_FINAL_OWNED_ASSET_RECORDS+="$final_asset_readme_inode"
    INIT_FINAL_OWNED_ASSET_RECORDS+=$'\t'
    INIT_FINAL_OWNED_ASSET_RECORDS+="$final_asset_readme_fingerprint"
    INIT_FINAL_OWNED_ASSET_RECORDS+=$'\n'
  done <<EOF
$INIT_OWNED_ASSET_RECORDS
EOF
  INIT_FINALIZATION_OWNERSHIP_READY=true
}

finalize_owned_directories() {
  verify_owned_directories || return 1
  verify_owned_asset_readme "$INIT_TASK" task "$INIT_TASK_EXISTING" || return 1
  verify_owned_asset_readme "$INIT_KNOWLEDGE" knowledge "$INIT_KNOWLEDGE_EXISTING" || return 1
  capture_finalization_ownership || return 1
  while IFS=$'\t' read -r created created_marker created_marker_fingerprint || [ -n "$created" ]; do
    [ -n "$created" ] || continue
    owned_directory_matches "$created" "$created_marker" "$created_marker_fingerprint" || {
      fail 'an initialization directory changed during finalization.'
      return 1
    }
    safe_root_remove_file "$created" .superteam-project-owner "$created_marker" "$created_marker_fingerprint" || {
      fail 'could not finalize an initialization directory.'
      return 1
    }
    [ ! -e "$created/.superteam-project-owner" ] && [ ! -L "$created/.superteam-project-owner" ] || {
      fail 'an initialization directory changed during finalization.'
      return 1
    }
  done <<EOF
$INIT_CREATED_RECORDS
EOF
  verify_owned_asset_readme "$INIT_TASK" task "$INIT_TASK_EXISTING" || return 1
  verify_owned_asset_readme "$INIT_KNOWLEDGE" knowledge "$INIT_KNOWLEDGE_EXISTING" || return 1
}

finalized_directory_inode_matches() {
  finalized_directory=$1
  finalized_expected_inode=$2
  require_current_root || return 1
  [ -d "$finalized_directory" ] && [ ! -L "$finalized_directory" ] || return 1
  finalized_physical=$(cd -P -- "$finalized_directory" && pwd -P) || return 1
  finalized_expected_physical=$(root_physical_path_for "$finalized_directory") || return 1
  [ "$finalized_physical" = "$finalized_expected_physical" ] || return 1
  finalized_actual_inode=$(filesystem_inode_for "$finalized_directory") || return 1
  [ "$finalized_actual_inode" = "$finalized_expected_inode" ]
}

cleanup_finalized_owned_assets() {
  while IFS=$'\t' read -r finalized_asset finalized_directory_inode finalized_readme_inode finalized_readme_fingerprint || [ -n "$finalized_asset" ]; do
    [ -n "$finalized_asset" ] || continue
    finalized_directory_inode_matches "$finalized_asset" "$finalized_directory_inode" || {
      report_rollback_problem
      continue
    }
    if [ -e "$finalized_asset/README.md" ] || [ -L "$finalized_asset/README.md" ]; then
      safe_root_remove_owned_snapshot_file "$finalized_asset" README.md "$finalized_readme_inode" "$finalized_readme_fingerprint" "$finalized_directory_inode" || report_rollback_problem
    fi
  done <<EOF
$INIT_FINAL_OWNED_ASSET_RECORDS
EOF
}

finalized_created_directory_inode_for() {
  finalized_lookup_directory=$1
  while IFS=$'\t' read -r finalized_lookup_recorded finalized_lookup_inode || [ -n "$finalized_lookup_recorded" ]; do
    [ "$finalized_lookup_recorded" = "$finalized_lookup_directory" ] || continue
    printf '%s\n' "$finalized_lookup_inode"
    return 0
  done <<EOF
$INIT_FINAL_CREATED_DIRECTORY_RECORDS
EOF
  return 1
}

cleanup_remaining_finalized_directory_markers() {
  while IFS=$'\t' read -r finalized_marker_directory finalized_marker_reference finalized_marker_fingerprint || [ -n "$finalized_marker_directory" ]; do
    [ -n "$finalized_marker_directory" ] || continue
    [ -e "$finalized_marker_directory" ] || [ -L "$finalized_marker_directory" ] || continue
    finalized_marker_directory_inode=$(finalized_created_directory_inode_for "$finalized_marker_directory") || {
      report_rollback_problem
      continue
    }
    finalized_directory_inode_matches "$finalized_marker_directory" "$finalized_marker_directory_inode" || {
      report_rollback_problem
      continue
    }
    finalized_marker_path=$finalized_marker_directory/.superteam-project-owner
    [ -e "$finalized_marker_path" ] || [ -L "$finalized_marker_path" ] || continue
    owned_regular_file_matches "$finalized_marker_path" "$finalized_marker_reference" "$finalized_marker_fingerprint" || {
      report_rollback_problem
      continue
    }
    safe_root_remove_file "$finalized_marker_directory" .superteam-project-owner "$finalized_marker_reference" "$finalized_marker_fingerprint" "$finalized_marker_directory_inode" || report_rollback_problem
  done <<EOF
$INIT_CREATED_RECORDS
EOF
}

cleanup_finalized_created_directories() {
  while :; do
    finalized_removed=false
    while IFS=$'\t' read -r finalized_created finalized_created_inode || [ -n "$finalized_created" ]; do
      [ -n "$finalized_created" ] || continue
      [ ! -e "$finalized_created" ] && [ ! -L "$finalized_created" ] && continue
      finalized_directory_inode_matches "$finalized_created" "$finalized_created_inode" || {
        report_rollback_problem
        continue
      }
      split_internal_root_path "$finalized_created" || {
        report_rollback_problem
        continue
      }
      if safe_root_rmdir_owned_snapshot "$ROOT_SPLIT_DIRECTORY" "$ROOT_SPLIT_LEAF" "$finalized_created_inode"; then
        finalized_removed=true
      else
        report_rollback_problem
      fi
    done <<EOF
$INIT_FINAL_CREATED_DIRECTORY_RECORDS
EOF
    [ "$finalized_removed" = true ] || break
  done
  while IFS=$'\t' read -r finalized_created finalized_created_inode || [ -n "$finalized_created" ]; do
    [ -n "$finalized_created" ] || continue
    [ ! -e "$finalized_created" ] && [ ! -L "$finalized_created" ] && continue
    report_rollback_problem
  done <<EOF
$INIT_FINAL_CREATED_DIRECTORY_RECORDS
EOF
}

cleanup_missing_owned_stage() {
  [ "$INIT_STAGE_OWNED" = true ] || return 0
  [ -n "$INIT_STAGE" ] || return 1
  [ ! -e "$INIT_STAGE" ] && [ ! -L "$INIT_STAGE" ] || return 1
  if [ -e "$INIT_STAGE_OWNER_REFERENCE" ] || [ -L "$INIT_STAGE_OWNER_REFERENCE" ]; then
    safe_root_remove_path "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_REFERENCE" "$INIT_STAGE_OWNER_FINGERPRINT" || return 1
  fi
  INIT_STAGE=''
  INIT_STAGE_IDENTITY=''
  INIT_STAGE_OWNED=false
  INIT_STAGE_SNAPSHOT=''
  INIT_STAGE_SNAPSHOT_READY=false
}

rollback_init() {
  TXN_LEDGER_RECORDING=false
  if [ "$TXN_LEDGER_READY" = true ] && ! transaction_ledger_is_current; then
    report_rollback_problem
    return 1
  fi
  if [ "$INIT_FINALIZATION_OWNERSHIP_READY" = true ]; then
    cleanup_finalized_owned_assets
    cleanup_remaining_finalized_directory_markers
    cleanup_finalized_created_directories
  elif [ "$INIT_STAGE_OWNED" = true ]; then
    if verify_stage_snapshot; then
      cleanup_owned_assets
      cleanup_created_directories
    else
      report_rollback_problem
    fi
  fi
  cleanup_metadata_gitignore
  cleanup_manifest
  if [ "$INIT_CREATED_GIT" = true ]; then
    if [ -n "$INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT" ]; then
      remove_finalized_new_git_tree || report_rollback_problem
    elif owned_new_git_is_unchanged; then
      remove_owned_tree "$INIT_ROOT/.git" "$INIT_GIT_SNAPSHOT" "$INIT_ROOT/.git/.superteam-project-owner" "$INIT_GIT_MARKER" "$INIT_GIT_MARKER_FINGERPRINT" || report_rollback_problem
    else
      report_rollback_problem
    fi
  fi
  if [ "$INIT_STAGE_OWNED" = true ] && [ -n "$INIT_STAGE" ]; then
    if [ ! -e "$INIT_STAGE" ] && [ ! -L "$INIT_STAGE" ]; then
      cleanup_missing_owned_stage || report_rollback_problem
    else
      cleanup_owned_stage || true
    fi
  fi
  cleanup_pending_transaction_intents || report_rollback_problem
  cleanup_retained_references || report_rollback_problem
  INIT_STAGE=''
  INIT_STAGE_OWNED=false
  INIT_GIT_MARKER=''
  INIT_GIT_MARKER_FINGERPRINT=''
  INIT_GIT_SNAPSHOT=''
  INIT_GIT_SNAPSHOT_READY=false
  INIT_FINAL_GIT_SNAPSHOT=''
  INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT=''
  INIT_FINALIZATION_OWNERSHIP_READY=false
  INIT_FINAL_CREATED_DIRECTORY_RECORDS=''
  INIT_FINAL_OWNED_ASSET_RECORDS=''
  INIT_FINAL_MANIFEST_INODE=''
  INIT_FINAL_MANIFEST_FINGERPRINT=''
  INIT_GIT_CANDIDATE_SNAPSHOT=''
}

apply_init() {
  INIT_CREATED_GIT=false
  INIT_MANIFEST_INSTALLED=false
  INIT_GITIGNORE_INSTALLED=false
  INIT_MANIFEST_NESTED_PATH=''
  INIT_GITIGNORE_NESTED_PATH=''
  INIT_OWNERSHIP_COUNT=0
  INIT_STAGE=''
  INIT_STAGE_IDENTITY=''
  INIT_STAGE_OWNED=false
  INIT_CREATED_RECORDS=''
  INIT_OWNED_ASSET_RECORDS=''
  INIT_GIT_MARKER=''
  INIT_GIT_MARKER_FINGERPRINT=''
  INIT_GIT_SNAPSHOT=''
  INIT_GIT_SNAPSHOT_READY=false
  INIT_FINAL_GIT_SNAPSHOT=''
  INIT_FINAL_GIT_OWNERSHIP_SNAPSHOT=''
  INIT_FINALIZATION_OWNERSHIP_READY=false
  INIT_FINAL_CREATED_DIRECTORY_RECORDS=''
  INIT_FINAL_OWNED_ASSET_RECORDS=''
  INIT_FINAL_MANIFEST_INODE=''
  INIT_FINAL_MANIFEST_FINGERPRINT=''
  INIT_GIT_CANDIDATE_SNAPSHOT=''
  INIT_RUNTIME_GIT_IDENTITY=''
  INIT_TASK_README_FINGERPRINT=''
  INIT_KNOWLEDGE_README_FINGERPRINT=''
  INIT_TASK_README_REFERENCE=''
  INIT_KNOWLEDGE_README_REFERENCE=''
  INIT_MANIFEST_REFERENCE=''
  INIT_MANIFEST_FINGERPRINT=''
  INIT_GITIGNORE_REFERENCE=''
  INIT_GITIGNORE_FINGERPRINT=''
  INIT_GIT_TEMPLATE=''
  INIT_GIT_BASELINE_WORKSPACE=''
  INIT_GIT_CANDIDATE_WORKSPACE=''
  prepare_stage || return 1
  if [ "$INIT_ROOT_MODE" != EXISTING ]; then
    create_new_root_repository || return 1
  fi
  if [ "$INIT_TASK_EXISTING" = false ]; then
    install_new_asset "$INIT_TASK" "$INIT_STAGE/task" || return 1
  fi
  if [ "$INIT_KNOWLEDGE_EXISTING" = false ]; then
    install_new_asset "$INIT_KNOWLEDGE" "$INIT_STAGE/knowledge" || return 1
  fi
  verify_adopted_assets || return 1
  verify_final_asset_boundaries || return 1
  install_metadata_gitignore || return 1
  install_manifest || return 1
  verify_final_transaction_state || return 1
  finalize_new_root_repository || return 1
  verify_final_transaction_state || return 1
  finalize_owned_directories || return 1
  cleanup_owned_stage || { fail 'could not clear the initialization staging directory safely.'; return 1; }
  verify_published_result_state || return 1
  cleanup_retained_references || { fail 'could not clear retained initialization references safely.'; return 1; }
}

print_initialization_result() {
  printf '%s\n' 'RESULT: INITIALIZED'
  printf '%s\n' "ROOT: $INIT_ROOT_PHYSICAL"
  printf '%s\n' 'GIT_STAGE: NONE'
  printf '%s\n' 'GIT_COMMIT: NONE'
  if [ "$INIT_CONFIRMED_ROOT_MODE" = METADATA_ONLY ]; then
    printf '%s\n' 'HEAD: UNBORN'
    printf '%s\n' 'INITIALIZATION_COMMIT: AVAILABLE'
    printf '%s\n' 'NEXT: Run superteam-project init-commit to review the exact first local commit.'
  fi
}

verify_metadata_only_initialization() {
  commit_directory=$1
  commit_location=$(resolve_directory "$commit_directory") || return 1
  INIT_COMMIT_ROOT=$(git_root_for "$commit_location" 2>/dev/null || true)
  [ -n "$INIT_COMMIT_ROOT" ] || {
    fail 'initialization commit requires an initialized metadata-only Root Repository.'
    return 1
  }
  INIT_COMMIT_ROOT=$(resolve_directory "$INIT_COMMIT_ROOT") || return 1
  parse_manifest "$INIT_COMMIT_ROOT" || return 1
  INIT_COMMIT_TASK=$MANIFEST_TASK
  INIT_COMMIT_KNOWLEDGE=$MANIFEST_KNOWLEDGE
  if safe_git -C "$INIT_COMMIT_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    fail 'initialization commit is only available while the metadata-only Root Repository has no HEAD.'
    return 1
  fi
  [ ! -L "$INIT_COMMIT_ROOT/.gitignore" ] && [ -f "$INIT_COMMIT_ROOT/.gitignore" ] || {
    fail 'initialization commit requires the generated metadata-only .gitignore.'
    return 1
  }
  expected_gitignore=$(render_metadata_gitignore "$INIT_COMMIT_TASK" "$INIT_COMMIT_KNOWLEDGE") || return 1
  actual_gitignore=$(cat "$INIT_COMMIT_ROOT/.gitignore") || return 1
  [ "$actual_gitignore" = "$expected_gitignore" ] || {
    fail 'initialization commit requires the unchanged generated metadata-only .gitignore.'
    return 1
  }
  safe_git -C "$INIT_COMMIT_ROOT" diff --cached --quiet -- || {
    fail 'initialization commit requires an empty Git index.'
    return 1
  }
}

print_initialization_commit_plan() {
  printf '%s\n' 'ACTION: INITIALIZATION_COMMIT'
  printf '%s\n' "ROOT: $INIT_COMMIT_ROOT"
  printf '%s\n' 'GIT_STAGE: .gitignore'
  printf '%s\n' 'GIT_STAGE: superteam.yaml'
  printf '%s\n' "GIT_STAGE: $INIT_COMMIT_TASK"
  printf '%s\n' "GIT_STAGE: $INIT_COMMIT_KNOWLEDGE"
  printf '%s\n' 'GIT_COMMIT: Initialize Superteam project'
  printf '%s\n' 'HEAD: UNBORN'
  [ "$INIT_COMMIT_APPLY" = true ] || printf '%s\n' 'NEXT: Re-run with --apply to create this first local commit.'
}

initialization_git() {
  safe_git -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"
}

resolve_initialization_commit_identity() {
  if INIT_COMMIT_AUTHOR_NAME=$(initialization_git -C "$INIT_COMMIT_ROOT" config --local --get user.name 2>/dev/null); then
    :
  elif INIT_COMMIT_AUTHOR_NAME=$(default_global_git_config_get user.name 2>/dev/null); then
    :
  else
    fail 'initialization commit requires user.name in the Root Repository or the default global Git config.'
    return 1
  fi
  if INIT_COMMIT_AUTHOR_EMAIL=$(initialization_git -C "$INIT_COMMIT_ROOT" config --local --get user.email 2>/dev/null); then
    :
  elif INIT_COMMIT_AUTHOR_EMAIL=$(default_global_git_config_get user.email 2>/dev/null); then
    :
  else
    fail 'initialization commit requires user.email in the Root Repository or the default global Git config.'
    return 1
  fi
  [ -n "$INIT_COMMIT_AUTHOR_NAME" ] || {
    fail 'initialization commit requires a non-empty Git user.name.'
    return 1
  }
  [ -n "$INIT_COMMIT_AUTHOR_EMAIL" ] || {
    fail 'initialization commit requires a non-empty Git user.email.'
    return 1
  }
  reject_line_breaks "$INIT_COMMIT_AUTHOR_NAME" 'Git user.name' || return 1
  reject_line_breaks "$INIT_COMMIT_AUTHOR_EMAIL" 'Git user.email' || return 1
}

clear_initialization_commit_index() {
  # The preflight requires an empty index.  If a later Git operation fails,
  # clear the whole index so a filter, hook, or other repository-local Git
  # behavior cannot leave staged entries outside the planned pathspecs.
  if ! initialization_git -C "$INIT_COMMIT_ROOT" rm -r --cached --ignore-unmatch -- . >/dev/null 2>&1; then
    initialization_git -C "$INIT_COMMIT_ROOT" read-tree --empty >/dev/null 2>&1 || return 1
  fi
  initialization_git -C "$INIT_COMMIT_ROOT" diff --cached --quiet --
}

fail_initialization_commit_with_rollback() {
  initialization_failure=$1
  if clear_initialization_commit_index; then
    fail "$initialization_failure; generated assets were retained and the index was restored."
  else
    fail "$initialization_failure; generated assets were retained, but index rollback is incomplete; clear the Git index manually before retrying."
  fi
}

apply_initialization_commit() {
  initialization_git --literal-pathspecs -C "$INIT_COMMIT_ROOT" add -- \
    .gitignore superteam.yaml "$INIT_COMMIT_TASK" "$INIT_COMMIT_KNOWLEDGE" || {
    fail_initialization_commit_with_rollback 'could not stage the planned Superteam initialization assets'
    return 1
  }
  initialization_planned_tree=$(initialization_git -C "$INIT_COMMIT_ROOT" write-tree) || {
    fail_initialization_commit_with_rollback 'could not record the planned Superteam initialization tree'
    return 1
  }
  # A metadata-only Root Repository is created by Superteam, but repository
  # hooks may be added before this separately confirmed commit.  Disable all
  # hooks and signing so the exact reviewed index tree is the only commit
  # input and no repository-local command can perform an external side effect.
  if ! initialization_git -c "user.name=$INIT_COMMIT_AUTHOR_NAME" \
      -c "user.email=$INIT_COMMIT_AUTHOR_EMAIL" \
      -C "$INIT_COMMIT_ROOT" commit -m 'Initialize Superteam project'; then
    fail_initialization_commit_with_rollback 'could not create the first local commit'
    return 1
  fi
  initialization_committed_tree=$(initialization_git -C "$INIT_COMMIT_ROOT" rev-parse --verify 'HEAD^{tree}') || return 1
  [ "$initialization_committed_tree" = "$initialization_planned_tree" ] || {
    fail 'the first local commit does not match the reviewed initialization tree.'
    return 1
  }
  initialization_git -C "$INIT_COMMIT_ROOT" diff --cached --quiet -- || {
    fail 'initialization commit left unexpected staged changes.'
    return 1
  }
  initialization_head=$(initialization_git -C "$INIT_COMMIT_ROOT" rev-parse --verify HEAD) || return 1
  printf '%s\n' 'RESULT: INITIALIZATION_COMMITTED'
  printf '%s\n' "ROOT: $INIT_COMMIT_ROOT"
  printf '%s\n' "HEAD: $initialization_head"
  printf '%s\n' 'REMOTE: NONE_CREATED'
  printf '%s\n' 'PUSH: NONE'
}

initialization_commit() {
  directory=.
  directory_seen=false
  INIT_COMMIT_APPLY=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) INIT_COMMIT_APPLY=true; shift ;;
      --*) fail "unknown option: $1"; return 1 ;;
      *) [ "$directory_seen" != true ] || { fail 'only one target directory may be supplied.'; return 1; }; directory=$1; directory_seen=true; shift ;;
    esac
  done
  verify_metadata_only_initialization "$directory" || return 1
  print_initialization_commit_plan
  if [ "$INIT_COMMIT_APPLY" = true ]; then
    resolve_initialization_commit_identity || return 1
    confirmed_root=$INIT_COMMIT_ROOT
    confirmed_task=$INIT_COMMIT_TASK
    confirmed_knowledge=$INIT_COMMIT_KNOWLEDGE
    verify_metadata_only_initialization "$directory" || return 1
    [ "$INIT_COMMIT_ROOT" = "$confirmed_root" ] && [ "$INIT_COMMIT_TASK" = "$confirmed_task" ] && [ "$INIT_COMMIT_KNOWLEDGE" = "$confirmed_knowledge" ] || {
      fail 'initialization commit plan changed before apply.'
      return 1
    }
    apply_initialization_commit
  fi
}

init_or_adopt() {
  action=$1
  shift
  directory=.
  directory_seen=false
  task=''
  knowledge=''
  adopt_task=false
  adopt_knowledge=false
  INIT_APPLY=false
  INIT_EXPECTED_PLAN_FINGERPRINT=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task) [ "$#" -ge 2 ] || { fail '--task requires a path.'; return 1; }; task=$2; shift 2 ;;
      --knowledge) [ "$#" -ge 2 ] || { fail '--knowledge requires a path.'; return 1; }; knowledge=$2; shift 2 ;;
      --adopt-task) adopt_task=true; shift ;;
      --adopt-knowledge) adopt_knowledge=true; shift ;;
      --plan-fingerprint) [ "$#" -ge 2 ] || { fail '--plan-fingerprint requires a value.'; return 1; }; INIT_EXPECTED_PLAN_FINGERPRINT=$2; shift 2 ;;
      --apply) INIT_APPLY=true; shift ;;
      --*) fail "unknown option: $1"; return 1 ;;
      *) [ "$directory_seen" != true ] || { fail 'only one target directory may be supplied.'; return 1; }; directory=$1; directory_seen=true; shift ;;
    esac
  done
  [ -n "$task" ] || { fail '--task is required.'; return 1; }
  [ -n "$knowledge" ] || { fail '--knowledge is required.'; return 1; }
  if [ "$INIT_APPLY" = true ]; then
    validate_plan_fingerprint_option "$INIT_EXPECTED_PLAN_FINGERPRINT" || return 1
  elif [ -n "$INIT_EXPECTED_PLAN_FINGERPRINT" ]; then
    fail '--plan-fingerprint is only accepted together with --apply.'
    return 1
  fi
  preflight_init "$action" "$directory" "$task" "$knowledge" "$adopt_task" "$adopt_knowledge" || return 1
  INIT_CONFIRMED_ROOT=$INIT_ROOT
  INIT_CONFIRMED_ROOT_MODE=$INIT_ROOT_MODE
  INIT_CONFIRMED_GIT_IDENTITY=$INIT_GIT_IDENTITY
  INIT_CONFIRMED_ROOT_IDENTITY=$INIT_ROOT_IDENTITY
  print_init_plan
  if [ "$INIT_APPLY" = true ]; then
    [ "$INIT_EXPECTED_PLAN_FINGERPRINT" = "$INIT_PLAN_FINGERPRINT" ] || {
      fail 'the reviewed initialization plan no longer matches the current target; no files were applied.'
      return 1
    }
    arm_project_transaction
    acquire_project_lock "$INIT_ROOT" || return 1
    VERIFY_ROOT_STABLE=true
    if ! preflight_init "$action" "$directory" "$task" "$knowledge" "$adopt_task" "$adopt_knowledge"; then
      finish_failed_project_transaction
      return 1
    fi
    if [ "$INIT_PLAN_FINGERPRINT" != "$INIT_EXPECTED_PLAN_FINGERPRINT" ]; then
      fail 'the reviewed initialization plan changed before apply; no files were applied.'
      finish_failed_project_transaction
      return 1
    fi
    # The lock acquisition leaves this shell in the verified Root Repository.
    # From this point on all root-relative writes use `.` so a later pathname
    # replacement cannot redirect a write into a replacement directory.
    INIT_ROOT=.
    if ! apply_init; then
      finish_failed_project_transaction
      return 1
    fi
    TXN_STATE=COMMITTING
    TXN_STATE=RELEASING
    if ! release_project_lock; then
      clear_project_trap
      TXN_STATE=IDLE
      return 1
    fi
    clear_project_trap
    TXN_STATE=FINISHED
    print_initialization_result
  fi
}

case ${1:-} in
  inspect) shift; [ "$#" -le 1 ] || { usage >&2; exit 2; }; inspect "$@" ;;
  init|adopt) command=$1; shift; init_or_adopt "$command" "$@" ;;
  init-commit) shift; initialization_commit "$@" ;;
  repository) shift; repository_command "$@" ;;
  status) shift; [ "$#" -le 1 ] || { usage >&2; exit 2; }; status "$@" ;;
  doctor) shift; [ "$#" -le 1 ] || { usage >&2; exit 2; }; doctor "$@" ;;
  pull) shift; [ "$#" -le 1 ] || { usage >&2; exit 2; }; project_pull "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) fail "unknown command: $1"; usage >&2; exit 2 ;;
esac
