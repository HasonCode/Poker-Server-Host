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
| `GET` | `/v1/tables/:id/my-turn` | Whether it is **your** turn: requires `X-Player-Token`; response `{ "ok": true, "player_id": "...", "is_my_turn": true|false }` |
| `POST` | `/v1/tables/:id/join` | Take a seat; response includes `token` and `table` |
| `POST` | `/v1/tables/:id/leave` | Leave (`player_id` in JSON) |
| `POST` | `/v1/tables/:id/ready` | Signal readiness for the current empty-table cohort's first hand on a `wait_for_ready` table. Body: `{ player_id, ready? }` (`ready` defaults to true). **Requires** `X-Player-Token`. |
| `POST` | `/v1/tables/:id/start` | Alias for `/ready` for bots that model readiness as a start request. |
| `POST` | `/v1/tables/:id/actions` | Submit an action (`player_id`, `action`, optional `amount`, optional `queue`, optional `client_action_id`, optional `expected_action_seq`). **Requires** `X-Player-Token` for any seated player. |

**Actions:** `fold`, `check`, `call`, `raise`, `bet`, `all_in`. For `raise` / `bet`, **`amount`** is your **total contribution this street** (not just the increment).

**Hardening fields on `POST /actions`:**

- **`client_action_id`** (string, ≤ 128 chars) — idempotency key. The server caches the response per `(player_id, id)` for 60 s; replaying with the same id returns the cached response instead of re-applying or re-queuing. **Always send one on retries** so a "fold" intended for hand N cannot silently become a queued action on hand N+1.
- **`expected_action_seq`** (non-negative integer) — assert the `hand.action_seq` you saw in the snapshot you based this decision on. If the server's current seq differs and the action would apply now, it is rejected with **`stale_action`** (HTTP 409) whose `error.details.current_seq` tells you how far ahead the table has moved. Ignored when the action would be queued.

**Related snapshot field:** `table.action_queue_drops[player_id]` surfaces any queued intent the server discarded at fire time (e.g. the betting round advanced before it fired → `reason: "stale_street"`, or the action became illegal → `reason` equals a game-engine code like `min_raise`). A drop entry for you is cleared by your next successful action submission.

**Mid-hand join:** You can now `POST /join` while a hand is active. You take the seat immediately and are dealt in at the **next** `start_hand`. While the in-progress hand continues, any `/actions` you submit are queued for the next deal (effectively `while_idle = true`); `queue: false` returns `wrong_turn` until you are in an actual hand.

---

## Ready gate for tournament-style tables (`wait_for_ready`)

Tables can be created with the option **`wait_for_ready: true`** (admin API on create, or later via `/admin/api/tables/:id/settings`). When set, the server **will not deal the first hand after a table has been empty** until every seated player has explicitly signalled readiness with:

```http
POST /v1/tables/:id/ready
Content-Type: application/json
X-Player-Token: <token from /join>

{ "player_id": "MyBot", "ready": true }
```

`POST /v1/tables/:id/start` is an alias with the same body and response.

`ready` is optional and defaults to `true`; pass `false` to withdraw a signal (e.g. if your bot crashes during warm-up). Only the token holder for `player_id` may toggle that player's flag.

**Response**

```json
{
  "ok": true,
  "player_id": "MyBot",
  "ready": true,
  "ready_status": {
    "wait_for_ready": true,
    "first_hand_started": false,
    "ready_players": ["MyBot"],
    "waiting_players": ["OtherBot"],
    "all_ready": false
  },
  "table": { ... }
}
```

**Behaviour summary**

- The cohort's first hand does **not** start until `ready_players` covers every currently-seated player **and** at least two players are seated. Actions submitted before then are auto-queued and fire on the deal; sending `"queue": false` returns **`not_ready`** (HTTP 409).
- Once that first hand is dealt, every subsequent hand proceeds automatically for as long as the table never becomes empty.
- When the table reaches **zero seated players**, the gate re-arms. The next set of players must send `/ready` or `/start` again before their first hand.
- A player who `leave`s (or is kicked) is removed from `ready_players`; if that leave makes the table empty, all ready flags and queued actions are cleared for the next cohort.
- **Admin `POST /admin/api/tables/:id/reset`** also re-arms the gate — all ready flags are cleared and a fresh round of ready signals is required.

The flag is surfaced on every snapshot as `table.ready` and on `GET /v1/tables` as `wait_for_ready` / `first_hand_started`, so clients can poll to see who is still holding things up.

---

## LLM / manual-deal table (optional)

These apply to tables configured with **manual start** (e.g. `llm_bots`):

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/tables/:id/start-hand` | Deal a new hand (requires **spectate** auth; see server env / UI) |
| `POST` | `/v1/tables/:id/llm-step` | Run one server-side LLM step (spectate password / admin; not for generic bots) |
| `GET` | `/v1/tables/:id/llm-step-log` | Streaming log for that step (spectate auth) |

For **custom bots**, you normally only need **`join`**, **`state`**, and **`actions`** (and **`leave`** on exit). Use **`my-turn`** if you want a small JSON response instead of parsing the full **`state`** snapshot.

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

**Join** table `players` as player `MyBot` (stack is the table **buy-in**)

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/players/join \
  -H 'Content-Type: application/json' \
  -d '{"player_id":"MyBot"}'
```

Save `token` from the JSON response.

**Poll state** (optional: no token = no private hole cards)

```bash
curl -sS https://poker.mineblue.org/v1/tables/players/state
```

**Check if it is your turn** (requires the token from **join**; `401` if missing or invalid, `404` if that player is not seated)

```bash
curl -sS -H 'X-Player-Token: TOKEN' \
  https://poker.mineblue.org/v1/tables/players/my-turn
```

**Act** (replace `TOKEN` and amounts with real values)

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/players/actions \
  -H 'Content-Type: application/json' \
  -H 'X-Player-Token: TOKEN' \
  -d '{"player_id":"MyBot","action":"call"}'
```

**Leave**

```bash
curl -sS -X POST https://poker.mineblue.org/v1/tables/players/leave \
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

## Example: API caller (production URL, minimum raise each action)

This script uses **`PokerClient`** only (no `bot_runner` import). It connects to **`https://poker.mineblue.org`** by default, joins a table, and on every turn chooses the **cheapest legal action**: check if free, else call, else **raise to** `current_bet + min_raise_increment` (minimum legal total for that street), else fold.

The same source lives in the repo as **`clients/python/api_caller_min_bet.py`**.

**Run from the repo** (so `poker_client.py` is importable):

```bash
export POKER_URL=https://poker.mineblue.org
python3 api_caller_min_bet.py --table players --name MinCaller
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--url` | `$POKER_URL` or `https://poker.mineblue.org` | Server base URL |
| `--table` | `players` | Table id |
| `--name` | `MinCaller` | `player_id` (must be unique at the table) |
| `--poll` | `0.5` | Poll interval while waiting for your turn |
| `--wait-turn-timeout` | `600` | Seconds before `wait_for_turn` retries |

Join uses the table’s configured **buy-in**; the script does not send a custom stack. If join is **deferred** (hand in progress), keep the process running — the client uses a long timeout on `POST /join` like the rest of the Python tools.

**Full script** (`api_caller_min_bet.py`):

```python
#!/usr/bin/env python3
"""
Minimal API caller: join https://poker.mineblue.org (or any base URL) and,
on each turn, take the cheapest legal line — prefer check/call, otherwise
raise to the *minimum legal total* for this street (current_bet + min_raise_increment).

Uses only stdlib + poker_client.py in this directory.

  export POKER_URL=https://poker.mineblue.org
  python3 api_caller_min_bet.py --table players --name MinBot
"""

from __future__ import annotations

import argparse
import os
import sys
import time

# Allow: python3 api_caller_min_bet.py from clients/python/
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from poker_client import PokerClient, PokerError, TransportError


def decide_min(state: dict, me: dict) -> dict:
    """Minimum chips to stay competitive: check > call > min-raise > fold."""
    hand = state.get("hand") or {}
    cb = int(hand.get("current_bet") or 0)
    mri = int(hand.get("min_raise_increment") or 1)
    stack = int(me.get("stack") or 0)
    contrib = int(me.get("contribution") or 0)

    target = cb + mri
    need_for_min_raise = target - contrib
    if need_for_min_raise > 0 and need_for_min_raise <= stack:
        return {"action": "raise", "amount": target}

    call_need = cb - contrib
    if call_need > 0 and call_need <= stack:
        return {"action": "call"}
    if contrib >= cb:
        return {"action": "check"}
    return {"action": "fold"}


def main() -> None:
    default_url = os.environ.get("POKER_URL", "https://poker.mineblue.org")
    p = argparse.ArgumentParser(description="Poker API caller — minimum bet/raise each action")
    p.add_argument("--url", default=default_url, help="Server base URL")
    p.add_argument("--table", default="players", help="Table id (default: players)")
    p.add_argument("--name", default="MinCaller", help="player_id when joining")
    p.add_argument("--poll", type=float, default=0.5, help="Seconds between state polls when waiting")
    p.add_argument("--wait-turn-timeout", type=float, default=600.0, help="Max seconds to wait for our turn (per wait)")
    args = p.parse_args()

    client = PokerClient(args.url, timeout=60.0)

    try:
        print(f"[api_caller] Joining {args.url} table={args.table} as {args.name!r}")
        client.join_table(args.table, player_id=args.name)
    except (PokerError, TransportError) as e:
        print(f"[api_caller] Join failed: {e}", file=sys.stderr)
        raise SystemExit(1)

    hands_done = 0
    try:
        while True:
            try:
                state = client.wait_for_turn(
                    args.table,
                    args.name,
                    poll_interval=args.poll,
                    timeout=args.wait_turn_timeout,
                )
            except TimeoutError:
                print("[api_caller] Still waiting for a turn (timeout); polling again…")
                time.sleep(1.0)
                continue

            me = _build_me(state, args.name)
            decision = decide_min(state, me)
            act = decision["action"]
            amt = decision.get("amount")

            try:
                resp = client.send_action(
                    args.table,
                    player_id=args.name,
                    action=act,
                    amount=amt,
                )
            except PokerError as e:
                print(f"[api_caller] Action rejected: {e.api_code} — {e.message}")
                continue

            tbl = (resp or {}).get("table") or {}
            h = tbl.get("hand") or {}
            if h.get("status") == "idle":
                hands_done += 1
                print(f"[api_caller] Hand finished (count={hands_done})")

    except KeyboardInterrupt:
        print("\n[api_caller] Interrupted")
    finally:
        try:
            client.leave_table(args.table, player_id=args.name)
        except Exception:
            pass
        print("[api_caller] Left table.")


def _build_me(state: dict, player_id: str) -> dict:
    seats = state.get("seats") or []
    hand = state.get("hand") or {}
    hc_map = hand.get("hole_cards") or {}
    contrib_map = hand.get("contribution") or {}
    seat = None
    stack = 0
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id") == player_id:
            seat = i
            stack = int(s.get("stack") or 0)
            break
    contribution = 0
    if seat is not None and isinstance(contrib_map, dict):
        contribution = int(contrib_map.get(str(seat), 0) or 0)
    return {
        "player_id": player_id,
        "seat": seat,
        "stack": stack,
        "contribution": contribution,
    }


if __name__ == "__main__":
    main()
```

---

## State shape (for `decide`)

Important keys your bot will read:

- `state["hand"]["status"]` — `"active"` or `"idle"`
- `state["hand"]["street"]`, `["community"]`, `["pot"]`, `["current_bet"]`, `["min_raise_increment"]`, `["action_to_seat"]`
- `state["hand"]["action_to_player_id"]` — `player_id` who must act when the hand is active (or omitted when none)
- `state["hand"]["is_my_turn"]` — `true` / `false` when you sent `X-Player-Token` on **`GET .../state`**; otherwise omitted
- `state["seats"]` — per-seat `player_id`, `stack`
- **`me`** (built by the runner): `player_id`, `seat`, `stack`, `hole_cards`, `contribution` (your share this street)

---

## Lua

See `src/poker/bot_runner.lua` and `bots/example_bot.lua`. Run with Lua on your PATH, `package.path` pointing at the repo `src/`, same HTTP API as Python.

---

## Common pitfalls

1. **401 `token_required` / 403 `token_invalid`** — `POST /actions` now requires `X-Player-Token` for any seated player, and the token must map to `player_id`. Every `PokerClient` instance is tied to **one** `player_id` from `join`.
2. **Wrong `amount` on raises** — Must be **total** chips committed on **this street**, not “add this many chips”.
3. **HTTPS** — Use `https://` for production; avoid mixed content if the bot runs in a browser context.
4. **Table list** — Hidden tables (e.g. some LLM-only ids) may not appear on `GET /v1/tables`; you can still use `GET /v1/tables/:id/state` if routing allows.
5. **Network retries without `client_action_id`** — Resubmitting the same `POST /actions` after a transport error can apply/queue it twice. Always include a fresh `client_action_id` per logical decision and reuse it across retries of that decision.
6. **Acting on stale state** — Between your `GET /state` and your `POST /actions`, another request (or a timeout firing during someone else's `GET /state`) can advance the hand. Pass `expected_action_seq = hand.action_seq` to have the server reject out-of-date submissions with `stale_action` (409) rather than folding / checking in the wrong spot.

---

## Admin / OAuth

Routes under `/admin/...` are for operators (OAuth, snapshots, kicks). They are **not** required for user bots using `join` / `state` / `my-turn` / `actions`.
