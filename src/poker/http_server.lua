-- Minimal HTTP/1.1 listener (LuaSocket). Optional dependency.

local json = require("poker.json")
local api = require("poker.api")

local M = {}

local function parse_request_line(line)
  line = line:gsub("\r$", "")
  local method, path, ver = line:match("^(%S+)%s+(%S+)%s+(%S+)")
  return method, path, ver
end

local function parse_cookies(header)
  local cookies = {}
  if not header or header == "" then return cookies end
  for pair in header:gmatch("[^;]+") do
    local k, v = pair:match("^%s*([^=]+)=(.*)%s*$")
    if k then
      local key = (k:match("^%s*(.-)%s*$") or k):lower()
      cookies[key] = (v:match("^%s*(.-)%s*$") or v)
    end
  end
  return cookies
end

local function parse_query_string(qs)
  local params = {}
  if not qs or qs == "" then return params end
  for pair in qs:gmatch("[^&]+") do
    local k, v = pair:match("^([^=]+)=?(.*)")
    if k then
      params[M.url_decode(k)] = M.url_decode(v or "")
    end
  end
  return params
end

function M.url_decode(str)
  str = str:gsub("+", " ")
  str = str:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return str
end

function M.url_encode(str)
  str = tostring(str)
  str = str:gsub("([^%w%-%.%_%~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  str = str:gsub(" ", "+")
  return str
end

local function read_http_request(client)
  client:settimeout(30)
  local first, err = client:receive("*l")
  if not first then
    return nil, err or "closed"
  end
  first = first:gsub("\r$", "")
  local headers = {}
  while true do
    local line, err2 = client:receive("*l")
    if not line then
      return nil, err2 or "closed"
    end
    line = line:gsub("\r$", "")
    if line == "" then
      break
    end
    local name, val = line:match("^([^:]+):%s*(.*)")
    if name then
      headers[name:lower()] = val
    end
  end
  local method, full_path = parse_request_line(first)
  local path = full_path and full_path:match("^([^?]*)") or full_path
  local query_string = full_path and full_path:match("%?(.*)$") or ""
  local body = ""
  local clen = tonumber(headers["content-length"] or "0") or 0
  if clen > 0 then
    client:settimeout(30)
    local chunk, err3 = client:receive(clen)
    if not chunk then
      return nil, err3 or "body"
    end
    body = chunk
  end
  return {
    method = method,
    path = path,
    query_string = query_string,
    query = parse_query_string(query_string),
    headers = headers,
    cookies = parse_cookies(headers["cookie"]),
    body = body,
  }
end

function M.send_json_response(client, status, body_tbl)
  local body = json.encode(body_tbl)
  local head = string.format(
    "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
    status,
    #body
  )
  client:send(head .. body)
end

local function send_json(client, status, body_tbl)
  M.send_json_response(client, status, body_tbl)
end

local MIME = {
  html = "text/html",
  css = "text/css",
  js = "text/javascript",
  json = "application/json",
  svg = "image/svg+xml",
  ico = "image/x-icon",
  png = "image/png",
  woff2 = "font/woff2",
}

local function mime_for(path)
  local ext = path:match("%.([^.]+)$")
  ext = ext and ext:lower()
  return MIME[ext or ""] or "application/octet-stream"
end

local function resolve_static(root, path)
  if not root or path == "" then
    return nil
  end
  if path:find("%.%.") or path:find("//") then
    return nil
  end
  local rel = path:gsub("^/", "")
  if rel == "" then
    rel = "index.html"
  end
  -- If the path ends with / (directory), try index.html inside it
  if rel:match("/$") then
    rel = rel .. "index.html"
  end
  local full = root .. "/" .. rel
  -- If the path has no extension and is a directory, try index.html
  if not rel:match("%.[^/]+$") then
    local idx = full .. "/index.html"
    local f = io.open(idx, "rb")
    if f then
      f:close()
      return idx
    end
  end
  return full
end

local function send_raw(client, status, content_type, body)
  local charset = ""
  if content_type:find("^text/") or content_type == "application/javascript" then
    charset = "; charset=utf-8"
  end
  local head = string.format(
    "HTTP/1.1 %s\r\nContent-Type: %s%s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
    status,
    content_type,
    charset,
    #body
  )
  client:send(head)
  client:send(body)
end

local function send_custom(client, status, headers, body)
  body = body or ""
  local parts = { "HTTP/1.1 " .. status .. "\r\n" }
  if not headers["content-length"] and not headers["Content-Length"] then
    parts[#parts + 1] = "Content-Length: " .. #body .. "\r\n"
  end
  if not headers["connection"] and not headers["Connection"] then
    parts[#parts + 1] = "Connection: close\r\n"
  end
  for k, v in pairs(headers) do
    parts[#parts + 1] = k .. ": " .. v .. "\r\n"
  end
  parts[#parts + 1] = "\r\n"
  client:send(table.concat(parts))
  if #body > 0 then
    client:send(body)
  end
end

function M.new(opts)
  opts = opts or {}
  local ok, socket = pcall(require, "socket")
  if not ok then
    return nil, "LuaSocket not installed (luasocket). HTTP server unavailable."
  end

  local host = opts.host or "*"
  local port = opts.port or 8080
  local server = assert(socket.bind(host, port))
  server:settimeout(0.5)

  local state = {
    server = server,
    socket = socket,
    host = host,
    port = port,
    get_context = opts.get_context or function()
      return {}
    end,
    routes = opts.routes or {},
    static_root = opts.static_root,
    tick = opts.tick,
    on_request_log = opts.on_request_log,
    request_log_enrich = opts.request_log_enrich,
  }
  return setmetatable(state, { __index = M })
end

function M:route(method, path, handler)
  self.routes[method .. " " .. path] = handler
end

function M:match_handler(method, path)
  local exact = self.routes[method .. " " .. path]
  if exact then
    return exact, {}
  end
  local   id = path:match("^/v1/tables/([^/]+)/state$")
  if id and method == "GET" then
    local h = self.routes["GET /v1/tables/:id/state"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/my%-turn$")
  if id and method == "GET" then
    local h = self.routes["GET /v1/tables/:id/my-turn"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/join$")
  if id and method == "POST" then
    local h = self.routes["POST /v1/tables/:id/join"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/actions$")
  if id and method == "POST" then
    local h = self.routes["POST /v1/tables/:id/actions"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/leave$")
  if id and method == "POST" then
    local h = self.routes["POST /v1/tables/:id/leave"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/bot/start$")
  if id and method == "POST" then
    local h = self.routes["POST /v1/tables/:id/bot/start"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/bot/stop$")
  if id and method == "POST" then
    local h = self.routes["POST /v1/tables/:id/bot/stop"]
    if h then
      return h, { table_id = id }
    end
  end
  id = path:match("^/v1/tables/([^/]+)/bot/list$")
  if id and method == "GET" then
    local h = self.routes["GET /v1/tables/:id/bot/list"]
    if h then
      return h, { table_id = id }
    end
  end

  -- Admin routes
  id = path:match("^/admin/api/tables/([^/]+)/kick$")
  if id and method == "POST" then
    local h = self.routes["POST /admin/api/tables/:id/kick"]
    if h then return h, { table_id = id } end
  end
  id = path:match("^/admin/api/tables/([^/]+)/reset$")
  if id and method == "POST" then
    local h = self.routes["POST /admin/api/tables/:id/reset"]
    if h then return h, { table_id = id } end
  end
  id = path:match("^/admin/api/tables/([^/]+)/settings$")
  if id and method == "POST" then
    local h = self.routes["POST /admin/api/tables/:id/settings"]
    if h then return h, { table_id = id } end
  end
  id = path:match("^/admin/api/tables/([^/]+)/delete$")
  if id and method == "POST" then
    local h = self.routes["POST /admin/api/tables/:id/delete"]
    if h then return h, { table_id = id } end
  end
  id = path:match("^/admin/api/tables/([^/]+)/snapshot$")
  if id and method == "GET" then
    local h = self.routes["GET /admin/api/tables/:id/snapshot"]
    if h then return h, { table_id = id } end
  end

  return nil
end

function M:serve_one()
  local client, err = self.server:accept()
  if not client then
    return false, err
  end
  client:settimeout(10)
  local req, rerr = read_http_request(client)
  if not req then
    client:close()
    return true
  end

  local t0 = os.clock()
  local function log_request(status_line, kind)
    if not self.on_request_log then
      return
    end
    local full_path = req.path
    if req.query_string and req.query_string ~= "" then
      full_path = full_path .. "?" .. req.query_string
    end
    local code = tonumber((status_line or ""):match("^(%d%d%d)")) or 0
    local ms = math.floor((os.clock() - t0) * 1000 + 0.5)
    local entry = {
      method = req.method or "?",
      path = full_path,
      status = code,
      status_line = status_line,
      ms = ms,
      kind = kind or "api",
    }
    if self.request_log_enrich then
      self.request_log_enrich(entry, req)
    end
    self.on_request_log(entry)
  end

  local handler, params = self:match_handler(req.method, req.path)

  if handler then
    req.json = nil
    if req.body and #req.body > 0 then
      local okj, decoded = pcall(json.decode, req.body)
      if not okj then
        send_json(client, "400 Bad Request", api.error_body("bad_request", "Request body must be valid JSON"))
        log_request("400 Bad Request", "json_error")
        client:close()
        return true
      end
      req.json = decoded
    end
  end

  if not handler and req.method == "GET" and self.static_root then
    local filepath = resolve_static(self.static_root, req.path)
    if filepath then
      local f = io.open(filepath, "rb")
      if f then
        local data = f:read("*a")
        f:close()
        send_raw(client, "200 OK", mime_for(filepath), data or "")
        log_request("200 OK", "static")
        client:close()
        return true
      end
    end
  end

  local status = "200 OK"
  local body
  if not handler then
    status = "404 Not Found"
    body = api.error_body("not_found", "No matching route or static file.", { path = req.path })
  else
    local ok, res_or_err, res2 = pcall(handler, req, params, self.get_context())
    if not ok then
      io.stderr:write("[poker-server] handler error: " .. tostring(res_or_err) .. "\n")
      status = "500 Internal Server Error"
      body = api.error_body("internal", "An unexpected error occurred.")
    elseif type(res_or_err) == "table" and res_or_err.__defer_join then
      local ctx = self.get_context()
      if not ctx.pending_joins then
        ctx.pending_joins = {}
      end
      local wait_sec = tonumber(os.getenv("POKER_JOIN_WAIT_SEC")) or 120
      ctx.pending_joins[#ctx.pending_joins + 1] = {
        client = client,
        deadline = os.clock() + wait_sec,
        ctx = res_or_err.ctx,
        json = res_or_err.json,
      }
      return true
    elseif type(res_or_err) == "table" and res_or_err.__raw then
      send_custom(client, res_or_err.status or "200 OK", res_or_err.headers or {}, res_or_err.body or "")
      log_request(res_or_err.status or "200 OK", "raw")
      client:close()
      return true
    elseif type(res_or_err) == "table" and res_or_err[1] then
      status = res_or_err[1]
      body = res_or_err[2]
    else
      body = res_or_err
    end
  end

  send_json(client, status, body)
  log_request(status, "api")
  client:close()
  return true
end

function M:run_loop()
  io.stderr:write(string.format("poker-server listening on %s:%s\n", self.host, tostring(self.port)))
  if self.static_root then
    io.stderr:write(string.format("  UI:  http://127.0.0.1:%s/\n", tostring(self.port)))
  end
  while true do
    if self.tick then
      self.tick(self)
    end
    self:serve_one()
  end
end

return M
