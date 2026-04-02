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
- **Action endpoint** — if the header is present, the server verifies the token
  matches the `player_id` in the body (returns `403` on mismatch).

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

### `POST /v1/tables/:id/actions`

Submit a poker action.

| Python client | `c.send_action("demo", player_id="Alice", action="raise", amount=20)` |
|---|---|
| Auth header | Optional — if present, must match `player_id` or `403` |

**Request body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `player_id` | string | yes | Must be seated |
| `action` | string | yes | `fold`, `check`, `call`, `raise`, `bet`, `all_in` |
| `amount` | integer | conditional | Required for `raise` and `bet` |
| `queue` | boolean | no | `true` = always queue; `false` = error if not your turn; omit = auto-queue when not your turn |

**Response**

```json
{
  "ok": true,
  "queued": false,
  "table": { "...snapshot..." }
}
```

`queued: true` means the action was stored and will execute when it becomes this
player's turn.

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
