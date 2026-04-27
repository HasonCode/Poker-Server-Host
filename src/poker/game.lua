-- Hand state: SB/BB, button, turn order, betting rounds, min-raise, cannot re-raise self.

local deck_mod = require("poker.deck")
local hand_eval = require("poker.hand_eval")

local HandState = {}
HandState.__index = HandState

local function copy_keys(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[k] = v
  end
  return out
end

local function seat_map_to_json(t)
  local out = {}
  for k, v in pairs(t or {}) do
    out[tostring(k)] = v
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
    --- Stable seat the button was on at the end of the previous hand, used
    --- to compute the next button regardless of who has joined or left in
    --- the meantime. nil before the first hand.
    last_button_seat = nil,
    contribution = {},
    current_bet = 0,
    min_raise_increment = 0,
    folded = {},
    action_to_seat = nil,
    pending = {},
    acted_this_street = {},
    last_raise_seat = nil,
    occupied_ring = {},
    deck = {},
    hole_cards = {},
    last_winners = nil,
  }, HandState)
end

function HandState:snapshot_public()
  local min_inc = self.min_raise_increment
  if self.status == "idle" then
    min_inc = self.bb_amount
  end
  local function cards_to_strings(list)
    local out = {}
    for _, c in ipairs(list or {}) do
      if type(c) == "table" then
        out[#out + 1] = deck_mod.card_str(c)
      else
        out[#out + 1] = tostring(c)
      end
    end
    return out
  end

  local comm = cards_to_strings(self.community)
  local last_comm = cards_to_strings(self.last_community)

  local hc = {}
  for seat, cards in pairs(self.hole_cards) do
    local arr = {}
    for _, c in ipairs(cards) do
      arr[#arr + 1] = deck_mod.card_str(c)
    end
    hc[tostring(seat)] = arr
  end
  return {
    status = self.status,
    street = self.street,
    pot = self.pot,
    community = comm,
    last_community = last_comm,
    action_log = self.action_log,
    hand_bets = seat_map_to_json(self.hand_bets),
    sb_amount = self.sb_amount,
    bb_amount = self.bb_amount,
    button_seat = self.button_seat,
    sb_seat = self.sb_seat,
    bb_seat = self.bb_seat,
    action_to_seat = self.action_to_seat,
    action_seq = self.seq,
    current_bet = self.current_bet,
    min_raise_increment = min_inc,
    contribution = seat_map_to_json(self.contribution),
    folded = seat_map_to_json(self.folded),
    hole_cards = hc,
    last_winners = self.last_winners,
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

--- Next occupied seat strictly after `last_seat` (clockwise, by seat number).
--- Works even when `last_seat` itself is no longer in `ring` (e.g. the
--- previous button left between hands).
local function next_seat_after(ring, last_seat)
  if not ring or #ring == 0 then
    return nil
  end
  if not last_seat then
    return ring[1]
  end
  for _, s in ipairs(ring) do
    if s > last_seat then
      return s
    end
  end
  return ring[1]
end

function HandState:_reset_street_betting()
  self.contribution = {}
  self.current_bet = 0
  self.min_raise_increment = self.bb_amount
  self.last_raise_seat = nil
  self.pending = {}
  self.acted_this_street = {}
  for _, s in ipairs(self.occupied_ring) do
    self.contribution[s] = 0
  end
end

--- First seat clockwise after the button who can actually act on a postflop
--- street: not folded and with chips remaining (all-in players cannot act,
--- so their turn is automatically skipped). Returns nil if no one can act.
function HandState:_first_postflop_actor(tbl)
  local start = next_in_ring(self.occupied_ring, self.button_seat)
  local s = start
  while s do
    if not self.folded[s] then
      local st = tbl and tbl:get_seat(s)
      if st and st.stack > 0 then
        return s
      end
    end
    s = next_in_ring(self.occupied_ring, s)
    if s == start then
      break
    end
  end
  return nil
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

function HandState:_seat_needs_action(tbl, seat)
  if self.folded[seat] then
    self.pending[seat] = nil
    return false
  end
  local st = tbl:get_seat(seat)
  if not st or st.stack <= 0 then
    self.pending[seat] = nil
    return false
  end
  local c = self.contribution[seat] or 0
  if c < self.current_bet then
    return true
  end
  if not self.acted_this_street[seat] then
    return true
  end
  -- A pending flag is only meaningful while the player still owes a response.
  -- If they have already acted and matched the current bet, do not loop the
  -- turn back to them because of stale pending state.
  if self.pending[seat] then
    self.pending[seat] = nil
  end
  return false
end

function HandState:_round_complete(tbl)
  -- Everyone matched or all-in; no one pending response to a raise
  if not self:_all_matched(tbl) then
    return false
  end
  -- Every non-folded player with chips must have had a turn this street.
  -- Without this check, the first actor on a new postflop street could
  -- "check" and instantly advance the round, skipping everyone else
  -- (action would then land on the same seat again as the first postflop
  -- actor on the next street). Also preserves the BB option preflop.
  for _, s in ipairs(self.occupied_ring) do
    if self:_seat_needs_action(tbl, s) then
      return false
    end
  end
  if not self:_pending_empty() then
    return false
  end
  return true
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
  self.last_community = {}
  for i, c in ipairs(self.community) do
    self.last_community[i] = c
  end
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
  self.acted_this_street = {}
  self.last_raise_seat = nil
  self.button_seat = nil
  self.sb_seat = nil
  self.bb_seat = nil
  self.hand_bets = {}
  self.deck = {}
  self.hole_cards = {}
end

--- Award pot to the last unfolded player (everyone else folded).
function HandState:_award_fold_winner(tbl)
  local winner_seat = nil
  for _, s in ipairs(self.occupied_ring) do
    if not self.folded[s] then
      winner_seat = s
      break
    end
  end
  if not winner_seat then return end

  local st = tbl:get_seat(winner_seat)
  if not st then return end
  local amount = self.pot
  st.stack = st.stack + amount

  local pid = st.player_id or ("seat_" .. winner_seat)
  self:_log(pid, winner_seat, "win", amount)
  self.last_winners = { { seat = winner_seat, player_id = pid, amount = amount, hand_name = "fold" } }
end

--- Award pot at showdown: evaluate hands, split among winners.
function HandState:_award_showdown(tbl)
  local active = {}
  for _, s in ipairs(self.occupied_ring) do
    if not self.folded[s] then
      active[#active + 1] = s
    end
  end

  if #active == 0 then return end
  if #active == 1 then
    self:_award_fold_winner(tbl)
    return
  end

  local evals = {}
  for _, s in ipairs(active) do
    local hc = self.hole_cards[s] or {}
    local all_cards = {}
    for _, c in ipairs(hc) do all_cards[#all_cards + 1] = c end
    for _, c in ipairs(self.community) do all_cards[#all_cards + 1] = c end
    evals[s] = hand_eval.best_of(all_cards)
  end

  -- Find best eval among active players
  local best = evals[active[1]]
  for i = 2, #active do
    if hand_eval.compare(evals[active[i]], best) > 0 then
      best = evals[active[i]]
    end
  end

  -- Collect all winners (ties split the pot)
  local winners = {}
  for _, s in ipairs(active) do
    if hand_eval.compare(evals[s], best) == 0 then
      winners[#winners + 1] = s
    end
  end

  local share = math.floor(self.pot / #winners)
  local remainder = self.pot - share * #winners

  self.last_winners = {}
  for i, s in ipairs(winners) do
    local st = tbl:get_seat(s)
    if st then
      local award = share
      if i <= remainder then award = award + 1 end
      st.stack = st.stack + award
      local pid = st.player_id or ("seat_" .. s)
      local hname = hand_eval.hand_name(evals[s])
      self:_log(pid, s, "win", award)
      self.last_winners[#self.last_winners + 1] = {
        seat = s, player_id = pid, amount = award, hand_name = hname,
      }
    end
  end
end

function HandState:_finish_hand(tbl)
  self.action_to_seat = nil
  --- Remember the seat (not a ring offset) so the next hand's button advances
  --- correctly even if players join or leave between hands.
  if self.button_seat then
    self.last_button_seat = self.button_seat
  end
end

function HandState:_advance_street_or_complete(tbl)
  --- Advance through as many streets as needed. If every remaining non-folded
  --- player is all-in, there's no more betting — burn/deal each remaining
  --- street with no actor and go straight to showdown.
  while true do
    if self:_count_active() <= 1 then
      self:_award_fold_winner(tbl)
      self:_finish_hand(tbl)
      self:_reset_between_hands()
      return
    end

    if self.street == "preflop" then
      self.street = "flop"
      deck_mod.draw(self.deck, 1) -- burn
      local flop = deck_mod.draw(self.deck, 3)
      self.community = flop
    elseif self.street == "flop" then
      self.street = "turn"
      deck_mod.draw(self.deck, 1) -- burn
      local turn = deck_mod.draw(self.deck, 1)
      self.community[4] = turn[1]
    elseif self.street == "turn" then
      self.street = "river"
      deck_mod.draw(self.deck, 1) -- burn
      local river = deck_mod.draw(self.deck, 1)
      self.community[5] = river[1]
    elseif self.street == "river" then
      self:_award_showdown(tbl)
      self:_finish_hand(tbl)
      self:_reset_between_hands()
      return
    end

    self:_reset_street_betting()
    self.action_to_seat = self:_first_postflop_actor(tbl)
    if self.action_to_seat then
      return
    end
    --- No one has chips to act (everyone remaining is all-in). Keep dealing
    --- the next street until we reach showdown.
  end
end

--- Compute (button, sb, bb, first_actor) for the given occupied ring,
--- using `last_button_seat` to advance the button by absolute seat number
--- (so leaves/joins between hands don't shift the button arbitrarily).
function HandState:_compute_positions(occ)
  local n = #occ
  if n < 2 then
    return nil
  end
  local btn = next_seat_after(occ, self.last_button_seat)
  local sb, bb, first
  if n == 2 then
    sb = btn
    bb = next_seat_after(occ, btn)
    first = sb
  else
    sb = next_seat_after(occ, btn)
    bb = next_seat_after(occ, sb)
    first = next_seat_after(occ, bb)
  end
  return { button = btn, sb = sb, bb = bb, first = first }
end

--- Who would act first preflop after posting blinds, without mutating state.
--- Returns seat number or nil, err (need_two_players, insufficient_chips).
function HandState:peek_first_actor(tbl)
  local occ = occupied_seats(tbl)
  if #occ < 2 then
    return nil, "need_two_players"
  end

  local pos = self:_compute_positions(occ)
  if not pos then
    return nil, "need_two_players"
  end

  local function can_post(seat, amt)
    local st = tbl:get_seat(seat)
    return st and st.stack >= amt
  end
  if not can_post(pos.sb, self.sb_amount) or not can_post(pos.bb, self.bb_amount) then
    return nil, "insufficient_chips"
  end

  return pos.first
end

function HandState:start_hand(tbl)
  local occ = occupied_seats(tbl)
  if #occ < 2 then
    return nil, "need_two_players"
  end

  local pos = self:_compute_positions(occ)
  if not pos then
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
  --- NOTE: do NOT wipe `last_winners` here. It refers to the *previous*
  --- hand's outcome and we want clients (UI, bots) to be able to read
  --- "who won the last hand" while a new hand is in progress. It will
  --- be naturally overwritten by the next call to `_award_fold_winner`
  --- or `_award_showdown` when the new hand resolves. The only paths
  --- that fully clear it are server-side resets (admin reset, table
  --- empties via `rearm_start_gate_if_empty`).

  self.button_seat = pos.button
  self.sb_seat = pos.sb
  self.bb_seat = pos.bb

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

  local ok, err = post(pos.sb, self.sb_amount)
  if not ok then
    return nil, err
  end
  ok, err = post(pos.bb, self.bb_amount)
  if not ok then
    return nil, err
  end

  self.current_bet = self.bb_amount
  self.min_raise_increment = self.bb_amount
  self.last_raise_seat = nil
  self.pending = {}
  self.acted_this_street = {}

  self.deck = deck_mod.shuffle(deck_mod.new_deck())
  self.hole_cards = {}
  for _, s in ipairs(occ) do
    self.hole_cards[s] = deck_mod.draw(self.deck, 2)
  end

  self.action_to_seat = pos.first

  return true
end

--- True iff `seat` is participating in the currently-active hand. Returns
--- false during idle, and false for players who joined after start_hand().
function HandState:is_seat_in_hand(seat)
  if self.status ~= "active" or not seat then
    return false
  end
  for _, s in ipairs(self.occupied_ring or {}) do
    if s == seat then
      return true
    end
  end
  return false
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

function HandState:_after_action(tbl, acted_seat)
  self.acted_this_street[acted_seat] = true

  if self:_round_complete(tbl) then
    self:_advance_street_or_complete(tbl)
    return
  end

  local start = next_in_ring(self.occupied_ring, acted_seat)
  local s = start
  local guard = 0
  while s and guard < 32 do
    guard = guard + 1
    if self:_seat_needs_action(tbl, s) then
      self.action_to_seat = s
      return
    end
    s = next_in_ring(self.occupied_ring, s)
    if s == start then
      break
    end
  end

  -- No remaining actor this street: the round is done.
  self:_advance_street_or_complete(tbl)
end

function HandState:apply_action(tbl, player_id, action, amount)
  action = string.lower(tostring(action or ""))
  local seat = tbl:seat_for_player(player_id)
  if not seat then
    return nil, "not_seated"
  end

  --- Starting a hand is explicit: callers must run `start_hand` (after any
  --- server-side ready gate / limbo autofold). Implicit auto-start here
  --- bypassed tournament-style gates and skipped first-hand autofolds.
  if self.status == "idle" then
    return nil, "hand_idle"
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
