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

local function demo_context()
  local new_table = poker.new_table
  local game = poker.game
  local tbl = new_table({ id = "demo", max_seats = 10 })
  tbl:seat_player({ seat = 1, player_id = "alice", chips = 1000 })
  tbl:seat_player({ seat = 3, player_id = "bob", chips = 950 })
  local hand = game.HandState.new({})
  hand.status = "idle"
  return { tbl = tbl, hand = hand }
end

local function run_cli()
  local ctx = demo_context()
  local snap = api.table_state_snapshot(ctx.tbl, ctx.hand)
  print(json.encode(snap))
end

local function run_http()
  local http_mod = poker.http_server()
  local ctx = demo_context()
  local srv, err = http_mod.new({
    host = os.getenv("POKER_HOST") or "*",
    port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080,
    get_context = function()
      return ctx
    end,
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
    return api.table_state_snapshot(c.tbl, c.hand)
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
