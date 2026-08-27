#!/usr/bin/env bash

set -eu

usage() {
  cat <<'EOF'
Usage: st-plugin-root.sh <require|from-script>

require      Validate SUPERTEAM_PLUGIN_ROOT supplied by a host or caller.
from-script  Resolve the bundle root from this script's filesystem path.

Runtime: Git and Bash with POSIX base utilities.
EOF
}

validate_root() {
  candidate=$1

  case "$candidate" in
    *$'\n'*|*$'\r'*)
      printf '%s\n' 'ERROR: plugin root path contains an unsupported line break.' >&2
      return 2
      ;;
  esac

  if [ ! -d "$candidate" ]; then
    printf '%s\n' "ERROR: plugin root does not exist: $candidate" >&2
    return 2
  fi

  root=$(cd "$candidate" && pwd -P)
  if [ ! -f "$root/scripts/st-project.sh" ] || [ ! -f "$root/skills/using-superteam/SKILL.md" ]; then
    printf '%s\n' 'ERROR: plugin root does not contain the required Superteam bundle files.' >&2
    return 2
  fi

  printf '%s\n' "PLUGIN_ROOT: $root"
}

require_root() {
  if [ -z "${SUPERTEAM_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' 'ERROR: SUPERTEAM_PLUGIN_ROOT is required for the environment handoff.' >&2
    return 2
  fi

  validate_root "$SUPERTEAM_PLUGIN_ROOT"
}

script_root() {
  script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
  validate_root "$script_dir/.."
}

case ${1:-} in
  require)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    require_root
    ;;
  from-script)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    script_root
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
