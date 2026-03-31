--- Example Lua bot: min-raise preflop, check/call postflop.
---
--- Run:
---   lua -e 'package.path="src/?.lua;src/?/init.lua;"..package.path' bots/example_bot.lua
---   lua -e 'package.path="src/?.lua;src/?/init.lua;"..package.path' bots/example_bot.lua --name Raiser --chips 1000

local bot_runner = require("poker.bot_runner")

local function decide(state, me)
  local hand = state.hand or {}
  local street = hand.street or "preflop"
  local cb = hand.current_bet or 0
  local mri = hand.min_raise_increment or 5
  local stack = me.stack or 0
  local contrib = me.contribution or 0

  if street == "preflop" then
    local target = cb + mri
    local need = target - contrib
    if need > 0 and need <= stack then
      return { action = "raise", amount = target }
    end
  end

  local call_need = cb - contrib
  if call_need > 0 and call_need <= stack then
    return { action = "call" }
  end

  if contrib >= cb then
    return { action = "check" }
  end

  return { action = "fold" }
end

local name = "LuaBot"
local chips = 500
local url = os.getenv("POKER_URL") or "http://127.0.0.1:8080"

for i = 1, #arg do
  if arg[i] == "--name" then name = arg[i + 1]
  elseif arg[i] == "--chips" then chips = tonumber(arg[i + 1]) or 500
  elseif arg[i] == "--url" then url = arg[i + 1]
  end
end

bot_runner.run({
  strategy = decide,
  url = url,
  player_id = name,
  chips = chips,
})
