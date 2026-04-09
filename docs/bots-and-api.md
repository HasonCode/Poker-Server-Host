# Bots and the HTTP API

This document describes how **bots** and other clients talk to the poker server over JSON HTTP. Examples use the public deployment:

**Base URL:** `https://poker.mineblue.org`

Replace it with `http://127.0.0.1:8080` (or your `POKER_PORT`) when developing locally.

---

## Conventions

- **JSON** bodies: `Content-Type: application/json`
- **Table id** in paths: `:id` is the table name (e.g. `demo`, `llm_bots`)
- **After joining**, keep the returned **`token`** and send it on later requests:

  `X-Player-Token: <token>`

- **Starting stack** for new seats is set by the **table** (`rebuy_amount`), not by arbitrary client values. The join body may still include `chips` for older clients; the server seats you with the table’s configured stack.

---

## Core endpoints (bots & clients)

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/health` | Liveness / version |
| `GET` | `/v1/tables` | List public tables (`table_id`, `seated`, `max_seats`, `rebuy_amount`, …) |
| `GET` | `/v1/tables/:id/state` | Full table snapshot (hole cards only for the authenticated seat, if token sent) |
| `POST` | `/v1/tables/:id/join` | Take a seat; response includes `token` and `table` |
| `POST` | `/v1/tables/:id/leave` | Leave (`player_id` in JSON) |
| `POST` | `/v1/tables/:id/actions` | Submit an action (`player_id`, `action`, optional `amount`, optional `queue`) |

**Actions:** `fold`, `check`, `call`, `raise`, `bet`, `all_in`. For `raise` / `bet`, **`amount`** is your **total contribution this street** (not just the increment).

---

## LLM / manual-deal table (optional)

These apply to tables configured with **manual start** (e.g. `llm_bots`):

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/tables/:id/start-hand` | Deal a new hand (requires **spectate** auth; see server env / UI) |
| `POST` | `/v1/tables/:id/llm-step` | Run one server-side LLM step (spectate password / admin; not for generic bots) |
| `GET` | `/v1/tables/:id/llm-step-log` | Streaming log for that step (spectate auth) |

For **custom bots**, you normally only need **`join`**, **`state`**, and **`actions`** (and **`leave`** on exit).

---

## Server-hosted bot processes (upload API)

The main **web UI** can upload a `.py` or `.lua` file; the server saves it and runs the official **bot runner** next to the server process.

| Method | Path | Body (JSON) |
|--------|------|----------------|
| `POST` | `/v1/tables/:id/bot/start` | `player_id`, `code` (file contents), optional `filename` |
| `POST` | `/v1/tables/:id/bot/stop` | `player_id` |
| `GET` | `/v1/tables/:id/bot/list` | — |

Response of **`bot/start`** includes `lang` (`python` / `lua`) and OS `pid` when spawn succeeds. Stack size follows the table **`rebuy_amount`**.

**Python** bots must define a top-level function:

```python
def decide(state: dict, me: dict) -> dict:
    return {"action": "call"}  # or raise with "amount": <int>
```

**Lua** bots expose a similar `decide` (see `bots/example_bot.lua` in the repo).

---

## curl examples (`https://poker.mineblue.org`)

**Health**

```bash
curl -sS https://poker.mineblue.org/health
```

**List tables**

```bash
curl -sS https://poker.mineblue.org/v1/tables
```

**Join** table `demo` as player `MyBot` (stack is determined by the table)

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/demo/join \
  -H 'Content-Type: application/json' \
  -d '{"player_id":"MyBot","chips":500}'
```

Save `token` from the JSON response.

**Poll state** (optional: no token = no private hole cards)

```bash
curl -sS https://poker.mineblue.org/v1/tables/demo/state
```

**Act** (replace `TOKEN` and amounts with real values)

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/demo/actions \
  -H 'Content-Type: application/json' \
  -H 'X-Player-Token: TOKEN' \
  -d '{"player_id":"MyBot","action":"call"}'
```

**Leave**

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/demo/leave \
  -H 'Content-Type: application/json' \
  -H 'X-Player-Token: TOKEN' \
  -d '{"player_id":"MyBot"}'
```

---

## Python: `poker_client` + `bot_runner`

The repo ships a **stdlib-only** client: `clients/python/poker_client.py`. The **`bot_runner`** loops: wait until it is your turn, call your strategy, then `POST` the action.

**Environment**

```bash
export POKER_URL=https://poker.mineblue.org
```

**Run the bundled min-raise logic (no custom file)**

```bash
cd /path/to/poker_server
python3 clients/python/bot_runner.py \
  --url https://poker.mineblue.org \
  --table demo \
  --name MyBot
```

**Run a custom bot file** (must define `decide(state, me)`)

```bash
python3 clients/python/bot_runner.py bots/example_bot.py \
  --url https://poker.mineblue.org \
  --table demo \
  --name Raiser
```

Useful flags:

| Flag | Meaning |
|------|---------|
| `--url` | Server base URL |
| `--table` | Table id |
| `--name` | `player_id` when joining |
| `--chips` | Sent on join; effective stack is still table policy |
| `--hands` | Stop after N completed hands (optional) |
| `-q` / `--quiet` | Less logging |

**Programmatic import**

```python
from bot_runner import run_bot

def decide(state, me):
    return {"action": "fold"}

run_bot(decide, url="https://poker.mineblue.org", table_id="demo", player_id="InlineBot")
```

---

## State shape (for `decide`)

Important keys your bot will read:

- `state["hand"]["status"]` — `"active"` or `"idle"`
- `state["hand"]["street"]`, `["community"]`, `["pot"]`, `["current_bet"]`, `["min_raise_increment"]`, `["action_to_seat"]`
- `state["seats"]` — per-seat `player_id`, `stack`
- **`me`** (built by the runner): `player_id`, `seat`, `stack`, `hole_cards`, `contribution` (your share this street)

---

## Lua

See `src/poker/bot_runner.lua` and `bots/example_bot.lua`. Run with Lua on your PATH, `package.path` pointing at the repo `src/`, same HTTP API as Python.

---

## Common pitfalls

1. **403 `Token does not match player_id`** — Every `PokerClient` instance is tied to **one** `player_id` from `join`. Send actions only with the client that joined as that player.
2. **Wrong `amount` on raises** — Must be **total** chips committed on **this street**, not “add this many chips”.
3. **HTTPS** — Use `https://` for production; avoid mixed content if the bot runs in a browser context.
4. **Table list** — Hidden tables (e.g. some LLM-only ids) may not appear on `GET /v1/tables`; you can still use `GET /v1/tables/:id/state` if routing allows.

---

## Admin / OAuth

Routes under `/admin/...` are for operators (OAuth, snapshots, kicks). They are **not** required for user bots using `join` / `state` / `actions`.
