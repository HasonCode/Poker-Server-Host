local poker = {
  new_table = require("poker.table_state"),
  game = require("poker.game"),
  api = require("poker.api"),
  json = require("poker.json"),
}

poker.http_server = function()
  return require("poker.http_server")
end

-- Optional HTTP client (LuaSocket): require("poker.client")

return poker
