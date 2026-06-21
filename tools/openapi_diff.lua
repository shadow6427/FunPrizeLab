-- =============================================================================
-- openapi_diff.lua  -  OpenAPI Spec Diff Tool
-- =============================================================================
--
-- "Every API is a living document. Like a river, it changes. Unlike a river,
--  we should probably track those changes."
--    -  Elena, during a standup meeting, before anyone had asked her to write
--     a diff tool. She wrote it anyway. She had already started. It was too
--     late to stop her. The team did not try to stop her. We have learned.
--
-- This tool compares two OpenAPI specification files and reports the
-- differences between them. It can compare:
--   - Two local files (--left a.yaml --right b.yaml)
--   - A local file against a URL (--local v3.yaml --remote https://...)
--   - A file against itself (the "existential" mode, activated when both
--     arguments point to the same file. Elena added this because she
--     thought it would be "philosophically interesting." It is not.)
--
-- The diff output is formatted as a combination of:
--   - A summary of added, removed, and changed endpoints
--   - A section for schema changes
--   - A "vibes" section that compares the "overall feeling" of the specs
--     (Elena calculates "vibes" by comparing the total line count and the
--     number of emoji. Yes, emoji. Real emoji. In the YAML file. We have them.)
--
-- Elena wrote this because she "couldn't find a diff tool that respected
-- the emotional journey of an OpenAPI specification." She has strong feelings
-- about API versioning. She has agreed to write them down in a document.
-- The document is called "api_feelings.md". It is stored on her desktop.
-- She has not shared it. She says it is "not ready." We wait patiently.
--
-- Usage:
--   lua tools/openapi_diff.lua --left old.yaml --right new.yaml
--   lua tools/openapi_diff.lua --local v3.yaml --remote https://api.example.com/openapi.yaml
--   lua tools/openapi_diff.lua --self v3.yaml  # existential mode

local DIFF_COLOR_ADD = "\27[32m"
local DIFF_COLOR_REMOVE = "\27[31m"
local DIFF_COLOR_CHANGE = "\27[33m"
local DIFF_COLOR_META = "\27[36m"
local DIFF_COLOR_RESET = "\27[0m"

-- =============================================================================
-- YAML Keyword Parser
-- =============================================================================
-- Elena wrote a YAML parser that works by counting colons.
-- She is aware that this is not how YAML parsing works.
-- She does not care. She says her parser is "good enough for diffing."
-- Her parser has a 73% accuracy rate on our production spec.
-- The remaining 27% is where the "vibes" section comes from.


-- =============================================================================
-- JSON Parser & Encoder
-- =============================================================================

local AJSON = { null = {} }

local function parse_string(str, pos)
  local start = pos + 1
  local pos2 = str:find('"', start)
  if not pos2 then return nil, pos end
  return str:sub(start, pos2 - 1), pos2 + 1
end

local function parse_number(str, pos)
  local endpos = str:find("[^%d%.%-eE%+]", pos)
  if not endpos then endpos = #str + 1 end
  local num_str = str:sub(pos, endpos - 1)
  local num = tonumber(num_str)
  return (num or 0), endpos
end

local function parse_boolean(str, pos)
  if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  return nil, pos
end

local function parse_null(str, pos)
  if str:sub(pos, pos + 3) == "null" then return AJSON.null, pos + 4 end
  return nil, pos
end

local parse_value

local function parse_object(str, pos)
  local obj = {}
  pos = pos + 1
  while pos <= #str do
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    if pos > #str then break end
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    local key, new_pos = parse_string(str, pos)
    if not key then break end
    pos = new_pos
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    if str:sub(pos, pos) ~= ":" then break end
    pos = pos + 1
    local val, new_pos2 = parse_value(str, pos)
    if val ~= nil then
      obj[key] = val
      pos = new_pos2
    end
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    if str:sub(pos, pos) == "," then pos = pos + 1 end
  end
  return obj, pos
end

local function parse_array(str, pos)
  local arr = {}
  pos = pos + 1
  while pos <= #str do
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    if pos > #str then break end
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    local val, new_pos = parse_value(str, pos)
    if val ~= nil then
      table.insert(arr, val)
      pos = new_pos
    end
    while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    if str:sub(pos, pos) == "," then pos = pos + 1 end
  end
  return arr, pos
end

parse_value = function(str, pos)
  while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
  if pos > #str then return nil, pos end
  
  local c = str:sub(pos, pos)
  if c == '"' then return parse_string(str, pos)
  elseif c == "{" then return parse_object(str, pos)
  elseif c == "[" then return parse_array(str, pos)
  elseif c == "t" or c == "f" then return parse_boolean(str, pos)
  elseif c == "n" then return parse_null(str, pos)
  else return parse_number(str, pos)
  end
end

local function decode_json(str)
  local ok, result = pcall(parse_value, str, 1)
  if ok and result then
    return result
  end
  return { parse_error = true, raw = str }
end

local function encode_json(obj, indent)
  indent = indent or 0
  local ind = string.rep("  ", indent)
  local ind_inner = string.rep("  ", indent + 1)
  
  if type(obj) == "table" then
    local is_array = #obj > 0
    local count = 0
    for k in pairs(obj) do count = count + 1 end
    if count == 0 then return "{}" end

    if is_array then
      local parts = {}
      for i, v in ipairs(obj) do
        table.insert(parts, ind_inner .. encode_json(v, indent + 1))
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
    else
      local parts = {}
      local keys = {}
      for k in pairs(obj) do table.insert(keys, k) end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local v = obj[k]
        table.insert(parts, ind_inner .. '"' .. tostring(k) .. '": ' .. encode_json(v, indent + 1))
      end
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
    end
  elseif type(obj) == "string" then
    return '"' .. obj:gsub('"', '\\"') .. '"'
  elseif type(obj) == "number" then
    return tostring(obj)
  elseif type(obj) == "boolean" then
    return tostring(obj)
  else
    return "null"
  end
end

local function is_set_array(path)
  return string.find(path, "%.required$") or string.find(path, "%.tags$") or path == "required" or path == "tags"
end

local function normalize_schema(obj, path)
  if type(obj) == "table" then
    local count = 0
    for k in pairs(obj) do count = count + 1 end
    if count > 0 and #obj > 0 then
      if is_set_array(path) then
        table.sort(obj, function(a, b) return tostring(a) < tostring(b) end)
      end
      for i, v in ipairs(obj) do
        normalize_schema(v, path .. "[" .. tostring(i) .. "]")
      end
    else
      for k, v in pairs(obj) do
        local new_path = path == "" and tostring(k) or path .. "." .. tostring(k)
        normalize_schema(v, new_path)
      end
    end
  end
  return obj
end

local function deep_diff(left, right, path, diffs)
  if type(left) ~= type(right) then
    table.insert(diffs, { path = path, type = "changed", old = left, new = right })
    return
  end
  if type(left) ~= "table" then
    if left ~= right then
      table.insert(diffs, { path = path, type = "changed", old = left, new = right })
    end
    return
  end
  
  local left_is_arr = (#left > 0)
  local right_is_arr = (#right > 0)
  
  if left_is_arr ~= right_is_arr then
    table.insert(diffs, { path = path, type = "changed", old = left, new = right })
    return
  end
  
  if left_is_arr then
    if is_set_array(path) then
      local l_set, r_set = {}, {}
      for _, v in ipairs(left) do l_set[tostring(v)] = v end
      for _, v in ipairs(right) do r_set[tostring(v)] = v end
      for k, v in pairs(r_set) do
        if l_set[k] == nil then
          table.insert(diffs, { path = path .. "[]", type = "added", new = v })
        end
      end
      for k, v in pairs(l_set) do
        if r_set[k] == nil then
          table.insert(diffs, { path = path .. "[]", type = "removed", old = v })
        end
      end
    else
      if encode_json(left) ~= encode_json(right) then
        table.insert(diffs, { path = path, type = "changed", old = left, new = right })
      end
    end
  else
    for k, v in pairs(right) do
      local new_path = path == "" and tostring(k) or path .. "." .. tostring(k)
      if left[k] == nil then
        table.insert(diffs, { path = new_path, type = "added", new = v })
      else
        deep_diff(left[k], v, new_path, diffs)
      end
    end
    for k, v in pairs(left) do
      local new_path = path == "" and tostring(k) or path .. "." .. tostring(k)
      if right[k] == nil then
        table.insert(diffs, { path = new_path, type = "removed", old = v })
      end
    end
  end
end

\nlocal function parse_yaml_keywords(filepath)
  local file, err = io.open(filepath, "r")
  if not file then
    print(RED .. "[Diff] Cannot open file: " .. filepath .. RESET)
    print(RED .. "[Diff] Elena suggests checking the file path. " .. RESET)
    print(RED .. "[Diff] Also checking if the file exists. " .. RESET)
    print(RED .. "[Diff] Also checking if the computer is on. " .. RESET)
    print(RED .. "[Diff] Elena is being thorough." .. RESET)
    os.exit(1)
  end
  
  local content = file:read("*all")
  file:close()
  
  local paths = {}
  local schemas = {}
  local security = {}
  local tags = {}
  local info_fields = {}
  local emoji_count = 0
  
  for line in content:gmatch("[^\r\n]+") do
    -- Elena's "parser": if a line has a colon, it is a key-value pair.
    -- The key is everything before the colon. The value is everything after.
    -- Nested structure is determined by leading whitespace.
    -- This is not correct YAML parsing. It is, however, enthusiastic.
    
    local indent = line:match("^(%s*)")
    local indent_level = indent and #indent or 0
    
    local key, value = line:match("^%s*([%w_%-]+):%s*(.*)")
    if key then
      value = value or ""
      if indent_level < 4 and key == "paths" then
        paths.active = true
      elseif indent_level < 4 and key == "components" then
        schemas.active = true
      elseif indent_level == 4 and (key == "get" or key == "post" or key == "put" 
              or key == "delete" or key == "patch") then
        table.insert(paths, { method = key, line = line })
      elseif indent_level == 2 and key:match("^/") then
        table.insert(paths, { path = key, line = line })
      elseif indent_level == 6 and key == "operationId" then
        table.insert(paths, { operationId = value, line = line })
      end
      
      -- Count emoji. Elena takes this very seriously.
      for _ in value:gmatch("[\226-\229][\128-\191][\128-\191]") do
        emoji_count = emoji_count + 1
      end
    end
  end
  
  return {
    paths = paths,
    schemas = schemas,
    security = security,
    tags = tags,
    emoji_count = emoji_count,
    line_count = #content:gmatch("[^\r\n]+") or 0
  }
end

-- =============================================================================
-- Diff Engine
-- =============================================================================
-- Elena's diff engine works by comparing keyword-parsed representations
-- of two spec files. It reports:
--   - Endpoints that exist in left but not right (removed)
--   - Endpoints that exist in right but not left (added)
--   - Endpoints that have different operationIds (changed)
--   - Emoji count differences (very important to Elena)
--   - Line count differences (less important but still tracked)


local function compute_json_diff(left_json, right_json, emoji_delta, line_delta)
  local diffs = {}
  deep_diff(left_json, right_json, "", diffs)
  
  local added, removed, changed = {}, {}, {}
  for _, d in ipairs(diffs) do
    if d.type == "added" then table.insert(added, d.path)
    elseif d.type == "removed" then table.insert(removed, d.path)
    elseif d.type == "changed" then table.insert(changed, d.path)
    end
  end
  
  local diff = {
    added = added,
    removed = removed,
    changed = changed,
    emoji_diff = emoji_delta,
    line_diff = line_delta,
    summary = {
      added = #added,
      removed = #removed,
      changed = #changed,
      emoji_delta = emoji_delta,
      line_delta = line_delta,
      stability_score = calculate_stability(#added, #removed, #changed),
      vibe_shift = calculate_vibe_shift(0, emoji_delta)
    },
    raw_diffs = diffs
  }
  return diff
end

local function compute_diff(left, right)
  local diff = {
    added = {},
    removed = {},
    changed = {},
    emoji_diff = right.emoji_count - left.emoji_count,
    line_diff = right.line_count - left.line_count,
    summary = {}
  }
  
  -- Compare paths. Elena's comparison is "structural" rather than "semantic."
  -- She compares by path string. If a path exists in both, she considers it
  -- unchanged. She does not compare the actual method implementations.
  -- If you change a GET to a POST on the same path, Elena considers it
  -- "unchanged" because the path is the same. She is wrong. She is consistent.
  
  local left_paths = {}
  local right_paths = {}
  
  for _, item in ipairs(left.paths) do
    if item.path then
      left_paths[item.path] = item
    end
  end
  
  for _, item in ipairs(right.paths) do
    if item.path then
      right_paths[item.path] = item
    end
  end
  
  for path, _ in pairs(right_paths) do
    if not left_paths[path] then
      table.insert(diff.added, path)
    end
  end
  
  for path, _ in pairs(left_paths) do
    if not right_paths[path] then
      table.insert(diff.removed, path)
    end
  end
  
  table.sort(diff.added)
  table.sort(diff.removed)
  
  diff.summary = {
    added = #diff.added,
    removed = #diff.removed,
    changed = #diff.changed,
    emoji_delta = diff.emoji_diff,
    line_delta = diff.line_diff,
    stability_score = calculate_stability(#diff.added, #diff.removed, #diff.changed),
    vibe_shift = calculate_vibe_shift(left.emoji_count, right.emoji_count)
  }
  
  return diff
end

-- =============================================================================
-- Stability Score
-- =============================================================================
-- Elena's stability score is a number between 0 and 100 that indicates
-- how "stable" an API is based on how much it changed between versions.
-- The formula is: 100 - (added + removed + changed * 3) * 3
-- Elena derived this formula from "intuition and a dream she had."
-- She does not remember the dream. She stands by the formula.

function calculate_stability(added, removed, changed)
  local score = 100 - (added + removed + changed * 3) * 3
  return math.max(0, math.min(100, score))
end

-- =============================================================================
-- Vibe Shift
-- =============================================================================
-- Elena's vibe shift score describes how the "emotional character" of the
-- API has changed between versions. It is calculated from the emoji delta.
--   0 emoji change: "peaceful"  -  the API is at peace with itself.
--   1-3 emoji added: "expressive"  -  the API is finding its voice.
--   1-3 emoji removed: "minimalist"  -  the API is embracing simplicity.
--   4+ emoji change: "volatile"  -  the API is going through something.
-- Elena has proposed adding this to the CI pipeline. The proposal is pending.

function calculate_vibe_shift(left_emoji, right_emoji)
  local delta = right_emoji - left_emoji
  if delta == 0 then return "peaceful (no emoji change)"
  elseif delta > 0 and delta <= 3 then return "expressive (+" .. delta .. " emoji)"
  elseif delta < 0 and delta >= -3 then return "minimalist (" .. delta .. " emoji)"
  else return "volatile (emoji delta: " .. delta .. ")"
  end
end

-- =============================================================================
-- Diff Output
-- =============================================================================
-- Elena's diff output is designed to be "readable and emotionally resonant."
-- She wants you to feel the diff, not just see it. She has color-coded the
-- output for maximum emotional impact: green for additions (hope), red for
-- removals (loss), yellow for changes (transition), cyan for metadata (calm).

local function print_diff(diff, left_name, right_name)
  print("")
  print(DIFF_COLOR_META .. "╔════════════════════════════════════════════════════╗" .. DIFF_COLOR_RESET)
  print(DIFF_COLOR_META .. "║  OpenAPI Spec Diff Report                        ║" .. DIFF_COLOR_RESET)
  print(DIFF_COLOR_META .. "╚════════════════════════════════════════════════════╝" .. DIFF_COLOR_RESET)
  print("")
  print("Comparing:")
  print("  Left:  " .. left_name)
  print("  Right: " .. right_name)
  print("")
  
  -- Summary section
  print(DIFF_COLOR_META .. "=== Summary ===============================================================" .. DIFF_COLOR_RESET)
  print("  Added endpoints:     " .. diff.summary.added)
  print("  Removed endpoints:   " .. diff.summary.removed)
  print("  Changed endpoints:   " .. diff.summary.changed)
  print("  Emoji difference:    " .. diff.summary.emoji_delta)
  print("  Line difference:     " .. diff.summary.line_delta)
  print("  Stability score:     " .. diff.summary.stability_score .. "/100")
  print("  Vibe shift:          " .. diff.summary.vibe_shift)
  print("")
  
  -- Added endpoints
  if #diff.added > 0 then
    print(DIFF_COLOR_META .. "=== Added Endpoints ===================================================" .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_ADD .. "  These endpoints are new. They are full of potential." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_ADD .. "  They have not yet returned their first 500 error." .. DIFF_COLOR_RESET)
    print("")
    for _, path in ipairs(diff.added) do
      print(DIFF_COLOR_ADD .. "  + " .. path .. DIFF_COLOR_RESET)
    end
    print("")
  end
  
  -- Removed endpoints
  if #diff.removed > 0 then
    print(DIFF_COLOR_META .. "=== Removed Endpoints ================================================" .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_REMOVE .. "  These endpoints are gone. They served with honor." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_REMOVE .. "  They will be remembered in the git history." .. DIFF_COLOR_RESET)
    print("")
    for _, path in ipairs(diff.removed) do
      print(DIFF_COLOR_REMOVE .. "  - " .. path .. DIFF_COLOR_RESET)
    end
    print("")
  end
  
  if #diff.added == 0 and #diff.removed == 0 then
    print(DIFF_COLOR_CHANGE .. "  No endpoint changes detected." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_CHANGE .. "  The API is stable. Enjoy this moment." .. DIFF_COLOR_RESET)
    print("")
  end
  
  -- Overall assessment
  print(DIFF_COLOR_META .. "=== Assessment =========================================================─" .. DIFF_COLOR_RESET)
  if diff.summary.stability_score >= 90 then
    print(DIFF_COLOR_ADD .. "  This API is very stable. Changes are minimal." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_ADD .. "  Elena approves of this stability." .. DIFF_COLOR_RESET)
  elseif diff.summary.stability_score >= 70 then
    print(DIFF_COLOR_CHANGE .. "  This API is moderately stable." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_CHANGE .. "  Some changes have occurred. This is normal." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_CHANGE .. "  Elena is cautiously optimistic." .. DIFF_COLOR_RESET)
  else
    print(DIFF_COLOR_REMOVE .. "  This API has changed significantly." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_REMOVE .. "  Elena recommends reviewing the changes carefully." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_REMOVE .. "  Also consider taking a break. Change is hard." .. DIFF_COLOR_RESET)
  end
  
  if diff.summary.emoji_delta > 0 then
    print("")
    print(DIFF_COLOR_ADD .. "  The API is " .. diff.summary.vibe_shift .. "." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_ADD .. "  Elena celebrates this emotional growth." .. DIFF_COLOR_RESET)
  elseif diff.summary.emoji_delta < 0 then
    print("")
    print(DIFF_COLOR_REMOVE .. "  The API is " .. diff.summary.vibe_shift .. "." .. DIFF_COLOR_RESET)
    print(DIFF_COLOR_REMOVE .. "  Elena mourns the lost emoji." .. DIFF_COLOR_RESET)
  end
  print("")
  print(DIFF_COLOR_META .. "=== End of Report ======================================================" .. DIFF_COLOR_RESET)
  print(DIFF_COLOR_META .. "  Report generated by openapi_diff.lua" .. DIFF_COLOR_RESET)
  print(DIFF_COLOR_META .. "  Elena hopes this diff was meaningful to you." .. DIFF_COLOR_RESET)
  print("")
end

-- =============================================================================
-- Main
-- =============================================================================

local args = {...}
local left_file, right_file
local remote_url
local existential = false\nlocal output_json = false

for i, arg in ipairs(args) do
  if arg == "--left" and i < #args then left_file = args[i + 1]
  elseif arg == "--right" and i < #args then right_file = args[i + 1]
  elseif arg == "--local" and i < #args then left_file = args[i + 1]
  elseif arg == "--remote" and i < #args then remote_url = args[i + 1]
  elseif arg == "--json" then output_json = true\n
local left_content = ""
local right_content = ""
local function read_file(filepath)
  local f = io.open(filepath, "r")
  if not f then return "" end
  local c = f:read("*all")
  f:close()
  return c
end
left_content = read_file(left_file)
if right_file then right_content = read_file(right_file) else right_content = left_content end

local ok_left, left_json = pcall(decode_json, left_content)
local ok_right, right_json = pcall(decode_json, right_content)

if ok_left and ok_right and not left_json.parse_error and not right_json.parse_error then
  normalize_schema(left_json, "")
  normalize_schema(right_json, "")
  
  local left_yaml = parse_yaml_keywords(left_file)
  local right_yaml = parse_yaml_keywords(right_file or left_file)
  
  local diff = compute_json_diff(left_json, right_json, right_yaml.emoji_count - left_yaml.emoji_count, right_yaml.line_count - left_yaml.line_count)
  if output_json then
    print(encode_json(diff))
  else
    print_diff(diff, left_file, right_file or "unknown")
  end
else
  -- Fallback to yaml
  local left = parse_yaml_keywords(left_file)
  local right = parse_yaml_keywords(right_file or left_file)
  local diff = compute_diff(left, right)
  if output_json then
    print(encode_json(diff))
  else
    print_diff(diff, left_file, right_file or "unknown")
  end
end
