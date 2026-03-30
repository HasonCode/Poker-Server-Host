-- Authoritative table: seats, stacks, join/leave. Max 10 seats.

local TableState = {}
TableState.__index = TableState

function TableState.new(opts)
  opts = opts or {}
  local self = setmetatable({
    id = opts.id or tostring(os.time()),
    max_seats = opts.max_seats or 10,
    seats = {}, -- [1..max_seats] = { player_id = string, stack = chips }
  }, TableState)
  return self
end

function TableState:capacity()
  return self.max_seats
end

function TableState:occupied_count()
  local n = 0
  for k in pairs(self.seats) do
    if self.seats[k] then
      n = n + 1
    end
  end
  return n
end

--- Lowest free seat index, or nil if full.
function TableState:first_available_seat()
  for i = 1, self.max_seats do
    if not self.seats[i] then
      return i
    end
  end
  return nil
end

--- @param args { seat: number, player_id: string, chips: number }
function TableState:seat_player(args)
  local seat = args.seat
  local player_id = args.player_id
  local chips = args.chips or 0
  if seat < 1 or seat > self.max_seats then
    return nil, "invalid_seat"
  end
  if self.seats[seat] then
    return nil, "seat_taken"
  end
  if self:occupied_count() >= self.max_seats then
    return nil, "table_full"
  end
  if not player_id or player_id == "" then
    return nil, "invalid_player"
  end
  chips = math.floor(chips)
  if chips < 0 then
    return nil, "invalid_chips"
  end
  self.seats[seat] = {
    player_id = player_id,
    stack = chips,
  }
  return true
end

function TableState:leave_seat(seat)
  if seat < 1 or seat > self.max_seats then
    return nil, "invalid_seat"
  end
  if not self.seats[seat] then
    return nil, "empty_seat"
  end
  self.seats[seat] = nil
  return true
end

function TableState:get_seat(seat)
  return self.seats[seat]
end

--- @return number|nil seat index if seated
function TableState:seat_for_player(player_id)
  if not player_id or player_id == "" then
    return nil
  end
  for i = 1, self.max_seats do
    local s = self.seats[i]
    if s and s.player_id == player_id then
      return i
    end
  end
  return nil
end

return function(opts)
  return TableState.new(opts)
end
