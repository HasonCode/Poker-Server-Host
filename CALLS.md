# Poker Server — API Reference

Base URL: `http://<host>:8080`

All request and response bodies are JSON. Successful responses include `"ok": true`.
Error responses follow the shape:

```json
{
  "error": {
    "code": "error_code",
    "message": "Human-readable explanation.",
    "details": {}
  }
}
```

---

## Authentication

Most player endpoints are public. When you **join** a table, the server returns a
unique `token` string. Include it as a header on subsequent requests to prove your
identity:

```
X-Player-Token: <token>
```

- **State endpoint** — only your hole cards are returned when the header is present;
  without it, all hole cards are hidden.
- **Action endpoint** — the header is **required** for any seated player. Missing
  header → `401 token_required`; token mapped to a different player → `403
  token_invalid`. (Sending an action as an unseated player_id is still allowed
  and will fail with `not_seated`.)

---

## Python Client

All endpoints below can be called directly with `urllib` / `requests`, or through
the provided `PokerClient` wrapper (`clients/python/poker_client.py`):

```python
from poker_client import PokerClient

c = PokerClient("http://127.0.0.1:8080")
```

The client stores the token automatically after `join_table()` and sends it with
every subsequent request.

---

## Player Endpoints

### `GET /health`

Server health check.

| Python client | `c.health()` |
|---|---|

**Response**

```json
{
  "ok": true,
  "service": "poker-server",
  "version": "0.1.0-skeleton"
}
```

---

### `GET /v1/tables`

List all tables on the server.

| Python client | *(no wrapper — use `c._request_json("GET", "/v1/tables")`)* |
|---|---|

**Response**

```json
{
  "ok": true,
  "tables": [
    {
      "table_id": "demo",
      "max_seats": 10,
      "seated": 6,
      "hand_status": "idle"
    }
  ]
}
```

---

### `GET /v1/tables/:id/state`

Full snapshot of a table: seats, hand state, community cards, pot, action queue.

| Python client | `c.get_table_state("demo")` |
|---|---|
| Auth header | Optional — filters hole cards to the authenticated player only |

**Response**

```json
{
  "table_id": "demo",
  "max_seats": 10,
  "zero_chips": "rebuy",
  "rebuy_amount": 500,
  "seats": [
    { "player_id": "Alice", "stack": 980 },
    false,
    "..."
  ],
  "hand": {
    "status": "active",
    "street": "flop",
    "pot": 40,
    "community": ["Ah", "Kd", "7c"],
    "hole_cards": { "Alice": ["As", "Ks"] },
    "action_to_seat": 1,
    "button_seat": 3,
    "sb_seat": 4,
    "bb_seat": 5,
    "sb_amount": 2,
    "bb_amount": 5,
    "current_bet": 10,
    "min_raise_increment": 5,
    "contribution": { "1": 20 },
    "hand_bets": { "1": 20 },
    "folded": [],
    "action_log": []
  },
  "action_queue": {}
}
```

`hole_cards` is keyed by player ID. Without a valid `X-Player-Token`, all entries
are empty. With a valid token, only the authenticated player's cards appear.

---

### `POST /v1/tables/:id/join`

Sit down at a table.

| Python client | `c.join_table("demo", player_id="Alice", chips=1000, seat=3)` |
|---|---|

**Request body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `player_id` | string | yes | Unique name for this player |
| `chips` | integer | yes | Starting chip stack |
| `seat` | integer | no | 1-based seat number; omit for first available |

**Response**

```json
{
  "ok": true,
  "token": "a1b2c3...64-hex-chars",
  "table": { "...snapshot..." }
}
```

Save the `token` — it is your auth credential for this table session.

---

### `POST /v1/tables/:id/leave`

Stand up from a table. If a hand is active, the player is auto-folded first.

| Python client | `c.leave_table("demo", player_id="Alice")` |
|---|---|

**Request body**

| Field | Type | Required |
|---|---|---|
| `player_id` | string | yes |

**Response**

```json
{
  "ok": true,
  "table": { "...snapshot..." }
}
```

---

### `POST /v1/tables/:id/ready`

Signal that a seated player is ready for the **first hand of the current table cohort** on a table created with `require_start_flags: true` (alias: `wait_for_ready: true`). A cohort begins when players sit at a table that was previously empty. That first hand does not deal until every seated player has signalled readiness (and ≥ 2 players are seated). All subsequent hands deal automatically until the table becomes empty again. On tables without this option, play auto-starts when two players are seated; this call is still accepted for consistency but does not affect dealing.

`POST /v1/tables/:id/start` and `POST /v1/tables/:id/start-flag` are aliases with the same request body and response.

| Python client | `c.set_ready("tournament", player_id="Alice")` or `c.start_table("tournament", player_id="Alice")`; pass `ready=False` to withdraw |
|---|---|
| Auth header | **Required** (`X-Player-Token` matching `player_id`). Missing → `401 token_required`. Mismatched → `403 token_invalid`. |

**Request body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `player_id` | string | yes | Must be seated |
| `ready` | boolean | no | Defaults to `true`. Pass `false` to withdraw a previous signal |

**Response**

```json
{
  "ok": true,
  "player_id": "Alice",
  "ready": true,
  "ready_status": {
    "wait_for_ready": true,
    "first_hand_started": false,
    "ready_players": ["Alice"],
    "waiting_players": ["Bob"],
    "all_ready": false
  },
  "table": { "...snapshot..." }
}
```

Also available on every table snapshot as `table.ready`, so bots can poll `GET .../state` to watch progress without hammering this endpoint.

Join requests before the cohort's first hand starts are batched in FIFO order for that table. If any joins are deferred, newer joins do not bypass older queued joins.

Common errors: `not_seated` (404), `token_required` (401), `token_invalid` (403), `invalid_player` (400).

---

### `POST /v1/tables/:id/actions`

Submit a poker action.

| Python client | `c.send_action("demo", player_id="Alice", action="raise", amount=20)` |
|---|---|
| Auth header | **Required** for any seated player (`X-Player-Token`). Missing → `401 token_required`. Mismatched → `403 token_invalid`. |

**Request body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `player_id` | string | yes | Must be seated |
| `action` | string | yes | `fold`, `check`, `call`, `raise`, `bet`, `all_in` |
| `amount` | integer | conditional | Required for `raise` and `bet` |
| `queue` | boolean | no | `true` = always queue; `false` = error if not your turn; omit = auto-queue when not your turn |
| `client_action_id` | string | no | Idempotency key, ≤ 128 chars. The server caches the response per `(player_id, id)` for 60 s; replay with the same id returns the cached response instead of re-applying. |
| `expected_action_seq` | integer | no | Assert the client's view of `hand.action_seq`. Mismatch when the action would apply now → `stale_action` (409) with `details.current_seq`. Ignored when the action would be queued. |

**Additional error on `wait_for_ready` tables:** `not_ready` (409) is returned when the request explicitly sets `queue: false` and the current table cohort is still waiting for every seat to signal ready/start for its first hand. Omit `queue` (or pass `queue: true`) to have the action auto-queued for the first deal instead. See `POST /v1/tables/:id/ready`.

**Response**

```json
{
  "ok": true,
  "queued": false,
  "table": { "...snapshot..." }
}
```

`queued: true` means the action was stored and will execute when it becomes this
player's turn (or on the next hand for players who joined mid-hand, for whom the
queue is always effectively `while_idle`).

**Related snapshot field:** `table.action_queue_drops[player_id]` exposes queued
intents the server discarded at fire time (`reason` = `stale_street` when the
betting round changed before the queue could fire, or a game-engine error code
like `min_raise` / `insufficient_chips`). Cleared by the player's next successful
action submission.

---

## Bot Management Endpoints

### `POST /v1/tables/:id/bot/start`

Upload and launch a bot script for a player seat.

| Python client | *(no wrapper)* |
|---|---|

**Request body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `player_id` | string | yes | The bot's player name |
| `chips` | integer | no | Default `500` |
| `code` | string | yes | Full source code of the bot script |
| `filename` | string | no | Default `"bot.py"`; used to detect language (`.py` or `.lua`) |

**Response**

```json
{
  "ok": true,
  "player_id": "my_bot",
  "lang": "python",
  "pid": 12345
}
```

---

### `POST /v1/tables/:id/bot/stop`

Kill a running bot process.

| Python client | *(no wrapper)* |
|---|---|

**Request body**

| Field | Type | Required |
|---|---|---|
| `player_id` | string | yes |

**Response**

```json
{
  "ok": true,
  "player_id": "my_bot",
  "stopped": true
}
```

---

### `GET /v1/tables/:id/bot/list`

List all running bots at a table.

| Python client | *(no wrapper)* |
|---|---|

**Response**

```json
{
  "ok": true,
  "bots": [
    { "player_id": "my_bot", "lang": "python", "pid": 12345 }
  ]
}
```

---

## Convenience Methods (Python Client Only)

These methods don't map to a single endpoint — they use `GET .../state` internally.

### `c.is_my_turn(table_id, player_id) -> bool`

Returns `True` if it is currently this player's turn to act.

### `c.wait_for_turn(table_id, player_id, poll_interval=0.5, timeout=None) -> state`

Blocks until it is this player's turn, then returns the full table state. Polls
the state endpoint every `poll_interval` seconds. Raises `TimeoutError` if
`timeout` is exceeded.

---

## Table Settings (visible in state)

Every table has a **zero-chips policy** that takes effect at the end of each hand:

| Field | Values | Description |
|---|---|---|
| `zero_chips` | `"rebuy"` (default) or `"eject"` | What happens when a player's stack reaches 0 |
| `rebuy_amount` | integer (default `500`) | Chips given on automatic rebuy |

These are returned in the table state snapshot and can be changed through the admin
settings endpoint.

---

## Error Codes

| Code | HTTP Status | Meaning |
|---|---|---|
| `bad_request` | 400 | Missing or malformed fields |
| `invalid_player` | 400 | Empty or missing `player_id` |
| `invalid_seat` | 400 | Seat number out of range |
| `seat_taken` | 409 | Another player occupies that seat |
| `table_full` | 409 | No available seats |
| `not_found` | 404 | Table ID doesn't exist |
| `not_seated` | 404 | Player is not at this table |
| `forbidden` | 403 | Token / player_id mismatch |
| `not_active` | 409 | No hand in progress |
| `wrong_turn` | 409 | Not this player's turn (when `queue=false`) |
| `already_folded` | 409 | Player already folded this hand |
| `invalid_action` | 400 | Unrecognized action string |
| `internal` | 500 | Server-side failure |
