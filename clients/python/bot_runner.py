"""
Bot runner: automatically plays poker using a user-supplied strategy function.

Usage::

    from bot_runner import run_bot

    def my_strategy(state, me):
        \"\"\"
        state  – full table state dict from GET /v1/tables/:id/state
        me     – dict with { player_id, seat, stack, hole_cards, contribution }

        Return a dict: { "action": "fold"|"check"|"call"|"raise"|"all_in",
                         "amount": <int> }   (amount only needed for raise/bet)
        \"\"\"
        hand = state["hand"]
        cb = hand["current_bet"]
        mri = hand["min_raise_increment"]
        return {"action": "raise", "amount": cb + mri}

    run_bot(my_strategy)

CLI::

    python bot_runner.py                     # uses built-in min-raise bot
    python bot_runner.py my_bot.py           # loads decide(state, me) from file
    python bot_runner.py --name Bot1 --chips 1000 --url http://localhost:8080
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import time
import traceback
from typing import Any, Callable, Optional

_ROOT = os.path.dirname(os.path.abspath(__file__))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from poker_client import PokerClient, PokerError, TransportError

StrategyFn = Callable[[dict, dict], dict]


def _build_me(state: dict, player_id: str) -> dict:
    """Extract convenience info about our player from the state."""
    seats = state.get("seats") or []
    hand = state.get("hand") or {}
    hole_cards_map = hand.get("hole_cards") or {}
    contrib_map = hand.get("contribution") or {}

    seat = None
    stack = 0
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id") == player_id:
            seat = i
            stack = s.get("stack", 0)
            break

    hole_cards = []
    if isinstance(hole_cards_map, dict) and seat is not None:
        hole_cards = hole_cards_map.get(str(seat), [])

    contribution = 0
    if isinstance(contrib_map, dict) and seat is not None:
        contribution = contrib_map.get(str(seat), 0)

    return {
        "player_id": player_id,
        "seat": seat,
        "stack": stack,
        "hole_cards": hole_cards,
        "contribution": contribution,
    }


def _default_strategy(state: dict, me: dict) -> dict:
    """Built-in fallback: min-raise when possible, else call/all-in, else check."""
    hand = state.get("hand") or {}
    cb = hand.get("current_bet", 0)
    mri = hand.get("min_raise_increment", 5)
    stack = me.get("stack", 0)
    contrib = me.get("contribution", 0)
    target = cb + mri
    need = target - contrib
    if need > 0 and need <= stack:
        return {"action": "raise", "amount": target}
    call_need = cb - contrib
    if call_need > 0 and call_need <= stack:
        return {"action": "call"}
    if call_need > 0 and stack > 0:
        return {"action": "all_in"}
    if contrib >= cb:
        return {"action": "check"}
    return {"action": "fold"}


def _load_strategy_file(path: str) -> StrategyFn:
    """Import a .py file and return its `decide(state, me)` function."""
    spec = importlib.util.spec_from_file_location("user_bot", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load module from {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    fn = getattr(mod, "decide", None)
    if fn is None:
        raise RuntimeError(
            f"{path} must define a top-level function: decide(state, me) -> dict"
        )
    return fn


def run_bot(
    strategy: Optional[StrategyFn] = None,
    *,
    url: str = "http://127.0.0.1:8080",
    table_id: str = "demo",
    player_id: str = "PythonBot",
    chips: Optional[int] = None,
    max_hands: Optional[int] = None,
    poll_interval: float = 0.5,
    verbose: bool = True,
) -> None:
    """
    Join a table and loop forever (or for *max_hands*), calling *strategy*
    each time it is our turn.
    """
    if strategy is None:
        strategy = _default_strategy

    client = PokerClient(url)

    if verbose:
        print(f"[bot] Connecting to {url}, table={table_id}, name={player_id}")

    try:
        resp = client.join_table(table_id, player_id=player_id, chips=chips)
    except PokerError as e:
        print(f"[bot] Join failed: {e}", file=sys.stderr)
        raise SystemExit(1)

    state = resp.get("table", {})
    me = _build_me(state, player_id)
    if verbose:
        print(f"[bot] Seated at seat {me['seat']} with {me.get('stack', '?')} chips")

    hands_played = 0
    try:
        while max_hands is None or hands_played < max_hands:
            if verbose:
                print(f"[bot] Waiting for turn…")

            try:
                state = client.wait_for_turn(
                    table_id, player_id, poll_interval=poll_interval, timeout=300,
                )
            except TimeoutError:
                if verbose:
                    print("[bot] Timed out waiting (5 min). Retrying…")
                continue

            me = _build_me(state, player_id)
            hand = state.get("hand") or {}

            if verbose:
                cards = " ".join(me["hole_cards"]) if me["hole_cards"] else "??"
                comm = " ".join(str(c) for c in (hand.get("community") or []))
                print(
                    f"[bot] Hand: [{cards}]  Community: [{comm}]  "
                    f"Pot: {hand.get('pot', 0)}  Bet: {hand.get('current_bet', 0)}  "
                    f"Stack: {me['stack']}"
                )

            try:
                decision = strategy(state, me)
            except Exception:
                traceback.print_exc()
                decision = {"action": "fold"}
                if verbose:
                    print("[bot] Strategy error — folding")

            action = decision.get("action", "fold")
            amount = decision.get("amount")

            try:
                resp = client.send_action(
                    table_id,
                    player_id=player_id,
                    action=action,
                    amount=amount,
                )
                if verbose:
                    amt_str = f" {amount}" if amount is not None else ""
                    print(f"[bot] -> {action}{amt_str}")
            except PokerError as e:
                if verbose:
                    print(f"[bot] Action rejected: {e.api_code} — {e.message}")

            new_hand = (resp or {}).get("table", {}).get("hand", {})
            if new_hand.get("status") == "idle":
                hands_played += 1
                if verbose:
                    print(f"[bot] Hand finished (total: {hands_played})")

    except KeyboardInterrupt:
        print("\n[bot] Interrupted")
    finally:
        if verbose:
            print(f"[bot] Leaving table…")
        try:
            client.leave_table(table_id, player_id=player_id)
        except Exception:
            pass


def main() -> None:
    default_url = os.environ.get("POKER_URL", "http://127.0.0.1:8080")
    p = argparse.ArgumentParser(description="Poker bot runner (Python)")
    p.add_argument(
        "bot_file", nargs="?", default=None,
        help="Path to a .py file with decide(state, me) -> dict",
    )
    p.add_argument("--url", default=default_url, help="Server URL")
    p.add_argument("--table", default="demo", help="Table ID")
    p.add_argument("--name", default="PythonBot", help="Player name")
    p.add_argument(
        "--chips",
        type=int,
        default=None,
        help="Deprecated: ignored by server; table buy_in_chips is used.",
    )
    p.add_argument("--hands", type=int, default=None, help="Max hands to play")
    p.add_argument("-q", "--quiet", action="store_true", help="Less output")
    args = p.parse_args()

    strategy = None
    if args.bot_file:
        strategy = _load_strategy_file(args.bot_file)
        print(f"[bot] Loaded strategy from {args.bot_file}")

    run_bot(
        strategy,
        url=args.url,
        table_id=args.table,
        player_id=args.name,
        chips=args.chips,  # optional; server uses table buy-in
        max_hands=args.hands,
        verbose=not args.quiet,
    )


if __name__ == "__main__":
    main()
