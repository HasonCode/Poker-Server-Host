# Poker server — HTTP API

JSON over HTTP. Base path **`/v1`** for table resources. The server may also serve static files (e.g. the web UI) from `/`.

## Conventions

- **Content-Type** for JSON responses: `application/json; charset=utf-8`
- **POST** bodies must be JSON with `Content-Type: application/json`
- **Errors** use HTTP 4xx/5xx and a JSON body (see below)
- **Table IDs** in paths are URL-encoded path segments (use `urllib.parse.quote` / the Lua client’s escaping)

## Success responses

Successful calls return **200** with a JSON object (shape depends on the route).

## Error responses

Non-success responses use a JSON object of the form:

```json
{
  "error": {
    "code": "not_found",
    "message": "Human-readable explanation.",
    "details": { "path": "/unknown" }
  }
}
```

- **`code`** — Stable machine-readable identifier (`not_found`, `internal`, `bad_request`, `seat_taken`, `not_seated`, …).
- **`message`** — Short explanation for logs and UI.
- **`details`** — Optional object with extra context (paths, field names, validation hints). Omitted when there is nothing to add.

**5xx** responses use a generic `message` for clients; internal causes may be logged on the server only.

## Routes (current)

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness / service metadata |
| GET | `/v1/tables/{table_id}/state` | Snapshot: seats, stacks, hand |
| POST | `/v1/tables/{table_id}/join` | Take a seat (see below) |
| POST | `/v1/tables/{table_id}/ready` | Signal readiness for the first hand of the current table cohort (`require_start_flags` / `wait_for_ready`) |
| POST | `/v1/tables/{table_id}/start` | Alias for `/ready` for clients that model this as a start request |
| POST | `/v1/tables/{table_id}/start-flag` | Alias for `/ready` with explicit start-flag naming |
| POST | `/v1/tables/{table_id}/actions` | Submit an action (see below) |

Unknown paths return **404** with `code: "not_found"`.

### POST `/v1/tables/{table_id}/join`

Body:

```json
{
  "player_id": "carol",
  "chips": 500
}
```

Optional explicit seat:

```json
{
  "seat": 2,
  "player_id": "carol",
  "chips": 500
}
```

- **`player_id`** — Non-empty string
- **`chips`** — Non-negative integer (starting stack)
- **`seat`** — Optional. If omitted (or empty), the server assigns the **lowest-numbered free seat**. If the table is full, the request fails with **`table_full`** (409).

**200** response:

```json
{
  "ok": true,
  "table": { "table_id": "...", "max_seats": 10, "seats": [...], "hand": {...} }
}
```

Common errors: **`seat_taken`** (409), **`table_full`** (409), **`invalid_seat`** (400).

### POST `/v1/tables/{table_id}/ready`

Signal that a player is ready for the **first hand of the current table cohort** on a table created with **`require_start_flags: true`** (alias: `wait_for_ready: true`). A cohort begins when players sit at a table that was previously empty.

While the gate is active the cohort is in a **pre-game lobby**: joiners get a token but **no seat number, no chips deduction, no button/SB/BB position, and no cards** until the gate releases. They sit in `ready_status.lobby_players` (FIFO arrival order) and the table's `seats` array shows them as empty. Action submissions for lobby players are rejected with `not_ready` (the only meaningful pre-game call is `/ready` itself).

The gate releases when **either** condition is met:

1. **Unanimous ready** — every player at the table (lobby + any pre-existing seats; minimum 2) has signalled ready, *and* any deferred joins have been processed, *and* the `start_grace_sec` settle window has elapsed since the most recent join/ready. The lobby is then **shuffled into random seats** at the table, blinds are posted as usual, and cards are dealt.
2. **Limbo-fold timeout** — `action_timeout_sec` has elapsed since the **first** `/ready` arrived, and at least two players have readied. The lobby is shuffled and seated as above, then any seat whose player did *not* ready up is **auto-folded for that first hand only**. They pay any blinds owed by the random position they landed on, but take no action and forfeit the hand. From the second hand of the cohort onward they participate normally.

If only one player has readied when the timer expires the gate keeps blocking — a hand cannot start with a single non-folded player. Subsequent hands for the cohort deal automatically. If the table becomes empty again the gate re-arms for the next cohort and the lobby starts over. On tables without the option, play auto-starts as soon as two players are seated; this endpoint is still accepted but has no effect on dealing.

> **Note:** because seats are randomly assigned on lobby release, the optional `seat` field in `POST /v1/tables/{id}/join` is *ignored* while the lobby is active. Pre-existing seats (e.g. AI players that the table was created with) keep their seats; only lobby joiners are randomized.

`POST /v1/tables/{table_id}/start` and `POST /v1/tables/{table_id}/start-flag` are aliases for this endpoint.

**Authentication:** `X-Player-Token` header is required and must match `player_id` (same auth model as `POST /actions`).

Body:

```json
{ "player_id": "alice", "ready": true }
```

- **`player_id`** — Must be at this table, either seated or in the pre-game lobby (`ready_status.lobby_players`).
- **`ready`** — Optional boolean, defaults to `true`. Pass `false` to withdraw a previous signal.

**200** response:

```json
{
  "ok": true,
  "player_id": "alice",
  "ready": true,
  "ready_status": {
    "wait_for_ready": true,
    "require_start_flags": true,
    "first_hand_started": false,
    "in_lobby_phase": true,
    "ready_players": ["alice"],
    "waiting_players": ["bob"],
    "lobby_players": ["alice", "bob"],
    "all_ready": false,
    "first_ready_received": true,
    "start_timeout_sec": 60,
    "start_timeout_remaining_sec": 47,
    "pending_join_count": 0,
    "start_grace_sec": 2
  },
  "table": { "table_id": "...", "seats": [...], "hand": {...}, "ready": {...} }
}
```

- `ready.ready_players` / `ready.waiting_players` / `ready.lobby_players` are also surfaced inside every `table` snapshot (`table.ready`) on other endpoints, so bots can poll without spamming the ready endpoint.
- **`in_lobby_phase`** is `true` while the gate is active and lobby joiners have not yet been seated. UIs should render `lobby_players` as a "waiting room" panel separate from the felt; once the gate releases, those players appear in the table's `seats` array at randomly assigned positions and `in_lobby_phase` flips to `false`.
- **`lobby_players`** lists the players who joined while the gate was active, in FIFO arrival order. Their entries do not appear in the `seats` array yet — `seats[i]` returns `false` for unassigned positions. Chip stacks for these players are not visible until they are seated; clients can assume the table's `buy_in_chips`.
- **`first_hand_started`** flips to `true` as soon as the cohort's first hand is dealt. It resets only when the table becomes completely empty or when `POST /admin/api/tables/{id}/reset` is called.
- **`start_timeout_sec`** equals the table's `action_timeout_sec` while the gate is active and the cohort is waiting for unanimous ready. **`start_timeout_remaining_sec`** is the live countdown until the limbo-fold deadline. It is `null` until the first `/ready` arrives; once it hits zero the hand starts and any seat in `waiting_players` is folded for that first hand. If `action_timeout_sec` is `0` (timeouts disabled) the timeout path is disabled entirely and the hand only starts on unanimous ready.
- Leaving the table (`POST /leave` / admin kick) removes the player from `ready_players`. A remaining seat that was previously "all ready" will see the gate re-arm until it reconfirms (or another player joins and signals). If the *last* readied player rescinds (sends `ready: false` or leaves), the limbo-fold timer is also cleared and will restart from zero on the next ready.
- Join requests are accepted until the first hand starts. Deferred joins are seated FIFO; newer joins do not bypass older queued joins for the same table. A late joiner does not extend the existing limbo-fold timer — they must ready up before it expires or be auto-folded.
- While the gate is active, `POST /actions` returns `"queued"` (or `not_ready` if `queue: false`); no per-seat actions are accepted, which is the "limbo" the player is in.

Common errors: **`not_seated`** (404), **`token_required`** (401), **`token_invalid`** (403), **`invalid_player`** (400).

### POST `/v1/tables/{table_id}/actions`

**Authentication:** the **`X-Player-Token`** header is **required** for any seated player. The token is returned by `POST /join`. Submitting without it (when the named `player_id` is seated) returns **`token_required`** (401); a token that does not map to `player_id` returns **`token_invalid`** (403). This closes a spoofing hole where an unauthenticated client could submit moves as another seated player.

Body:

```json
{
  "player_id": "alice",
  "action": "raise",
  "amount": 50
}
```

Optional:

```json
{
  "player_id": "alice",
  "action": "fold",
  "queue": true,
  "client_action_id": "01J9Q...",
  "expected_action_seq": 7
}
```

- **`player_id`** — Must already be seated at this table
- **`action`** — One of: `fold`, `check`, `call`, `raise`, `bet`, `all_in`
- **`amount`** — For **`raise`** / **`bet`**: **total chips you commit on this betting street** after the action (not “chips added on top of call” only). Example: after blinds (SB=2, BB=5), a raise “to 15” means **`amount`: 15** total for that seat on that street.
- **`all_in`** — No `amount`; entire stack goes in.
- **`client_action_id`** — Optional string (≤ 128 chars). Idempotency key. The server caches the response per (player, id) for 60 s; replaying with the same id returns the original response instead of re-applying or re-queuing the action. Use it on network retries so a "fold" intended for hand N is never silently re-applied as a queued move on hand N+1.
- **`expected_action_seq`** — Optional non-negative integer. Asserts that you are acting on the `hand.action_seq` you observed in a recent snapshot. If the server's current seq differs and the action would otherwise apply now, it is rejected with **`stale_action`** (409) and the error `details` include `current_seq` and `expected_seq`. Ignored when the action would be queued.
- **`queue`** — Optional boolean. Controls **action queue** (precache) behavior:
  - **`queue: true`** — Store this action only: do **not** start a hand while **`hand.status` is `idle`**, and do **not** apply when it is not your turn. If it **is** your turn on an active hand, the action is applied immediately (same as a normal submit).
  - **`queue: false`** — If it is **not** your turn on an active hand, the server returns **`wrong_turn`** instead of storing.
  - **Omitted** — If it is **not** your turn (or idle and you would **not** be first to act after blinds), the server **stores** the action for you and returns **`queued: true`**. Each player keeps at most one queued action; a new submission **replaces** the previous.

**Queue execution:** When it becomes your turn, the server applies your queued action (if any) before bots act. If the queued action is no longer legal (e.g. bet size changed), it is **discarded** and logged; you must act again. Queued actions taken while the hand is **active** are tagged with the current **`street`**; if the betting round advances before your turn, the queue entry is **dropped** (so a precached move cannot fire on a later street).

**Strict queue (optional):** When enabled in the **admin console** (Server settings → *Strict action queue*), if **`queue` is omitted** and the hand is **active** but it is **not** your turn, the server returns **`wrong_turn`** instead of storing (same as **`queue: false`**). Explicit **`queue: true`** still allows precaching off-turn. The flag is stored in memory and resets when the server restarts; default is **off**.

**Turn order:** Only the player in **`hand.action_to_seat`** may act **immediately** without using the queue. If the hand is **`idle`**, the first valid **non-queue-only** action from the **first player to act** preflop **starts** a new hand (posts blinds, sets positions). If you are **not** first to act and the hand is idle, your request is **queued** (unless you used **`queue: false`**, which only applies to **wrong_turn** on an **active** hand).

**Snapshot:** `GET .../state` includes **`action_queue`** (map of `player_id` → `{ "action", "amount" }` for queued intents) and **`action_queue_drops`** (map of `player_id` → `{ "action", "amount", "street", "reason", "at" }` for queued intents the server discarded at fire time, e.g. because the betting round changed (`reason: "stale_street"`) or the action became illegal). A player's drop entry is cleared by their next successful action submission.

**Mid-hand join:** Joining via `POST /join` while a hand is **active** is allowed; the new seat is dealt in at the **next** `start_hand`. While the hand they joined into is still running, any actions they submit are **queued for the next deal** (`while_idle = true`) — `queue: false` returns `wrong_turn`, `queue: true`/omitted is stored.

**Blinds & positions (defaults):** Small blind **2** chips, big blind **5** chips. The snapshot includes **`button_seat`**, **`sb_seat`**, **`bb_seat`**, **`sb_amount`**, **`bb_amount`**. Heads-up: the button posts the small blind and acts first preflop. With 3+ players, first preflop actor is UTG (seat after the big blind).

**Minimum raise:** Each raise must increase the **current bet level** by at least **`min_raise_increment`** (starts at the big blind; after a raise, it becomes the size of that raise). Too small a raise → **`min_raise`**.

**Cannot “raise yourself”:** You cannot **raise** again while you are still the **last player who raised** this betting round (someone else must raise in between, or the round ends). Otherwise **`cannot_raise_self`**.

**Streets:** Preflop → flop → turn → river (community cards are placeholders until a real deck exists). When a betting round completes, the next street runs; after the river, the hand ends and the button rotates for the next hand.

**200** response:

```json
{
  "ok": true,
  "queued": false,
  "table": { "table_id": "...", "action_queue": {}, "seats": [...], "hand": {...} }
}
```

- **`queued`** — `true` if this request only stored an action for later.

Common errors: **`wrong_turn`** (when `queue: false` and not your turn), **`not_seated`**, **`min_raise`**, **`cannot_raise_self`**, **`cannot_check`**, **`need_two_players`**, **`stale_action`** (when `expected_action_seq` doesn't match), **`not_ready`** (409, returned when `queue: false` on a `wait_for_ready` table whose current cohort has not dealt its first hand yet — the table is still waiting for every seat to signal ready/start; omit `queue` to have the action auto-queued for the first deal instead), **`hand_idle`** (409, internal consistency error: an action reached the engine with no active hand; refresh state and retry), **`token_required`** / **`token_invalid`**, plus the generic validation codes above.

## Python client

`clients/python/poker_client.py` (stdlib only).

```python
import sys
sys.path.insert(0, "clients/python")
from poker_client import PokerClient, PokerError, TransportError

c = PokerClient("http://127.0.0.1:8080", timeout=10.0)
try:
    print(c.health())
    print(c.get_table_state("demo"))
    print(c.join_table("demo", player_id="carol", chips=500))  # first free seat
    # print(c.join_table("demo", seat=2, player_id="carol", chips=500))
    print(c.send_action("demo", player_id="carol", action="check"))
    print(c.send_action("demo", player_id="carol", action="raise", amount=20))

    # For tables created with `wait_for_ready`:
    # print(c.set_ready("tournament", player_id="carol"))
    # or: print(c.start_table("tournament", player_id="carol"))
    # print(c.wait_for_hand("tournament", timeout=60))
except PokerError as e:
    print(e.status_code, e.api_code, e.message, e.details)
except TransportError as e:
    print("transport:", e)
```

## Lua client

`src/poker/client.lua` (requires LuaSocket).

```lua
package.path = "src/?.lua;src/?/init.lua;" .. package.path
local Client = require("poker.client")
local c, cerr = Client.new({ base_url = "http://127.0.0.1:8080", timeout = 10 })
assert(c, cerr)

local data, err = c:join_table("demo", { player_id = "carol", chips = 500 })
-- explicit seat: c:join_table("demo", { seat = 2, player_id = "carol", chips = 500 })
if err then ... end

local d2, err2 = c:send_action("demo", { player_id = "carol", action = "check" })
local d3, err3 = c:send_action("demo", { player_id = "carol", action = "raise", amount = 20 })
```

On failure, **`err.kind`** is `Client.ERR_API` or `Client.ERR_TRANSPORT`. API errors include **`err.code`**, **`err.message`**, optional **`err.details`**, and **`err.http_status`**.
