-- Hand state: SB/BB, button, turn order, betting rounds, min-raise, cannot re-raise self.

local HandState = {}
HandState.__index = HandState

local function copy_keys(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
end

function HandState.new(opts)
  opts = opts or {}
  return setmetatable({
    status = "idle",
    street = "none",
    pot = 0,
    community = {},
    action_log = {},
    hand_bets = {},
    seq = 0,
    sb_amount = opts.sb_amount or 2,
    bb_amount = opts.bb_amount or 5,
    button_seat = nil,
    sb_seat = nil,
    bb_seat = nil,
    dealer_ring_index = 0,
    contribution = {},
    current_bet = 0,
    min_raise_increment = 0,
    folded = {},
    action_to_seat = nil,
    pending = {},
    last_raise_seat = nil,
    occupied_ring = {},
  }, HandState)
end

function HandState:snapshot_public()
  local min_inc = self.min_raise_increment
  if self.status == "idle" then
    min_inc = self.bb_amount
  end
  return {
    status = self.status,
    street = self.street,
    pot = self.pot,
    community = self.community,
    action_log = self.action_log,
    hand_bets = self.hand_bets,
    sb_amount = self.sb_amount,
    bb_amount = self.bb_amount,
    button_seat = self.button_seat,
    sb_seat = self.sb_seat,
    bb_seat = self.bb_seat,
    action_to_seat = self.action_to_seat,
    current_bet = self.current_bet,
    min_raise_increment = min_inc,
    contribution = copy_keys(self.contribution),
    folded = copy_keys(self.folded),
  }
end

local function occupied_seats(tbl)
  local list = {}
  for i = 1, tbl.max_seats do
    if tbl:get_seat(i) then
      list[#list + 1] = i
    end
  end
  return list
end

local function index_of(ring, seat)
  for i, r in ipairs(ring) do
    if r == seat then
      return i
    end
  end
  return nil
end

local function next_in_ring(ring, seat)
  local idx = index_of(ring, seat)
  if not idx then
    return nil
  end
  return ring[(idx % #ring) + 1]
end

function HandState:_reset_street_betting()
  self.contribution = {}
  self.current_bet = 0
  self.min_raise_increment = self.bb_amount
  self.last_raise_seat = nil
  self.pending = {}
  for _, s in ipairs(self.occupied_ring) do
    self.contribution[s] = 0
  end
end

function HandState:_first_postflop_actor()
  local s = next_in_ring(self.occupied_ring, self.button_seat)
  while s do
    if not self.folded[s] then
      return s
    end
    s = next_in_ring(self.occupied_ring, s)
    if s == next_in_ring(self.occupied_ring, self.button_seat) then
      break
    end
  end
  return self.occupied_ring[1]
end

function HandState:_rebuild_pending_after_raise(tbl, raiser_seat)
  self.pending = {}
  for _, s in ipairs(self.occupied_ring) do
    if s ~= raiser_seat and not self.folded[s] then
      local st = tbl:get_seat(s)
      if st and st.stack > 0 then
        self.pending[s] = true
      end
    end
  end
end

function HandState:_all_matched(tbl)
  for _, s in ipairs(self.occupied_ring) do
    if not self.folded[s] then
      local c = self.contribution[s] or 0
      local st = tbl:get_seat(s)
      if st and c < self.current_bet and st.stack > 0 then
        return false
      end
    end
  end
  return true
end

function HandState:_pending_empty()
  for s in pairs(self.pending) do
    if self.pending[s] then
      return false
    end
  end
  return true
end

function HandState:_round_complete(tbl)
  -- Everyone matched or all-in; no one pending response to a raise
  if not self:_all_matched(tbl) then
    return false
  end
  return self:_pending_empty()
end

function HandState:_count_active()
  local n = 0
  for _, s in ipairs(self.occupied_ring) do
    if not self.folded[s] then
      n = n + 1
    end
  end
  return n
end

function HandState:_reset_between_hands()
  self.status = "idle"
  self.street = "none"
  self.pot = 0
  self.community = {}
  self.action_log = {}
  self.seq = 0
  self.contribution = {}
  self.current_bet = 0
  self.min_raise_increment = self.bb_amount
  self.folded = {}
  self.action_to_seat = nil
  self.pending = {}
  self.last_raise_seat = nil
  self.button_seat = nil
  self.sb_seat = nil
  self.bb_seat = nil
  self.hand_bets = {}
end

function HandState:_advance_street_or_complete(tbl)
  if self:_count_active() <= 1 then
    self.action_to_seat = nil
    local n = math.max(1, #self.occupied_ring)
    self.dealer_ring_index = (self.dealer_ring_index + 1) % n
    self:_reset_between_hands()
    return
  end

  if self.street == "preflop" then
    self.street = "flop"
    self.community = { "?", "?", "?" }
  elseif self.street == "flop" then
    self.street = "turn"
    self.community[4] = "?"
  elseif self.street == "turn" then
    self.street = "river"
    self.community[5] = "?"
  elseif self.street == "river" then
    self.action_to_seat = nil
    local n = math.max(1, #self.occupied_ring)
    self.dealer_ring_index = (self.dealer_ring_index + 1) % n
    self:_reset_between_hands()
    return
  end

  self:_reset_street_betting()
  self.action_to_seat = self:_first_postflop_actor()
  while self.action_to_seat and self.folded[self.action_to_seat] do
    self.action_to_seat = next_in_ring(self.occupied_ring, self.action_to_seat)
  end
end

--- Who would act first preflop after posting blinds, without mutating state.
--- Returns seat number or nil, err (need_two_players, insufficient_chips).
function HandState:peek_first_actor(tbl)
  local occ = occupied_seats(tbl)
  if #occ < 2 then
    return nil, "need_two_players"
  end

  local n = #occ
  local b = self.dealer_ring_index % n
  local sb, bb
  if n == 2 then
    sb = occ[(b % 2) + 1]
    bb = occ[((b + 1) % 2) + 1]
  else
    sb = occ[(b + 1) % n + 1]
    bb = occ[(b + 2) % n + 1]
  end

  local function can_post(seat, amt)
    local st = tbl:get_seat(seat)
    return st and st.stack >= amt
  end
  if not can_post(sb, self.sb_amount) or not can_post(bb, self.bb_amount) then
    return nil, "insufficient_chips"
  end

  if n == 2 then
    return sb
  end
  return occ[(b + 3) % n + 1]
end

function HandState:start_hand(tbl)
  local occ = occupied_seats(tbl)
  if #occ < 2 then
    return nil, "need_two_players"
  end

  self.occupied_ring = occ
  self.folded = {}
  self.contribution = {}
  self.pot = 0
  self.community = {}
  self.action_log = {}
  self.seq = 0
  self.status = "active"
  self.street = "preflop"

  local n = #occ
  local b = self.dealer_ring_index % n
  local btn = occ[b + 1]
  local sb, bb

  if n == 2 then
    sb = occ[(b % 2) + 1]
    bb = occ[((b + 1) % 2) + 1]
  else
    sb = occ[(b + 1) % n + 1]
    bb = occ[(b + 2) % n + 1]
  end

  self.button_seat = btn
  self.sb_seat = sb
  self.bb_seat = bb

  local function post(seat, amt)
    local st = tbl:get_seat(seat)
    if not st or st.stack < amt then
      return nil, "insufficient_chips"
    end
    st.stack = st.stack - amt
    self.pot = self.pot + amt
    self.contribution[seat] = (self.contribution[seat] or 0) + amt
    self.hand_bets[seat] = (self.hand_bets[seat] or 0) + amt
    return true
  end

  local ok, err = post(sb, self.sb_amount)
  if not ok then
    return nil, err
  end
  ok, err = post(bb, self.bb_amount)
  if not ok then
    return nil, err
  end

  self.current_bet = self.bb_amount
  self.min_raise_increment = self.bb_amount
  self.last_raise_seat = nil -- voluntary raises only; BB post is not a "raise" for re-raise rules
  self.pending = {}

  if n == 2 then
    self.action_to_seat = sb
  else
    self.action_to_seat = occ[(b + 3) % n + 1]
  end

  return true
end

function HandState:_log(player_id, seat, action, amount)
  self.seq = self.seq + 1
  self.action_log[#self.action_log + 1] = {
    seq = self.seq,
    player_id = player_id,
    seat = seat,
    action = action,
    amount = amount,
    street = self.street,
  }
end

function HandState:_set_next_actor(tbl, from_seat)
  local start = next_in_ring(self.occupied_ring, from_seat)
  local s = start
  for _ = 1, #self.occupied_ring + 2 do
    if not s then
      break
    end
    if not self.folded[s] then
      local st = tbl:get_seat(s)
      local c = self.contribution[s] or 0
      if st and c < self.current_bet and st.stack > 0 then
        self.action_to_seat = s
        return
      end
      if self.pending[s] and st and st.stack > 0 then
        self.action_to_seat = s
        return
      end
    end
    s = next_in_ring(self.occupied_ring, s)
    if s == start then
      break
    end
  end
  return nil
end

function HandState:_after_action(tbl, acted_seat)
  if self:_round_complete(tbl) then
    self:_advance_street_or_complete(tbl)
    return
  end

  local s = next_in_ring(self.occupied_ring, acted_seat)
  local guard = 0
  while s and guard < 32 do
    guard = guard + 1
    if not self.folded[s] then
      local st = tbl:get_seat(s)
      local c = self.contribution[s] or 0
      if st and c < self.current_bet and st.stack > 0 then
        self.action_to_seat = s
        return
      end
      if self.pending[s] and st and st.stack > 0 then
        self.action_to_seat = s
        return
      end
    end
    s = next_in_ring(self.occupied_ring, s)
    if s == next_in_ring(self.occupied_ring, acted_seat) then
      break
    end
  end

  if self:_round_complete(tbl) then
    self:_advance_street_or_complete(tbl)
    return
  end

  self:_set_next_actor(tbl, acted_seat)
end

function HandState:apply_action(tbl, player_id, action, amount)
  action = string.lower(tostring(action or ""))
  local seat = tbl:seat_for_player(player_id)
  if not seat then
    return nil, "not_seated"
  end

  if self.status == "idle" then
    local ok, err = self:start_hand(tbl)
    if not ok then
      return nil, err
    end
  end

  if self.action_to_seat ~= seat then
    return nil, "wrong_turn"
  end

  local st = tbl:get_seat(seat)
  if not st then
    return nil, "not_seated"
  end

  if self.folded[seat] then
    return nil, "already_folded"
  end

  local c = self.contribution[seat] or 0

  if action == "fold" then
    self.folded[seat] = true
    self.pending[seat] = nil
    self:_log(player_id, seat, "fold", nil)
    self:_after_action(tbl, seat)
    return true
  end

  if action == "check" then
    if c < self.current_bet then
      return nil, "cannot_check"
    end
    self:_log(player_id, seat, "check", nil)
    self:_after_action(tbl, seat)
    return true
  end

  if action == "call" then
    local need = self.current_bet - c
    if need <= 0 then
      return nil, "nothing_to_call"
    end
    if st.stack < need then
      return nil, "insufficient_chips"
    end
    st.stack = st.stack - need
    self.pot = self.pot + need
    self.contribution[seat] = c + need
    self.hand_bets[seat] = (self.hand_bets[seat] or 0) + need
    self.pending[seat] = nil
    self:_log(player_id, seat, "call", need)
    self:_after_action(tbl, seat)
    return true
  end

  if action == "all_in" then
    local push = st.stack
    if push < 1 then
      return nil, "insufficient_chips"
    end
    st.stack = 0
    self.pot = self.pot + push
    local newc = c + push
    self.contribution[seat] = newc
    self.hand_bets[seat] = (self.hand_bets[seat] or 0) + push
    if newc > self.current_bet then
      local inc = newc - self.current_bet
      self.current_bet = newc
      -- Short all-in may be less than min raise; still counts as last raise
      self.min_raise_increment = math.max(self.min_raise_increment, inc)
      self.last_raise_seat = seat
      self:_rebuild_pending_after_raise(tbl, seat)
    end
    self.pending[seat] = nil
    self:_log(player_id, seat, "all_in", push)
    self:_after_action(tbl, seat)
    return true
  end

  if action ~= "raise" and action ~= "bet" then
    return nil, "invalid_action"
  end

  if amount == nil then
    return nil, "amount_required"
  end
  amount = math.floor(tonumber(amount) or 0)
  if amount < 1 then
    return nil, "invalid_amount"
  end

  if amount <= c then
    return nil, "raise_not_increase"
  end

  local chips_in = amount - c
  if chips_in > st.stack then
    return nil, "insufficient_chips"
  end

  -- Cannot "re-raise yourself" in the same sense as raising again before anyone else has raised
  if self.last_raise_seat ~= nil and seat == self.last_raise_seat then
    return nil, "cannot_raise_self"
  end

  local increment = amount - self.current_bet
  if increment < self.min_raise_increment and chips_in < st.stack then
    return nil, "min_raise"
  end

  st.stack = st.stack - chips_in
  self.pot = self.pot + chips_in
  self.contribution[seat] = amount
  self.hand_bets[seat] = (self.hand_bets[seat] or 0) + chips_in

  self.current_bet = amount
  self.min_raise_increment = math.max(self.min_raise_increment, increment)
  self.last_raise_seat = seat
  self:_rebuild_pending_after_raise(tbl, seat)
  self.pending[seat] = nil

  self:_log(player_id, seat, action, chips_in)
  self:_after_action(tbl, seat)
  return true
end

return {
  HandState = HandState,
}
