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
| `GET` | `/v1/tables/:id/last-winners` | Most recent hand winner(s) and amount won. Persists across the whole next hand so you can poll mid-game. No auth. |
| `GET` | `/v1/tables/:id/busts` | Per-player bust counts (times each player hit zero chips and was either ejected or rebought). No auth. |
| `POST` | `/v1/tables/:id/join` | Take a seat; response includes `token` and `table` |
| `POST` | `/v1/tables/:id/leave` | Leave (`player_id` in JSON) |
| `POST` | `/v1/tables/:id/ready` | Signal readiness from the lobby on a `require_start_flags` / `wait_for_ready` table. Required for every joiner before they are seated and dealt in (applies to both the first cohort and any later mid-game joiner). Body: `{ player_id, ready? }` (`ready` defaults to true). **Requires** `X-Player-Token`. |
| `POST` | `/v1/tables/:id/start` | Alias for `/ready` for bots that model readiness as a start request. |
| `POST` | `/v1/tables/:id/start-flag` | Alias for `/ready` with explicit start-flag naming. |
| `POST` | `/v1/tables/:id/actions` | Submit an action (`player_id`, `action`, optional `amount`, optional `queue`, optional `client_action_id`, optional `expected_action_seq`). **Requires** `X-Player-Token` for any seated player. |

**Actions:** `fold`, `check`, `call`, `raise`, `bet`, `all_in`. For `raise` / `bet`, **`amount`** is your **total contribution this street** (not just the increment). `all_in` is legal even when the stack is too small to call or make a full minimum raise; showdown side pots are awarded from each player's total committed chips. A short `call` is treated as `all_in` instead of being rejected.

**Hardening fields on `POST /actions`:**

- **`client_action_id`** (string, ≤ 128 chars) — idempotency key. The server caches the response per `(player_id, id)` for 60 s; replaying with the same id returns the cached response instead of re-applying or re-queuing. **Always send one on retries** so a "fold" intended for hand N cannot silently become a queued action on hand N+1.
- **`expected_action_seq`** (non-negative integer) — assert the `hand.action_seq` you saw in the snapshot you based this decision on. If the server's current seq differs and the action would apply now, it is rejected with **`stale_action`** (HTTP 409) whose `error.details.current_seq` tells you how far ahead the table has moved. Ignored when the action would be queued.

**Related snapshot field:** `table.action_queue_drops[player_id]` surfaces any queued intent the server discarded at fire time (e.g. the betting round advanced before it fired → `reason: "stale_street"`, or the action became illegal → `reason` equals a game-engine code like `min_raise`). A drop entry for you is cleared by your next successful action submission.

**Mid-hand join:** You can now `POST /join` while a hand is active. You take the seat immediately and are dealt in at the **next** `start_hand`. While the in-progress hand continues, any `/actions` you submit are queued for the next deal (effectively `while_idle = true`); `queue: false` returns `wrong_turn` until you are in an actual hand.

---

## Ready gate for tournament-style tables (`wait_for_ready`)

Tables can be created with the option **`require_start_flags: true`** (alias: `wait_for_ready: true`; admin API on create, or later via `/admin/api/tables/:id/settings`). When set, the server holds **every** joiner in a **pre-game lobby** until they POST `/ready`: they receive a token but **no seat number, no chips deduction, no button/SB/BB position, and no cards** until the gate releases for them. While in the lobby they appear in `ready_status.lobby_players` and the table's `seats` array continues to show empty slots; submitting an action returns `not_ready`.

The lobby is **continuous** — it applies before the first hand *and* between every later hand: a player who joins mid-game lands in the lobby, has to ready up, and is only dealt in for the *next* hand once the gate releases. Players already seated from a previous lobby cohort do **not** have to re-ready every hand; they are considered implicitly ready as long as they remain seated.

The lobby releases when **either**:

- every lobby member has signalled readiness, **the post-release total (seated + ready lobby members) is at least `min_players_to_start`** (default 2), **and** the start-grace window has elapsed (default 8s, env `POKER_START_GRACE_SEC`), **or**
- `action_timeout_sec` has elapsed since the *first* ready signal of the current lobby cohort arrived **and** at least `min_players_to_start` participants are ready — in which case any lobby member who never readied is **fully ejected from the table** (their lobby slot is dropped, their auth token is invalidated, and any running bot is killed) before the rest are seated.

### Holding the gate for the full cohort

By default `min_players_to_start = 2`, which is the engine's absolute minimum. **If you are running an N-handed game and want hand 1 to wait for *all* N players to join + ready (instead of dealing immediately as soon as the first 2 ready), set `min_players_to_start: N`** when you create the table or via `/admin/api/tables/:id/settings`. The gate will then refuse to release until that many participants are present and ready, regardless of how quickly the early joiners flip their flags. Combine it with a generous `start_grace_sec` (e.g. 15–30s) for an even more forgiving window when joiners are still trickling in. The value is clamped to `[2, max_seats]` so it cannot deadlock.

You can set the same defaults globally via `POKER_MIN_PLAYERS_TO_START` and `POKER_START_GRACE_SEC` environment variables.

When the lobby releases, lobby members are **randomly shuffled across the free seats** of the table, blinds are posted, and cards are dealt. Players already seated keep their seat. The optional `seat` field on `POST /join` is ignored while the gate is active — placement of new joiners is randomized by design.

Players signal readiness with:

```http
POST /v1/tables/:id/ready
Content-Type: application/json
X-Player-Token: <token from /join>

{ "player_id": "MyBot", "ready": true }
```

`POST /v1/tables/:id/start` and `POST /v1/tables/:id/start-flag` are aliases with the same body and response.

`ready` is optional and defaults to `true`; pass `false` to withdraw a signal (e.g. if your bot crashes during warm-up). Only the token holder for `player_id` may toggle that player's flag.

**Response**

```json
{
  "ok": true,
  "player_id": "MyBot",
  "ready": true,
  "ready_status": {
    "wait_for_ready": true,
    "require_start_flags": true,
    "first_hand_started": false,
    "in_lobby_phase": true,
    "ready_players": ["MyBot"],
    "waiting_players": ["OtherBot"],
    "lobby_players": ["MyBot", "OtherBot"],
    "all_ready": false,
    "first_ready_received": true,
    "min_players_to_start": 4,
    "start_grace_sec": 8,
    "start_timeout_sec": 60,
    "start_timeout_remaining_sec": 47
  },
  "table": { ... }
}
```

**Behaviour summary**

- A hand does **not** start while there is at least one un-ready non-AI player in `lobby_players`. Actions submitted by lobby members are returned with **`not_ready`** (lobby joiners have no seat to act from). Actions submitted by a *seated* player while the lobby is blocking the next hand are auto-queued for that next hand (or returned with **`not_ready`** when `queue: false`).
- Joins are accepted at any time. They are always appended FIFO to `lobby_players`; even players who join mid-hand land in the lobby and only join the felt for the next hand once they have readied. Lobby members are shuffled into the free seats randomly when the gate releases — pre-existing seats keep their position and only the new lobby cohort is shuffled.
- The hand-end → next-hand transition consults the gate every time. If the lobby is empty and ≥ 2 players are seated, the next hand starts automatically. If a new joiner is in the lobby, the next hand is held until they ready (or time out).
- When the table reaches **zero seated players** *and* the lobby is empty, the gate re-arms (cosmetic — `first_hand_started` returns to false and the start-grace clock is cleared).
- A player who `leave`s (or is kicked) is removed from `ready_players` and from any lobby slot; if that leave empties both the table and the lobby, all ready flags and queued actions are cleared for the next cohort.
- **Admin `POST /admin/api/tables/:id/reset`** force-empties the table and lobby and re-arms the gate.
- **Admin `POST /admin/api/tables/:id/settings`** with `require_start_flags: true` migrates any humans currently seated back into the lobby so they have to ready up again before the next deal (AI players keep their seat).

The flag is surfaced on every snapshot as `table.ready` and on `GET /v1/tables` as `wait_for_ready` / `first_hand_started`, so clients can poll to see who is still holding things up. Use `start_timeout_remaining_sec` to render a countdown — once it hits zero any still-un-ready lobby member is **ejected** from the table (they must `POST /join` again to re-enter, which puts them back in the lobby) and the surviving ready cohort is seated. Late joiners do **not** reset the timer; if they want to play in the impending hand they must ready up before the existing window closes.

---

## Last-hand winner and bust counts

Two read-only endpoints expose the most recent hand outcome and per-player bust counts. Both fields are also mirrored at the top level of every `/state` snapshot (under `last_winners`, `last_hand_finished_at`, and `bust_counts`) so polling clients don't strictly need to call them — they exist as convenience endpoints for thin UIs and bots that only need the highlight reel.

### `GET /v1/tables/:id/last-winners`

Returns who won the most recent hand on this table. The data persists across the entire next hand (it's only overwritten when the next hand resolves) so you can poll it during an active hand and still see "the previous winner". Cleared on admin reset and when the table goes fully empty.

```json
{
  "ok": true,
  "table_id": "demo",
  "hand_status": "active",
  "street": "flop",
  "last_winners": [
    {
      "seat": 3,
      "player_id": "Alice",
      "amount": 42,
      "hand_name": "Two Pair, Aces and Sevens"
    }
  ],
  "total_awarded": 42,
  "finished_at": 1743031829,
  "had_winner": true,
  "went_to_showdown": true
}
```

- `last_winners` is `null` when no hand has resolved for the current cohort yet (e.g. just after admin reset).
- `had_winner` is a convenience boolean for empty-state rendering.
- `went_to_showdown` is `false` when the hand ended on a single fold (`hand_name == "fold"`); `true` otherwise.
- Ties and side pots can produce multiple `last_winners` entries. `amount` is the total chips awarded to that player across the pot layers they won; `total_awarded` sums them.
- `finished_at` is a Unix timestamp (seconds, server clock).

### `GET /v1/tables/:id/busts`

Returns per-player bust counts — how many times each player has reached zero chips and been either ejected (`zero_chips=eject`) or rebought (`zero_chips=rebuy`). Useful for leaderboards, "biggest grinder" stats, or just to know who keeps going broke. Cleared on admin reset and when the table goes fully empty.

```json
{
  "ok": true,
  "table_id": "demo",
  "bust_counts": { "Alice": 1, "Bob": 3 },
  "busts": [
    { "player_id": "Bob", "count": 3 },
    { "player_id": "Alice", "count": 1 }
  ],
  "total_busts": 4,
  "zero_chips": "rebuy",
  "rebuy_amount": 500
}
```

- `bust_counts` is the raw map, keyed by `player_id`.
- `busts` is a parallel array sorted **descending by `count`** (then ascending by `player_id` for stability) so a leaderboard can render it directly without re-sorting.
- `total_busts` is the sum across all players.
- `zero_chips` and `rebuy_amount` are echoed so clients can phrase the count correctly ("3× ejected" vs "3× rebought for 500").

Both fields are also embedded in `GET /v1/tables/:id/state` as top-level `last_winners`, `last_hand_finished_at`, and `bust_counts`, so a UI that already polls `/state` doesn't need a second round-trip.

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

This script uses **`PokerClient`** only (no `bot_runner` import). It connects to **`https://poker.mineblue.org`** by default, joins a table, and on every turn chooses a simple minimum-pressure action: **raise to** `current_bet + min_raise_increment` when affordable, else call, else all-in if short, else check/fold.

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
    """Minimum pressure: min-raise when possible, else call/all-in, else check/fold."""
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
    if call_need > 0 and stack > 0:
        return {"action": "all_in"}
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

**Who can log in:** Configure Google OAuth with `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`, then list one or more Google accounts:

- **`ADMIN_EMAIL`** — one address, or several separated by commas (e.g. `you@example.com,colleague@example.com`).
- **`ADMIN_EMAILS`** — optional extra comma-separated list merged with `ADMIN_EMAIL` (handy when `ADMIN_EMAIL` is already set by another layer and you only need to append more).

Matching is case-insensitive. After you change env vars, restart the server. Each person signs in at `/admin/oauth/login` with their own Google account; only addresses in the allowlist get a session cookie.

If your OAuth client is in **Testing** mode in Google Cloud Console, add every admin as a **Test user** under APIs & Services → OAuth consent screen, or they will get Google’s “access blocked” error even when their email is on the allowlist.
