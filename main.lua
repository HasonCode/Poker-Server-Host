#!/usr/bin/env lua
-- Poker server entry: optional HTTP (LuaSocket) or --cli snapshot.

local function script_dir()
  local p = arg[0] or "."
  local d = p:match("^(.*)/[^/]+$") or "."
  return d
end

package.path = script_dir() .. "/src/?.lua;" .. script_dir() .. "/src/?/init.lua;" .. package.path

local poker = require("poker")
local api = poker.api
local json = poker.json
local ai = require("poker.ai")
local admin_auth = require("poker.admin_auth")

local function join_http_error(err)
  local t = {
    invalid_seat = { "400 Bad Request", "invalid_seat", "Seat must be between 1 and max_seats." },
    seat_taken = { "409 Conflict", "seat_taken", "That seat is already occupied." },
    table_full = { "409 Conflict", "table_full", "No empty seats available." },
    invalid_player = { "400 Bad Request", "invalid_player", "player_id is required and non-empty." },
    invalid_chips = { "400 Bad Request", "invalid_chips", "chips must be a non-negative integer." },
  }
  local row = t[err]
  if not row then
    return { "500 Internal Server Error", api.error_body("internal", "Seat operation failed.") }
  end
  return { row[1], api.error_body(row[2], row[3], { reason = err }) }
end

local function action_http_error(err)
  local t = {
    invalid_player = { "400 Bad Request", "invalid_player", "player_id is missing or empty." },
    not_seated = { "403 Forbidden", "not_seated", "Player is not seated at this table." },
    wrong_turn = { "400 Bad Request", "wrong_turn", "It is not this player's turn to act." },
    invalid_action = {
      "400 Bad Request",
      "invalid_action",
      "action must be fold, check, call, raise, bet, or all_in.",
    },
    amount_required = { "400 Bad Request", "amount_required", "raise and bet require a positive amount." },
    invalid_amount = { "400 Bad Request", "invalid_amount", "amount must be a positive integer." },
    insufficient_chips = { "400 Bad Request", "insufficient_chips", "Not enough chips for this action." },
    need_two_players = { "400 Bad Request", "need_two_players", "At least two seated players are required to start a hand." },
    hand_complete = { "400 Bad Request", "hand_complete", "Start a new hand before acting (hand is finished)." },
    cannot_check = { "400 Bad Request", "cannot_check", "There is a bet to face; call, fold, or raise." },
    nothing_to_call = { "400 Bad Request", "nothing_to_call", "You are already matched to the current bet." },
    already_folded = { "400 Bad Request", "already_folded", "This player has already folded." },
    raise_not_increase = { "400 Bad Request", "raise_not_increase", "Raise must increase your total contribution this street." },
    min_raise = { "400 Bad Request", "min_raise", "Raise does not meet the minimum raise size." },
    cannot_raise_self = { "400 Bad Request", "cannot_raise_self", "You cannot raise again until another player has raised." },
  }
  local row = t[err]
  if not row then
    return { "500 Internal Server Error", api.error_body("internal", "Action failed.") }
  end
  return { row[1], api.error_body(row[2], row[3], { reason = err }) }
end

local function create_table_context(id, max_seats, opts)
  opts = opts or {}
  local new_table = poker.new_table
  local game = poker.game
  local tbl = new_table({ id = id, max_seats = max_seats or 10 })
  local ai_players = {}
  if opts.with_ais then
    for i = 1, math.min(6, max_seats or 10) do
      local pid = "ai_" .. i
      tbl:seat_player({ seat = i, player_id = pid, chips = opts.ai_chips or 1000 })
      ai_players[pid] = true
    end
  end
  local hand = game.HandState.new({
    sb_amount = opts.sb_amount or 2,
    bb_amount = opts.bb_amount or 5,
  })
  hand.status = "idle"
  return {
    tbl = tbl,
    hand = hand,
    ai_players = ai_players,
    action_queue = {},
    _prev_hand_status = nil,
    running_bots = {},
    player_tokens = {},
    token_to_player = {},
    zero_chips = opts.zero_chips or "rebuy",
    rebuy_amount = opts.rebuy_amount or 500,
  }
end

math.randomseed(os.time() + math.floor(os.clock() * 10000))

local function generate_player_token()
  local chars = {}
  for i = 1, 32 do
    chars[i] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(chars)
end

local function resolve_auth_player(req, ctx)
  local token = req.headers and req.headers["x-player-token"]
  if not token or token == "" then return nil end
  return ctx.token_to_player[token]
end

local function filter_snapshot_for_player(snap, auth_pid, tbl)
  if not snap or not snap.hand then return snap end
  local hc = snap.hand.hole_cards
  if not hc or type(hc) ~= "table" then return snap end
  if not auth_pid then
    snap.hand.hole_cards = {}
    return snap
  end
  local seat = tbl:seat_for_player(auth_pid)
  local filtered = {}
  if seat then
    filtered[tostring(seat)] = hc[tostring(seat)]
  end
  snap.hand.hole_cards = filtered
  return snap
end

local function remove_player_token(ctx, player_id)
  local old = ctx.player_tokens[player_id]
  if old then
    ctx.token_to_player[old] = nil
    ctx.player_tokens[player_id] = nil
  end
end

local function create_server_state()
  return {
    tables = {
      demo = create_table_context("demo", 10, { with_ais = true }),
      players = create_table_context("players", 10, {}),
    },
  }
end

local function detect_lang(filename, content)
  if filename and filename:match("%.lua$") then return "lua" end
  if filename and filename:match("%.py$")  then return "python" end
  if content and content:match("^#!.-python") then return "python" end
  if content and content:match("^%-%-") then return "lua" end
  if content and content:match("def%s+decide%s*%(") then return "python" end
  if content and content:match("function%s+decide%s*%(") then return "lua" end
  return "python"
end

local function spawn_bot(root, lang, bot_file, player_id, table_id, port)
  local cmd
  local url = "http://127.0.0.1:" .. tostring(port)
  if lang == "lua" then
    cmd = string.format(
      "lua -e 'package.path=\"%s/src/?.lua;%s/src/?/init.lua;\"..package.path' %q --name %q --url %q 2>&1 &\necho $!",
      root, root, bot_file, player_id, url
    )
  else
    cmd = string.format(
      "python3 %q %q --name %q --table %q --url %q 2>&1 &\necho $!",
      root .. "/clients/python/bot_runner.py",
      bot_file, player_id, table_id, url
    )
  end
  local h = io.popen(cmd, "r")
  if not h then return nil end
  local output = h:read("*a")
  h:close()
  local pid = output:match("(%d+)%s*$")
  return pid and tonumber(pid) or nil
end

local function kill_bot(pid)
  os.execute("kill " .. tostring(pid) .. " 2>/dev/null")
end

local function validate_action_shape(action, amount)
  action = string.lower(tostring(action or ""))
  if
    action ~= "fold"
    and action ~= "check"
    and action ~= "call"
    and action ~= "raise"
    and action ~= "bet"
    and action ~= "all_in"
  then
    return nil, "invalid_action"
  end
  if action == "raise" or action == "bet" then
    if amount == nil then
      return nil, "amount_required"
    end
    local a = math.floor(tonumber(amount) or 0)
    if a < 1 then
      return nil, "invalid_amount"
    end
    return { action = action, amount = a }, nil
  end
  return { action = action, amount = nil }, nil
end

--- @return "applied"|"queued"|nil, err
local function submit_action(ctx, player_id, action, amount, queue)
  local tbl = ctx.tbl
  local hand = ctx.hand
  local q = queue == true
  local qfalse = queue == false

  local ent, verr = validate_action_shape(action, amount)
  if not ent then
    return nil, verr
  end
  local act, amt = ent.action, ent.amount

  local seat = tbl:seat_for_player(player_id)
  if not seat then
    return nil, "not_seated"
  end

  if hand.status == "active" and hand.folded[seat] then
    return nil, "already_folded"
  end

  if q and hand.status == "idle" then
    ctx.action_queue[player_id] = { action = act, amount = amt }
    return "queued"
  end

  if q and hand.status == "active" then
    if hand.action_to_seat == seat then
      local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
      if not ok then
        return nil, err2
      end
      return "applied"
    end
    ctx.action_queue[player_id] = { action = act, amount = amt }
    return "queued"
  end

  if hand.status == "idle" then
    local first, perr = hand:peek_first_actor(tbl)
    if not first then
      return nil, perr
    end
    if first == seat then
      local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
      if not ok then
        return nil, err2
      end
      return "applied"
    end
    ctx.action_queue[player_id] = { action = act, amount = amt }
    return "queued"
  end

  if hand.action_to_seat == seat then
    local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
    if not ok then
      return nil, err2
    end
    return "applied"
  end

  if qfalse then
    return nil, "wrong_turn"
  end
  ctx.action_queue[player_id] = { action = act, amount = amt }
  return "queued"
end

local function handle_zero_chips(ctx)
  for i = 1, ctx.tbl.max_seats do
    local s = ctx.tbl:get_seat(i)
    if s and s.stack <= 0 then
      local pid = s.player_id
      if ctx.zero_chips == "eject" then
        ctx.tbl:leave_seat(i)
        if ctx.action_queue then ctx.action_queue[pid] = nil end
        remove_player_token(ctx, pid)
        if ctx.ai_players then ctx.ai_players[pid] = nil end
        if ctx.running_bots and ctx.running_bots[pid] then
          kill_bot(ctx.running_bots[pid].pid)
          ctx.running_bots[pid] = nil
        end
        io.stderr:write("[table:" .. ctx.tbl.id .. "] Ejected " .. pid .. " (zero chips)\n")
      else
        s.stack = ctx.rebuy_amount or 500
        io.stderr:write("[table:" .. ctx.tbl.id .. "] Rebuy " .. pid .. " -> " .. tostring(s.stack) .. " chips\n")
      end
    end
  end
end

local function table_snapshot(ctx)
  local h = ctx.hand
  if ctx._prev_hand_status == "active" and h.status == "idle" then
    ctx.action_queue = {}
    handle_zero_chips(ctx)
  end
  ctx._prev_hand_status = h.status
  ai.run_until_human(ctx)
  local snap = api.table_state_snapshot(ctx.tbl, ctx.hand, ctx.action_queue)
  snap.zero_chips = ctx.zero_chips
  snap.rebuy_amount = ctx.rebuy_amount
  return snap
end

local function run_cli()
  local state = create_server_state()
  local ctx = state.tables.demo
  local snap = table_snapshot(ctx)
  print(json.encode(snap))
end

local function run_http()
  local http_mod = poker.http_server()
  local state = create_server_state()
  local root = script_dir()
  local srv, err = http_mod.new({
    host = os.getenv("POKER_HOST") or "*",
    port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080,
    get_context = function()
      return state
    end,
    static_root = root .. "/frontend",
  })

  local function resolve_table(params, s)
    s = s or state
    local tid = params.table_id
    if not tid then return nil end
    return s.tables[tid]
  end
  if not srv then
    io.stderr:write(err .. "\n")
    io.stderr:write("Tip: luarocks install luasocket  (or your distro's lua-socket package)\n")
    io.stderr:write("Running CLI snapshot instead:\n")
    run_cli()
    return
  end

  srv:route("GET", "/health", function()
    return api.health()
  end)

  local not_found_table = { "404 Not Found", api.error_body("not_found", "unknown table") }

  srv:route("GET", "/v1/tables", function(_, _, s)
    local list = {}
    for tid, ctx in pairs(s.tables) do
      list[#list + 1] = {
        table_id = tid,
        max_seats = ctx.tbl.max_seats,
        seated = ctx.tbl:occupied_count(),
        hand_status = ctx.hand.status,
      }
    end
    return { ok = true, tables = list }
  end)

  srv:route("GET", "/v1/tables/:id/state", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    local auth_pid = resolve_auth_player(req, c)
    return filter_snapshot_for_player(table_snapshot(c), auth_pid, c.tbl)
  end)

  srv:route("POST", "/v1/tables/:id/join", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body(
          "bad_request",
          "JSON body required with player_id and chips; seat is optional (first free seat if omitted).",
          { fields = { "player_id", "chips", "seat" } }
        ),
      }
    end
    local j = req.json
    local player_id = j.player_id
    local chips = j.chips ~= nil and tonumber(j.chips) or nil
    if not player_id or chips == nil then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "player_id and chips are required."),
      }
    end
    local seat
    local seat_raw = j.seat
    if seat_raw == nil or seat_raw == "" then
      seat = c.tbl:first_available_seat()
      if not seat then
        return join_http_error("table_full")
      end
    else
      seat = tonumber(seat_raw)
      if not seat or seat ~= math.floor(seat) then
        return {
          "400 Bad Request",
          api.error_body(
            "bad_request",
            "seat must be an integer between 1 and max_seats, or omitted for the first available seat."
          ),
        }
      end
      seat = math.floor(seat)
    end
    player_id = tostring(player_id)
    local ok, err = c.tbl:seat_player({
      seat = seat,
      player_id = player_id,
      chips = chips,
    })
    if not ok then
      return join_http_error(err)
    end
    remove_player_token(c, player_id)
    local token = generate_player_token()
    c.player_tokens[player_id] = token
    c.token_to_player[token] = player_id
    return {
      ok = true,
      token = token,
      table = filter_snapshot_for_player(table_snapshot(c), player_id, c.tbl),
    }
  end)

  srv:route("POST", "/v1/tables/:id/leave", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id."),
      }
    end
    local player_id = req.json.player_id
    if not player_id or player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required and non-empty."),
      }
    end
    player_id = tostring(player_id)
    local seat = c.tbl:seat_for_player(player_id)
    if not seat then
      return {
        "404 Not Found",
        api.error_body("not_seated", "Player is not seated at this table."),
      }
    end
    if c.hand.status == "active" and c.hand.folded and not c.hand.folded[seat] then
      c.hand.folded[seat] = true
      c.hand.pending[seat] = nil
      if c.hand.action_to_seat == seat then
        c.hand:_after_action(c.tbl, seat)
      end
    end
    c.tbl:leave_seat(seat)
    if c.action_queue then
      c.action_queue[player_id] = nil
    end
    remove_player_token(c, player_id)
    return {
      ok = true,
      table = filter_snapshot_for_player(table_snapshot(c), nil, c.tbl),
    }
  end)

  srv:route("POST", "/v1/tables/:id/actions", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body(
          "bad_request",
          "JSON body required with player_id and action.",
          { fields = { "player_id", "action", "amount" } }
        ),
      }
    end
    local j = req.json
    local player_id = j.player_id
    local action = j.action
    if not player_id or not action then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "player_id and action are required."),
      }
    end
    local amount = j.amount
    if amount ~= nil then
      amount = tonumber(amount)
    end
    local q = j.queue
    if q ~= nil and type(q) ~= "boolean" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "queue must be a boolean if provided."),
      }
    end
    local pid_str = tostring(player_id)
    local auth_pid = resolve_auth_player(req, c)
    if auth_pid and auth_pid ~= pid_str then
      return { "403 Forbidden", api.error_body("forbidden", "Token does not match player_id.") }
    end

    local result, err = submit_action(c, pid_str, tostring(action), amount, q)
    if not result then
      return action_http_error(err)
    end
    return {
      ok = true,
      queued = (result == "queued"),
      table = filter_snapshot_for_player(table_snapshot(c), auth_pid or pid_str, c.tbl),
    }
  end)

  srv:route("POST", "/v1/tables/:id/bot/start", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id, chips, and code (file contents)."),
      }
    end
    local j = req.json
    local player_id = j.player_id
    local chips = tonumber(j.chips or 500) or 500
    local code = j.code
    local filename = j.filename or "bot.py"
    if not player_id or player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required."),
      }
    end
    if not code or code == "" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "code (bot file contents) is required."),
      }
    end
    player_id = tostring(player_id)

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end

    local lang = detect_lang(filename, code)

    local tmpdir = root .. "/tmp_bots"
    os.execute("mkdir -p " .. tmpdir)
    local safe_name = player_id:gsub("[^%w_%-]", "_")
    local ext = lang == "lua" and ".lua" or ".py"
    local bot_path = tmpdir .. "/" .. safe_name .. ext
    local f = io.open(bot_path, "w")
    if not f then
      return {
        "500 Internal Server Error",
        api.error_body("internal", "Failed to save bot file."),
      }
    end
    f:write(code)
    f:close()

    local port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
    local pid = spawn_bot(root, lang, bot_path, player_id, params.table_id, port)
    if not pid then
      return {
        "500 Internal Server Error",
        api.error_body("internal", "Failed to spawn bot process."),
      }
    end

    c.running_bots[player_id] = { pid = pid, file = bot_path, lang = lang }
    return {
      ok = true,
      player_id = player_id,
      lang = lang,
      pid = pid,
    }
  end)

  srv:route("POST", "/v1/tables/:id/bot/stop", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id."),
      }
    end
    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required."),
      }
    end
    local bot = c.running_bots[player_id]
    if not bot then
      return {
        "404 Not Found",
        api.error_body("not_found", "No running bot for this player."),
      }
    end
    kill_bot(bot.pid)
    c.running_bots[player_id] = nil
    return { ok = true, player_id = player_id, stopped = true }
  end)

  srv:route("GET", "/v1/tables/:id/bot/list", function(_, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    local bots = {}
    for pid_name, info in pairs(c.running_bots) do
      bots[#bots + 1] = {
        player_id = pid_name,
        lang = info.lang,
        pid = info.pid,
      }
    end
    return { ok = true, bots = bots }
  end)

  -- ── Admin: Google OAuth2 ──────────────────────────────────────────────

  local GOOGLE_CLIENT_ID     = os.getenv("GOOGLE_CLIENT_ID") or ""
  local GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET") or ""
  local ADMIN_EMAIL          = os.getenv("ADMIN_EMAIL") or ""
  local admin_port           = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
  local ADMIN_REDIRECT_URI   = os.getenv("ADMIN_REDIRECT_URI")
    or ("http://localhost:" .. admin_port .. "/admin/oauth/callback")

  local function require_admin(req)
    if ADMIN_EMAIL == "" then
      return nil, { "503 Service Unavailable",
        api.error_body("not_configured", "Admin auth not configured. Set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, and ADMIN_EMAIL.") }
    end
    local sess = admin_auth.validate_session(req, ADMIN_EMAIL)
    if not sess then
      return nil, { "401 Unauthorized", api.error_body("unauthorized", "Admin login required.") }
    end
    return sess
  end

  srv:route("GET", "/admin/oauth/login", function(req)
    if GOOGLE_CLIENT_ID == "" then
      return {
        __raw = true,
        status = "503 Service Unavailable",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Google OAuth not configured. Set GOOGLE_CLIENT_ID env var.",
      }
    end
    local url = admin_auth.build_google_auth_url(GOOGLE_CLIENT_ID, ADMIN_REDIRECT_URI)
    return {
      __raw = true,
      status = "302 Found",
      headers = { Location = url },
      body = "",
    }
  end)

  srv:route("GET", "/admin/oauth/callback", function(req)
    local code = req.query and req.query.code
    if not code or code == "" then
      return {
        __raw = true,
        status = "400 Bad Request",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Missing 'code' parameter.",
      }
    end

    local result, err2 = admin_auth.exchange_code(code, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ADMIN_REDIRECT_URI)
    if not result then
      io.stderr:write("[admin] OAuth error: " .. tostring(err2) .. "\n")
      return {
        __raw = true,
        status = "500 Internal Server Error",
        headers = { ["Content-Type"] = "text/plain" },
        body = "OAuth token exchange failed: " .. tostring(err2),
      }
    end

    if not result.email then
      return {
        __raw = true,
        status = "403 Forbidden",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Could not retrieve email from Google.",
      }
    end

    if result.email ~= ADMIN_EMAIL then
      io.stderr:write("[admin] Access denied for: " .. result.email .. "\n")
      return {
        __raw = true,
        status = "403 Forbidden",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Access denied. This account (" .. result.email .. ") is not authorized.",
      }
    end

    local token = admin_auth.create_session(result.email)
    io.stderr:write("[admin] Logged in: " .. result.email .. "\n")
    return {
      __raw = true,
      status = "302 Found",
      headers = {
        Location = "/admin",
        ["Set-Cookie"] = admin_auth.session_cookie(token),
      },
      body = "",
    }
  end)

  srv:route("GET", "/admin/oauth/logout", function(req)
    local token = req.cookies and req.cookies[admin_auth.SESSION_COOKIE]
    if token then
      admin_auth.destroy_session(token)
    end
    return {
      __raw = true,
      status = "302 Found",
      headers = {
        Location = "/admin",
        ["Set-Cookie"] = admin_auth.clear_cookie(),
      },
      body = "",
    }
  end)

  srv:route("GET", "/admin/api/session", function(req)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    return { ok = true, email = sess.email }
  end)

  -- ── Admin: API endpoints ───────────────────────────────────────────────

  srv:route("GET", "/admin/api/tables", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local list = {}
    for tid, ctx in pairs(s.tables) do
      local seated = ctx.tbl:occupied_count()
      local total_chips = 0
      for i = 1, ctx.tbl.max_seats do
        local si = ctx.tbl:get_seat(i)
        if si then total_chips = total_chips + si.stack end
      end
      local bot_count = 0
      for _ in pairs(ctx.running_bots or {}) do bot_count = bot_count + 1 end
      list[#list + 1] = {
        table_id = tid,
        max_seats = ctx.tbl.max_seats,
        seated = seated,
        total_chips = total_chips,
        hand_status = ctx.hand.status,
        sb_amount = ctx.hand.sb_amount,
        bb_amount = ctx.hand.bb_amount,
        running_bots = bot_count,
        zero_chips = ctx.zero_chips,
      }
    end
    return { ok = true, tables = list }
  end)

  srv:route("POST", "/admin/api/tables", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required with table_id.") }
    end
    local j = req.json
    local tid = tostring(j.table_id or ""):match("^%s*(.-)%s*$")
    if tid == "" then
      return { "400 Bad Request", api.error_body("bad_request", "table_id is required.") }
    end
    if not tid:match("^[%w_%-]+$") then
      return { "400 Bad Request", api.error_body("bad_request", "table_id must be alphanumeric/underscore/hyphen.") }
    end
    if s.tables[tid] then
      return { "409 Conflict", api.error_body("already_exists", "A table with this ID already exists.") }
    end

    local max_seats = tonumber(j.max_seats) or 10
    max_seats = math.max(2, math.min(10, math.floor(max_seats)))
    local sb = tonumber(j.sb_amount) or 2
    local bb = tonumber(j.bb_amount) or 5
    local with_ais = j.with_ais == true

    local zc = j.zero_chips
    if zc ~= "eject" and zc ~= "rebuy" then zc = "rebuy" end

    s.tables[tid] = create_table_context(tid, max_seats, {
      with_ais = with_ais,
      sb_amount = math.max(1, math.floor(sb)),
      bb_amount = math.max(1, math.floor(bb)),
      ai_chips = tonumber(j.ai_chips) or 1000,
      zero_chips = zc,
      rebuy_amount = tonumber(j.rebuy_amount) or 500,
    })

    io.stderr:write("[admin] Created table: " .. tid .. " (seats=" .. max_seats .. ")\n")
    return { ok = true, table_id = tid }
  end)

  srv:route("POST", "/admin/api/tables/:id/delete", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local tid = params.table_id
    local c = s.tables[tid]
    if not c then return not_found_table end

    for pid_name, info in pairs(c.running_bots or {}) do
      kill_bot(info.pid)
    end
    s.tables[tid] = nil

    io.stderr:write("[admin] Deleted table: " .. tid .. "\n")
    return { ok = true, deleted = tid }
  end)

  srv:route("GET", "/admin/api/stats", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local tid = req.query and req.query.table_id or "demo"
    local c = s.tables[tid]
    if not c then return not_found_table end

    local seated = 0
    local total_chips = 0
    local players = {}
    for i = 1, c.tbl.max_seats do
      local si = c.tbl:get_seat(i)
      if si then
        seated = seated + 1
        total_chips = total_chips + si.stack
        players[#players + 1] = { seat = i, player_id = si.player_id, stack = si.stack }
      end
    end

    local bots = {}
    for pid_name, info in pairs(c.running_bots or {}) do
      bots[#bots + 1] = { player_id = pid_name, lang = info.lang, pid = info.pid }
    end

    return {
      ok = true,
      table_id = c.tbl.id,
      max_seats = c.tbl.max_seats,
      seated = seated,
      total_chips = total_chips,
      players = players,
      hand_status = c.hand.status,
      street = c.hand.street,
      pot = c.hand.pot,
      sb_amount = c.hand.sb_amount,
      bb_amount = c.hand.bb_amount,
      running_bots = bots,
      ai_players = c.ai_players,
      zero_chips = c.zero_chips,
      rebuy_amount = c.rebuy_amount,
    }
  end)

  srv:route("POST", "/admin/api/tables/:id/kick", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body with player_id required.") }
    end
    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id is required.") }
    end

    local seat = c.tbl:seat_for_player(player_id)
    if not seat then
      return { "404 Not Found", api.error_body("not_seated", "Player not found at table.") }
    end

    if c.hand.status == "active" and c.hand.folded and not c.hand.folded[seat] then
      c.hand.folded[seat] = true
      c.hand.pending[seat] = nil
      if c.hand.action_to_seat == seat then
        c.hand:_after_action(c.tbl, seat)
      end
    end
    c.tbl:leave_seat(seat)
    if c.action_queue then c.action_queue[player_id] = nil end

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end
    remove_player_token(c, player_id)

    io.stderr:write("[admin] Kicked player: " .. player_id .. "\n")
    return { ok = true, kicked = player_id, table = table_snapshot(c) }
  end)

  srv:route("POST", "/admin/api/tables/:id/reset", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end

    c.hand:_reset_between_hands()
    c.action_queue = {}

    local default_chips = (req.json and tonumber(req.json.chips)) or 1000
    for i = 1, c.tbl.max_seats do
      local si = c.tbl:get_seat(i)
      if si then
        si.stack = default_chips
      end
    end

    io.stderr:write("[admin] Table reset, stacks set to " .. default_chips .. "\n")
    return { ok = true, table = table_snapshot(c) }
  end)

  srv:route("POST", "/admin/api/tables/:id/settings", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required.") }
    end

    local j = req.json
    if j.sb_amount ~= nil then
      local sb = tonumber(j.sb_amount)
      if sb and sb >= 1 then c.hand.sb_amount = math.floor(sb) end
    end
    if j.bb_amount ~= nil then
      local bb = tonumber(j.bb_amount)
      if bb and bb >= 1 then c.hand.bb_amount = math.floor(bb) end
    end
    if j.zero_chips ~= nil then
      if j.zero_chips == "eject" or j.zero_chips == "rebuy" then
        c.zero_chips = j.zero_chips
      end
    end
    if j.rebuy_amount ~= nil then
      local ra = tonumber(j.rebuy_amount)
      if ra and ra >= 1 then c.rebuy_amount = math.floor(ra) end
    end

    io.stderr:write("[admin] Settings updated: SB=" .. c.hand.sb_amount .. " BB=" .. c.hand.bb_amount
      .. " zero_chips=" .. c.zero_chips .. " rebuy=" .. tostring(c.rebuy_amount) .. "\n")
    return {
      ok = true,
      sb_amount = c.hand.sb_amount,
      bb_amount = c.hand.bb_amount,
      zero_chips = c.zero_chips,
      rebuy_amount = c.rebuy_amount,
    }
  end)

  srv:route("POST", "/admin/api/bot/start", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required with table_id, player_id, chips, code.") }
    end
    local j = req.json
    local tid = tostring(j.table_id or "demo")
    local c = s.tables[tid]
    if not c then return not_found_table end

    local player_id = tostring(j.player_id or "")
    local chips = tonumber(j.chips or 500) or 500
    local code = j.code or ""
    local filename = j.filename or "bot.py"

    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id required.") }
    end
    if code == "" then
      return { "400 Bad Request", api.error_body("bad_request", "code required.") }
    end

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end

    local lang = detect_lang(filename, code)
    local tmpdir = root .. "/tmp_bots"
    os.execute("mkdir -p " .. tmpdir)
    local safe_name = player_id:gsub("[^%w_%-]", "_")
    local ext = lang == "lua" and ".lua" or ".py"
    local bot_path = tmpdir .. "/" .. safe_name .. ext
    local f = io.open(bot_path, "w")
    if not f then
      return { "500 Internal Server Error", api.error_body("internal", "Failed to save bot file.") }
    end
    f:write(code)
    f:close()

    local port2 = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
    local pid = spawn_bot(root, lang, bot_path, player_id, tid, port2)
    if not pid then
      return { "500 Internal Server Error", api.error_body("internal", "Failed to spawn bot.") }
    end

    c.running_bots[player_id] = { pid = pid, file = bot_path, lang = lang }
    return { ok = true, player_id = player_id, lang = lang, pid = pid }
  end)

  srv:route("POST", "/admin/api/bot/stop", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body with player_id, table_id required.") }
    end
    local tid = tostring(req.json.table_id or "demo")
    local c = s.tables[tid]
    if not c then return not_found_table end

    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id required.") }
    end

    local bot = c.running_bots[player_id]
    if not bot then
      return { "404 Not Found", api.error_body("not_found", "No running bot for this player.") }
    end
    kill_bot(bot.pid)
    c.running_bots[player_id] = nil
    io.stderr:write("[admin] Stopped bot: " .. player_id .. "\n")
    return { ok = true, player_id = player_id, stopped = true }
  end)

  if ADMIN_EMAIL ~= "" then
    io.stderr:write(string.format("  Admin: http://127.0.0.1:%s/admin (email: %s)\n", tostring(admin_port), ADMIN_EMAIL))
    io.stderr:write(string.format("  OAuth redirect: %s\n", ADMIN_REDIRECT_URI))
  end

  srv:run_loop()
end

local function main()
  for i = 1, #arg do
    if arg[i] == "--cli" then
      run_cli()
      return
    end
  end
  run_http()
end

main()
