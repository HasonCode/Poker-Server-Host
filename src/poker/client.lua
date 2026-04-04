-- HTTP JSON client for the poker server (LuaSocket + LTN12).
--
--   package.path = "src/?.lua;src/?/init.lua;" .. package.path
--   local Client = require("poker.client")
--   local c, cerr = Client.new({ base_url = "http://127.0.0.1:8080" })
--   if not c then error(cerr) end
--   local data, err = c:health()
--   if err then ... end

local json = require("poker.json")

local M = {}
M.__index = M

M.ERR_TRANSPORT = "transport"
M.ERR_API = "api"

--- @param opts { base_url?: string, timeout?: number }
function M.new(opts)
  opts = opts or {}
  local ok_http, http = pcall(require, "socket.http")
  local ok_lt, ltn12 = pcall(require, "ltn12")
  if not ok_http or not http or not ok_lt or not ltn12 then
    return nil, "LuaSocket (socket.http) and LTN12 are required for poker.client"
  end
  local base = opts.base_url or "http://127.0.0.1:8080"
  base = base:gsub("/+$", "")
  return setmetatable({
    base_url = base,
    timeout = opts.timeout or 30,
    token = nil,
    _joined_table_id = nil,
    _joined_player_id = nil,
    _http = http,
    _ltn12 = ltn12,
  }, M)
end

local function uri_escape_segment(s)
  return (tostring(s):gsub("[^%w%-_.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function path_table(table_id, suffix)
  return "/v1/tables/" .. uri_escape_segment(table_id) .. "/" .. suffix
end

local function path_table_state(table_id)
  return path_table(table_id, "state")
end

local function err_transport(msg, http_status, raw)
  return {
    kind = M.ERR_TRANSPORT,
    message = msg,
    http_status = http_status,
    raw = raw,
  }
end

local function err_api(http_status, decoded, raw)
  local e = decoded and decoded.error
  if type(e) == "table" then
    return {
      kind = M.ERR_API,
      http_status = http_status,
      code = e.code,
      message = e.message,
      details = e.details,
      raw = raw,
    }
  end
  return {
    kind = M.ERR_API,
    http_status = http_status,
    code = "unknown",
    message = raw or "",
    raw = raw,
  }
end

function M:_request(method, path, json_body, timeout_override)
  local http = self._http
  local ltn12 = self._ltn12
  local url = self.base_url .. path
  local chunks = {}
  local reqt = {
    url = url,
    method = method,
    sink = ltn12.sink.table(chunks),
    timeout = timeout_override or self.timeout,
  }
  local hdrs = {}
  if self.token then
    hdrs["x-player-token"] = self.token
  end
  if json_body ~= nil then
    local payload = json.encode(json_body)
    reqt.source = ltn12.source.string(payload)
    hdrs["content-type"] = "application/json"
    hdrs["content-length"] = tostring(#payload)
  end
  reqt.headers = hdrs
  local r, code, headers, status_line = http.request(reqt)
  local body = table.concat(chunks)

  -- socket.protect: on failure returns nil, err (string)
  if not r then
    return nil, err_transport(tostring(code), nil, body)
  end

  code = tonumber(code)
  if not code then
    return nil, err_transport("invalid HTTP status: " .. tostring(code), nil, body)
  end

  local ok_dec, decoded = pcall(json.decode, body)
  if not ok_dec then
    if code >= 200 and code < 300 then
      return nil, err_transport("response is not valid JSON: " .. tostring(decoded), code, body)
    end
    return nil, err_transport("error response is not valid JSON", code, body)
  end

  if code < 200 or code >= 300 then
    return nil, err_api(code, decoded, body)
  end

  return decoded, nil
end

function M:health()
  return self:_request("GET", "/health")
end

function M:get_table_state(table_id)
  return self:_request("GET", path_table_state(table_id))
end

--- @param args { seat?: number, player_id: string, chips: number }
function M:join_table(table_id, args)
  local body = {
    player_id = args.player_id,
    chips = args.chips,
  }
  if args.seat ~= nil then
    body.seat = args.seat
  end
  local join_timeout = math.max(self.timeout, 150)
  local data, err = self:_request("POST", path_table(table_id, "join"), body, join_timeout)
  if data and data.token then
    self.token = data.token
  end
  if not err then
    self._joined_table_id = table_id
    self._joined_player_id = args.player_id
  end
  return data, err
end

--- Call before process exit (Lua has no portable auto-hook) to leave the table if still joined.
function M:leave_if_joined()
  local tid = self._joined_table_id
  local pid = self._joined_player_id
  if not tid or not pid then
    return true
  end
  return self:leave_table(tid, pid)
end

function M:leave_table(table_id, player_id)
  local data, err = self:_request("POST", path_table(table_id, "leave"), {
    player_id = player_id,
  })
  if not err then
    self.token = nil
    if self._joined_table_id == table_id and self._joined_player_id == player_id then
      self._joined_table_id = nil
      self._joined_player_id = nil
    end
  end
  return data, err
end

--- True if it is player_id's turn right now.
function M:is_my_turn(table_id, player_id)
  local data, err = self:get_table_state(table_id)
  if not data then
    return false, err
  end
  local hand = data.hand
  if not hand or hand.status ~= "active" then
    return false
  end
  local ats = hand.action_to_seat
  if not ats then
    return false
  end
  local seats = data.seats or {}
  local seat_info = seats[ats]
  if type(seat_info) ~= "table" then
    return false
  end
  return seat_info.player_id == player_id
end

--- Block until it is player_id's turn; returns state snapshot.
--- @param opts { poll_interval?: number, timeout?: number }
function M:wait_for_turn(table_id, player_id, opts)
  opts = opts or {}
  local interval = opts.poll_interval or 0.5
  local deadline = opts.timeout and (os.clock() + opts.timeout) or nil
  local socket_ok, socket = pcall(require, "socket")
  local sleep = socket_ok and socket.sleep or function(s)
    os.execute("sleep " .. tostring(s))
  end
  while true do
    local data, err = self:get_table_state(table_id)
    if data then
      local hand = data.hand
      if hand and hand.status == "active" then
        local ats = hand.action_to_seat
        local seats = data.seats or {}
        local info = ats and seats[ats]
        if type(info) == "table" and info.player_id == player_id then
          return data
        end
      end
    end
    if deadline and os.clock() >= deadline then
      return nil, { kind = M.ERR_TRANSPORT, message = "timed out waiting for turn" }
    end
    sleep(interval)
  end
end

--- @param args { player_id: string, action: string, amount?: number, queue?: boolean }
function M:send_action(table_id, args)
  local body = {
    player_id = args.player_id,
    action = args.action,
  }
  if args.amount ~= nil then
    body.amount = args.amount
  end
  if args.queue ~= nil then
    body.queue = args.queue
  end
  return self:_request("POST", path_table(table_id, "actions"), body)
end

M.path_table = path_table
M.path_table_state = path_table_state

return M
