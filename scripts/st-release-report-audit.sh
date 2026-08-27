#!/usr/bin/env bash

set -u

LC_ALL=C
export LC_ALL

report_file=${1:-}
report_field_value=''
pass_field_value=''
candidate_head=''

fail() {
  printf '%s\n' "ERROR: $*" >&2
  exit 1
}

read_report_field() {
  report_section=$1
  report_label=$2

  report_field_value=$(awk -v wanted_section="$report_section" \
    -v wanted_label="$report_label" '
    BEGIN {
      current_section = "TOP"
      prefix = "- " wanted_label ": "
    }
    /^## / {
      current_section = substr($0, 4)
      next
    }
    current_section == wanted_section && index($0, prefix) == 1 {
      matches += 1
      value = substr($0, length(prefix) + 1)
    }
    END {
      if (matches != 1 || value == "") {
        exit 1
      }
      print value
    }
  ' "$report_file") || return 1
  [ -n "$report_field_value" ]
}

extract_tested_hash() {
  tested_hash_text=$1
  tested_hash_value=$(printf '%s\n' "$tested_hash_text" | \
    awk '
      length($0) == 58 &&
          substr($0, 1, 1) == "`" &&
          substr($0, 42) == "` (tested source)" {
        print substr($0, 2, 40)
      }
    ')
  [ "${#tested_hash_value}" -eq 40 ] || return 1
  case "$tested_hash_value" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

require_pass_field() {
  pass_platform_label=$1
  pass_section=$2
  pass_label=$3

  read_report_field "$pass_section" "$pass_label" || \
    fail "$pass_platform_label PASS evidence is missing field: $pass_label"
  pass_field_value=$report_field_value
}

audit_platform() {
  local platform_label section_heading summary_status image_required
  local section_status tested_candidate bats_evidence bats_counts
  local gate_result audit_result host_result model_result

  platform_label=$1
  section_heading=$2
  summary_status=$3
  image_required=$4

  read_report_field "$section_heading" Status || \
    fail "$platform_label evidence is missing field: Status"
  section_status=$report_field_value
  [ "$section_status" = "$summary_status" ] || \
    fail "$platform_label summary status does not match its evidence section"

  [ "$summary_status" = PASS ] || return 0

  require_pass_field "$platform_label" "$section_heading" \
    'Tested source candidate'
  tested_candidate=$pass_field_value
  [ "$tested_candidate" = "\`$candidate_head\`" ] || \
    fail "$platform_label tested candidate does not match Candidate HEAD"

  if [ "$image_required" = yes ]; then
    require_pass_field "$platform_label" "$section_heading" Image
  fi
  require_pass_field "$platform_label" "$section_heading" Platform
  require_pass_field "$platform_label" "$section_heading" Bash
  require_pass_field "$platform_label" "$section_heading" Git
  require_pass_field "$platform_label" "$section_heading" Bats
  bats_evidence=$pass_field_value
  require_pass_field "$platform_label" "$section_heading" 'Gate prerequisites'
  require_pass_field "$platform_label" "$section_heading" 'Gate result'
  gate_result=$pass_field_value
  require_pass_field "$platform_label" "$section_heading" 'Release audit'
  audit_result=$pass_field_value
  require_pass_field "$platform_label" "$section_heading" 'Host discovery'
  host_result=$pass_field_value
  require_pass_field "$platform_label" "$section_heading" 'Codex CLI'
  require_pass_field "$platform_label" "$section_heading" 'Claude Code'
  require_pass_field "$platform_label" "$section_heading" 'Qoder CLI'
  require_pass_field "$platform_label" "$section_heading" \
    'model-backed invocation'
  model_result=$pass_field_value

  bats_counts=$(printf '%s\n' "$bats_evidence" | awk '
    {
      separator = index($0, "; ")
      if (separator == 0) {
        exit 1
      }
      summary = substr($0, separator + 2)
      if (summary !~ /^[0-9]+ cases, [0-9]+ passed, [0-9]+ skipped, [0-9]+ failed$/) {
        exit 1
      }
      gsub(/[^0-9]+/, " ", summary)
      sub(/^ /, "", summary)
      sub(/ $/, "", summary)
      print summary
    }
  ')
  [ -n "$bats_counts" ] || \
    fail "$platform_label Bats evidence lacks pass, skip, and fail counts"
  set -- $bats_counts
  [ "$4" -eq 0 ] && [ "$1" -eq $(( $2 + $3 + $4 )) ] || \
    fail "$platform_label Bats evidence does not describe a passing full suite"
  [ "$gate_result" = PASS ] || fail "$platform_label gate result is not PASS"
  [ "$audit_result" = PASS ] || fail "$platform_label release audit is not PASS"
  case "$host_result" in
    PASS\;*) ;;
    *) fail "$platform_label Host discovery is not PASS" ;;
  esac
  [ "$model_result" = SKIP ] || \
    fail "$platform_label model-backed invocation must remain SKIP"
}

[ -n "$report_file" ] || \
  fail 'usage: st-release-report-audit.sh <release-report>'
[ -f "$report_file" ] || fail 'release report does not exist'

read_report_field TOP 'Native macOS' || \
  fail 'release report is missing Native macOS summary status'
macos_status=$report_field_value
read_report_field TOP 'Containerized Ubuntu 24.04' || \
  fail 'release report is missing Ubuntu summary status'
ubuntu_status=$report_field_value
read_report_field TOP 'Remote CI' || \
  fail 'release report is missing Remote CI summary status'
remote_ci_status=$report_field_value

case "$macos_status" in
  PENDING|PASS|FAIL) ;;
  *) fail 'Native macOS summary status is invalid' ;;
esac
case "$ubuntu_status" in
  PENDING|PASS|FAIL) ;;
  *) fail 'Ubuntu summary status is invalid' ;;
esac
[ "$remote_ci_status" = 'NOT RUN' ] || \
  fail 'Remote CI must remain NOT RUN until hosted evidence exists'

if [ "$macos_status" = PASS ] || [ "$ubuntu_status" = PASS ]; then
  read_report_field TOP 'Candidate HEAD' || \
    fail 'PASS evidence requires Candidate HEAD'
  extract_tested_hash "$report_field_value" || \
    fail 'Candidate HEAD is not an exact tested source hash'
  candidate_head=$tested_hash_value

  read_report_field TOP 'Candidate tree' || \
    fail 'PASS evidence requires Candidate tree'
  extract_tested_hash "$report_field_value" || \
    fail 'Candidate tree is not an exact tested source hash'
fi

audit_platform 'Native macOS' 'Native macOS result' "$macos_status" no
audit_platform Ubuntu 'Containerized Ubuntu 24.04 result' "$ubuntu_status" yes

printf '%s\n' 'RELEASE_REPORT_RESULT: PASS'
