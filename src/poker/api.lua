-- HTTP-facing snapshots and command stubs.

local M = {}

function M.health()
  return {
    ok = true,
    service = "poker-server",
    version = "0.1.0-skeleton",
  }
end

function M.table_state_snapshot(tbl, hand, action_queue)
  local seats_out = {}
  for i = 1, tbl.max_seats do
    local s = tbl:get_seat(i)
    if s then
      seats_out[i] = { player_id = s.player_id, stack = s.stack }
    else
      seats_out[i] = false
    end
  end

  local q = {}
  if type(action_queue) == "table" then
    for pid, ent in pairs(action_queue) do
      if type(ent) == "table" and ent.action then
        q[pid] = { action = ent.action, amount = ent.amount }
      end
    end
  end

  return {
    table_id = tbl.id,
    max_seats = tbl.max_seats,
    seats = seats_out,
    hand = hand and hand:snapshot_public() or nil,
    action_queue = q,
  }
end

--- @param code string Machine-readable error code (e.g. "not_found", "bad_request").
--- @param message string Human-readable message.
--- @param details table|nil Optional structured context (paths, fields, etc.).
function M.error_body(code, message, details)
  local err = { code = code, message = message }
  if details ~= nil then
    err.details = details
  end
  return { error = err }
end

return M
