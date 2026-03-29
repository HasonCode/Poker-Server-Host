-- Minimal HTTP/1.1 listener (LuaSocket). Optional dependency.

local json = require("poker.json")

local M = {}

local function parse_request_line(line)
  local method, path, ver = line:match("^(%S+)%s+(%S+)%s+(%S+)")
  return method, path, ver
end

local function read_http_request(client)
  client:settimeout(30)
  local buf = {}
  while true do
    local line, err = client:receive("*l")
    if not line then
      return nil, err or "closed"
    end
    if line == "" then
      break
    end
    buf[#buf + 1] = line
  end
  if #buf == 0 then
    return nil, "empty"
  end
  local method, path = parse_request_line(buf[1])
  path = path and path:match("^([^?]*)") or path
  return {
    method = method,
    path = path,
    raw_headers = buf,
  }
end

local function send_json(client, status, body_tbl)
  local body = json.encode(body_tbl)
  local head = string.format(
    "HTTP/1.1 %s\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
    status,
    #body
  )
  client:send(head .. body)
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
  }
  return setmetatable(state, { __index = M })
end

function M:route(method, path, handler)
  self.routes[method .. " " .. path] = handler
end

function M:match_handler(method, path)
  if self.routes[method .. " " .. path] then
    return self.routes[method .. " " .. path], {}
  end
  local pattern = "^/v1/tables/([^/]+)/state$"
  local id = path:match(pattern)
  if id and method == "GET" then
    local h = self.routes["GET /v1/tables/:id/state"]
    if h then
      return h, { table_id = id }
    end
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

  local handler, params = self:match_handler(req.method, req.path)
  local status = "200 OK"
  local body
  if not handler then
    status = "404 Not Found"
    body = { error = { code = "not_found", message = req.path } }
  else
    local ok, res_or_err, res2 = pcall(handler, req, params, self.get_context())
    if not ok then
      status = "500 Internal Server Error"
      body = { error = { code = "internal", message = tostring(res_or_err) } }
    elseif type(res_or_err) == "table" and res_or_err[1] then
      status = res_or_err[1]
      body = res_or_err[2]
    else
      body = res_or_err
    end
  end

  send_json(client, status, body)
  client:close()
  return true
end

function M:run_loop()
  io.stderr:write(string.format("poker-server listening on %s:%s\n", self.host, tostring(self.port)))
  while true do
    self:serve_one()
  end
end

return M
