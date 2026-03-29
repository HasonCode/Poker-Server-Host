-- HTTP-facing snapshots and command stubs.

local M = {}

function M.health()
  return {
    ok = true,
    service = "poker-server",
    version = "0.1.0-skeleton",
  }
end

function M.table_state_snapshot(tbl, hand)
  local seats_out = {}
  for i = 1, tbl.max_seats do
    local s = tbl:get_seat(i)
    if s then
      seats_out[i] = { player_id = s.player_id, stack = s.stack }
    else
      seats_out[i] = false
    end
  end

  return {
    table_id = tbl.id,
    max_seats = tbl.max_seats,
    seats = seats_out,
    hand = hand and hand:snapshot_public() or nil,
  }
end

function M.error_body(code, message)
  return { error = { code = code, message = message } }
end

return M
