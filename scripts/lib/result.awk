# Validate only the opening completion summary. The remaining Markdown is
# evidence for the agent to interpret, including expected historical failures.
# document=ticket starts after ## Result; document=feature permits an H1 title.
function reject(message) {
  print "ERROR: completion summary " message ": " FILENAME > "/dev/stderr"
  failed = 1
  exit 1
}

function trim(value) {
  sub(/^[[:space:]]+/, "", value)
  sub(/[[:space:]]+$/, "", value)
  return value
}

BEGIN { active = (document != "ticket") }

!active {
  if ($0 ~ /^## Result[[:space:]]*$/) active = 1
  next
}

body {
  if ($0 ~ /[^[:space:]]/) explanation = 1
  next
}

/^[[:space:]]*$/ {
  if (started) body = 1
  next
}

!started && document == "feature" && !title && /^# [^#]/ {
  title = 1
  next
}

{
  if ($0 ~ /^(Outcome|Verification|Verification exit codes):/) {
    key = $0
    sub(/:.*/, "", key)
    if (key in fields) reject("has duplicate field " key)
    value = $0
    sub(/^[^:]*:/, "", value)
    fields[key] = trim(value)
    started = 1
  } else {
    if (!started) reject("must begin with Outcome, Verification and Verification exit codes")
    body = 1
    explanation = 1
  }
}

END {
  if (failed) exit 1
  if (!("Outcome" in fields)) reject("is missing Outcome")
  if (!("Verification" in fields)) reject("is missing Verification")
  if (!("Verification exit codes" in fields)) reject("is missing Verification exit codes")
  if (fields["Outcome"] != "DONE") reject("requires Outcome: DONE")

  verification = fields["Verification"]
  codes = fields["Verification exit codes"]
  if (verification == "PASS") {
    if (codes !~ /^0([[:space:]]*,[[:space:]]*0)*$/)
      reject("PASS requires one or more zero final verification exit codes")
  } else if (verification == "NOT_APPLICABLE") {
    if (codes != "NONE") reject("NOT_APPLICABLE requires Verification exit codes: NONE")
    if (!explanation) reject("NOT_APPLICABLE requires an explanation in the body")
  } else if (verification == "FAIL" || verification == "NOT_RUN") {
    reject("cannot complete with Verification: " verification)
  } else {
    reject("has unknown Verification value")
  }
}
