package.path = "src/?.lua;src/?/init.lua;src/?/?.lua;" .. package.path

local game = require("poker.game")
local new_table = require("poker.table_state")
local deck = require("poker.deck")

local function card(rank, suit)
  return deck.card(rank, suit)
end

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function make_table(stacks)
  local tbl = new_table({ max_seats = #stacks })
  for seat, stack in ipairs(stacks) do
    local ok, err = tbl:seat_player({
      seat = seat,
      player_id = "p" .. seat,
      chips = stack,
    })
    assert(ok, err)
  end
  return tbl
end

local function base_board()
  return {
    card("2", "c"),
    card("7", "d"),
    card("9", "s"),
    card("J", "h"),
    card("Q", "c"),
  }
end

local function ranked_holes()
  return {
    [1] = { card("A", "h"), card("A", "s") },
    [2] = { card("K", "h"), card("K", "d") },
    [3] = { card("3", "h"), card("4", "d") },
  }
end

local function test_short_stack_wins_only_main_pot()
  local tbl = make_table({ 0, 0, 0 })
  local hand = game.HandState.new()
  hand.occupied_ring = { 1, 2, 3 }
  hand.pot = 2100
  hand.hand_bets = { [1] = 500, [2] = 800, [3] = 800 }
  hand.folded = {}
  hand.community = base_board()
  hand.hole_cards = ranked_holes()

  hand:_award_showdown(tbl)

  assert_eq(tbl:get_seat(1).stack, 1500, "p1 main-pot award")
  assert_eq(tbl:get_seat(2).stack, 600, "p2 side-pot award")
  assert_eq(tbl:get_seat(3).stack, 0, "p3 award")
  assert_eq(hand.last_winners[1].player_id, "p1", "first winner")
  assert_eq(hand.last_winners[1].amount, 1500, "first winner amount")
  assert_eq(hand.last_winners[2].player_id, "p2", "second winner")
  assert_eq(hand.last_winners[2].amount, 600, "second winner amount")
end

local function test_short_call_becomes_all_in()
  local tbl = make_table({ 500, 0, 0 })
  local hand = game.HandState.new()
  hand.status = "active"
  hand.street = "river"
  hand.occupied_ring = { 1, 2, 3 }
  hand.action_to_seat = 1
  hand.current_bet = 800
  hand.min_raise_increment = 100
  hand.contribution = { [1] = 0, [2] = 800, [3] = 800 }
  hand.hand_bets = { [1] = 0, [2] = 800, [3] = 800 }
  hand.acted_this_street = { [2] = true, [3] = true }
  hand.pending = { [1] = true }
  hand.pot = 1600
  hand.community = base_board()
  hand.hole_cards = ranked_holes()

  local ok, err = hand:apply_action(tbl, "p1", "call")
  assert(ok, err)

  assert_eq(tbl:get_seat(1).stack, 1500, "short caller main-pot award")
  assert_eq(tbl:get_seat(2).stack, 600, "next-best side-pot award")
  assert_eq(tbl:get_seat(3).stack, 0, "third player award")
end

test_short_stack_wins_only_main_pot()
test_short_call_becomes_all_in()

print("side pot regression checks passed")
