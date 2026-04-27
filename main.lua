#!/usr/bin/env lua
-- Poker server entry: optional HTTP (LuaSocket) or --cli snapshot.

local function script_dir()
  local p = arg[0] or "."
  local d = p:match("^(.*)/[^/]+$") or "."
  return d
end

package.path = script_dir() .. "/src/?.lua;" .. script_dir() .. "/src/?/init.lua;" .. package.path

local poker = require("poker")
local api = poker.api
local json = poker.json
local ai = require("poker.ai")
local admin_auth = require("poker.admin_auth")

local function join_http_error(err)
  local t = {
    invalid_seat = { "400 Bad Request", "invalid_seat", "Seat must be between 1 and max_seats." },
    seat_taken = { "409 Conflict", "seat_taken", "That seat is already occupied." },
    table_full = { "409 Conflict", "table_full", "No empty seats available." },
    already_seated = { "409 Conflict", "already_seated", "Player is already seated at this table." },
    invalid_player = { "400 Bad Request", "invalid_player", "player_id is required and non-empty." },
    invalid_chips = { "400 Bad Request", "invalid_chips", "chips must be a non-negative integer." },
  }
  local row = t[err]
  if not row then
    return { "500 Internal Server Error", api.error_body("internal", "Seat operation failed.") }
  end
  return { row[1], api.error_body(row[2], row[3], { reason = err }) }
end

local function action_http_error(err, extra)
  local t = {
    invalid_player = { "400 Bad Request", "invalid_player", "player_id is missing or empty." },
    not_seated = { "403 Forbidden", "not_seated", "Player is not seated at this table." },
    wrong_turn = { "400 Bad Request", "wrong_turn", "It is not this player's turn to act." },
    invalid_action = {
      "400 Bad Request",
      "invalid_action",
      "action must be fold, check, call, raise, bet, or all_in.",
    },
    amount_required = { "400 Bad Request", "amount_required", "raise and bet require a positive amount." },
    invalid_amount = { "400 Bad Request", "invalid_amount", "amount must be a positive integer." },
    insufficient_chips = { "400 Bad Request", "insufficient_chips", "Not enough chips for this action." },
    need_two_players = { "400 Bad Request", "need_two_players", "At least two seated players are required to start a hand." },
    hand_complete = { "400 Bad Request", "hand_complete", "Start a new hand before acting (hand is finished)." },
    cannot_check = { "400 Bad Request", "cannot_check", "There is a bet to face; call, fold, or raise." },
    nothing_to_call = { "400 Bad Request", "nothing_to_call", "You are already matched to the current bet." },
    already_folded = { "400 Bad Request", "already_folded", "This player has already folded." },
    raise_not_increase = { "400 Bad Request", "raise_not_increase", "Raise must increase your total contribution this street." },
    min_raise = { "400 Bad Request", "min_raise", "Raise does not meet the minimum raise size." },
    cannot_raise_self = { "400 Bad Request", "cannot_raise_self", "You cannot raise again until another player has raised." },
    stale_action = { "409 Conflict", "stale_action", "expected_action_seq does not match current hand.action_seq; refresh state and resubmit." },
    hand_idle = { "409 Conflict", "hand_idle", "No active hand; the server should start the hand before applying this action." },
    not_ready = { "409 Conflict", "not_ready", "This table is waiting for every seated player to POST /v1/tables/{id}/start before dealing the first hand." },
    token_required = { "401 Unauthorized", "token_required", "X-Player-Token header required for this action (returned by POST /v1/tables/{id}/join)." },
    token_invalid = { "403 Forbidden", "token_invalid", "X-Player-Token does not match this player_id at this table." },
  }
  local row = t[err]
  if not row then
    return { "500 Internal Server Error", api.error_body("internal", "Action failed.") }
  end
  local details = { reason = err }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      details[k] = v
    end
  end
  return { row[1], api.error_body(row[2], row[3], details) }
end

local function create_table_context(id, max_seats, opts)
  opts = opts or {}
  local new_table = poker.new_table
  local game = poker.game
  local tbl = new_table({ id = id, max_seats = max_seats or 10 })
  local ai_players = {}
  local env_buy = tonumber(os.getenv("POKER_DEFAULT_BUY_IN"))
  local buy_in = opts.buy_in_chips or env_buy or 500
  buy_in = math.max(1, math.floor(tonumber(buy_in) or 500))
  local env_at = tonumber(os.getenv("POKER_ACTION_TIMEOUT_SEC"))
  local action_timeout_sec = opts.action_timeout_sec
  if action_timeout_sec == nil then
    action_timeout_sec = env_at
  end
  if action_timeout_sec == nil then
    action_timeout_sec = 60
  end
  action_timeout_sec = math.floor(tonumber(action_timeout_sec) or 60)
  if action_timeout_sec < 0 then
    action_timeout_sec = 0
  end
  local action_timeout_mode = opts.action_timeout_mode or "eject"
  if action_timeout_mode ~= "eject" and action_timeout_mode ~= "fold_only" then
    action_timeout_mode = "eject"
  end
  --- Default grace window between "everyone ready" and "deal the hand".
  --- Bumped from 2s to 8s because the original window was easy to race:
  --- if the first 2 players to join readied quickly, slow joiners P3/P4
  --- could fall through after the gate had already released. Eight
  --- seconds gives interactive UIs a comfortable buffer; bots and tests
  --- can still tighten via `start_grace_sec` per-table or the env
  --- POKER_START_GRACE_SEC.
  local start_grace_sec = opts.start_grace_sec
  if start_grace_sec == nil then
    start_grace_sec = tonumber(os.getenv("POKER_START_GRACE_SEC")) or 8
  end
  start_grace_sec = tonumber(start_grace_sec) or 8
  if start_grace_sec < 0 then
    start_grace_sec = 0
  end
  if opts.with_ais then
    for i = 1, math.min(6, max_seats or 10) do
      local pid = "ai_" .. i
      tbl:seat_player({ seat = i, player_id = pid, chips = buy_in })
      ai_players[pid] = true
    end
  end
  local hand = game.HandState.new({
    sb_amount = opts.sb_amount or 2,
    bb_amount = opts.bb_amount or 5,
  })
  hand.status = "idle"
  return {
    tbl = tbl,
    hand = hand,
    ai_players = ai_players,
    action_queue = {},
    --- Queued actions dropped at apply-time (stale street, illegal, etc.).
    --- Keyed by player_id; consumers (e.g. the player) clear after observing.
    action_queue_drops = {},
    --- Idempotency cache: per-player, the last (client_action_id, response).
    --- Replaying a request with the same id returns the cached response
    --- instead of re-applying. Bounded to one entry per player.
    last_action_results = {},
    pending_join_count = 0,
    start_grace_sec = start_grace_sec,
    _last_join_at = nil,
    _last_start_flag_at = nil,
    --- Wall-clock time (os.clock seconds) when the first /ready signal of the
    --- current cohort arrived. Used to drive the start-timeout: once this is
    --- set, the first hand will force-start after action_timeout_sec even if
    --- some players have not yet readied -- non-ready players are ejected
    --- from the table at that moment. Cleared on hand start, when the table
    --- empties, when the last ready is rescinded, or on admin reset.
    _first_ready_at = nil,
    _prev_hand_status = nil,
    _act_turn_key = nil,
    _act_deadline = nil,
    running_bots = {},
    player_tokens = {},
    token_to_player = {},
    zero_chips = opts.zero_chips or "rebuy",
    rebuy_amount = opts.rebuy_amount or 500,
    buy_in_chips = buy_in,
    action_timeout_sec = action_timeout_sec,
    action_timeout_mode = action_timeout_mode,
    bust_counts = {}, -- player_id -> times reached 0 chips at end of hand (eject or rebuy)
    hidden = opts.hidden == true, -- if true, omitted from GET /v1/tables public list
    --- When true, the first hand after the table has been empty will not start
    --- until every seated player has signalled ready/start. Once that first
    --- hand has started, subsequent hands proceed automatically until the
    --- table becomes empty again. Admin reset also re-arms the wait.
    wait_for_ready = opts.wait_for_ready == true,
    first_hand_started = false,
    ready_players = {}, -- player_id -> true
    --- Pre-game lobby. While `wait_for_ready` is on and the cohort's first
    --- hand has not started, joins are routed here instead of `tbl:seat_player`
    --- so no chips are deducted, no positions (button/SB/BB) are assigned, and
    --- no cards are dealt. Each entry is `{ player_id, chips }` and the order
    --- preserves arrival (FIFO). Once every lobby player readies (or the
    --- start-timeout fires with at least 2 ready), any player who never
    --- readied is *ejected* from the table, the surviving lobby is shuffled
    --- and randomly seated, and only then does `start_hand` run.
    pending_seats = {},
  }
end

local IDEMPOTENCY_TTL_SEC = 60

local function lookup_idempotent(ctx, player_id, client_action_id)
  if not client_action_id or client_action_id == "" then
    return nil
  end
  local cache = ctx.last_action_results
  if not cache then
    return nil
  end
  local entry = cache[player_id]
  if not entry then
    return nil
  end
  if entry.expires_at and entry.expires_at < os.clock() then
    cache[player_id] = nil
    return nil
  end
  if entry.client_action_id ~= client_action_id then
    return nil
  end
  return entry.body
end

local function store_idempotent(ctx, player_id, client_action_id, body)
  if not client_action_id or client_action_id == "" then
    return
  end
  ctx.last_action_results = ctx.last_action_results or {}
  ctx.last_action_results[player_id] = {
    client_action_id = client_action_id,
    body = body,
    expires_at = os.clock() + IDEMPOTENCY_TTL_SEC,
  }
end

local function clear_player_action_state(ctx, player_id)
  if ctx.action_queue then
    ctx.action_queue[player_id] = nil
  end
  if ctx.action_queue_drops then
    ctx.action_queue_drops[player_id] = nil
  end
  if ctx.last_action_results then
    ctx.last_action_results[player_id] = nil
  end
  if ctx.ready_players then
    ctx.ready_players[player_id] = nil
  end
end

--- True whenever the table is configured to require explicit `/ready`
--- before dealing. While this returns true every new joiner is routed
--- into `ctx.pending_seats` instead of `tbl:seat_player`; they pay no
--- blinds, are not assigned positions, and get no cards until they POST
--- `/ready` (and the gate releases). This used to be limited to the
--- "first hand of a cohort" but the user reported that mid-hand joiners
--- could slip past the gate -- now the lobby applies continuously, so
--- *every* joiner must ready up before sitting down. AI players (which
--- the server seats up front via `with_ais`) are implicitly ready and
--- never enter the lobby.
local function lobby_active(ctx)
  return ctx and ctx.wait_for_ready == true
end

--- 1-based index of `pid` in `ctx.pending_seats`, or nil if absent.
local function lobby_index(ctx, pid)
  local list = ctx and ctx.pending_seats
  if not list or not pid then
    return nil
  end
  for i = 1, #list do
    if list[i].player_id == pid then
      return i
    end
  end
  return nil
end

--- Remove the entry for `pid` from `ctx.pending_seats` if present.
local function lobby_remove(ctx, pid)
  local idx = lobby_index(ctx, pid)
  if not idx then return false end
  table.remove(ctx.pending_seats, idx)
  if ctx.ready_players then
    ctx.ready_players[pid] = nil
  end
  if next(ctx.ready_players or {}) == nil then
    ctx._first_ready_at = nil
  end
  return true
end

--- Forward declarations for helpers defined later in the module. We need
--- them callable from the lobby-eject path which lives above their
--- definitions.
local kill_bot
local remove_player_token

--- Fully eject a pre-game player from the table: drops them from the
--- lobby and/or their seat, clears their queued actions, kills their
--- running bot (if any), and forgets their auth token. Returns true iff
--- the player was found in either place. Used by the start-timeout path
--- so non-ready players literally lose their place at the table.
local function eject_lobby_or_seat(ctx, pid)
  if not ctx or not pid then
    return false
  end
  local removed = false

  --- Lobby branch: just drop the FIFO entry. No chips were deducted, no
  --- seat assignment, so nothing on `tbl` to clean.
  if lobby_remove(ctx, pid) then
    removed = true
  end

  --- Seat branch: in case the table migrated seated humans to the lobby
  --- (or a player somehow got a seat in the pre-start window) we also
  --- clear the seat. `leave_seat` drops the player record so the seat
  --- becomes available for the lobby shuffle.
  local tbl = ctx.tbl
  if tbl then
    local seat = tbl:seat_for_player(pid)
    if seat then
      tbl:leave_seat(seat)
      removed = true
    end
  end

  if not removed then
    return false
  end

  clear_player_action_state(ctx, pid)
  if ctx.ai_players then
    ctx.ai_players[pid] = nil
  end
  if ctx.running_bots and ctx.running_bots[pid] and kill_bot then
    kill_bot(ctx.running_bots[pid].pid)
    ctx.running_bots[pid] = nil
  end
  if remove_player_token then
    remove_player_token(ctx, pid)
  end
  io.stderr:write(
    "[table:"
      .. tostring(tbl and tbl.id or "?")
      .. "] Ejected pre-game player "
      .. tostring(pid)
      .. " (failed to ready before start)\n"
  )
  return true
end

--- Eject every non-AI lobby member who has not signalled ready. Called
--- immediately before `release_lobby_to_table` so the next hand is dealt
--- only to confirmed players. Already-seated players are *not* iterated
--- here -- under the continuous-lobby model, seated players are
--- implicitly part of the game (they've been through a prior lobby) and
--- only leave via `/leave`, admin kick, the action timeout, or busting
--- out. Returns the number ejected.
local function eject_unready_pre_start(ctx)
  if not ctx or ctx.wait_for_ready ~= true then
    return 0
  end
  local readied = ctx.ready_players or {}
  local ai_players = ctx.ai_players or {}

  --- Collect victim list first (don't mutate while iterating).
  local victims = {}
  if ctx.pending_seats then
    for _, entry in ipairs(ctx.pending_seats) do
      local pid = entry.player_id
      if pid and not readied[pid] and not ai_players[pid] then
        victims[#victims + 1] = pid
      end
    end
  end

  for _, pid in ipairs(victims) do
    eject_lobby_or_seat(ctx, pid)
  end
  return #victims
end

--- When `wait_for_ready` flips on while the cohort hasn't dealt yet, any
--- players already at a seat (typically humans seated before the gate was
--- enabled) are migrated back into the pre-game lobby so they pay no
--- blinds and get no cards until they POST `/ready`. AI players stay
--- seated -- they're implicitly ready. Returns the number migrated.
local function migrate_seated_humans_to_lobby(ctx)
  if not ctx or not lobby_active(ctx) then
    return 0
  end
  local tbl = ctx.tbl
  if not tbl then return 0 end
  local ai_players = ctx.ai_players or {}
  ctx.pending_seats = ctx.pending_seats or {}
  local moved = 0
  for i = 1, tbl.max_seats do
    local s = tbl:get_seat(i)
    if s and s.player_id and not ai_players[s.player_id] then
      local pid = s.player_id
      local chips = math.max(1, math.floor(s.stack or ctx.buy_in_chips or 500))
      tbl:leave_seat(i)
      ctx.pending_seats[#ctx.pending_seats + 1] = {
        player_id = pid,
        chips = chips,
      }
      moved = moved + 1
      io.stderr:write(
        "[table:"
          .. tostring(tbl.id)
          .. "] Migrated "
          .. tostring(pid)
          .. " from seat "
          .. tostring(i)
          .. " back to pre-game lobby\n"
      )
    end
  end
  if moved > 0 then
    ctx._last_join_at = os.clock()
  end
  return moved
end

--- Fisher-Yates shuffle (in place).
local function shuffle_in_place(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

--- Release the pre-game lobby. Run when the ready gate has just opened
--- (everyone readied, or the start-timeout expired with at least two
--- ready players). The flow is:
---   1. Eject every non-AI participant who never POSTed `/ready`. They
---      lose their place at the table entirely -- no ghost seat, no
---      token, no bot. This implements the user-requested
---      "timed-out players are ejected" semantics.
---   2. Shuffle the remaining lobby into the random unoccupied seats.
---      Order of arrival is forgotten on purpose -- random table
---      placement was an explicit user requirement.
--- Returns the number of players actually seated. Players who could not
--- be seated (table somehow full) stay in the lobby and the caller
--- should re-arm.
local function release_lobby_to_table(ctx)
  if not ctx then
    return 0
  end
  local tbl = ctx.tbl
  if not tbl then return 0 end

  --- 1. Eject anyone still un-ready before any chips move or cards deal.
  ---    Idempotent if everyone readied (no-op).
  eject_unready_pre_start(ctx)

  if not ctx.pending_seats or #ctx.pending_seats == 0 then
    return 0
  end

  --- Snapshot lobby into a local list so we can shuffle and clear the
  --- canonical store atomically.
  local lobby = ctx.pending_seats
  ctx.pending_seats = {}

  --- Available seats (random order).
  local free = {}
  for i = 1, tbl.max_seats do
    if not tbl:get_seat(i) then
      free[#free + 1] = i
    end
  end
  shuffle_in_place(free)
  shuffle_in_place(lobby)

  local seated = 0
  for _, entry in ipairs(lobby) do
    local seat = table.remove(free)
    if not seat then
      --- No more seats; push the player back into the lobby. Subsequent
      --- joins on this cohort will defer per `try_join_seat`.
      ctx.pending_seats[#ctx.pending_seats + 1] = entry
    else
      local ok = tbl:seat_player({
        seat = seat,
        player_id = entry.player_id,
        chips = entry.chips,
      })
      if ok then
        seated = seated + 1
        --- Drop the per-cohort ready flag now that this player is in.
        --- Future cohorts (e.g. they leave and rejoin via lobby) will
        --- have to re-ready, which is the correct semantics.
        if ctx.ready_players then
          ctx.ready_players[entry.player_id] = nil
        end
        io.stderr:write(
          "[table:" .. tostring(tbl.id) .. "] Lobby release seated "
            .. tostring(entry.player_id) .. " at seat " .. tostring(seat) .. "\n"
        )
      else
        --- Re-queue if seat_player rejected (e.g. duplicate ID race).
        ctx.pending_seats[#ctx.pending_seats + 1] = entry
      end
    end
  end
  if seated > 0 then
    ctx._last_join_at = os.clock()
  end
  --- If the lobby is fully cleared (everyone got a seat or was ejected)
  --- reset the start-timeout so the *next* lobby cohort gets a fresh
  --- window. Stragglers (who couldn't be seated because the table is
  --- full) keep the existing timer ticking.
  if not ctx.pending_seats or #ctx.pending_seats == 0 then
    ctx._first_ready_at = nil
  end
  return seated
end

--- Classify everyone who is currently part of the table cohort -- both
--- those already seated and those still in the pre-game lobby -- into
--- "ready" (or AI, which is implicit) vs "waiting" buckets. A single
--- helper keeps `ready_gate_blocks_start`, `ready_status_snapshot`, and
--- the eject path in lock-step. Notes:
---   * Already-seated players (humans who've been through the lobby in
---     a previous cohort) do *not* need to re-ready every hand. They are
---     reported in `ready` so the snapshot/gate sees them as
---     participants who can already play.
---   * Pending-seat (lobby) entries are gated: an unready lobby joiner
---     blocks the next hand from dealing.
local function tally_ready(ctx)
  local tbl = ctx and ctx.tbl
  local seated = {}
  local ready = {}
  local waiting = {}
  local seen = {}
  if not tbl then
    return seated, ready, waiting
  end
  for i = 1, tbl.max_seats do
    local s = tbl:get_seat(i)
    if s then
      local pid = s.player_id
      seen[pid] = true
      seated[#seated + 1] = pid
      --- Seated players are considered ready by virtue of being seated.
      --- They've already been through the lobby (or were seated as AI by
      --- `with_ais`). Re-readying every hand would be hostile UX.
      ready[#ready + 1] = pid
    end
  end
  if ctx.pending_seats then
    for _, entry in ipairs(ctx.pending_seats) do
      local pid = entry.player_id
      if not seen[pid] then
        seen[pid] = true
        seated[#seated + 1] = pid
        local is_ai = ctx.ai_players and ctx.ai_players[pid]
        if (ctx.ready_players and ctx.ready_players[pid]) or is_ai then
          ready[#ready + 1] = pid
        else
          waiting[#waiting + 1] = pid
        end
      end
    end
  end
  return seated, ready, waiting
end

--- True iff the next hand should be held back because some lobby player
--- has not yet signalled ready. Applies *continuously* while
--- `wait_for_ready` is on -- not just before the very first hand. The
--- semantics:
---   * If a hand is currently active, the gate is irrelevant (a hand in
---     progress finishes regardless).
---   * If the lobby is empty and ≥ 2 players are seated, no gate -- play
---     proceeds normally between hands. New joiners during a hand land
---     in the lobby for the *next* hand.
---   * If the lobby has un-ready non-AI members, block until either
---     everyone readies or the start-timeout (= action_timeout_sec from
---     the first ready) elapses and at least two participants are ready.
---   * On release, `release_lobby_to_table` ejects un-ready non-AI
---     lobby members and shuffles the rest into random free seats.
--- The "first hand of a cohort" is now just a special case of this rule
--- -- it's the hand where the entire table is in the lobby.
local function ready_gate_blocks_start(ctx)
  if not ctx or ctx.wait_for_ready ~= true then
    return false
  end
  --- Hand in progress: gate doesn't apply to active hands. New lobby
  --- joiners simply wait for the next idle transition.
  if ctx.hand and ctx.hand.status == "active" then
    return false
  end
  local tbl = ctx.tbl
  if not tbl then
    return false
  end

  --- Inspect the lobby roster and the seated cohort.
  local seated_count = tbl:occupied_count()
  local readied = ctx.ready_players or {}
  local ai_p = ctx.ai_players or {}
  local ready_lobby = 0
  local unready_lobby = 0
  if ctx.pending_seats then
    for _, e in ipairs(ctx.pending_seats) do
      local pid = e.player_id
      if readied[pid] or ai_p[pid] then
        ready_lobby = ready_lobby + 1
      else
        unready_lobby = unready_lobby + 1
      end
    end
  end
  --- After release, who would actually be at the felt: existing seats
  --- plus the lobby members who readied (un-ready ones get ejected).
  local total_after_release = seated_count + ready_lobby

  if unready_lobby > 0 then
    --- Lobby has at least one player who hasn't readied. Block by
    --- default; the only escape is the start-timeout. Note that we
    --- count *seated_count + ready_lobby* (i.e. the post-release total)
    --- toward the "≥ 2 ready" requirement so an established 4-handed
    --- table doesn't deadlock just because a 5th joiner is mid-handshake.
    if ctx._first_ready_at then
      local timeout = tonumber(ctx.action_timeout_sec) or 0
      if timeout > 0 and total_after_release >= 2 then
        local elapsed = os.clock() - ctx._first_ready_at
        if elapsed >= timeout then
          --- Even on timeout, respect any in-flight joins/grace so we
          --- don't race against a player who is mid-handshake. They get
          --- no extension once the timer is up, but the snapshot batch
          --- settles before we eject.
          if (ctx.pending_join_count or 0) > 0 and tbl:first_available_seat() then
            return true
          end
          return false
        end
      end
    end
    return true
  end

  --- All lobby members are ready (or the lobby is empty).
  if total_after_release < 2 then
    --- Not enough participants to deal yet. Block until at least two
    --- ready/seated players are present.
    return true
  end

  --- Honour any pending join settle so a still-being-seated joiner
  --- isn't raced past the gate.
  if (ctx.pending_join_count or 0) > 0 and tbl:first_available_seat() then
    return true
  end

  --- Apply the start-grace window so back-to-back joins/readies converge
  --- before we deal. Reset by every join AND every ready in
  --- `try_join_seat` / `handle_ready_signal`. Only relevant when the
  --- lobby has at least one member; an empty-lobby + seated cohort
  --- between hands shouldn't be paused.
  local lobby_count = ready_lobby + unready_lobby
  if lobby_count > 0 then
    local grace = tonumber(ctx.start_grace_sec) or 0
    if grace > 0 then
      local last_change = math.max(ctx._last_join_at or 0, ctx._last_start_flag_at or 0)
      if last_change > 0 and (os.clock() - last_change) < grace then
        return true
      end
    end
  end
  return false
end

local function ready_status_snapshot(ctx)
  if not ctx then return nil end
  local tbl = ctx.tbl
  local seated, ready_list, waiting_list = tally_ready(ctx)

  --- Compute the time remaining on the start-timeout (if active). When
  --- nil, no timer is running yet (no readies received) or it has already
  --- elapsed; UI clients can use this to render a countdown until any
  --- still-un-ready player is ejected and the next hand begins.
  local timeout = tonumber(ctx.action_timeout_sec) or 0
  local remaining_sec = nil
  if ctx.wait_for_ready == true and ctx._first_ready_at and timeout > 0 then
    local r = timeout - (os.clock() - ctx._first_ready_at)
    if r < 0 then r = 0 end
    remaining_sec = math.floor(r + 0.5)
  end

  local pending_block = (ctx.pending_join_count or 0) > 0 and tbl and tbl:first_available_seat()
  local grace = ctx.start_grace_sec or 0
  local grace_block = false
  if grace > 0 then
    local last_change = math.max(ctx._last_join_at or 0, ctx._last_start_flag_at or 0)
    if last_change > 0 and (os.clock() - last_change) < grace then
      grace_block = true
    end
  end

  --- Lobby roster (FIFO order of arrival). Seats in this list have not been
  --- placed at the table yet -- they pay no blinds and are not dealt cards
  --- until `release_lobby_to_table` shuffles them onto random seats.
  local lobby = {}
  if ctx.pending_seats then
    for i, e in ipairs(ctx.pending_seats) do
      lobby[i] = e.player_id
    end
  end

  return {
    wait_for_ready = ctx.wait_for_ready == true,
    require_start_flags = ctx.wait_for_ready == true,
    first_hand_started = ctx.first_hand_started == true,
    --- Cosmetic for clients: true while at least one lobby member exists
    --- and the table requires ready signals. With the continuous-lobby
    --- model this can flip back to true between hands when a new player
    --- joins; it's no longer a one-shot "before the first hand" flag.
    in_lobby_phase = lobby_active(ctx) == true and #lobby > 0,
    pending_join_count = ctx.pending_join_count or 0,
    start_grace_sec = ctx.start_grace_sec or 0,
    ready_players = ready_list,
    waiting_players = waiting_list,
    --- Players who are not yet at a seat. UIs render this as a separate
    --- "waiting room" panel distinct from the felt.
    lobby_players = lobby,
    --- True when every player (seated + lobby) is ready and the table
    --- has at least two participants. Pending joins and grace still
    --- apply -- the gate may still be blocking briefly even when this
    --- is true.
    all_ready = ctx.wait_for_ready == true
      and (not pending_block)
      and (not grace_block)
      and (#waiting_list == 0)
      and (#seated >= 2),
    --- Start-timeout fields. start_timeout_sec is the maximum window
    --- (= action_timeout_sec) and start_timeout_remaining_sec ticks
    --- down once the first /ready of the current lobby cohort arrives.
    --- When it hits zero, anyone still in waiting_players is *ejected*
    --- (drops their token, bot, and lobby/seat slot) and the next hand
    --- starts with the remaining ready cohort, provided at least two
    --- participants are ready.
    start_timeout_sec = (ctx.wait_for_ready == true) and timeout or 0,
    start_timeout_remaining_sec = remaining_sec,
    first_ready_received = ctx._first_ready_at ~= nil,
  }
end

local function rearm_start_gate_if_empty(ctx)
  if not ctx or not ctx.tbl then return false end
  if ctx.tbl:occupied_count() > 0 then return false end
  if ctx.pending_seats and #ctx.pending_seats > 0 then return false end

  --- A completely empty table starts a new cohort. If wait_for_ready is on,
  --- the next cohort must explicitly signal before its first hand; if it is
  --- off, normal auto-start resumes as soon as two seats are occupied.
  if ctx.hand and ctx.hand.status ~= "idle" then
    ctx.hand:_reset_between_hands()
    ctx.hand.last_button_seat = nil
  end
  ctx.first_hand_started = false
  ctx.ready_players = {}
  ctx.pending_seats = {}
  ctx.action_queue = {}
  ctx.action_queue_drops = {}
  ctx.last_action_results = {}
  ctx._prev_hand_status = nil
  ctx._act_turn_key = nil
  ctx._act_deadline = nil
  ctx._last_join_at = nil
  ctx._last_start_flag_at = nil
  ctx._first_ready_at = nil
  return true
end

math.randomseed(os.time() + math.floor(os.clock() * 10000))

local function generate_player_token()
  local chars = {}
  for i = 1, 32 do
    chars[i] = string.format("%02x", math.random(0, 255))
  end
  return table.concat(chars)
end

local function resolve_auth_player(req, ctx)
  local token = req.headers and req.headers["x-player-token"]
  if not token or token == "" then return nil end
  return ctx.token_to_player[token]
end

local function filter_snapshot_for_player(snap, auth_pid, tbl)
  if not snap or not snap.hand then return snap end
  local hc = snap.hand.hole_cards
  if not hc or type(hc) ~= "table" then return snap end
  if not auth_pid then
    snap.hand.hole_cards = {}
    return snap
  end
  local seat = tbl:seat_for_player(auth_pid)
  local filtered = {}
  if seat then
    filtered[tostring(seat)] = hc[tostring(seat)]
  end
  snap.hand.hole_cards = filtered
  return snap
end

--- Defined here (assigning into the forward `local` declared up top so
--- `eject_lobby_or_seat` can call it).
function remove_player_token(ctx, player_id)
  local old = ctx.player_tokens[player_id]
  if old then
    ctx.token_to_player[old] = nil
    ctx.player_tokens[player_id] = nil
  end
end

local function create_server_state()
  return {
    tables = {
      demo = create_table_context("demo", 10, {
        with_ais = true,
        buy_in_chips = 1000,
        hidden = true, -- omit from GET /v1/tables; admins still see it in /admin/api/tables
      }),
      players = create_table_context("players", 10, {
        buy_in_chips = 500,
        rebuy_amount = 500,
        zero_chips = "rebuy",
        action_timeout_sec = 30,
        action_timeout_mode = "fold_only",
      }),
    },
    pending_joins = {},
    api_request_log = {},
    api_request_log_seq = 0,
    --- When true, POST /actions with queue omitted returns wrong_turn if not your turn (active hand).
    strict_action_queue = false,
  }
end

--- Ring buffer of recent HTTP requests (newest first). Used by admin UI and optional env POKER_API_LOG_MAX.
local function append_api_request_log(state, entry)
  if not state or not entry then
    return
  end
  state.api_request_log_seq = (state.api_request_log_seq or 0) + 1
  entry.seq = state.api_request_log_seq
  entry.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local log = state.api_request_log
  if not log then
    state.api_request_log = {}
    log = state.api_request_log
  end
  table.insert(log, 1, entry)
  local cap = tonumber(os.getenv("POKER_API_LOG_MAX") or "500") or 500
  while #log > cap do
    table.remove(log)
  end
end

local function detect_lang(filename, content)
  if filename and filename:match("%.lua$") then return "lua" end
  if filename and filename:match("%.py$")  then return "python" end
  if content and content:match("^#!.-python") then return "python" end
  if content and content:match("^%-%-") then return "lua" end
  if content and content:match("def%s+decide%s*%(") then return "python" end
  if content and content:match("function%s+decide%s*%(") then return "lua" end
  return "python"
end

local function spawn_bot(root, lang, bot_file, player_id, table_id, port, buy_in_chips)
  buy_in_chips = math.max(1, math.floor(tonumber(buy_in_chips) or 500))
  local cmd
  local url = "http://127.0.0.1:" .. tostring(port)
  if lang == "lua" then
    cmd = string.format(
      "lua -e 'package.path=\"%s/src/?.lua;%s/src/?/init.lua;\"..package.path' %q --name %q --url %q --chips %d 2>&1 &\necho $!",
      root, root, bot_file, player_id, url, buy_in_chips
    )
  else
    cmd = string.format(
      "python3 %q %q --name %q --table %q --url %q --chips %d 2>&1 &\necho $!",
      root .. "/clients/python/bot_runner.py",
      bot_file, player_id, table_id, url, buy_in_chips
    )
  end
  local h = io.popen(cmd, "r")
  if not h then return nil end
  local output = h:read("*a")
  h:close()
  local pid = output:match("(%d+)%s*$")
  return pid and tonumber(pid) or nil
end

--- Assigning into the forward `local` declared up top so
--- `eject_lobby_or_seat` can call it.
function kill_bot(pid)
  os.execute("kill " .. tostring(pid) .. " 2>/dev/null")
end

local function validate_action_shape(action, amount)
  action = string.lower(tostring(action or ""))
  if
    action ~= "fold"
    and action ~= "check"
    and action ~= "call"
    and action ~= "raise"
    and action ~= "bet"
    and action ~= "all_in"
  then
    return nil, "invalid_action"
  end
  if action == "raise" or action == "bet" then
    if amount == nil then
      return nil, "amount_required"
    end
    local a = math.floor(tonumber(amount) or 0)
    if a < 1 then
      return nil, "invalid_amount"
    end
    return { action = action, amount = a }, nil
  end
  return { action = action, amount = nil }, nil
end

--- Queue metadata: idle queues (and queues from a player who isn't in the
--- current hand) apply after the next start_hand; active queues are tagged
--- with hand.street so precached actions cannot fire on a later betting
--- round of the same hand.
local function queue_entry(act, amt, hand, in_current_hand, expected_seq)
  local entry
  if hand.status == "idle" or not in_current_hand then
    entry = { action = act, amount = amt, while_idle = true }
  else
    entry = { action = act, amount = amt, street = hand.street }
  end
  if hand.status == "active" and expected_seq ~= nil then
    entry.expected_action_seq = tonumber(expected_seq)
  end
  return entry
end

--- @return "applied"|"queued"|nil, err [, err_details]
local function submit_action(ctx, player_id, action, amount, queue, strict_queue, opts)
  opts = opts or {}
  local expected_seq = opts.expected_action_seq

  local tbl = ctx.tbl
  local hand = ctx.hand
  local q = queue == true
  local qfalse = queue == false
  strict_queue = strict_queue == true

  local ent, verr = validate_action_shape(action, amount)
  if not ent then
    return nil, verr
  end
  local act, amt = ent.action, ent.amount

  local seat = tbl:seat_for_player(player_id)
  if not seat then
    --- Lobby (pre-game): the player joined but has not been shuffled into
    --- a seat yet. They cannot act on a hand that has not been dealt; the
    --- only valid pre-game call for them is `/ready`.
    if lobby_index(ctx, player_id) then
      return nil, "not_ready"
    end
    return nil, "not_seated"
  end

  if hand.status == "active" and hand.folded[seat] then
    return nil, "already_folded"
  end

  --- True iff this player is in the *currently active* hand. Players who
  --- joined mid-hand are not (they wait for the next deal).
  local in_current_hand = hand:is_seat_in_hand(seat)

  --- Refuse to apply now if the client's view of action_seq is stale.
  --- Only checked when we'd actually apply this turn (not when queuing).
  local function check_seq_for_apply()
    if expected_seq == nil then
      return nil
    end
    if hand.status ~= "active" then
      return nil
    end
    local expect_n = tonumber(expected_seq)
    if not expect_n then
      return "invalid_amount"
    end
    if hand.seq ~= expect_n then
      return "stale_action", { current_seq = hand.seq, expected_seq = expect_n }
    end
    return nil
  end

  --- While the "first hand" ready gate is still blocking, actions cannot
  --- force the hand to start. Queue them so they fire automatically on the
  --- deal, or refuse them if the caller explicitly asked for non-queued.
  if hand.status == "idle" and ready_gate_blocks_start(ctx) then
    if qfalse then
      return nil, "not_ready"
    end
    ctx.action_queue[player_id] = queue_entry(act, amt, hand, in_current_hand, expected_seq)
    return "queued"
  end

  if q and hand.status == "idle" then
    ctx.action_queue[player_id] = queue_entry(act, amt, hand, in_current_hand, expected_seq)
    return "queued"
  end

  if q and hand.status == "active" then
    if hand.action_to_seat == seat and in_current_hand then
      local serr, sdetails = check_seq_for_apply()
      if serr then
        return nil, serr, sdetails
      end
      local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
      if not ok then
        return nil, err2
      end
      ctx.action_queue[player_id] = nil
      return "applied"
    end
    ctx.action_queue[player_id] = queue_entry(act, amt, hand, in_current_hand, expected_seq)
    return "queued"
  end

  if hand.status == "idle" then
    --- Release the pre-game cohort before starting a hand. This ejects
    --- any non-ready non-AI lobby members and shuffles the surviving
    --- lobby into random free seats so `start_hand` deals only to
    --- confirmed players. Runs on every idle->next-hand transition so
    --- mid-hand joiners also get gated. For non-`wait_for_ready` tables
    --- this is a no-op. `ready_gate_blocks_start` has already returned
    --- false to reach here.
    if ctx.wait_for_ready == true then
      release_lobby_to_table(ctx)
      --- Caller might have just been ejected by release_lobby_to_table
      --- (e.g. an unready non-AI player still on the seat got purged).
      --- Re-check seat.
      seat = tbl:seat_for_player(player_id)
      if not seat then
        return nil, "not_seated"
      end
    end
    local first, perr = hand:peek_first_actor(tbl)
    if not first then
      return nil, perr
    end
    if first == seat then
      --- apply_action no longer auto-starts an idle hand (that bypassed the
      --- ready gate and pre-start ejection). Mirror ai.run_until_human.
      local ok_sh, err_sh = hand:start_hand(tbl)
      if not ok_sh then
        return nil, err_sh
      end
      ai.after_start_hand_pre_start_eject(ctx)
      ctx.first_hand_started = true
      ctx._first_ready_at = nil
      local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
      if not ok then
        return nil, err2
      end
      ctx.action_queue[player_id] = nil
      return "applied"
    end
    ctx.action_queue[player_id] = queue_entry(act, amt, hand, in_current_hand, expected_seq)
    return "queued"
  end

  --- hand.status == "active". If this player isn't in the current hand
  --- (mid-hand join), they cannot act now — queue for next deal or refuse
  --- per queue=false / strict_queue.
  if not in_current_hand then
    if qfalse then
      return nil, "wrong_turn"
    end
    if strict_queue then
      return nil, "wrong_turn"
    end
    ctx.action_queue[player_id] = queue_entry(act, amt, hand, false, expected_seq)
    return "queued"
  end

  if hand.action_to_seat == seat then
    local serr, sdetails = check_seq_for_apply()
    if serr then
      return nil, serr, sdetails
    end
    local ok, err2 = hand:apply_action(tbl, player_id, act, amt)
    if not ok then
      return nil, err2
    end
    ctx.action_queue[player_id] = nil
    return "applied"
  end

  if qfalse then
    return nil, "wrong_turn"
  end
  if strict_queue and hand.status == "active" then
    return nil, "wrong_turn"
  end
  ctx.action_queue[player_id] = queue_entry(act, amt, hand, in_current_hand, expected_seq)
  return "queued"
end

local function eject_action_timeout(ctx, player_id, seat)
  local hand = ctx.hand
  if hand.status == "active" and hand.action_to_seat == seat and not hand.folded[seat] then
    local ok, err = hand:apply_action(ctx.tbl, player_id, "fold", nil)
    if not ok then
      io.stderr:write("[table:" .. ctx.tbl.id .. "] action timeout fold failed: " .. tostring(err) .. "\n")
      hand.folded[seat] = true
      hand.pending[seat] = nil
      if hand.action_to_seat == seat then
        hand:_after_action(ctx.tbl, seat)
      end
    end
  end
  ctx.tbl:leave_seat(seat)
  clear_player_action_state(ctx, player_id)
  remove_player_token(ctx, player_id)
  rearm_start_gate_if_empty(ctx)
  if ctx.running_bots and ctx.running_bots[player_id] then
    kill_bot(ctx.running_bots[player_id].pid)
    ctx.running_bots[player_id] = nil
  end
  if ctx.ai_players then
    ctx.ai_players[player_id] = nil
  end
end

local function check_action_timeout(ctx)
  local hand = ctx.hand
  local sec = ctx.action_timeout_sec or 0
  if sec <= 0 or hand.status ~= "active" or not hand.action_to_seat then
    ctx._act_turn_key = nil
    ctx._act_deadline = nil
    return
  end
  local seat = hand.action_to_seat
  local row = ctx.tbl:get_seat(seat)
  if not row then
    ctx._act_turn_key = nil
    ctx._act_deadline = nil
    return
  end
  local pid = row.player_id
  if ctx.ai_players and ctx.ai_players[pid] then
    ctx._act_turn_key = nil
    ctx._act_deadline = nil
    return
  end

  local key = tostring(seat) .. ":" .. tostring(hand.street) .. ":" .. tostring(hand.seq)
  if ctx._act_turn_key ~= key then
    ctx._act_turn_key = key
    ctx._act_deadline = os.clock() + sec
    return
  end

  if os.clock() < (ctx._act_deadline or math.huge) then
    return
  end

  ctx._act_turn_key = nil
  ctx._act_deadline = nil

  local mode = ctx.action_timeout_mode or "eject"
  io.stderr:write(
    "[table:"
      .. ctx.tbl.id
      .. "] Action timeout ("
      .. tostring(sec)
      .. "s) for "
      .. tostring(pid)
      .. " mode="
      .. tostring(mode)
      .. "\n"
  )

  if mode == "fold_only" then
    if hand.action_to_seat == seat and not hand.folded[seat] then
      local ok, err = hand:apply_action(ctx.tbl, pid, "fold", nil)
      if not ok then
        io.stderr:write("[table:" .. ctx.tbl.id .. "] timeout fold_only failed: " .. tostring(err) .. "\n")
      end
    end
    if ctx.action_queue then
      ctx.action_queue[pid] = nil
    end
    if ctx.action_queue_drops then
      ctx.action_queue_drops[pid] = nil
    end
    return
  end

  eject_action_timeout(ctx, pid, seat)
end

local function handle_zero_chips(ctx)
  for i = 1, ctx.tbl.max_seats do
    local s = ctx.tbl:get_seat(i)
    if s and s.stack <= 0 then
      local pid = s.player_id
      ctx.bust_counts = ctx.bust_counts or {}
      ctx.bust_counts[pid] = (ctx.bust_counts[pid] or 0) + 1
      if ctx.zero_chips == "eject" then
        ctx.tbl:leave_seat(i)
        clear_player_action_state(ctx, pid)
        remove_player_token(ctx, pid)
        if ctx.ai_players then ctx.ai_players[pid] = nil end
        if ctx.running_bots and ctx.running_bots[pid] then
          kill_bot(ctx.running_bots[pid].pid)
          ctx.running_bots[pid] = nil
        end
        io.stderr:write("[table:" .. ctx.tbl.id .. "] Ejected " .. pid .. " (zero chips)\n")
      else
        s.stack = ctx.rebuy_amount or 500
        io.stderr:write("[table:" .. ctx.tbl.id .. "] Rebuy " .. pid .. " -> " .. tostring(s.stack) .. " chips\n")
      end
    end
  end
  rearm_start_gate_if_empty(ctx)
end

local function table_snapshot(ctx)
  local h = ctx.hand
  if ctx._prev_hand_status == "active" and h.status == "idle" then
    ctx.action_queue = {}
    handle_zero_chips(ctx)
  end
  if h.status == "active" then
    --- Defensive: any code path that actually dealt a hand clears the
    --- "wait for ready" gate, even if start_hand was called somewhere other
    --- than ai.run_until_human.
    ctx.first_hand_started = true
  end
  ctx._prev_hand_status = h.status
  check_action_timeout(ctx)
  rearm_start_gate_if_empty(ctx)
  if not ready_gate_blocks_start(ctx) then
    --- Pre-game lobby release. With `wait_for_ready` on, every joiner
    --- is queued in `pending_seats` until the gate opens; the moment it
    --- does we (a) eject anyone who never readied (start-timeout fired)
    --- and (b) shuffle the surviving lobby into random free seats so
    --- `start_hand` (run inside `ai.run_until_human`) deals only to
    --- confirmed players. We run this on *every* idle->next-hand
    --- transition (not just the first hand) so mid-hand joiners also
    --- have to ready before they get dealt in. For non-`wait_for_ready`
    --- tables this is a no-op.
    if ctx.wait_for_ready == true and ctx.hand.status == "idle" then
      release_lobby_to_table(ctx)
    end
    ai.run_until_human(ctx)
  end
  local snap = api.table_state_snapshot(ctx.tbl, ctx.hand, ctx.action_queue, ctx.action_queue_drops)
  snap.zero_chips = ctx.zero_chips
  snap.rebuy_amount = ctx.rebuy_amount
  snap.buy_in_chips = ctx.buy_in_chips
  snap.action_timeout_sec = ctx.action_timeout_sec
  snap.action_timeout_mode = ctx.action_timeout_mode
  snap.ready = ready_status_snapshot(ctx)
  local hh = ctx.hand
  if
    ctx.action_timeout_sec
    and ctx.action_timeout_sec > 0
    and hh.status == "active"
    and hh.action_to_seat
    and ctx._act_deadline
  then
    local s = hh.action_to_seat
    local r = ctx.tbl:get_seat(s)
    if r and not (ctx.ai_players and ctx.ai_players[r.player_id]) then
      snap.action_deadline_remaining_sec = math.max(0, math.ceil(ctx._act_deadline - os.clock()))
    end
  end
  return snap
end

local function run_cli()
  local state = create_server_state()
  local ctx = state.tables.demo
  local snap = table_snapshot(ctx)
  print(json.encode(snap))
end

local function run_http()
  local http_mod = poker.http_server()
  local socket_ok, socket = pcall(require, "socket")
  local state = create_server_state()
  local root = script_dir()

  local function pending_client_closed(client)
    if not socket_ok then
      return false
    end
    local r, sel_err = socket.select({ client }, nil, 0)
    if sel_err or not r or #r == 0 then
      return false
    end
    client:settimeout(0)
    local chunk, err = client:receive(1)
    if chunk == nil and err == "closed" then
      return true
    end
    if chunk ~= nil then
      return true
    end
    return false
  end

  local function join_response_success(c, player_id)
    remove_player_token(c, player_id)
    local token = generate_player_token()
    c.player_tokens[player_id] = token
    c.token_to_player[token] = player_id
    return {
      ok = true,
      token = token,
      table = filter_snapshot_for_player(table_snapshot(c), player_id, c.tbl),
    }
  end

  local function count_pending_joins_for_table(s, c)
    local n = 0
    for _, pj in ipairs((s and s.pending_joins) or {}) do
      if pj.ctx == c then
        n = n + 1
      end
    end
    return n
  end

  local function has_prior_pending_join_for_table(s, c)
    return count_pending_joins_for_table(s, c) > 0
  end

  --- @return "ok", body_tbl | "defer" | "error", err_pack
  local function try_join_seat(c, j, from_pending)
    local player_id = tostring(j.player_id)
    if c.tbl:seat_for_player(player_id) then
      return "error", join_http_error("already_seated")
    end
    if lobby_index(c, player_id) then
      return "error", join_http_error("already_seated")
    end
    if not from_pending and has_prior_pending_join_for_table(state, c) then
      return "defer"
    end

    local buy_in = math.max(1, math.floor(tonumber(c.buy_in_chips) or 500))

    --- Pre-game lobby: when `wait_for_ready` is on, *every* join lands
    --- in `pending_seats` rather than being placed at a specific seat
    --- -- this applies before the first hand and continuously between
    --- later hands too, so a mid-game joiner is gated like any other
    --- new player. Chips are not deducted, no button/SB/BB position is
    --- assigned, and no cards are dealt. The shuffle and actual
    --- `seat_player` happens in `release_lobby_to_table` once every
    --- lobby member has POSTed `/ready` (or the start-timeout fires
    --- with at least 2 ready, ejecting the un-ready rest). The optional
    --- `seat` field on the request is ignored in lobby mode --
    --- placements are random by design.
    if lobby_active(c) then
      if c.tbl:occupied_count() + #c.pending_seats >= c.tbl.max_seats then
        return "defer"
      end
      c.pending_seats[#c.pending_seats + 1] = {
        player_id = player_id,
        chips = buy_in,
      }
      c._last_join_at = os.clock()
      return "ok", join_response_success(c, player_id)
    end

    local seat_raw = j.seat
    local seat
    if seat_raw == nil or seat_raw == "" then
      seat = c.tbl:first_available_seat()
      if not seat then
        return "defer"
      end
    else
      seat = tonumber(seat_raw)
      if not seat or seat ~= math.floor(seat) then
        return "error", {
          "400 Bad Request",
          api.error_body(
            "bad_request",
            "seat must be an integer between 1 and max_seats, or omitted for the first available seat."
          ),
        }
      end
      seat = math.floor(seat)
      if c.tbl.seats[seat] then
        return "defer"
      end
    end
    --- Mid-hand joins are allowed: the player takes the seat now and is
    --- dealt in at the next start_hand. Their action submissions during
    --- the in-progress hand are queued (while_idle=true) per submit_action.
    local ok, err = c.tbl:seat_player({
      seat = seat,
      player_id = player_id,
      chips = buy_in,
    })
    if not ok then
      if err == "seat_taken" or err == "table_full" then
        return "defer"
      end
      return "error", join_http_error(err)
    end
    c._last_join_at = os.clock()
    return "ok", join_response_success(c, player_id)
  end

  local function process_pending_join_entry(pj)
    local client = pj.client
    local j = pj.json
    local c = pj.ctx

    if pending_client_closed(client) then
      pcall(function()
        client:close()
      end)
      return true
    end

    if os.clock() >= pj.deadline then
      http_mod.send_json_response(
        client,
        "408 Request Timeout",
        api.error_body(
          "join_timeout",
          "Timed out waiting to join. A seat opens between hands when the table is not full."
        )
      )
      append_api_request_log(state, {
        method = "POST",
        path = "/v1/tables/" .. tostring(c.tbl.id) .. "/join",
        status = 408,
        status_line = "408 Request Timeout",
        kind = "join_deferred",
        table_id = tostring(c.tbl.id),
        player_id = j and j.player_id and tostring(j.player_id) or nil,
      })
      pcall(function()
        client:close()
      end)
      return true
    end

    local kind, payload = try_join_seat(c, j, true)
    if kind == "defer" then
      return false
    end
    if kind == "error" then
      http_mod.send_json_response(client, payload[1], payload[2])
      append_api_request_log(state, {
        method = "POST",
        path = "/v1/tables/" .. tostring(c.tbl.id) .. "/join",
        status = tonumber((payload[1] or ""):match("^(%d%d%d)")) or 0,
        status_line = payload[1],
        kind = "join_deferred",
        table_id = tostring(c.tbl.id),
        player_id = j and j.player_id and tostring(j.player_id) or nil,
      })
      pcall(function()
        client:close()
      end)
      return true
    end
    http_mod.send_json_response(client, "200 OK", payload)
    append_api_request_log(state, {
      method = "POST",
      path = "/v1/tables/" .. tostring(c.tbl.id) .. "/join",
      status = 200,
      status_line = "200 OK",
      kind = "join_deferred",
      table_id = tostring(c.tbl.id),
      player_id = j and j.player_id and tostring(j.player_id) or nil,
    })
    pcall(function()
      client:close()
    end)
    return true
  end

  local function process_pending_joins(srv)
    local s = srv.get_context()
    for _, ctx in pairs(s.tables) do
      ctx.pending_join_count = count_pending_joins_for_table(s, ctx)
    end
    for _, ctx in pairs(s.tables) do
      table_snapshot(ctx)
    end
    local i = 1
    local blocked_tables = {}
    while i <= #s.pending_joins do
      local pj = s.pending_joins[i]
      if pj and blocked_tables[pj.ctx] then
        i = i + 1
      elseif process_pending_join_entry(pj) then
        table.remove(s.pending_joins, i)
      else
        if pj and pj.ctx then
          blocked_tables[pj.ctx] = true
        end
        i = i + 1
      end
    end
    for _, ctx in pairs(s.tables) do
      ctx.pending_join_count = count_pending_joins_for_table(s, ctx)
    end
  end

  --- Fill table_id / player_id when present in path, JSON body, or X-Player-Token (per-table session).
  local function request_log_enrich(entry, req)
    local path = req.path or ""
    local tid = path:match("^/v1/tables/([^/]+)/") or path:match("^/admin/api/tables/([^/]+)/")
    if not tid and type(req.json) == "table" and req.json.table_id then
      tid = tostring(req.json.table_id)
    end
    if tid then
      entry.table_id = tid
    end
    local pid = nil
    if type(req.json) == "table" then
      local jp = req.json.player_id
      if jp and tostring(jp) ~= "" then
        pid = tostring(jp)
      end
    end
    if not pid then
      local tok = req.headers and req.headers["x-player-token"]
      if tok and tok ~= "" and tid then
        local c = state.tables and state.tables[tid]
        if c and c.token_to_player then
          pid = c.token_to_player[tok]
        end
      end
    end
    if pid then
      entry.player_id = pid
    end
  end

  local function on_request_log(entry)
    local p = entry.path or ""
    if p:match("^/admin/api/request%-log") then
      return
    end
    append_api_request_log(state, entry)
  end

  local srv, err = http_mod.new({
    host = os.getenv("POKER_HOST") or "*",
    port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080,
    get_context = function()
      return state
    end,
    static_root = root .. "/frontend",
    tick = process_pending_joins,
    on_request_log = on_request_log,
    request_log_enrich = request_log_enrich,
  })

  local function resolve_table(params, s)
    s = s or state
    local tid = params.table_id
    if not tid then return nil end
    return s.tables[tid]
  end
  if not srv then
    io.stderr:write(err .. "\n")
    io.stderr:write("Tip: luarocks install luasocket  (or your distro's lua-socket package)\n")
    io.stderr:write("Running CLI snapshot instead:\n")
    run_cli()
    return
  end

  --- Must be defined before routes that call it. Admin cookie OR POKER_SPECTATE_SECRET (header / query).
  local function spectate_authorized(req)
    local admin_email = os.getenv("ADMIN_EMAIL") or ""
    if admin_email ~= "" then
      local sess = admin_auth.validate_session(req, admin_email)
      if sess then
        return true
      end
    end
    local secret = os.getenv("POKER_SPECTATE_SECRET") or ""
    if secret ~= "" then
      local h = req.headers or {}
      local sent = h["x-spectate-secret"] or h["x-spectate-key"] or ""
      if type(sent) == "string" and sent ~= "" then
        sent = sent:match("^%s*(.-)%s*$") or sent
        if sent == secret then
          return true
        end
      end
      local q = req.query or {}
      local qk = q.spectate_key or q.key
      if qk and qk == secret then
        return true
      end
    end
    return false
  end

  srv:route("GET", "/health", function()
    return api.health()
  end)

  local not_found_table = { "404 Not Found", api.error_body("not_found", "unknown table") }

  srv:route("GET", "/v1/tables", function(_, _, s)
    local list = {}
    for tid, ctx in pairs(s.tables) do
      if not ctx.hidden then
        list[#list + 1] = {
          table_id = tid,
          max_seats = ctx.tbl.max_seats,
          seated = ctx.tbl:occupied_count(),
          hand_status = ctx.hand.status,
          buy_in_chips = ctx.buy_in_chips,
          wait_for_ready = ctx.wait_for_ready == true,
          require_start_flags = ctx.wait_for_ready == true,
          first_hand_started = ctx.first_hand_started == true,
          pending_join_count = ctx.pending_join_count or 0,
        }
      end
    end
    return { ok = true, tables = list }
  end)

  srv:route("GET", "/v1/tables/:id/state", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    local q = req.query or {}
    local want_spectate = q.spectate == "1" or q.spectate == "true"
    if want_spectate then
      if not spectate_authorized(req) then
        return {
          "401 Unauthorized",
          api.error_body(
            "spectate_denied",
            "Spectate denied. Sign in at /admin (same browser), or set env POKER_SPECTATE_SECRET and pass it via X-Spectate-Secret or ?spectate_key= on the request."
          ),
        }
      end
      return table_snapshot(c)
    end
    local auth_pid = resolve_auth_player(req, c)
    return filter_snapshot_for_player(table_snapshot(c), auth_pid, c.tbl)
  end)

  --- Minimal response: whether the authenticated player must act now.
  --- Requires X-Player-Token from POST .../join.
  srv:route("GET", "/v1/tables/:id/my-turn", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    local auth_pid = resolve_auth_player(req, c)
    if not auth_pid then
      return {
        "401 Unauthorized",
        api.error_body(
          "unauthorized",
          "X-Player-Token header required (returned by POST /v1/tables/{id}/join)."
        ),
      }
    end
    table_snapshot(c)
    local seat = c.tbl:seat_for_player(auth_pid)
    if not seat then
      return {
        "404 Not Found",
        api.error_body("not_seated", "Token player is not seated at this table."),
      }
    end
    local h = c.hand
    local ats = h.action_to_seat
    local is_my_turn = h.status == "active" and ats ~= nil and ats == seat
    return { ok = true, player_id = auth_pid, is_my_turn = is_my_turn }
  end)

  srv:route("POST", "/v1/tables/:id/join", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body(
          "bad_request",
          "JSON body required with player_id; seat is optional. Starting stack is the table buy_in_chips (see GET state).",
          { fields = { "player_id", "seat" } }
        ),
      }
    end
    local j = req.json
    local player_id = j.player_id
    if not player_id or tostring(player_id) == "" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "player_id is required."),
      }
    end
    local kind, payload = try_join_seat(c, j)
    if kind == "ok" then
      return payload
    end
    if kind == "error" then
      return payload
    end
    return { __defer_join = true, ctx = c, json = j }
  end)

  --- Signal that a seated player is ready/start-confirmed for the first hand
  --- of the current table cohort. Body: `{ player_id, ready? }`. `ready`
  --- defaults to true; pass `false` to withdraw.
  --- Requires `X-Player-Token` matching `player_id` (same auth model as
  --- `POST /actions`). Once a cohort's first hand has been dealt this endpoint
  --- is still accepted but has no effect until the table becomes empty again.
  local function handle_ready_signal(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body(
          "bad_request",
          "JSON body required with player_id (and optional boolean ready, default true)."
        ),
      }
    end
    local j = req.json
    local player_id = j.player_id
    if not player_id or tostring(player_id) == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required and non-empty."),
      }
    end
    player_id = tostring(player_id)

    --- Accept readies from either seated players or pre-game lobby players.
    --- The lobby is the normal case under `wait_for_ready` -- players join
    --- the lobby first, ready up, and only then get shuffled into seats.
    local seat = c.tbl:seat_for_player(player_id)
    local in_lobby = lobby_index(c, player_id) ~= nil
    if not seat and not in_lobby then
      return {
        "404 Not Found",
        api.error_body("not_seated", "Player is not at this table (and not in the pre-game lobby)."),
      }
    end

    local auth_pid = resolve_auth_player(req, c)
    if not auth_pid then
      return {
        "401 Unauthorized",
        api.error_body(
          "token_required",
          "X-Player-Token header required (returned by POST /v1/tables/{id}/join)."
        ),
      }
    end
    if auth_pid ~= player_id then
      return {
        "403 Forbidden",
        api.error_body(
          "token_invalid",
          "X-Player-Token does not match the player_id in the request body."
        ),
      }
    end

    --- Optional, defaults to true. Accepts bool or the strings
    --- "true"/"false"/"1"/"0" for lenient clients.
    local ready_flag = j.ready
    if ready_flag == nil then
      ready_flag = true
    elseif type(ready_flag) == "string" then
      local lv = string.lower(ready_flag)
      ready_flag = (lv == "true" or lv == "1" or lv == "yes")
    else
      ready_flag = ready_flag == true
    end

    c.ready_players = c.ready_players or {}
    if ready_flag then
      c.ready_players[player_id] = true
      --- Start the start-timeout countdown on the very first ready signal
      --- of the current lobby cohort. Subsequent readies do not reset
      --- it; if a join arrives after the timer started the new player
      --- still gets the remaining window to ready up before being
      --- ejected. The timer is cleared when `release_lobby_to_table`
      --- empties the lobby, when the table empties, or when the last
      --- ready in the lobby is rescinded.
      if not c._first_ready_at then
        c._first_ready_at = os.clock()
      end
    else
      c.ready_players[player_id] = nil
      --- If the un-ready signal removed the last ready flag, cancel the
      --- start-timeout so we don't eject an empty cohort the moment the
      --- next player readies.
      if next(c.ready_players) == nil then
        c._first_ready_at = nil
      end
    end
    c._last_start_flag_at = os.clock()

    return {
      ok = true,
      player_id = player_id,
      ready = ready_flag,
      ready_status = ready_status_snapshot(c),
      table = filter_snapshot_for_player(table_snapshot(c), player_id, c.tbl),
    }
  end

  srv:route("POST", "/v1/tables/:id/ready", handle_ready_signal)
  srv:route("POST", "/v1/tables/:id/start", handle_ready_signal)
  srv:route("POST", "/v1/tables/:id/start-flag", handle_ready_signal)

  srv:route("POST", "/v1/tables/:id/leave", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id."),
      }
    end
    local player_id = req.json.player_id
    if not player_id or player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required and non-empty."),
      }
    end
    player_id = tostring(player_id)
    local seat = c.tbl:seat_for_player(player_id)
    if not seat then
      --- Lobby leave: drop the FIFO entry, drop the token, re-arm if the
      --- table is now completely empty (no seats and no lobby entries).
      if lobby_remove(c, player_id) then
        clear_player_action_state(c, player_id)
        remove_player_token(c, player_id)
        rearm_start_gate_if_empty(c)
        return {
          ok = true,
          table = filter_snapshot_for_player(table_snapshot(c), nil, c.tbl),
        }
      end
      return {
        "404 Not Found",
        api.error_body("not_seated", "Player is not at this table."),
      }
    end
    if c.hand.status == "active" and c.hand.folded and not c.hand.folded[seat] then
      c.hand.folded[seat] = true
      c.hand.pending[seat] = nil
      if c.hand.action_to_seat == seat then
        c.hand:_after_action(c.tbl, seat)
      end
    end
    c.tbl:leave_seat(seat)
    clear_player_action_state(c, player_id)
    remove_player_token(c, player_id)
    rearm_start_gate_if_empty(c)
    return {
      ok = true,
      table = filter_snapshot_for_player(table_snapshot(c), nil, c.tbl),
    }
  end)

  srv:route("POST", "/v1/tables/:id/actions", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body(
          "bad_request",
          "JSON body required with player_id and action.",
          { fields = { "player_id", "action", "amount" } }
        ),
      }
    end
    local j = req.json
    local player_id = j.player_id
    local action = j.action
    if not player_id or not action then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "player_id and action are required."),
      }
    end
    local amount = j.amount
    if amount ~= nil then
      amount = tonumber(amount)
    end
    local q = j.queue
    if q ~= nil and type(q) ~= "boolean" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "queue must be a boolean if provided."),
      }
    end
    local pid_str = tostring(player_id)

    --- Token enforcement on actions: the server issues a per-player token at
    --- POST /join; without it any unauthenticated client could submit moves
    --- as any seated player. If the player is currently seated we require the
    --- header to match; if they are not seated yet we still let the request
    --- through (it'll fail with not_seated below) so spoofing a missing
    --- player can't be silently turned into a permission error.
    local raw_token = req.headers and req.headers["x-player-token"]
    local seated_seat = c.tbl:seat_for_player(pid_str)
    if seated_seat then
      if not raw_token or raw_token == "" then
        return action_http_error("token_required")
      end
      local mapped = c.token_to_player and c.token_to_player[raw_token] or nil
      if mapped ~= pid_str then
        return action_http_error("token_invalid")
      end
    elseif raw_token and raw_token ~= "" then
      local mapped = c.token_to_player and c.token_to_player[raw_token] or nil
      if mapped and mapped ~= pid_str then
        return action_http_error("token_invalid")
      end
    end

    local client_action_id = j.client_action_id
    if client_action_id ~= nil and type(client_action_id) ~= "string" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "client_action_id must be a string if provided."),
      }
    end
    if type(client_action_id) == "string" and #client_action_id > 128 then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "client_action_id must be at most 128 characters."),
      }
    end

    local expected_action_seq = j.expected_action_seq
    if expected_action_seq ~= nil then
      local n = tonumber(expected_action_seq)
      if not n or n < 0 or n ~= math.floor(n) then
        return {
          "400 Bad Request",
          api.error_body("bad_request", "expected_action_seq must be a non-negative integer if provided."),
        }
      end
      expected_action_seq = math.floor(n)
    end

    local cached = lookup_idempotent(c, pid_str, client_action_id)
    if cached then
      return cached
    end

    local result, err, err_details = submit_action(
      c,
      pid_str,
      tostring(action),
      amount,
      q,
      s.strict_action_queue,
      { expected_action_seq = expected_action_seq }
    )
    if not result then
      return action_http_error(err, err_details)
    end

    --- A successful submission cancels any outstanding "your queued action
    --- was dropped" notice for this player; they've effectively moved on.
    if c.action_queue_drops then
      c.action_queue_drops[pid_str] = nil
    end

    local body = {
      ok = true,
      queued = (result == "queued"),
      table = filter_snapshot_for_player(table_snapshot(c), pid_str, c.tbl),
    }
    store_idempotent(c, pid_str, client_action_id, body)
    return body
  end)

  srv:route("POST", "/v1/tables/:id/bot/start", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id and code (file contents). Bot buy-in matches the table."),
      }
    end
    local j = req.json
    local player_id = j.player_id
    local code = j.code
    local filename = j.filename or "bot.py"
    if not player_id or player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required."),
      }
    end
    if not code or code == "" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "code (bot file contents) is required."),
      }
    end
    player_id = tostring(player_id)

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end

    local lang = detect_lang(filename, code)

    local tmpdir = root .. "/tmp_bots"
    os.execute("mkdir -p " .. tmpdir)
    local safe_name = player_id:gsub("[^%w_%-]", "_")
    local ext = lang == "lua" and ".lua" or ".py"
    local bot_path = tmpdir .. "/" .. safe_name .. ext
    local f = io.open(bot_path, "w")
    if not f then
      return {
        "500 Internal Server Error",
        api.error_body("internal", "Failed to save bot file."),
      }
    end
    f:write(code)
    f:close()

    local port = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
    local buy_in = math.max(1, math.floor(tonumber(c.buy_in_chips) or 500))
    local pid = spawn_bot(root, lang, bot_path, player_id, params.table_id, port, buy_in)
    if not pid then
      return {
        "500 Internal Server Error",
        api.error_body("internal", "Failed to spawn bot process."),
      }
    end

    c.running_bots[player_id] = { pid = pid, file = bot_path, lang = lang }
    return {
      ok = true,
      player_id = player_id,
      lang = lang,
      pid = pid,
    }
  end)

  srv:route("POST", "/v1/tables/:id/bot/stop", function(req, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return {
        "400 Bad Request",
        api.error_body("bad_request", "JSON body required with player_id."),
      }
    end
    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return {
        "400 Bad Request",
        api.error_body("invalid_player", "player_id is required."),
      }
    end
    local bot = c.running_bots[player_id]
    if not bot then
      return {
        "404 Not Found",
        api.error_body("not_found", "No running bot for this player."),
      }
    end
    kill_bot(bot.pid)
    c.running_bots[player_id] = nil
    return { ok = true, player_id = player_id, stopped = true }
  end)

  srv:route("GET", "/v1/tables/:id/bot/list", function(_, params, s)
    local c = resolve_table(params, s)
    if not c then return not_found_table end
    local bots = {}
    for pid_name, info in pairs(c.running_bots) do
      bots[#bots + 1] = {
        player_id = pid_name,
        lang = info.lang,
        pid = info.pid,
      }
    end
    return { ok = true, bots = bots }
  end)

  -- ── Admin: Google OAuth2 ──────────────────────────────────────────────

  local GOOGLE_CLIENT_ID     = os.getenv("GOOGLE_CLIENT_ID") or ""
  local GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET") or ""
  local ADMIN_EMAIL          = os.getenv("ADMIN_EMAIL") or ""
  local admin_port           = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
  local ADMIN_REDIRECT_URI   = os.getenv("ADMIN_REDIRECT_URI")
    or ("http://localhost:" .. admin_port .. "/admin/oauth/callback")
  local ADMIN_COOKIE_SECURE  = (ADMIN_REDIRECT_URI:sub(1, 8) == "https://")

  local function require_admin(req)
    if ADMIN_EMAIL == "" then
      return nil, { "503 Service Unavailable",
        api.error_body("not_configured", "Admin auth not configured. Set GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, and ADMIN_EMAIL.") }
    end
    local sess = admin_auth.validate_session(req, ADMIN_EMAIL)
    if not sess then
      return nil, { "401 Unauthorized", api.error_body("unauthorized", "Admin login required.") }
    end
    return sess
  end

  srv:route("GET", "/admin/oauth/login", function(req)
    if GOOGLE_CLIENT_ID == "" then
      return {
        __raw = true,
        status = "503 Service Unavailable",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Google OAuth not configured. Set GOOGLE_CLIENT_ID env var.",
      }
    end
    local url = admin_auth.build_google_auth_url(GOOGLE_CLIENT_ID, ADMIN_REDIRECT_URI)
    return {
      __raw = true,
      status = "302 Found",
      headers = { Location = url },
      body = "",
    }
  end)

  srv:route("GET", "/admin/oauth/callback", function(req)
    local code = req.query and req.query.code
    if not code or code == "" then
      return {
        __raw = true,
        status = "400 Bad Request",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Missing 'code' parameter.",
      }
    end

    local result, err2 = admin_auth.exchange_code(code, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, ADMIN_REDIRECT_URI)
    if not result then
      io.stderr:write("[admin] OAuth error: " .. tostring(err2) .. "\n")
      return {
        __raw = true,
        status = "500 Internal Server Error",
        headers = { ["Content-Type"] = "text/plain" },
        body = "OAuth token exchange failed: " .. tostring(err2),
      }
    end

    if not result.email then
      return {
        __raw = true,
        status = "403 Forbidden",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Could not retrieve email from Google.",
      }
    end

    if result.email ~= ADMIN_EMAIL then
      io.stderr:write("[admin] Access denied for: " .. result.email .. "\n")
      return {
        __raw = true,
        status = "403 Forbidden",
        headers = { ["Content-Type"] = "text/plain" },
        body = "Access denied. This account (" .. result.email .. ") is not authorized.",
      }
    end

    local token = admin_auth.create_session(result.email)
    io.stderr:write("[admin] Logged in: " .. result.email .. "\n")
    return {
      __raw = true,
      status = "302 Found",
      headers = {
        Location = "/admin",
        ["Set-Cookie"] = admin_auth.session_cookie(token, ADMIN_COOKIE_SECURE),
      },
      body = "",
    }
  end)

  srv:route("GET", "/admin/oauth/logout", function(req)
    local token = req.cookies and req.cookies[admin_auth.SESSION_COOKIE]
    if token then
      admin_auth.destroy_session(token)
    end
    return {
      __raw = true,
      status = "302 Found",
      headers = {
        Location = "/admin",
        ["Set-Cookie"] = admin_auth.clear_cookie(),
      },
      body = "",
    }
  end)

  srv:route("GET", "/admin/api/session", function(req)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    return { ok = true, email = sess.email }
  end)

  srv:route("GET", "/admin/api/request-log", function(req)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    return { ok = true, entries = state.api_request_log or {} }
  end)

  srv:route("GET", "/admin/api/server-settings", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    return { ok = true, strict_action_queue = s.strict_action_queue == true }
  end)

  srv:route("POST", "/admin/api/server-settings", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required.") }
    end
    local v = req.json.strict_action_queue
    if v ~= nil and type(v) ~= "boolean" then
      return { "400 Bad Request", api.error_body("bad_request", "strict_action_queue must be a boolean.") }
    end
    if v ~= nil then
      s.strict_action_queue = v
    end
    return { ok = true, strict_action_queue = s.strict_action_queue == true }
  end)

  srv:route("GET", "/admin/api/request-log/download", function(req)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end
    local payload = {
      ok = true,
      exported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      entries = state.api_request_log or {},
    }
    local body = json.encode(payload)
    local fname = "poker-request-log-" .. os.date("!%Y%m%d-%H%M%S") .. "Z.json"
    return {
      __raw = true,
      status = "200 OK",
      headers = {
        ["Content-Type"] = "application/json; charset=utf-8",
        ["Content-Disposition"] = 'attachment; filename="' .. fname .. '"',
      },
      body = body,
    }
  end)

  -- ── Admin: API endpoints ───────────────────────────────────────────────

  srv:route("GET", "/admin/api/tables", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local list = {}
    for tid, ctx in pairs(s.tables) do
      local seated = ctx.tbl:occupied_count()
      local total_chips = 0
      for i = 1, ctx.tbl.max_seats do
        local si = ctx.tbl:get_seat(i)
        if si then total_chips = total_chips + si.stack end
      end
      local bot_count = 0
      for _ in pairs(ctx.running_bots or {}) do bot_count = bot_count + 1 end
      list[#list + 1] = {
        table_id = tid,
        max_seats = ctx.tbl.max_seats,
        seated = seated,
        total_chips = total_chips,
        hand_status = ctx.hand.status,
        sb_amount = ctx.hand.sb_amount,
        bb_amount = ctx.hand.bb_amount,
        running_bots = bot_count,
        zero_chips = ctx.zero_chips,
        buy_in_chips = ctx.buy_in_chips,
        action_timeout_sec = ctx.action_timeout_sec,
        action_timeout_mode = ctx.action_timeout_mode,
        hidden = ctx.hidden == true,
        wait_for_ready = ctx.wait_for_ready == true,
        require_start_flags = ctx.wait_for_ready == true,
        first_hand_started = ctx.first_hand_started == true,
        pending_join_count = ctx.pending_join_count or 0,
      }
    end
    return { ok = true, tables = list }
  end)

  srv:route("POST", "/admin/api/tables", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required with table_id.") }
    end
    local j = req.json
    local tid = tostring(j.table_id or ""):match("^%s*(.-)%s*$")
    if tid == "" then
      return { "400 Bad Request", api.error_body("bad_request", "table_id is required.") }
    end
    if not tid:match("^[%w_%-]+$") then
      return { "400 Bad Request", api.error_body("bad_request", "table_id must be alphanumeric/underscore/hyphen.") }
    end
    if s.tables[tid] then
      return { "409 Conflict", api.error_body("already_exists", "A table with this ID already exists.") }
    end

    local max_seats = tonumber(j.max_seats) or 10
    max_seats = math.max(2, math.min(10, math.floor(max_seats)))
    local sb = tonumber(j.sb_amount) or 2
    local bb = tonumber(j.bb_amount) or 5
    local with_ais = j.with_ais == true
    local hidden = j.hidden == true

    local zc = j.zero_chips
    if zc ~= "eject" and zc ~= "rebuy" then zc = "rebuy" end

    local buy_in = tonumber(j.buy_in_chips) or 500
    buy_in = math.max(1, math.floor(buy_in))
    local ats = j.action_timeout_sec
    if ats == nil then
      ats = tonumber(os.getenv("POKER_ACTION_TIMEOUT_SEC")) or 60
    end
    ats = math.floor(tonumber(ats) or 60)
    if ats < 0 then
      ats = 0
    end
    local atm = tostring(j.action_timeout_mode or "eject")
    if atm ~= "eject" and atm ~= "fold_only" then
      atm = "eject"
    end

    local require_start_flags = j.require_start_flags == true
      or j.wait_for_ready == true
      or j.wait_for_start_flags == true

    s.tables[tid] = create_table_context(tid, max_seats, {
      with_ais = with_ais,
      sb_amount = math.max(1, math.floor(sb)),
      bb_amount = math.max(1, math.floor(bb)),
      buy_in_chips = buy_in,
      zero_chips = zc,
      rebuy_amount = tonumber(j.rebuy_amount) or 500,
      action_timeout_sec = ats,
      action_timeout_mode = atm,
      hidden = hidden,
      wait_for_ready = require_start_flags,
    })

    io.stderr:write(
      "[admin] Created table: "
        .. tid
        .. " (seats="
        .. max_seats
        .. (hidden and ", hidden" or "")
        .. ")\n"
    )
    return { ok = true, table_id = tid, require_start_flags = require_start_flags, wait_for_ready = require_start_flags }
  end)

  srv:route("POST", "/admin/api/tables/:id/delete", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local tid = params.table_id
    local c = s.tables[tid]
    if not c then return not_found_table end

    for pid_name, info in pairs(c.running_bots or {}) do
      kill_bot(info.pid)
    end
    s.tables[tid] = nil

    io.stderr:write("[admin] Deleted table: " .. tid .. "\n")
    return { ok = true, deleted = tid }
  end)

  srv:route("GET", "/admin/api/stats", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local tid = req.query and req.query.table_id or "demo"
    local c = s.tables[tid]
    if not c then return not_found_table end

    local seated = 0
    local total_chips = 0
    local players = {}
    for i = 1, c.tbl.max_seats do
      local si = c.tbl:get_seat(i)
      if si then
        seated = seated + 1
        total_chips = total_chips + si.stack
        local pid = si.player_id
        local busts = (c.bust_counts and c.bust_counts[pid]) or 0
        players[#players + 1] = { seat = i, player_id = pid, stack = si.stack, busts = busts }
      end
    end

    local bots = {}
    for pid_name, info in pairs(c.running_bots or {}) do
      bots[#bots + 1] = { player_id = pid_name, lang = info.lang, pid = info.pid }
    end

    return {
      ok = true,
      table_id = c.tbl.id,
      max_seats = c.tbl.max_seats,
      seated = seated,
      total_chips = total_chips,
      players = players,
      hand_status = c.hand.status,
      street = c.hand.street,
      pot = c.hand.pot,
      sb_amount = c.hand.sb_amount,
      bb_amount = c.hand.bb_amount,
      running_bots = bots,
      ai_players = c.ai_players,
      zero_chips = c.zero_chips,
      rebuy_amount = c.rebuy_amount,
      buy_in_chips = c.buy_in_chips,
      action_timeout_sec = c.action_timeout_sec,
      action_timeout_mode = c.action_timeout_mode,
      wait_for_ready = c.wait_for_ready == true,
      require_start_flags = c.wait_for_ready == true,
      first_hand_started = c.first_hand_started == true,
      pending_join_count = c.pending_join_count or 0,
      ready_status = ready_status_snapshot(c),
    }
  end)

  -- Full table state for admin spectate (all hole cards visible; requires admin session).
  srv:route("GET", "/admin/api/tables/:id/snapshot", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end

    local snap = table_snapshot(c)
    local busts = {}
    if c.bust_counts then
      for pid, n in pairs(c.bust_counts) do
        busts[tostring(pid)] = n
      end
    end
    return {
      ok = true,
      table_id = c.tbl.id,
      table = snap,
      bust_counts = busts,
    }
  end)

  srv:route("POST", "/admin/api/tables/:id/kick", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body with player_id required.") }
    end
    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id is required.") }
    end

    local seat = c.tbl:seat_for_player(player_id)
    if not seat then
      if lobby_remove(c, player_id) then
        clear_player_action_state(c, player_id)
        if c.running_bots[player_id] then
          kill_bot(c.running_bots[player_id].pid)
          c.running_bots[player_id] = nil
        end
        remove_player_token(c, player_id)
        rearm_start_gate_if_empty(c)
        io.stderr:write("[admin] Kicked lobby player: " .. player_id .. "\n")
        return { ok = true, kicked = player_id, table = table_snapshot(c) }
      end
      return { "404 Not Found", api.error_body("not_seated", "Player not found at table.") }
    end

    if c.hand.status == "active" and c.hand.folded and not c.hand.folded[seat] then
      c.hand.folded[seat] = true
      c.hand.pending[seat] = nil
      if c.hand.action_to_seat == seat then
        c.hand:_after_action(c.tbl, seat)
      end
    end
    c.tbl:leave_seat(seat)
    clear_player_action_state(c, player_id)
    rearm_start_gate_if_empty(c)

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end
    remove_player_token(c, player_id)

    io.stderr:write("[admin] Kicked player: " .. player_id .. "\n")
    return { ok = true, kicked = player_id, table = table_snapshot(c) }
  end)

  srv:route("POST", "/admin/api/tables/:id/reset", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end

    c.hand:_reset_between_hands()
    c.hand.last_button_seat = nil
    c.action_queue = {}
    c.action_queue_drops = {}
    c.last_action_results = {}
    --- Re-arm the "wait for ready" gate so a reset table (configured with
    --- wait_for_ready) pauses again until everyone reconfirms.
    c.first_hand_started = false
    c.ready_players = {}
    c.pending_seats = {}
    c._prev_hand_status = nil
    c._last_join_at = nil
    c._last_start_flag_at = nil
    c._first_ready_at = nil

    local default_chips = math.max(1, math.floor(tonumber(c.buy_in_chips) or 500))
    for i = 1, c.tbl.max_seats do
      local si = c.tbl:get_seat(i)
      if si then
        si.stack = default_chips
      end
    end

    --- After resetting stacks, migrate any seated humans into the new
    --- pre-game lobby (ready_required tables). They keep their fresh
    --- buy-in and must POST /ready before the next hand starts. AIs stay
    --- seated.
    if c.wait_for_ready == true then
      migrate_seated_humans_to_lobby(c)
    end

    io.stderr:write("[admin] Table reset, stacks set to table buy-in " .. default_chips .. "\n")
    return { ok = true, table = table_snapshot(c) }
  end)

  srv:route("POST", "/admin/api/tables/:id/settings", function(req, params, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    local c = resolve_table(params, s)
    if not c then return not_found_table end
    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required.") }
    end

    local j = req.json
    if j.sb_amount ~= nil then
      local sb = tonumber(j.sb_amount)
      if sb and sb >= 1 then c.hand.sb_amount = math.floor(sb) end
    end
    if j.bb_amount ~= nil then
      local bb = tonumber(j.bb_amount)
      if bb and bb >= 1 then c.hand.bb_amount = math.floor(bb) end
    end
    if j.zero_chips ~= nil then
      if j.zero_chips == "eject" or j.zero_chips == "rebuy" then
        c.zero_chips = j.zero_chips
      end
    end
    if j.rebuy_amount ~= nil then
      local ra = tonumber(j.rebuy_amount)
      if ra and ra >= 1 then c.rebuy_amount = math.floor(ra) end
    end
    if j.buy_in_chips ~= nil then
      local bi = tonumber(j.buy_in_chips)
      if bi and bi >= 1 then c.buy_in_chips = math.floor(bi) end
    end
    if j.action_timeout_sec ~= nil then
      local ats = tonumber(j.action_timeout_sec)
      if ats then
        ats = math.floor(ats)
        if ats < 0 then
          ats = 0
        end
        c.action_timeout_sec = ats
      end
    end
    if j.action_timeout_mode ~= nil then
      local atm = tostring(j.action_timeout_mode)
      if atm == "eject" or atm == "fold_only" then
        c.action_timeout_mode = atm
      end
    end
    local start_flag_setting = j.require_start_flags
    if start_flag_setting == nil then
      start_flag_setting = j.wait_for_start_flags
    end
    if start_flag_setting == nil then
      start_flag_setting = j.wait_for_ready
    end
    if start_flag_setting ~= nil then
      local new_val = start_flag_setting == true
      c.wait_for_ready = new_val
      --- Turning the gate ON while the hand is idle re-arms the cohort: a
      --- stale first_hand_started (e.g. option was off, a hand finished,
      --- flag turned on) would otherwise skip the ready requirement
      --- entirely. We do this on every save (not just the false->true
      --- edge) so the admin can recover a stuck table by simply re-saving
      --- the form -- previously this was idempotent only on the edge.
      if new_val and c.hand and c.hand.status == "idle" then
        c.first_hand_started = false
        c.ready_players = {}
        c.action_queue = {}
        c.action_queue_drops = {}
        c._first_ready_at = nil
        c._last_join_at = nil
        c._last_start_flag_at = nil
        --- Pull any humans who were already seated back into the pre-game
        --- lobby so they pay no blinds and get no cards until they
        --- POST `/ready`. AI players (implicit ready) keep their seats.
        migrate_seated_humans_to_lobby(c)
      end
    end

    io.stderr:write("[admin] Settings updated: SB=" .. c.hand.sb_amount .. " BB=" .. c.hand.bb_amount
      .. " zero_chips=" .. c.zero_chips .. " rebuy=" .. tostring(c.rebuy_amount)
      .. " buy_in=" .. tostring(c.buy_in_chips)
      .. " action_timeout=" .. tostring(c.action_timeout_sec) .. "s " .. tostring(c.action_timeout_mode)
      .. " wait_for_ready=" .. tostring(c.wait_for_ready)
      .. "\n")
    return {
      ok = true,
      sb_amount = c.hand.sb_amount,
      bb_amount = c.hand.bb_amount,
      zero_chips = c.zero_chips,
      rebuy_amount = c.rebuy_amount,
      buy_in_chips = c.buy_in_chips,
      action_timeout_sec = c.action_timeout_sec,
      action_timeout_mode = c.action_timeout_mode,
      wait_for_ready = c.wait_for_ready,
      require_start_flags = c.wait_for_ready == true,
      first_hand_started = c.first_hand_started == true,
      pending_join_count = c.pending_join_count or 0,
    }
  end)

  srv:route("POST", "/admin/api/bot/start", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body required with table_id, player_id, code.") }
    end
    local j = req.json
    local tid = tostring(j.table_id or "demo")
    local c = s.tables[tid]
    if not c then return not_found_table end

    local player_id = tostring(j.player_id or "")
    local code = j.code or ""
    local filename = j.filename or "bot.py"

    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id required.") }
    end
    if code == "" then
      return { "400 Bad Request", api.error_body("bad_request", "code required.") }
    end

    if c.running_bots[player_id] then
      kill_bot(c.running_bots[player_id].pid)
      c.running_bots[player_id] = nil
    end

    local lang = detect_lang(filename, code)
    local tmpdir = root .. "/tmp_bots"
    os.execute("mkdir -p " .. tmpdir)
    local safe_name = player_id:gsub("[^%w_%-]", "_")
    local ext = lang == "lua" and ".lua" or ".py"
    local bot_path = tmpdir .. "/" .. safe_name .. ext
    local f = io.open(bot_path, "w")
    if not f then
      return { "500 Internal Server Error", api.error_body("internal", "Failed to save bot file.") }
    end
    f:write(code)
    f:close()

    local port2 = tonumber(os.getenv("POKER_PORT") or "8080") or 8080
    local buy_in = math.max(1, math.floor(tonumber(c.buy_in_chips) or 500))
    local pid = spawn_bot(root, lang, bot_path, player_id, tid, port2, buy_in)
    if not pid then
      return { "500 Internal Server Error", api.error_body("internal", "Failed to spawn bot.") }
    end

    c.running_bots[player_id] = { pid = pid, file = bot_path, lang = lang }
    return { ok = true, player_id = player_id, lang = lang, pid = pid }
  end)

  srv:route("POST", "/admin/api/bot/stop", function(req, _, s)
    local sess, err2 = require_admin(req)
    if not sess then return err2 end

    if type(req.json) ~= "table" then
      return { "400 Bad Request", api.error_body("bad_request", "JSON body with player_id, table_id required.") }
    end
    local tid = tostring(req.json.table_id or "demo")
    local c = s.tables[tid]
    if not c then return not_found_table end

    local player_id = tostring(req.json.player_id or "")
    if player_id == "" then
      return { "400 Bad Request", api.error_body("bad_request", "player_id required.") }
    end

    local bot = c.running_bots[player_id]
    if not bot then
      return { "404 Not Found", api.error_body("not_found", "No running bot for this player.") }
    end
    kill_bot(bot.pid)
    c.running_bots[player_id] = nil
    io.stderr:write("[admin] Stopped bot: " .. player_id .. "\n")
    return { ok = true, player_id = player_id, stopped = true }
  end)

  if ADMIN_EMAIL ~= "" then
    io.stderr:write(string.format("  Admin: http://127.0.0.1:%s/admin (email: %s)\n", tostring(admin_port), ADMIN_EMAIL))
    io.stderr:write(string.format("  OAuth redirect: %s\n", ADMIN_REDIRECT_URI))
  end

  srv:run_loop()
end

local function main()
  for i = 1, #arg do
    if arg[i] == "--cli" then
      run_cli()
      return
    end
  end
  run_http()
end

main()
