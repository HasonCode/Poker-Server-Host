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

local function demo_context()
  local new_table = poker.new_table
  local game = poker.game
  local tbl = new_table({ id = "demo", max_seats = 10 })
  tbl:seat_player({ seat = 1, player_id = "alice", chips = 1000 })
  local ai_players = {}
  for i = 1, 5 do
    local id = "ai_" .. i
    tbl:seat_player({ seat = i + 1, player_id = id, chips = 1000 })
    ai_players[id] = true
  end
  local hand = game.HandState.new({})
  hand.status = "idle"
  return {
    tbl = tbl,
    hand = hand,
    ai_players = ai_players,
    action_queue = {},
    _prev_hand_status = nil,
  }
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

local function table_snapshot(ctx)
  local h = ctx.hand
  if ctx._prev_hand_status == "active" and h.status == "idle" then
    ctx.action_queue = {}
  end
  ctx._prev_hand_status = h.status
  ai.run_until_human(ctx)
  return api.table_state_snapshot(ctx.tbl, ctx.hand, ctx.action_queue)
end

local function run_cli()
  local ctx = demo_context()
  local snap = table_snapshot(ctx)
  print(json.encode(snap))
end

local function run_http()
  local http_mod = poker.http_server()
  local ctx = demo_context()
  local root = script_dir()
  local srv, err = http_mod.new({
    host = os.getenv("POKER_HOST") or "*",
    port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080,
    get_context = function()
      return ctx
    end,
    static_root = root .. "/frontend",
  })
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

  srv:route("GET", "/v1/tables/:id/state", function(_, params, c)
    if params.table_id ~= c.tbl.id then
      return { "404 Not Found", api.error_body("not_found", "unknown table") }
    end
    return table_snapshot(c)
  end)

  srv:route("POST", "/v1/tables/:id/join", function(req, params, c)
    if params.table_id ~= c.tbl.id then
      return { "404 Not Found", api.error_body("not_found", "unknown table") }
    end
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
    local ok, err = c.tbl:seat_player({
      seat = seat,
      player_id = tostring(player_id),
      chips = chips,
    })
    if not ok then
      return join_http_error(err)
    end
    return {
      ok = true,
      table = table_snapshot(c),
    }
  end)

  srv:route("POST", "/v1/tables/:id/actions", function(req, params, c)
    if params.table_id ~= c.tbl.id then
      return { "404 Not Found", api.error_body("not_found", "unknown table") }
    end
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
    local result, err = submit_action(c, tostring(player_id), tostring(action), amount, q)
    if not result then
      return action_http_error(err)
    end
    return {
      ok = true,
      queued = (result == "queued"),
      table = table_snapshot(c),
    }
  end)

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
