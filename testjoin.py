#!/usr/bin/env python3
"""
Interactive poker console client.

Run from the repo root with the server up::

    python testjoin.py
    python testjoin.py --url http://127.0.0.1:8080 --name Carol --chips 1000
"""

from __future__ import annotations

import argparse
import os
import sys

_ROOT = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_ROOT, "clients", "python"))

from poker_client import PokerClient, PokerError, TransportError

TABLE = "demo"

# ── display helpers ──────────────────────────────────────────────────────

def _seat_label(i: int, seat: dict | bool, hand: dict) -> str:
    if not isinstance(seat, dict):
        return f"  Seat {i}: -- empty --"
    pid = seat["player_id"]
    stack = seat["stack"]
    tags: list[str] = []
    if hand.get("button_seat") == i:
        tags.append("BTN")
    if hand.get("sb_seat") == i:
        tags.append("SB")
    if hand.get("bb_seat") == i:
        tags.append("BB")
    contribs = hand.get("contribution") or {}
    contrib = contribs.get(str(i), 0) if isinstance(contribs, dict) else 0
    folded_map = hand.get("folded") or {}
    if isinstance(folded_map, dict) and folded_map.get(str(i)):
        tags.append("FOLDED")
    if hand.get("action_to_seat") == i:
        tags.append("* TO ACT *")
    tag_str = f"  [{', '.join(tags)}]" if tags else ""
    return f"  Seat {i}: {pid}  chips={stack}  bet={contrib}{tag_str}"


def show_table(state: dict, player: str = "") -> None:
    hand = state.get("hand") or {}
    seats = state.get("seats") or []
    max_s = state.get("max_seats", len(seats))
    print()
    print("=" * 52)
    print(f"  Table: {state.get('table_id', '?')}   "
          f"Status: {hand.get('status', '?')}   "
          f"Street: {hand.get('street', '?')}")
    print(f"  Pot: {hand.get('pot', 0)}   "
          f"Current bet: {hand.get('current_bet', 0)}   "
          f"Min raise increment: {hand.get('min_raise_increment', 0)}")
    comm = hand.get("community") or []
    if comm:
        print(f"  Community: {' '.join(str(c) for c in comm)}")

    hole_cards = hand.get("hole_cards") or {}
    my_seat = None
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id") == player:
            my_seat = i
            break
    if isinstance(hole_cards, dict) and my_seat is not None:
        cards = hole_cards.get(str(my_seat)) or []
        if cards:
            print(f"  Your hand: {' '.join(cards)}")

    winners = hand.get("last_winners")
    if winners and isinstance(winners, list):
        for w in winners:
            hname = w.get("hand_name", "")
            hname_str = f" ({hname})" if hname and hname != "fold" else ""
            print(f"  ** {w.get('player_id','?')} won {w.get('amount',0)} chips{hname_str} **")

    print("-" * 52)
    for i in range(1, max_s + 1):
        seat = seats[i - 1] if i <= len(seats) else False
        print(_seat_label(i, seat, hand))
    print("=" * 52)


def show_log(state: dict, n: int = 8) -> None:
    hand = state.get("hand") or {}
    log = hand.get("action_log") or []
    entries = log[-n:]
    if not entries:
        print("  (no actions yet)")
        return
    for e in entries:
        amt = f"  amount={e['amount']}" if e.get("amount") is not None else ""
        print(f"  [{e.get('street', '?')}] {e['player_id']} -> {e['action']}{amt}")


def show_queue(state: dict) -> None:
    q = state.get("action_queue") or {}
    if not q:
        print("  (queue empty)")
        return
    for pid, ent in q.items():
        amt = f" amount={ent['amount']}" if ent.get("amount") is not None else ""
        print(f"  {pid}: {ent['action']}{amt}")


HELP = """\
Commands:
  hand / h          Show table & hand state
  log  / l [N]      Show last N actions (default 8)
  queue / q         Show queued actions
  fold / f          Fold
  check / x         Check
  call / c          Call
  raise / r <amt>   Raise (total street contribution)
  bet / b <amt>     Bet (alias for raise)
  allin / a         All-in
  help / ?          Show this help
  quit / exit       Leave the game
"""

# ── main loop ────────────────────────────────────────────────────────────

def game_loop(client: PokerClient, player: str) -> None:
    print(HELP)

    state = client.get_table_state(TABLE)
    show_table(state, player)

    while True:
        hand = (state.get("hand") or {})
        status = hand.get("status", "idle")

        if status != "active" or not _is_my_turn(state, player):
            print(f"\nWaiting for your turn...")
            try:
                state = client.wait_for_turn(TABLE, player, timeout=120)
            except TimeoutError:
                print("Timed out waiting. Refreshing state...")
                state = client.get_table_state(TABLE)
            show_table(state, player)

        try:
            raw = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            _leave(client, player)
            return

        if not raw:
            continue

        parts = raw.split(None, 1)
        cmd = parts[0].lower()
        arg = parts[1].strip() if len(parts) > 1 else ""

        try:
            if cmd in ("quit", "exit"):
                _leave(client, player)
                return

            elif cmd in ("help", "?"):
                print(HELP)

            elif cmd in ("hand", "h"):
                state = client.get_table_state(TABLE)
                show_table(state, player)

            elif cmd in ("log", "l"):
                n = int(arg) if arg.isdigit() else 8
                state = client.get_table_state(TABLE)
                show_log(state, n)

            elif cmd in ("queue", "q"):
                state = client.get_table_state(TABLE)
                show_queue(state)

            elif cmd in ("fold", "f"):
                resp = client.send_action(TABLE, player_id=player, action="fold")
                state = _after_action(resp, "Folded.", player)

            elif cmd in ("check", "x"):
                resp = client.send_action(TABLE, player_id=player, action="check")
                state = _after_action(resp, "Checked.", player)

            elif cmd in ("call", "c"):
                resp = client.send_action(TABLE, player_id=player, action="call")
                state = _after_action(resp, "Called.", player)

            elif cmd in ("raise", "r", "bet", "b"):
                if not arg:
                    print("Usage: raise <amount>  (total street contribution)")
                    continue
                try:
                    amount = int(arg)
                except ValueError:
                    print("Amount must be an integer.")
                    continue
                resp = client.send_action(
                    TABLE, player_id=player, action="raise", amount=amount
                )
                state = _after_action(resp, f"Raised to {amount}.", player)

            elif cmd in ("allin", "a"):
                resp = client.send_action(TABLE, player_id=player, action="all_in")
                state = _after_action(resp, "All-in!", player)

            else:
                print(f"Unknown command: {cmd!r}  (type 'help' for commands)")

        except PokerError as e:
            print(f"  Server error: {e.api_code or e.status_code} — {e.message}")
            state = client.get_table_state(TABLE)


def _leave(client: PokerClient, player: str) -> None:
    try:
        client.leave_table(TABLE, player_id=player)
        print(f"{player} left the table. Goodbye!")
    except PokerError as e:
        print(f"Leave failed: {e.api_code} — {e.message}")
    except TransportError:
        print("Could not reach server. Goodbye!")


def _after_action(resp: dict, msg: str, player: str = "") -> dict:
    if resp.get("queued"):
        print(f"  (queued) {msg}")
    else:
        print(f"  {msg}")
    state = resp.get("table", {})
    show_table(state, player)
    return state


def _is_my_turn(state: dict, player: str) -> bool:
    hand = state.get("hand") or {}
    if hand.get("status") != "active":
        return False
    ats = hand.get("action_to_seat")
    seats = state.get("seats") or []
    if not isinstance(ats, int) or ats < 1 or ats > len(seats):
        return False
    info = seats[ats - 1]
    return isinstance(info, dict) and info.get("player_id") == player


def main() -> None:
    default_url = os.environ.get("POKER_URL", "http://127.0.0.1:8080")
    p = argparse.ArgumentParser(description="Interactive poker console client")
    p.add_argument(
        "--url", default=default_url,
        help="Server base URL (default: $POKER_URL or http://127.0.0.1:8080)",
    )
    p.add_argument("--name", default="Hason", help="Player name (default: Hason)")
    p.add_argument("--chips", type=int, default=500, help="Starting chips (default: 500)")
    args = p.parse_args()

    player = args.name
    client = PokerClient(args.url)

    try:
        resp = client.join_table(TABLE, player_id=player, chips=args.chips)
        state = resp.get("table", {})
        seats = state.get("seats", [])
        for i, s in enumerate(seats, 1):
            if isinstance(s, dict) and s.get("player_id") == player:
                print(f"Joined table '{TABLE}' at seat {i} with {args.chips} chips.")
                break
    except PokerError as e:
        print(f"Could not join: {e.api_code} — {e.message}", file=sys.stderr)
        raise SystemExit(1)
    except TransportError as e:
        print(f"Connection failed: {e}", file=sys.stderr)
        raise SystemExit(2)

    try:
        game_loop(client, player)
    except TransportError as e:
        print(f"\nConnection lost: {e}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
