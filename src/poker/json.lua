-- Minimal JSON encoder (no external deps). Tables only.

local M = {}

local function escape_string(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return '"' .. s .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
    if k > n then
      n = k
    end
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return n > 0 or next(t) == nil
end

function M.encode(val)
  local t = type(val)
  if val == nil then
    return "null"
  end
  if t == "number" then
    if val ~= val or val == math.huge or val == -math.huge then
      return "null"
    end
    return string.format("%.17g", val)
  end
  if t == "boolean" then
    return val and "true" or "false"
  end
  if t == "string" then
    return escape_string(val)
  end
  if t ~= "table" then
    error("json.encode: unsupported type " .. t)
  end

  if is_array(val) then
    local parts = {}
    for i = 1, #val do
      parts[i] = M.encode(val[i])
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for k in pairs(val) do
    if type(k) ~= "string" then
      error("json.encode: object keys must be strings")
    end
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do
    parts[i] = escape_string(k) .. ":" .. M.encode(val[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return M
