#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SNAPSHOT="$SCRIPT_DIR/st-project-snapshot.sh"
FRONTMATTER="$SCRIPT_DIR/lib/frontmatter.sh"
PLAN="$SCRIPT_DIR/st-plan.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-contract.sh write <prd|spec> <feature-directory> <candidate-file> [candidate-ticket-directory]
  st-contract.sh validate <prd|spec> <feature-directory> <candidate-file>

Validates a complete PRD or Spec candidate against the Project Snapshot, then
atomically installs it as the feature's Current Contract. A revision with an
existing Current Plan requires a complete candidate ticket set and reconciles
both artifacts in one transaction. It uses only Git and Bash, never changes the
Git index, and never starts Build.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

command=${1:-}
case "$command" in write|validate) ;; *) usage ;; esac
kind=${2:-}
feature=${3:-}
candidate=${4:-}
candidate_tickets=${5:-}
if [ "$command" = validate ]; then
  [ "$#" -eq 4 ] || usage
else
  [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || usage
fi
[ -n "$feature" ] && [ -n "$candidate" ] || usage
case "$kind" in prd|spec) ;; *) usage ;; esac

[ -d "$feature" ] && [ ! -L "$feature" ] || {
  fail 'feature path must be a regular directory.'
  exit 1
}
feature=$(cd -P -- "$feature" && pwd -P) || exit 1
project_root=$(bash "$SNAPSHOT" root "$feature") || exit 1
task_root=$(bash "$SNAPSHOT" task "$feature") || exit 1
feature_parent=$(dirname "$feature")
[ "$feature_parent" = "$task_root" ] || {
  fail 'feature directory must be directly inside the configured task path.'
  exit 1
}

bash "$FRONTMATTER" validate "$candidate" "$kind" || exit 1
id=$(bash "$FRONTMATTER" get "$candidate" id "$kind") || exit 1
slug=$(bash "$FRONTMATTER" get "$candidate" slug "$kind") || exit 1
created_at=$(bash "$FRONTMATTER" get "$candidate" created_at "$kind") || exit 1
printf '%s\n' "$id" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9-]*$' || {
  fail "invalid $kind id."
  exit 1
}
printf '%s\n' "$slug" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*$' || {
  fail "invalid $kind slug."
  exit 1
}
feature_name=$(basename "$feature")
[ "$feature_name" = "$id-$slug" ] || {
  fail "$kind id and slug do not match the feature directory."
  exit 1
}
printf '%s\n' "$created_at" | LC_ALL=C grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || {
  fail "$kind created_at must use YYYY-MM-DD."
  exit 1
}

repository_count=0
while IFS= read -r repository; do
  [ -n "$repository" ] || {
    fail "$kind contains an empty Repository ID."
    exit 1
  }
  bash "$SNAPSHOT" repositories "$project_root" | grep -qxF -- "$repository" || {
    fail "unknown Repository ID in $kind: $repository"
    exit 1
  }
  repository_count=$((repository_count + 1))
done < <(bash "$FRONTMATTER" get-list "$candidate" repositories "$kind")
[ "$repository_count" -gt 0 ] || {
  fail "$kind must name at least one Repository."
  exit 1
}

target=$feature/$kind.md
if [ -e "$target" ] || [ -L "$target" ]; then
  [ -f "$target" ] && [ ! -L "$target" ] || {
    fail 'Current Contract must be a regular file.'
    exit 1
  }
  bash "$FRONTMATTER" validate "$target" "$kind" >/dev/null || exit 1
  current_created_at=$(bash "$FRONTMATTER" get "$target" created_at "$kind") || exit 1
  [ "$created_at" = "$current_created_at" ] || {
    fail 'created_at must match the Current Contract during revision.'
    exit 1
  }
fi

[ "$command" = write ] || exit 0

has_current_tickets=false
current_tickets=$feature/tickets
if [ -e "$current_tickets" ] || [ -L "$current_tickets" ]; then
  [ -d "$current_tickets" ] && [ ! -L "$current_tickets" ] || {
    fail 'Current Plan path exists but is invalid.'
    exit 1
  }
  invalid_ticket_entry=$(find "$current_tickets" -mindepth 1 -maxdepth 1 \
    \( ! -type f -o ! -name '*.md' \) -print -quit)
  [ -z "$invalid_ticket_entry" ] &&
    find "$current_tickets" -maxdepth 1 -type f -name '*.md' -print -quit | grep -q . || {
    fail 'Current Plan path exists but is invalid.'
    exit 1
  }
  has_current_tickets=true
fi
if [ "$has_current_tickets" = true ]; then
  [ -n "$candidate_tickets" ] || {
    fail 'contract revision with existing tickets requires a reconciled candidate ticket set.'
    exit 1
  }
  exec bash "$PLAN" reconcile "$kind" "$feature" "$candidate" "$candidate_tickets"
fi
[ -z "$candidate_tickets" ] || {
  fail 'a candidate ticket set is only valid when a Current Plan already exists.'
  exit 1
}
bash "$FRONTMATTER" install "$target" "$candidate" "$kind" || exit 1
printf 'CONTRACT: %s\n' "$(printf '%s' "$kind" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
printf 'PATH: %s\n' "$target"
