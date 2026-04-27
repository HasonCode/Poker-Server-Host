--- Admin authentication: Google OAuth2 + in-memory sessions.

local M = {}

local sessions = {} -- token -> { email, created_at }

local SESSION_COOKIE = "poker_admin_session"
local SESSION_TTL = 86400 -- 24 hours

--- Generate a random hex session token.
function M.generate_session_id()
  local bytes = {}
  for _ = 1, 32 do
    bytes[#bytes + 1] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(bytes)
end

--- Create a session for the given email. Returns the session token.
function M.create_session(email)
  local token = M.generate_session_id()
  sessions[token] = { email = email, created_at = os.time() }
  return token
end

--- Remove a session.
function M.destroy_session(token)
  sessions[token] = nil
end

--- Validate the session cookie on a request.
--- Returns the session table { email, created_at } or nil.
--- @param admin_allow string|table|nil If a string, session email must match
--- (case-insensitive). If a table, keys must be lowercased emails allowed
--- as admins. If nil, any valid session passes (not used by the server).
function M.validate_session(req, admin_allow)
  local c = req.cookies
  local token = c and (c[SESSION_COOKIE] or c[SESSION_COOKIE:lower()])
  if not token or token == "" then return nil end

  local sess = sessions[token]
  if not sess then return nil end

  if os.time() - sess.created_at > SESSION_TTL then
    sessions[token] = nil
    return nil
  end

  if admin_allow then
    local e = (sess.email or ""):lower()
    if type(admin_allow) == "string" then
      if e ~= admin_allow:lower() then
        return nil
      end
    elseif type(admin_allow) == "table" then
      if not admin_allow[e] then
        return nil
      end
    end
  end

  return sess
end

--- Build the Set-Cookie header value for a session.
--- @param secure boolean|nil If true, add Secure (use when the site is served over HTTPS).
function M.session_cookie(token, secure)
  local suf = secure and "; Secure" or ""
  -- Path=/ so the session is sent on /v1/... (e.g. table spectate on the main UI).
  return SESSION_COOKIE
    .. "="
    .. token
    .. "; Path=/; HttpOnly; SameSite=Lax; Max-Age="
    .. SESSION_TTL
    .. suf
end

--- Build the Set-Cookie header to clear the session.
function M.clear_cookie()
  return SESSION_COOKIE .. "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
end

--- Build the Google OAuth2 authorization URL.
function M.build_google_auth_url(client_id, redirect_uri)
  local http_server = require("poker.http_server")
  local encode = http_server.url_encode
  return "https://accounts.google.com/o/oauth2/v2/auth"
    .. "?client_id=" .. encode(client_id)
    .. "&redirect_uri=" .. encode(redirect_uri)
    .. "&response_type=code"
    .. "&scope=" .. encode("openid email")
    .. "&access_type=online"
    .. "&prompt=consent"
end

--- Base64url decode (JWT uses URL-safe base64 without padding).
local function b64url_decode(input)
  input = input:gsub("-", "+"):gsub("_", "/")
  local pad = 4 - (#input % 4)
  if pad < 4 then
    input = input .. string.rep("=", pad)
  end
  -- Use mime module from LuaSocket if available, else manual decode
  local ok, mime = pcall(require, "mime")
  if ok and mime.unb64 then
    return mime.unb64(input)
  end
  -- Manual base64 decode fallback
  local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  input = input:gsub("[^" .. b .. "=]", "")
  return (input:gsub(".", function(x)
    if x == "=" then return "" end
    local pos = b:find(x, 1, true)
    if not pos then return "" end
    local r, f = "", pos - 1
    for i = 6, 1, -1 do
      r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return r
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then return "" end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
    end
    return string.char(c)
  end))
end

--- Extract the email from a JWT ID token (decode payload, no signature check).
function M.decode_id_token(id_token)
  if type(id_token) ~= "string" or id_token == "" then
    return nil, "id_token must be a non-empty string"
  end
  local parts = {}
  for part in id_token:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  if #parts < 2 then return nil, "invalid JWT structure" end
  local payload_json = b64url_decode(parts[2])
  if not payload_json then return nil, "base64 decode failed" end
  local json = require("poker.json")
  local ok_j, payload = pcall(json.decode, payload_json)
  if not ok_j then return nil, "JSON decode failed" end
  return payload
end

--- Pick HTTP(S) client: LuaSec's ssl.https is required for reliable HTTPS on many servers.
local function http_request_impl()
  local http_ok, http = pcall(require, "socket.http")
  if not http_ok then return nil, "socket.http not available" end
  local sec_ok, https = pcall(require, "ssl.https")
  if sec_ok and https and https.request then
    return https
  end
  io.stderr:write(
    "[admin] ssl.https (LuaSec) not available — Google token HTTPS may fail. "
      .. "Install lua-sec / lua5.4-sec (e.g. apt install lua5.4-sec).\n"
  )
  return http
end

--- Exchange an authorization code for tokens via Google's token endpoint.
--- Returns { id_token, access_token, email } or nil, err.
function M.exchange_code(code, client_id, client_secret, redirect_uri)
  local http_mod, herr = http_request_impl()
  if not http_mod then return nil, herr end
  local ltn12_ok, ltn12 = pcall(require, "ltn12")
  if not ltn12_ok then return nil, "ltn12 not available" end
  local http_server = require("poker.http_server")
  local encode = http_server.url_encode

  local post_body = "code=" .. encode(code)
    .. "&client_id=" .. encode(client_id)
    .. "&client_secret=" .. encode(client_secret)
    .. "&redirect_uri=" .. encode(redirect_uri)
    .. "&grant_type=authorization_code"

  local response_body = {}
  local req_tbl = {
    url = "https://oauth2.googleapis.com/token",
    method = "POST",
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      ["Content-Length"] = tostring(#post_body),
    },
    source = ltn12.source.string(post_body),
    sink = ltn12.sink.table(response_body),
  }

  local ok_rq, res, status_code = pcall(function()
    return http_mod.request(req_tbl)
  end)
  if not ok_rq then
    return nil, "HTTPS request error (install lua-sec / lua5.x-sec for Google OAuth): " .. tostring(res)
  end

  if not res then
    return nil, "HTTP request failed: " .. tostring(status_code)
  end

  local body_str = table.concat(response_body)

  if status_code ~= 200 then
    return nil, "Token exchange failed (HTTP " .. tostring(status_code) .. "): " .. body_str
  end

  local json = require("poker.json")
  local ok_j, token_data = pcall(json.decode, body_str)
  if not ok_j then return nil, "Failed to parse token response" end

  local id_token = token_data.id_token
  if type(id_token) ~= "string" or id_token == "" then
    return nil, "No id_token in response"
  end

  local payload, perr = M.decode_id_token(id_token)
  if not payload then return nil, "Failed to decode id_token: " .. tostring(perr) end

  return {
    id_token = id_token,
    access_token = token_data.access_token,
    email = payload.email,
    email_verified = payload.email_verified,
    name = payload.name,
    picture = payload.picture,
  }
end

M.SESSION_COOKIE = SESSION_COOKIE

return M
