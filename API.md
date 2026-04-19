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

### POST `/v1/tables/{table_id}/actions`

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
  "queue": true
}
```

- **`player_id`** — Must already be seated at this table
- **`action`** — One of: `fold`, `check`, `call`, `raise`, `bet`, `all_in`
- **`amount`** — For **`raise`** / **`bet`**: **total chips you commit on this betting street** after the action (not “chips added on top of call” only). Example: after blinds (SB=2, BB=5), a raise “to 15” means **`amount`: 15** total for that seat on that street.
- **`all_in`** — No `amount`; entire stack goes in.
- **`queue`** — Optional boolean. Controls **action queue** (precache) behavior:
  - **`queue: true`** — Store this action only: do **not** start a hand while **`hand.status` is `idle`**, and do **not** apply when it is not your turn. If it **is** your turn on an active hand, the action is applied immediately (same as a normal submit).
  - **`queue: false`** — If it is **not** your turn on an active hand, the server returns **`wrong_turn`** instead of storing.
  - **Omitted** — If it is **not** your turn (or idle and you would **not** be first to act after blinds), the server **stores** the action for you and returns **`queued: true`**. Each player keeps at most one queued action; a new submission **replaces** the previous.

**Queue execution:** When it becomes your turn, the server applies your queued action (if any) before bots act. If the queued action is no longer legal (e.g. bet size changed), it is **discarded** and logged; you must act again. Queued actions taken while the hand is **active** are tagged with the current **`street`**; if the betting round advances before your turn, the queue entry is **dropped** (so a precached move cannot fire on a later street).

**Strict queue (optional):** When enabled in the **admin console** (Server settings → *Strict action queue*), if **`queue` is omitted** and the hand is **active** but it is **not** your turn, the server returns **`wrong_turn`** instead of storing (same as **`queue: false`**). Explicit **`queue: true`** still allows precaching off-turn. The flag is stored in memory and resets when the server restarts; default is **off**.

**Turn order:** Only the player in **`hand.action_to_seat`** may act **immediately** without using the queue. If the hand is **`idle`**, the first valid **non-queue-only** action from the **first player to act** preflop **starts** a new hand (posts blinds, sets positions). If you are **not** first to act and the hand is idle, your request is **queued** (unless you used **`queue: false`**, which only applies to **wrong_turn** on an **active** hand).

**Snapshot:** `GET .../state` includes **`action_queue`**: a map of **`player_id`** → `{ "action", "amount" }` for queued intents (empty when none).

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

Common errors: **`wrong_turn`** (when `queue: false` and not your turn), **`not_seated`**, **`min_raise`**, **`cannot_raise_self`**, **`cannot_check`**, **`need_two_players`**, plus the generic validation codes above.

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
