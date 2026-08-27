function fail(message) {
  print "ERROR: " message > "/dev/stderr"
  failed = 1
  exit 1
}

function decode_scalar(raw,    body, output, position, character, escaped, quote, slash) {
  quote = sprintf("%c", 34)
  slash = sprintf("%c", 92)
  if (raw ~ /^[A-Za-z0-9][A-Za-z0-9._+:\/-]*$/) {
    decoded = raw
    return 1
  }
  if (substr(raw, 1, 1) != quote || substr(raw, length(raw), 1) != quote) return 0
  body = substr(raw, 2, length(raw) - 2)
  output = ""
  for (position = 1; position <= length(body); position++) {
    character = substr(body, position, 1)
    if (character == slash) {
      position++
      if (position > length(body)) return 0
      escaped = substr(body, position, 1)
      if (escaped != slash && escaped != quote) return 0
      output = output escaped
    } else {
      if (character == quote) return 0
      output = output character
    }
  }
  decoded = output
  return 1
}

function quote_scalar(value,    output, position, character, quote, slash) {
  quote = sprintf("%c", 34)
  slash = sprintf("%c", 92)
  output = quote
  for (position = 1; position <= length(value); position++) {
    character = substr(value, position, 1)
    if (character == slash || character == quote) output = output slash
    output = output character
  }
  return output quote
}

function scalar_allowed(key) {
  if (schema == "prd" || schema == "spec")
    return key == "id" || key == "slug" || key == "created_at"
  return key == "id" || key == "status" || key == "claimed_by" ||
    key == "claimed_at" || key == "resolved_at" || key == "blocked_at" ||
    key == "blocked_reason"
}

function list_allowed(key) {
  if (schema == "prd" || schema == "spec")
    return key == "repositories" || key == "supersedes"
  return key == "repositories" || key == "blocked_by"
}

function branch_field_allowed(key) {
  return key == "base" || key == "feature_branch" || key == "ticket_branch" ||
    key == "ticket_head" || key == "prepared_head" || key == "integrated_head"
}

function require_key(key) {
  if (!top_seen[key]) fail("missing required frontmatter key: " key)
}

function validate_required() {
  if (schema == "prd" || schema == "spec") {
    require_key("id")
    require_key("slug")
    require_key("repositories")
    require_key("created_at")
    require_key("supersedes")
  } else if (schema == "ticket") {
    require_key("id")
    require_key("status")
    require_key("repositories")
    require_key("blocked_by")
    require_key("claimed_by")
    require_key("claimed_at")
    require_key("branches")
  } else {
    fail("unknown frontmatter schema: " schema)
  }
}

function remember_list_value(key, value,    duplicate_key) {
  duplicate_key = key SUBSEP value
  if (list_value_seen[duplicate_key]) fail("duplicate list value for frontmatter key: " key)
  list_value_seen[duplicate_key] = 1
  list_count[key]++
  list_value[key, list_count[key]] = value
}

function remember_branch(repository, field, value,    duplicate_key) {
  duplicate_key = repository SUBSEP field
  if (branch_value_seen[duplicate_key])
    fail("duplicate Repository branch field: " repository "." field)
  branch_value_seen[duplicate_key] = 1
  branch_value[repository, field] = value
}

function parse_top_line(line,    separator, key, raw) {
  separator = index(line, ":")
  if (separator < 2) fail("malformed frontmatter line " NR)
  key = substr(line, 1, separator - 1)
  raw = substr(line, separator + 1)
  if (raw ~ /^ /) raw = substr(raw, 2)
  if (key !~ /^[a-z][a-z0-9_]*$/) fail("malformed frontmatter key on line " NR)
  if (top_seen[key]) fail("duplicate frontmatter key: " key)
  top_seen[key] = 1
  section = ""

  if (raw == "") {
    if (list_allowed(key)) {
      section = "list"
      section_key = key
      return
    }
    if (schema == "ticket" && key == "branches") {
      section = "branches"
      return
    }
    fail("frontmatter key requires a scalar value: " key)
  }
  if (raw == "[]") {
    if (!list_allowed(key)) fail("frontmatter key is not a list: " key)
    return
  }
  if (raw == "{}") {
    if (schema != "ticket" || key != "branches")
      fail("frontmatter key is not a mapping: " key)
    return
  }
  if (!scalar_allowed(key)) fail("unknown frontmatter key or structure: " key)
  if (!decode_scalar(raw)) fail("unsupported scalar for frontmatter key: " key)
  scalar_value[key] = decoded
}

function read_operations(    line, parts, count, action, key, value, item_count, items, cursor, repository, field) {
  if (operations == "") return
  while ((getline line < operations) > 0) {
    count = split(line, parts, "\t")
    action = parts[1]
    if (action == "set") {
      if (count != 3) fail("malformed scalar update")
      key = parts[2]
      value = parts[3]
      if (!scalar_allowed(key)) fail("unknown scalar frontmatter key: " key)
      scalar_value[key] = value
      top_seen[key] = 1
    } else if (action == "list") {
      if (count < 2 || count > 3) fail("malformed list update")
      key = parts[2]
      value = count == 3 ? parts[3] : ""
      if (!list_allowed(key)) fail("unknown list frontmatter key: " key)
      for (cursor = 1; cursor <= list_count[key]; cursor++)
        delete list_value[key, cursor]
      list_count[key] = 0
      for (cursor in list_value_seen)
        if (cursor ~ ("^" key SUBSEP)) delete list_value_seen[cursor]
      top_seen[key] = 1
      if (value != "") {
        item_count = split(value, items, ",")
        for (cursor = 1; cursor <= item_count; cursor++) {
          sub(/^[[:space:]]+/, "", items[cursor])
          sub(/[[:space:]]+$/, "", items[cursor])
          if (items[cursor] == "") fail("empty value in list update: " key)
          remember_list_value(key, items[cursor])
        }
      }
    } else if (action == "branch") {
      if (count != 4) fail("malformed Repository branch update")
      repository = parts[2]
      field = parts[3]
      value = parts[4]
      if (schema != "ticket" || repository !~ /^[a-z0-9][a-z0-9._-]*$/ ||
          !branch_field_allowed(field)) fail("invalid Repository branch update")
      if (!branch_seen[repository]) {
        branch_seen[repository] = 1
        branch_order[++branch_count] = repository
      }
      top_seen["branches"] = 1
      branch_value[repository, field] = value
      branch_value_seen[repository SUBSEP field] = 1
    } else {
      fail("unknown frontmatter update action")
    }
  }
  close(operations)
}

function render_list(key,    cursor) {
  if (list_count[key] == 0) {
    print key ": []"
    return
  }
  print key ":"
  for (cursor = 1; cursor <= list_count[key]; cursor++)
    print "  - " quote_scalar(list_value[key, cursor])
}

function render_scalar(key) {
  if (top_seen[key]) print key ": " quote_scalar(scalar_value[key])
}

function render_branches(    repository_index, repository, field_index, field, fields) {
  if (branch_count == 0) {
    print "branches: {}"
    return
  }
  split("base feature_branch ticket_branch ticket_head prepared_head integrated_head", fields, " ")
  print "branches:"
  for (repository_index = 1; repository_index <= branch_count; repository_index++) {
    repository = branch_order[repository_index]
    print "  " repository ":"
    for (field_index = 1; field_index <= 6; field_index++) {
      field = fields[field_index]
      if (branch_value_seen[repository SUBSEP field])
        print "    " field ": " quote_scalar(branch_value[repository, field])
    }
  }
}

function render_document(    body_index) {
  print "---"
  if (schema == "prd" || schema == "spec") {
    render_scalar("id")
    render_scalar("slug")
    render_list("repositories")
    render_scalar("created_at")
    render_list("supersedes")
  } else {
    render_scalar("id")
    render_scalar("status")
    render_list("repositories")
    render_list("blocked_by")
    render_scalar("claimed_by")
    render_scalar("claimed_at")
    render_scalar("resolved_at")
    render_scalar("blocked_at")
    render_scalar("blocked_reason")
    render_branches()
  }
  print "---"
  for (body_index = 1; body_index <= body_count; body_index++) print body[body_index]
}

BEGIN {
  failed = 0
  closed = 0
  section = ""
}

NR == 1 {
  if ($0 != "---") fail("frontmatter must start on the first line")
  next
}

{
  if (failed) next
  if (!closed) {
    if ($0 == "---") {
      closed = 1
      section = ""
      next
    }
    if ($0 == "" || $0 ~ /[[:space:]]+$/) fail("non-canonical frontmatter whitespace on line " NR)
    if ($0 !~ /^ /) {
      parse_top_line($0)
      next
    }
    if ($0 ~ /^  - /) {
      if (section != "list") fail("list item outside a declared list on line " NR)
      raw = substr($0, 5)
      if (!decode_scalar(raw) || decoded == "")
        fail("unsupported list value on line " NR)
      remember_list_value(section_key, decoded)
      next
    }
    if ($0 ~ /^  [a-z0-9][a-z0-9._-]*:$/) {
      if (section != "branches" && section != "branch")
        fail("mapping entry outside branches on line " NR)
      repository = substr($0, 3, length($0) - 3)
      if (branch_seen[repository]) fail("duplicate Repository branch mapping: " repository)
      branch_seen[repository] = 1
      branch_order[++branch_count] = repository
      active_repository = repository
      section = "branch"
      next
    }
    if ($0 ~ /^  [a-z0-9][a-z0-9._-]*: /) {
      if (section != "branches") fail("mapping entry outside branches on line " NR)
      branch_line = substr($0, 3)
      separator = index(branch_line, ":")
      repository = substr(branch_line, 1, separator - 1)
      raw = substr(branch_line, separator + 2)
      if (branch_seen[repository]) fail("duplicate Repository branch mapping: " repository)
      if (!decode_scalar(raw)) fail("unsupported Repository branch value on line " NR)
      branch_seen[repository] = 1
      branch_order[++branch_count] = repository
      remember_branch(repository, "ticket_branch", decoded)
      section = "branches"
      next
    }
    if ($0 ~ /^    [a-z][a-z0-9_]*: /) {
      if (section != "branch") fail("branch field outside a Repository mapping on line " NR)
      branch_line = substr($0, 5)
      separator = index(branch_line, ":")
      field = substr(branch_line, 1, separator - 1)
      raw = substr(branch_line, separator + 2)
      if (!branch_field_allowed(field)) fail("unknown Repository branch field: " field)
      if (!decode_scalar(raw)) fail("unsupported Repository branch value on line " NR)
      remember_branch(active_repository, field, decoded)
      next
    }
    fail("unsupported frontmatter structure on line " NR)
  } else {
    body[++body_count] = $0
  }
}

END {
  if (failed) exit 1
  if (!closed) fail("frontmatter closing delimiter is missing")
  validate_required()
  if (mode == "validate") exit 0
  if (mode == "get") {
    if (!scalar_allowed(query)) fail("unknown scalar frontmatter key: " query)
    if (top_seen[query]) print scalar_value[query]
    exit 0
  }
  if (mode == "get-list") {
    if (!list_allowed(query)) fail("unknown list frontmatter key: " query)
    for (cursor = 1; cursor <= list_count[query]; cursor++) print list_value[query, cursor]
    exit 0
  }
  if (mode == "branch-get") {
    if (schema != "ticket" || !branch_field_allowed(branch_field))
      fail("invalid Repository branch query")
    if (branch_value_seen[branch_repository SUBSEP branch_field])
      print branch_value[branch_repository, branch_field]
    exit 0
  }
  if (mode == "branch-repositories") {
    if (schema != "ticket") fail("Repository branches are only valid for tickets")
    for (cursor = 1; cursor <= branch_count; cursor++) print branch_order[cursor]
    exit 0
  }
  if (mode == "render") {
    read_operations()
    validate_required()
    render_document()
    exit 0
  }
  fail("unknown frontmatter operation")
}
