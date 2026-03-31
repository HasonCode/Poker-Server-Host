--- Bot runner: joins a table and loops, calling a strategy function each turn.
---
--- Usage:
---   local bot_runner = require("poker.bot_runner")
---   bot_runner.run({
---     strategy = function(state, me) return { action = "call" } end,
---     url  = "http://127.0.0.1:8080",
---     table_id  = "demo",
---     player_id = "LuaBot",
---     chips     = 500,
---   })

local Client = require("poker.client")

local M = {}

local function build_me(state, player_id)
  local seats = state.seats or {}
  local hand = state.hand or {}
  local hc_map = hand.hole_cards or {}
  local contrib_map = hand.contribution or {}
  local seat, stack = nil, 0

  for i, s in ipairs(seats) do
    if type(s) == "table" and s.player_id == player_id then
      seat = i
      stack = s.stack or 0
      break
    end
  end

  local hole_cards = {}
  if seat and type(hc_map) == "table" then
    hole_cards = hc_map[tostring(seat)] or {}
  end

  local contribution = 0
  if seat and type(contrib_map) == "table" then
    contribution = contrib_map[tostring(seat)] or 0
  end

  return {
    player_id = player_id,
    seat = seat,
    stack = stack,
    hole_cards = hole_cards,
    contribution = contribution,
  }
end

local function default_strategy(state, me)
  local hand = state.hand or {}
  local cb = hand.current_bet or 0
  local mri = hand.min_raise_increment or 5
  local stack = me.stack or 0
  local contrib = me.contribution or 0

  local target = cb + mri
  local need = target - contrib
  if need > 0 and need <= stack then
    return { action = "raise", amount = target }
  end

  local call_need = cb - contrib
  if call_need > 0 and call_need <= stack then
    return { action = "call" }
  end

  if contrib >= cb then
    return { action = "check" }
  end

  return { action = "fold" }
end

--- @param opts { strategy?: function, url?: string, table_id?: string, player_id?: string, chips?: number, max_hands?: number, verbose?: boolean }
function M.run(opts)
  opts = opts or {}
  local strategy = opts.strategy or default_strategy
  local url = opts.url or "http://127.0.0.1:8080"
  local table_id = opts.table_id or "demo"
  local player_id = opts.player_id or "LuaBot"
  local chips = opts.chips or 500
  local max_hands = opts.max_hands
  local verbose = opts.verbose ~= false

  local client, cerr = Client.new({ base_url = url })
  if not client then
    io.stderr:write("[bot] Client error: " .. tostring(cerr) .. "\n")
    return
  end

  if verbose then
    io.write("[bot] Connecting to " .. url .. ", table=" .. table_id .. ", name=" .. player_id .. "\n")
  end

  local resp, jerr = client:join_table(table_id, { player_id = player_id, chips = chips })
  if not resp then
    io.stderr:write("[bot] Join failed: " .. tostring(jerr and jerr.message or jerr) .. "\n")
    return
  end

  local state = resp.table or {}
  local me = build_me(state, player_id)
  if verbose then
    io.write("[bot] Seated at seat " .. tostring(me.seat) .. " with " .. chips .. " chips\n")
  end

  local hands_played = 0
  while max_hands == nil or hands_played < max_hands do
    if verbose then
      io.write("[bot] Waiting for turn…\n")
    end

    state = client:wait_for_turn(table_id, player_id, { timeout = 300 })
    if not state then
      if verbose then
        io.write("[bot] Timed out waiting. Retrying…\n")
      end
    else
      me = build_me(state, player_id)
      local hand = state.hand or {}

      if verbose then
        local cards = table.concat(me.hole_cards or {}, " ")
        if cards == "" then cards = "??" end
        local comm_list = hand.community or {}
        local comm = table.concat(comm_list, " ")
        io.write("[bot] Hand: [" .. cards .. "]  Community: [" .. comm .. "]  "
          .. "Pot: " .. tostring(hand.pot or 0) .. "  Bet: " .. tostring(hand.current_bet or 0)
          .. "  Stack: " .. tostring(me.stack) .. "\n")
      end

      local ok_strat, decision = pcall(strategy, state, me)
      if not ok_strat then
        io.stderr:write("[bot] Strategy error: " .. tostring(decision) .. "\n")
        decision = { action = "fold" }
      end

      local action = decision.action or "fold"
      local amount = decision.amount

      local aresp, aerr = client:send_action(table_id, {
        player_id = player_id,
        action = action,
        amount = amount,
      })

      if verbose then
        if aresp then
          local amt_str = amount and (" " .. tostring(amount)) or ""
          io.write("[bot] -> " .. action .. amt_str .. "\n")
        else
          io.write("[bot] Action rejected: " .. tostring(aerr and aerr.message or aerr) .. "\n")
        end
      end

      local new_hand = aresp and aresp.table and aresp.table.hand or {}
      if new_hand.status == "idle" then
        hands_played = hands_played + 1
        if verbose then
          io.write("[bot] Hand finished (total: " .. hands_played .. ")\n")
        end
      end
    end
  end

  if verbose then
    io.write("[bot] Leaving table…\n")
  end
  pcall(function() client:leave_table(table_id, player_id) end)
end

return M
