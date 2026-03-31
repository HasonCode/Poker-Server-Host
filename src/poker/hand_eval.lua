--- Poker hand evaluator: ranks 5-card hands and finds the best 5 from 7.

local M = {}

local RANK_VALUE = {
  ["2"] = 2, ["3"] = 3, ["4"] = 4, ["5"] = 5,
  ["6"] = 6, ["7"] = 7, ["8"] = 8, ["9"] = 9,
  ["T"] = 10, ["J"] = 11, ["Q"] = 12, ["K"] = 13, ["A"] = 14,
}

local HAND_RANK = {
  high_card       = 1,
  one_pair        = 2,
  two_pair        = 3,
  three_of_a_kind = 4,
  straight        = 5,
  flush           = 6,
  full_house      = 7,
  four_of_a_kind  = 8,
  straight_flush  = 9,
}

M.HAND_RANK = HAND_RANK

local function rank_val(card)
  return RANK_VALUE[card.rank] or 0
end

local function sort_desc(cards)
  local copy = {}
  for i, c in ipairs(cards) do copy[i] = c end
  table.sort(copy, function(a, b) return rank_val(a) > rank_val(b) end)
  return copy
end

--- Evaluate exactly 5 cards → { rank (int), kickers (list of ints for tiebreak), name (string) }
function M.evaluate5(cards)
  local sorted = sort_desc(cards)
  local vals = {}
  for i, c in ipairs(sorted) do vals[i] = rank_val(c) end

  local is_flush = true
  local s0 = sorted[1].suit
  for i = 2, 5 do
    if sorted[i].suit ~= s0 then is_flush = false; break end
  end

  local is_straight = false
  local straight_high = 0
  if vals[1] - vals[5] == 4
    and vals[1] ~= vals[2]
    and vals[2] ~= vals[3]
    and vals[3] ~= vals[4]
    and vals[4] ~= vals[5]
  then
    is_straight = true
    straight_high = vals[1]
  end

  -- A-2-3-4-5 wheel
  if not is_straight
    and vals[1] == 14 and vals[2] == 5
    and vals[3] == 4 and vals[4] == 3 and vals[5] == 2
  then
    is_straight = true
    straight_high = 5
  end

  if is_straight and is_flush then
    return { rank = HAND_RANK.straight_flush, kickers = { straight_high }, name = "straight_flush" }
  end

  -- Count ranks
  local counts = {}
  for _, v in ipairs(vals) do counts[v] = (counts[v] or 0) + 1 end

  local quads, trips, pairs_list, singles = {}, {}, {}, {}
  for v, n in pairs(counts) do
    if n == 4 then quads[#quads + 1] = v
    elseif n == 3 then trips[#trips + 1] = v
    elseif n == 2 then pairs_list[#pairs_list + 1] = v
    else singles[#singles + 1] = v
    end
  end
  table.sort(quads, function(a, b) return a > b end)
  table.sort(trips, function(a, b) return a > b end)
  table.sort(pairs_list, function(a, b) return a > b end)
  table.sort(singles, function(a, b) return a > b end)

  if #quads == 1 then
    local k = {}
    for _, v in ipairs(vals) do if v ~= quads[1] then k[#k + 1] = v end end
    table.sort(k, function(a, b) return a > b end)
    return { rank = HAND_RANK.four_of_a_kind, kickers = { quads[1], k[1] }, name = "four_of_a_kind" }
  end

  if #trips >= 1 and #pairs_list >= 1 then
    return { rank = HAND_RANK.full_house, kickers = { trips[1], pairs_list[1] }, name = "full_house" }
  end

  if is_flush then
    return { rank = HAND_RANK.flush, kickers = vals, name = "flush" }
  end

  if is_straight then
    return { rank = HAND_RANK.straight, kickers = { straight_high }, name = "straight" }
  end

  if #trips == 1 then
    return { rank = HAND_RANK.three_of_a_kind, kickers = { trips[1], singles[1], singles[2] }, name = "three_of_a_kind" }
  end

  if #pairs_list == 2 then
    return { rank = HAND_RANK.two_pair, kickers = { pairs_list[1], pairs_list[2], singles[1] }, name = "two_pair" }
  end

  if #pairs_list == 1 then
    return { rank = HAND_RANK.one_pair, kickers = { pairs_list[1], singles[1], singles[2], singles[3] }, name = "one_pair" }
  end

  return { rank = HAND_RANK.high_card, kickers = vals, name = "high_card" }
end

--- Compare two eval results: returns  1 if a wins, -1 if b wins, 0 if tie.
function M.compare(a, b)
  if a.rank ~= b.rank then
    return a.rank > b.rank and 1 or -1
  end
  for i = 1, math.max(#a.kickers, #b.kickers) do
    local ak = a.kickers[i] or 0
    local bk = b.kickers[i] or 0
    if ak ~= bk then
      return ak > bk and 1 or -1
    end
  end
  return 0
end

--- Generate all C(n,5) combinations of indices.
local function combinations(n)
  local result = {}
  for a = 1, n - 4 do
    for b = a + 1, n - 3 do
      for c = b + 1, n - 2 do
        for d = c + 1, n - 1 do
          for e = d + 1, n do
            result[#result + 1] = { a, b, c, d, e }
          end
        end
      end
    end
  end
  return result
end

--- Find the best 5-card hand from a set of cards (typically 7: 2 hole + 5 community).
--- Returns the eval result for the best hand.
function M.best_of(cards)
  local combos = combinations(#cards)
  local best = nil
  for _, idx in ipairs(combos) do
    local hand5 = {}
    for i, j in ipairs(idx) do hand5[i] = cards[j] end
    local ev = M.evaluate5(hand5)
    if not best or M.compare(ev, best) > 0 then
      best = ev
    end
  end
  return best
end

local HAND_NAMES = {
  [HAND_RANK.high_card]       = "High Card",
  [HAND_RANK.one_pair]        = "Pair",
  [HAND_RANK.two_pair]        = "Two Pair",
  [HAND_RANK.three_of_a_kind] = "Three of a Kind",
  [HAND_RANK.straight]        = "Straight",
  [HAND_RANK.flush]           = "Flush",
  [HAND_RANK.full_house]      = "Full House",
  [HAND_RANK.four_of_a_kind]  = "Four of a Kind",
  [HAND_RANK.straight_flush]  = "Straight Flush",
}

function M.hand_name(eval_result)
  return HAND_NAMES[eval_result.rank] or "Unknown"
end

return M
