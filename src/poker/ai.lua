-- Demo bots: raise to a fixed target (10 chips) once per street, then call.

local M = {}

local AI_BET_TARGET = 10

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

  if need > st.stack then
    return "all_in", nil
  end

  if cb < AI_BET_TARGET then
    local target = math.max(cb + mri, AI_BET_TARGET)
    local chips_in = target - c
    if chips_in > 0 and chips_in <= st.stack then
      return "raise", target
    end
  end

  if need > 0 and need <= st.stack then
    return "call", nil
  end

  if c >= cb then
    return "check", nil
  end

  return "fold", nil
end

--- Record a dropped queued action so the player can see what happened on
--- their next snapshot. Bounded to one entry per player; consumers of the
--- snapshot are expected to clear it after observing.
local function record_drop(ctx, pid, qent, reason)
  if not ctx then
    return
  end
  ctx.action_queue_drops = ctx.action_queue_drops or {}
  ctx.action_queue_drops[pid] = {
    action = qent and qent.action,
    amount = qent and qent.amount,
    street = qent and qent.street,
    reason = reason,
    at = os.time(),
  }
end

--- @param ctx { tbl: table, hand: table, ai_players: { [string]: boolean }, action_queue?: table, action_queue_drops?: table }
function M.run_until_human(ctx)
  local tbl = ctx.tbl
  local hand = ctx.hand
  local ai_players = ctx.ai_players or {}
  local queue = ctx.action_queue
  local max_steps = 500

  if hand.status == "idle" then
    local first, perr = hand:peek_first_actor(tbl)
    if not first then
      return
    end
    local ok, serr = hand:start_hand(tbl)
    if not ok then
      io.stderr:write("[poker-server] auto-start failed: " .. tostring(serr) .. "\n")
      return
    end
  end

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
        if qent.while_idle and hand.status ~= "active" then
          return
        end
        local stale = not qent.while_idle
          and hand.status == "active"
          and qent.street
          and qent.street ~= hand.street
        if stale then
          queue[pid] = nil
          record_drop(ctx, pid, qent, "stale_street")
          io.stderr:write(
            "[poker-server] Queued action dropped (betting round changed) for "
              .. tostring(pid)
              .. "\n"
          )
        else
          queue[pid] = nil
          local ok, err = hand:apply_action(tbl, pid, qent.action, qent.amount)
          if not ok then
            record_drop(ctx, pid, qent, tostring(err))
            io.stderr:write(
              "[poker-server] Queued action discarded for "
                .. tostring(pid)
                .. ": "
                .. tostring(err)
                .. "\n"
            )
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
