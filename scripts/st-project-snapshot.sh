#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJECT="$SCRIPT_DIR/st-project.sh"
. "$SCRIPT_DIR/lib/git.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  st-project-snapshot.sh root [directory]
  st-project-snapshot.sh task [directory]
  st-project-snapshot.sh knowledge [directory]
  st-project-snapshot.sh repositories [directory]
  st-project-snapshot.sh repository-path <repository> [directory]
  st-project-snapshot.sh repository-root <repository> [directory]

Returns one named value from a validated Project Snapshot. It never evaluates
configuration expressions and never writes Project or Git state.
EOF
  exit 2
}

fail() {
  printf '%s\n' "ERROR: $1" >&2
  return 1
}

reject_line_breaks() {
  case "$1" in
    *$'\n'*|*$'\r'*) fail "$2 contains an unsupported line break."; return 1 ;;
  esac
}

query=${1:-}
[ -n "$query" ] || usage
shift

repository=''
case "$query" in
  root|task|knowledge|repositories)
    [ "$#" -le 1 ] || usage
    directory=${1:-.}
    ;;
  repository-path|repository-root)
    repository=${1:-}
    [ -n "$repository" ] && [ "$#" -le 2 ] || usage
    directory=${2:-.}
    printf '%s\n' "$repository" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9._-]*$' || {
      fail 'invalid Repository ID.'
      exit 2
    }
    ;;
  *) usage ;;
esac
reject_line_breaks "$directory" 'directory path' || exit 1

snapshot=$(mktemp "${TMPDIR:-/tmp}/superteam-project-snapshot.XXXXXX") || exit 1
trap 'rm -f -- "$snapshot"' EXIT HUP INT TERM
if ! bash "$PROJECT" inspect "$directory" > "$snapshot"; then
  exit 1
fi
[ "$(grep -c '^STATUS: CONFIGURED$' "$snapshot" || true)" -eq 1 ] || {
  fail 'Project is not initialized.'
  exit 1
}
for required in ROOT TASK KNOWLEDGE; do
  [ "$(grep -c "^$required: " "$snapshot" || true)" -eq 1 ] || {
    fail "Project Snapshot has an ambiguous $required field."
    exit 1
  }
done

case "$query" in
  root) sed -n 's/^ROOT: //p' "$snapshot" ;;
  task) sed -n 's/^TASK: //p' "$snapshot" ;;
  knowledge) sed -n 's/^KNOWLEDGE: //p' "$snapshot" ;;
  repositories)
    sed -n 's/^REPOSITORY: //p' "$snapshot"
    ;;
  repository-path|repository-root)
    if [ "$repository" = root ]; then
      grep -qx 'REPOSITORY: root' "$snapshot" || {
        fail 'Project Snapshot does not contain root.'
        exit 1
      }
      value=.
    else
      value=$(awk -v wanted="$repository" '
        /^REPOSITORY: / {
          active = substr($0, 13) == wanted
          if (active) matches++
          next
        }
        active && /^REPOSITORY_PATH: / {
          print substr($0, 18)
          active = 0
        }
        END { if (matches != 1) exit 1 }
      ' "$snapshot") || {
        fail "unknown Repository ID: $repository"
        exit 1
      }
      [ -n "$value" ] || {
        fail "Project Snapshot has no path for Repository: $repository"
        exit 1
      }
    fi
    if [ "$query" = repository-path ]; then
      printf '%s\n' "$value"
      exit 0
    fi
    root=$(sed -n 's/^ROOT: //p' "$snapshot")
    candidate=$root
    [ "$value" = . ] || candidate=$root/$value
    [ -d "$candidate" ] || {
      fail "Repository $repository has a missing or mismatched Git root: $value"
      exit 1
    }
    resolved=$(cd -P -- "$candidate" && pwd -P) || {
      fail "Repository $repository has a missing or mismatched Git root: $value"
      exit 1
    }
    actual=$(isolated_git -C "$resolved" rev-parse --show-toplevel 2>/dev/null) || {
      fail "Repository $repository has a missing or mismatched Git root: $value"
      exit 1
    }
    actual=$(cd -P -- "$actual" && pwd -P) || exit 1
    [ "$actual" = "$resolved" ] || {
      fail "Repository $repository has a missing or mismatched Git root: $value"
      exit 1
    }
    printf '%s\n' "$resolved"
    ;;
esac
