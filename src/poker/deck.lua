-- Standard 52-card deck: create, shuffle (Fisher–Yates), deal.

local M = {}

local RANKS = { "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A" }
local SUITS = { "s", "h", "d", "c" } -- spades, hearts, diamonds, clubs

local SUIT_SYMBOL = { s = "♠", h = "♥", d = "♦", c = "♣" }
local RANK_DISPLAY = {
  T = "10", J = "J", Q = "Q", K = "K", A = "A",
}

function M.card(rank, suit)
  return { rank = rank, suit = suit }
end

function M.card_str(c)
  return (RANK_DISPLAY[c.rank] or c.rank) .. SUIT_SYMBOL[c.suit]
end

function M.is_red(c)
  return c.suit == "h" or c.suit == "d"
end

function M.new_deck()
  local cards = {}
  for _, s in ipairs(SUITS) do
    for _, r in ipairs(RANKS) do
      cards[#cards + 1] = M.card(r, s)
    end
  end
  return cards
end

function M.shuffle(cards)
  math.randomseed(os.time())
  for i = #cards, 2, -1 do
    local j = math.random(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

--- Draw n cards from the top of the deck (mutates deck).
function M.draw(deck, n)
  local hand = {}
  for _ = 1, n do
    if #deck == 0 then
      break
    end
    hand[#hand + 1] = table.remove(deck)
  end
  return hand
end

return M
