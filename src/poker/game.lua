-- Stub hand state: pot, streets, board, action log. Rules engine TBD.

local HandState = {}
HandState.__index = HandState

function HandState.new(opts)
  opts = opts or {}
  return setmetatable({
    status = "idle", -- idle | active | complete
    street = "none", -- none | preflop | flop | turn | river | showdown
    pot = 0,
    community = {},
    action_log = {},
    hand_bets = {}, -- seat -> chips committed this hand (stub)
  }, HandState)
end

function HandState:snapshot_public()
  return {
    status = self.status,
    street = self.street,
    pot = self.pot,
    community = self.community,
    action_log = self.action_log,
    hand_bets = self.hand_bets,
  }
end

return {
  HandState = HandState,
}
