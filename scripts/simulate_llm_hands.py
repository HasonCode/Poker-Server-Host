#!/usr/bin/env python3
"""
Run N full poker hands with configured LLM players against a running poker server,
and write a CSV log (actions, blinds rotation, rebuys, winners).

Requires:
  - Server running (e.g. main.lua) with table ``llm_bots`` (manual start-hand).
  - API keys in the environment for each joined player (same as ``python -m llm_players``).
  - ``POKER_LLM_SPECTATE_PASSWORD`` if the server overrides the default spectate password.

Blinds / buy-in: sent via POST /v1/tables/:id/table-settings (spectate password)
before players join. Starting stack for each seat follows the table rebuy_amount.

Usage:
  PYTHONPATH=. python3 scripts/simulate_llm_hands.py --hands 5 --sb 2 --bb 5 --chips 1000 \\
    --out simulation.csv --url http://127.0.0.1:8080 --table llm_bots
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CLIENT_PY = os.path.join(_ROOT, "clients", "python")
if _CLIENT_PY not in sys.path:
    sys.path.insert(0, _CLIENT_PY)
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from poker_client import PokerClient, PokerError  # noqa: E402

from llm_players.config import DEFAULT_PLAYERS, DEFAULT_TABLE_ID, PlayerConfig  # noqa: E402
from llm_players.providers import resolve_model_env  # noqa: E402
from llm_players.runner import _decide, _join_players_parallel  # noqa: E402

CSV_HEADERS = [
    "record_type",
    "hand_number",
    "step_index",
    "player_id",
    "action",
    "amount",
    "street",
    "button_seat",
    "sb_seat",
    "bb_seat",
    "sb_amount",
    "bb_amount",
    "data_json",
]


def _spectate_password() -> str:
    return (os.environ.get("POKER_LLM_SPECTATE_PASSWORD") or "1234").strip()


_SUIT_UNICODE_TO_LETTER = {"♠": "S", "♥": "H", "♦": "D", "♣": "C"}
_ASCII_SUIT_TO_LETTER = {"s": "S", "h": "H", "d": "D", "c": "C"}


def format_card_compact(card: str) -> str:
    """
    Server uses rank + suit symbol (e.g. 4♣, 10♥). CSV uses 4C, 10H (rank + letter).
    """
    s = str(card).strip()
    if not s:
        return ""
    last = s[-1]
    if last in _SUIT_UNICODE_TO_LETTER:
        return (s[:-1] + _SUIT_UNICODE_TO_LETTER[last]).upper()
    if last.lower() in _ASCII_SUIT_TO_LETTER:
        return (s[:-1] + _ASCII_SUIT_TO_LETTER[last.lower()]).upper()
    return s.upper()


def get_spectate_state(base_url: str, table_id: str) -> dict[str, Any]:
    """Full table snapshot with all hole cards (spectate password)."""
    q = urllib.parse.urlencode(
        {"spectate": "1", "spectate_password": _spectate_password()}
    )
    tid = urllib.parse.quote(table_id, safe="")
    url = f"{base_url.rstrip('/')}/v1/tables/{tid}/state?{q}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=60.0) as resp:
        return json.loads(resp.read().decode("utf-8"))


def hole_cards_by_player(state: dict[str, Any]) -> dict[str, list[str]]:
    hc = (state.get("hand") or {}).get("hole_cards") or {}
    seats = state.get("seats") or []
    out: dict[str, list[str]] = {}
    if not isinstance(hc, dict):
        return out
    for seat_key, cards in hc.items():
        if not isinstance(cards, list):
            continue
        try:
            si = int(seat_key)
        except (TypeError, ValueError):
            continue
        if 1 <= si <= len(seats):
            row = seats[si - 1]
            if isinstance(row, dict) and row.get("player_id"):
                pid = str(row["player_id"])
                out[pid] = [format_card_compact(c) for c in cards]
    return out


def community_cards_compact(state: dict[str, Any]) -> list[str]:
    comm = (state.get("hand") or {}).get("community") or []
    if not isinstance(comm, list):
        return []
    return [format_card_compact(c) for c in comm]


def _post_json(
    base_url: str,
    path: str,
    body: dict[str, Any],
    *,
    timeout: float = 30.0,
) -> dict[str, Any] | None:
    url = base_url.rstrip("/") + path
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            j = json.loads(raw)
        except json.JSONDecodeError:
            j = None
        msg = f"HTTP {e.code} {raw[:500]}"
        if isinstance(j, dict) and j.get("error"):
            err = j["error"]
            if isinstance(err, dict) and err.get("message"):
                msg = err["message"]
        raise RuntimeError(f"{e.code} {msg}") from e


def post_table_settings(
    base_url: str,
    table_id: str,
    *,
    sb_amount: int,
    bb_amount: int,
    rebuy_amount: int,
) -> None:
    tid = urllib.parse.quote(table_id, safe="")
    body: dict[str, Any] = {
        "spectate_password": _spectate_password(),
        "sb_amount": sb_amount,
        "bb_amount": bb_amount,
        "rebuy_amount": rebuy_amount,
    }
    _post_json(base_url, f"/v1/tables/{tid}/table-settings", body)


def post_start_hand(base_url: str, table_id: str) -> dict[str, Any] | None:
    tid = urllib.parse.quote(table_id, safe="")
    body = {"spectate_password": _spectate_password()}
    return _post_json(base_url, f"/v1/tables/{tid}/start-hand", body, timeout=60.0)


def post_start_hand_safe(
    base_url: str,
    table_id: str,
    probe: PokerClient,
) -> dict[str, Any] | None:
    for _ in range(4):
        try:
            return post_start_hand(base_url, table_id)
        except RuntimeError as e:
            s = str(e).lower()
            if "409" in s or "hand_not_idle" in s or "already in progress" in s:
                wait_hand_idle(probe, table_id, timeout=180.0)
                continue
            raise
    raise RuntimeError("start-hand failed after retries (table still not idle?)")


def _stacks_seat_order(state: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    seats = state.get("seats") or []
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id"):
            pid = str(s["player_id"])
            out[f"seat_{i}"] = {"player_id": pid, "stack": s.get("stack")}
    return out


def _stack_for_player(state: dict[str, Any], player_id: str) -> Any:
    for s in state.get("seats") or []:
        if isinstance(s, dict) and s.get("player_id") == player_id:
            return s.get("stack")
    return None


def _actor_pid(state: dict[str, Any]) -> str | None:
    h = state.get("hand") or {}
    if h.get("status") != "active":
        return None
    ats = h.get("action_to_seat")
    seats = state.get("seats") or []
    if not isinstance(ats, int) or ats < 1 or ats > len(seats):
        return None
    row = seats[ats - 1]
    if not isinstance(row, dict):
        return None
    pid = row.get("player_id")
    return str(pid) if pid else None


def wait_hand_idle(client: PokerClient, table_id: str, timeout: float = 300.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st = client.get_table_state(table_id)
        h = st.get("hand") or {}
        if h.get("status") == "idle":
            return
        time.sleep(0.25)
    raise TimeoutError("Timed out waiting for hand to finish (idle).")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Simulate N hands with LLM players and log results to CSV.",
    )
    p.add_argument(
        "--hands",
        type=int,
        required=True,
        help="Number of hands to play (each starts with POST start-hand).",
    )
    p.add_argument(
        "--sb",
        type=int,
        required=True,
        help="Small blind amount (applied before join; table rebuy_amount = chips).",
    )
    p.add_argument(
        "--bb",
        type=int,
        required=True,
        help="Big blind amount.",
    )
    p.add_argument(
        "--chips",
        type=int,
        required=True,
        help="Starting / rebuy stack size (table rebuy_amount; each seat gets this on join).",
    )
    p.add_argument(
        "--out",
        type=str,
        required=True,
        help="Output CSV path.",
    )
    p.add_argument(
        "--url",
        default=os.environ.get("POKER_SERVER_URL", "http://127.0.0.1:8080"),
        help="Server base URL",
    )
    p.add_argument(
        "--table",
        default=os.environ.get("POKER_LLM_TABLE", DEFAULT_TABLE_ID),
        help=f"Table id (default {DEFAULT_TABLE_ID})",
    )
    p.add_argument(
        "--players",
        default="",
        help="Comma-separated player_ids to include (default: all configured).",
    )
    p.add_argument(
        "--max-steps",
        type=int,
        default=800,
        help="Safety cap on betting actions per hand (default 800).",
    )
    return p.parse_args()


def main() -> None:
    args = parse_args()
    if args.hands < 1:
        raise SystemExit("--hands must be >= 1")
    if args.sb < 1 or args.bb < 1 or args.chips < 1:
        raise SystemExit("--sb, --bb, --chips must be positive integers")

    players: tuple[PlayerConfig, ...] = tuple(DEFAULT_PLAYERS)
    if args.players.strip():
        wanted = {x.strip() for x in args.players.split(",") if x.strip()}
        players = tuple(p for p in DEFAULT_PLAYERS if p.player_id in wanted)

    if len(players) < 2:
        raise SystemExit("Need at least two players (check --players or config).")

    base_url = args.url
    table_id = args.table
    env = os.environ

    print(f"[simulate] POST table-settings SB={args.sb} BB={args.bb} rebuy={args.chips}…", flush=True)
    try:
        post_table_settings(
            base_url,
            table_id,
            sb_amount=args.sb,
            bb_amount=args.bb,
            rebuy_amount=args.chips,
        )
    except RuntimeError as e:
        raise SystemExit(f"table-settings failed: {e}") from e

    print("[simulate] joining players…", flush=True)
    clients, joined = _join_players_parallel(
        players, base_url, table_id, args.chips, allow_without_key=False
    )
    if len(joined) < 2:
        raise SystemExit("Fewer than two players joined — set API keys.")

    player_by_id = {pc.player_id: pc for pc in joined}
    pid_to_client = {pc.player_id: c for pc, c in zip(joined, clients)}
    probe = clients[0]

    seat_order = [pc.player_id for pc in joined]
    meta = {
        "rotation_help": (
            "Button moves clockwise each hand; SB is next clockwise from BTN, "
            "BB next after SB (heads-up rules differ). Seats fill in join order."
        ),
        "seat_order_join": seat_order,
        "sb_amount": args.sb,
        "bb_amount": args.bb,
        "buy_in_chips": args.chips,
        "table_id": table_id,
        "csv_notes": (
            "hand_start.data_json includes hole_cards_by_player (rank+suit letter, e.g. 4C,TH) "
            "and community_cards when known. Rows with record_type=board log each new community "
            "reveal (flop/turn/river) as cards appear."
        ),
    }

    out_path = os.path.abspath(args.out)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(CSV_HEADERS)
        w.writerow(
            [
                "meta",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                "",
                json.dumps(meta),
            ]
        )

        for hn in range(1, args.hands + 1):
            print(f"[simulate] --- hand {hn}/{args.hands} ---", flush=True)
            wait_hand_idle(probe, table_id, timeout=120.0)
            st = probe.get_table_state(table_id)
            pre_bust = dict(st.get("bust_counts") or {})
            pre_stacks = _stacks_seat_order(st)

            try:
                post_start_hand_safe(base_url, table_id, probe)
            except RuntimeError as e:
                raise SystemExit(f"start-hand failed (hand {hn}): {e}") from e

            sp = get_spectate_state(base_url, table_id)
            h = sp.get("hand") or {}
            if h.get("status") != "active":
                raise SystemExit(f"Hand {hn} did not start (hand.status != active).")

            post_blind = _stacks_seat_order(sp)
            hole = hole_cards_by_player(sp)
            comm0 = community_cards_compact(sp)
            last_board = list(comm0)
            hand_row = {
                "stacks_before_blinds": pre_stacks,
                "stacks_after_blinds": post_blind,
                "pot": h.get("pot"),
                "hole_cards_by_player": hole,
                "community_cards": comm0,
            }
            w.writerow(
                [
                    "hand_start",
                    hn,
                    "",
                    "",
                    "",
                    "",
                    "",
                    h.get("button_seat", ""),
                    h.get("sb_seat", ""),
                    h.get("bb_seat", ""),
                    h.get("sb_amount", ""),
                    h.get("bb_amount", ""),
                    json.dumps(hand_row),
                ]
            )

            step_i = 0
            no_actor_spins = 0
            while True:
                st = probe.get_table_state(table_id)
                h = st.get("hand") or {}
                if h.get("status") != "active":
                    break
                pid = _actor_pid(st)
                if not pid:
                    no_actor_spins += 1
                    if no_actor_spins > 120:
                        raise SystemExit(
                            f"Hand {hn}: no action_to_seat while hand still active — server state stuck?"
                        )
                    time.sleep(0.15)
                    continue
                no_actor_spins = 0
                if pid not in player_by_id:
                    raise SystemExit(
                        f"Actor {pid!r} is not in this run's player list — "
                        "another client may be at the table."
                    )
                pc = player_by_id[pid]
                act_client = pid_to_client[pid]
                key = env.get(pc.env_api_key) or ""
                if not key.strip():
                    raise SystemExit(f"Missing API key for {pc.player_id}")
                model = resolve_model_env(pc, env)
                st = act_client.get_table_state(table_id)
                try:
                    action, amount = _decide(pc, key, model, st)
                except Exception as e:
                    print(f"[simulate] decide error {pid}: {e}", flush=True)
                    action, amount = "fold", None
                action = (action or "fold").lower()
                try:
                    act_client.send_action(
                        table_id,
                        player_id=pc.player_id,
                        action=action,
                        amount=amount,
                        queue=False,
                    )
                except PokerError as e:
                    print(f"[simulate] action failed {pid}: {e}", flush=True)
                    try:
                        act_client.send_action(
                            table_id,
                            player_id=pc.player_id,
                            action="fold",
                            queue=False,
                        )
                    except Exception:
                        pass

                st = probe.get_table_state(table_id)
                h = st.get("hand") or {}
                step_i += 1
                w.writerow(
                    [
                        "action",
                        hn,
                        step_i,
                        pid,
                        action,
                        amount if amount is not None else "",
                        h.get("street", ""),
                        h.get("button_seat", ""),
                        h.get("sb_seat", ""),
                        h.get("bb_seat", ""),
                        h.get("sb_amount", ""),
                        h.get("bb_amount", ""),
                        "",
                    ]
                )
                sp2 = get_spectate_state(base_url, table_id)
                brd = community_cards_compact(sp2)
                if brd != last_board:
                    last_board = list(brd)
                    hh = sp2.get("hand") or {}
                    w.writerow(
                        [
                            "board",
                            hn,
                            step_i,
                            "",
                            "",
                            "",
                            hh.get("street", ""),
                            hh.get("button_seat", ""),
                            hh.get("sb_seat", ""),
                            hh.get("bb_seat", ""),
                            hh.get("sb_amount", ""),
                            hh.get("bb_amount", ""),
                            json.dumps(
                                {
                                    "community_cards": brd,
                                    "street": hh.get("street"),
                                }
                            ),
                        ]
                    )
                if step_i >= args.max_steps:
                    raise SystemExit(
                        f"Exceeded --max-steps ({args.max_steps}) in hand {hn} — aborting."
                    )

            wait_hand_idle(probe, table_id, timeout=120.0)
            st = probe.get_table_state(table_id)
            post_bust = dict(st.get("bust_counts") or {})
            h2 = st.get("hand") or {}
            winners = h2.get("last_winners")
            last_pot = h2.get("pot")

            for pid in seat_order:
                b0 = int(pre_bust.get(pid) or 0)
                b1 = int(post_bust.get(pid) or 0)
                if b1 > b0:
                    w.writerow(
                        [
                            "rebuy",
                            hn,
                            "",
                            pid,
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            "",
                            json.dumps(
                                {
                                    "bust_events_total": b1,
                                    "new_rebuy_events_this_hand": b1 - b0,
                                    "stack_after_rebuy": _stack_for_player(st, pid),
                                }
                            ),
                        ]
                    )

            w.writerow(
                [
                    "hand_end",
                    hn,
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    json.dumps({"winners": winners, "last_pot": last_pot}),
                ]
            )

    print(f"[simulate] done — wrote {out_path}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n[simulate] interrupted", file=sys.stderr)
        raise SystemExit(130) from None
