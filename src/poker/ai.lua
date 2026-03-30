-- Demo bots: when it is their turn, raise by the minimum legal amount when possible.

local M = {}

local function choose(tbl, hand, seat)
  local st = tbl:get_seat(seat)
  if not st or hand.folded[seat] then
    return nil
  end
  local c = hand.contribution[seat] or 0
  local cb = hand.current_bet
  local mri = hand.min_raise_increment
  local need = cb - c
  if need < 0 then
    need = 0
  end
  local target = cb + mri

  if need > st.stack then
    return "all_in", nil
  end

  if c + st.stack >= target then
    return "raise", target
  end

  if need > 0 and need <= st.stack then
    return "call", nil
  end

  if c >= cb then
    if st.stack > 0 then
      return "all_in", nil
    end
    return "check", nil
  end

  return "fold", nil
end

--- @param ctx { tbl: table, hand: table, ai_players: { [string]: boolean }, action_queue?: table }
function M.run_until_human(ctx)
  local tbl = ctx.tbl
  local hand = ctx.hand
  local ai_players = ctx.ai_players or {}
  local queue = ctx.action_queue
  local max_steps = 500

  for _ = 1, max_steps do
    if hand.status ~= "active" or not hand.action_to_seat then
      return
    end
    local seat = hand.action_to_seat
    local row = tbl:get_seat(seat)
    if not row then
      return
    end
    local pid = row.player_id

    local function run_ai()
      local a, amt = choose(tbl, hand, seat)
      if not a then
        return nil
      end
      local ok, err = hand:apply_action(tbl, pid, a, amt)
      if not ok then
        io.stderr:write("[poker-server] AI " .. tostring(pid) .. " failed: " .. tostring(err) .. "\n")
        return false
      end
      return true
    end

    if type(queue) == "table" then
      local qent = queue[pid]
      if type(qent) == "table" and qent.action then
        queue[pid] = nil
        local ok, err = hand:apply_action(tbl, pid, qent.action, qent.amount)
        if not ok then
          io.stderr:write(
            "[poker-server] Queued action discarded for "
              .. tostring(pid)
              .. ": "
              .. tostring(err)
              .. "\n"
          )
        end
      elseif not ai_players[pid] then
        return
      else
        local r = run_ai()
        if r == nil or r == false then
          return
        end
      end
    elseif not ai_players[pid] then
      return
    else
      local r = run_ai()
      if r == nil or r == false then
        return
      end
    end
  end
end

return M
