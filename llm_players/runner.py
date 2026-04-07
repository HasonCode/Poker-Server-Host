"""Multi-threaded LLM players at one table + hand / transcript logging."""

from __future__ import annotations

import argparse
import os
import signal
import sys
import threading
import time
from typing import Any

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CLIENT_PY = os.path.join(_ROOT, "clients", "python")
if _CLIENT_PY not in sys.path:
    sys.path.insert(0, _CLIENT_PY)

from poker_client import PokerClient, PokerError, TransportError  # noqa: E402

from . import prompts
from .config import DEFAULT_PLAYERS, DEFAULT_TABLE_ID, PlayerConfig
from .game_files import GameRecorder, resolve_game_id
from .providers import (
    decide_anthropic,
    decide_openai_compat,
    monologue_anthropic,
    monologue_openai_compat,
    resolve_model_env,
)


def _extra_headers_for_openai_compat(base_url: str, api_key: str) -> dict[str, str]:
    if "generativelanguage.googleapis.com" in base_url:
        return {"x-goog-api-key": api_key}
    return {}


def _resolve_openai_base(pc: PlayerConfig) -> str:
    if pc.base_url:
        return pc.base_url
    env = os.environ
    if pc.base_url_env:
        v = env.get(pc.base_url_env)
        if v:
            return v
    if pc.player_id == "gpt_5_4":
        return env.get("OPENAI_BASE_URL") or "https://api.openai.com/v1"
    if pc.player_id == "llama_4":
        return env.get("LLAMA_OPENAI_BASE_URL") or "https://api.together.xyz/v1"
    return "https://api.openai.com/v1"


def _monologue(
    pc: PlayerConfig,
    api_key: str,
    model: str,
    *,
    user_message: str | None = None,
) -> str:
    if pc.provider == "anthropic":
        return monologue_anthropic(
            api_key=api_key,
            model=model,
            display_name=pc.display_name,
            user_message=user_message,
        )
    base = _resolve_openai_base(pc)
    ex = _extra_headers_for_openai_compat(base, api_key)
    return monologue_openai_compat(
        base_url=base,
        api_key=api_key,
        model=model,
        display_name=pc.display_name,
        extra_headers=ex or None,
        user_message=user_message,
    )


def _monologue_user_message_after_play(
    pc: PlayerConfig,
    hand_ctx: str,
    action: str,
    amount: int | None,
) -> str:
    amt = "" if amount is None else f" amount={amount}"
    return (
        f"Label: {pc.display_name} ({pc.player_id})\n"
        f"Table context: {hand_ctx}\n"
        f"You just took action: {action}{amt}.\n"
        f"{prompts.MONOLOGUE_AFTER_ACTION}\n"
        f"Write your internal Death Note–style monologue now."
    )


def _decide(pc: PlayerConfig, api_key: str, model: str, state: dict) -> tuple[str, int | None]:
    if pc.provider == "anthropic":
        return decide_anthropic(
            api_key=api_key,
            model=model,
            state=state,
            player_id=pc.player_id,
            display_name=pc.display_name,
        )
    base = _resolve_openai_base(pc)
    ex = _extra_headers_for_openai_compat(base, api_key)
    return decide_openai_compat(
        base_url=base,
        api_key=api_key,
        model=model,
        state=state,
        player_id=pc.player_id,
        display_name=pc.display_name,
        extra_headers=ex or None,
    )


def _player_loop(
    pc: PlayerConfig,
    client: PokerClient,
    table_id: str,
    recorder: GameRecorder,
    shared: dict[str, Any],
    stop: threading.Event,
) -> None:
    env = os.environ
    key = env.get(pc.env_api_key) or ""
    if not key.strip():
        sys.stderr.write(f"[llm_players] Missing env {pc.env_api_key} for {pc.player_id}\n")
        return
    model = resolve_model_env(pc, env)

    while not stop.is_set():
        try:
            state = client.wait_for_turn(
                table_id, pc.player_id, poll_interval=0.4, timeout=None
            )
        except (PokerError, TransportError) as e:
            sys.stderr.write(f"[{pc.player_id}] wait_for_turn: {e}\n")
            time.sleep(1.0)
            continue

        if stop.is_set():
            break

        ctx = shared.get("hand_label") or "unknown street"
        try:
            action, amount = _decide(pc, key, model, state)
        except Exception as e:
            sys.stderr.write(f"[{pc.player_id}] decide error: {e}\n")
            action, amount = "fold", None

        action = (action or "fold").lower()
        try:
            client.send_action(
                table_id,
                player_id=pc.player_id,
                action=action,
                amount=amount,
                queue=False,
            )
        except PokerError as e:
            sys.stderr.write(f"[{pc.player_id}] action {action} failed: {e}\n")
            try:
                client.send_action(
                    table_id,
                    player_id=pc.player_id,
                    action="fold",
                    queue=False,
                )
            except Exception:
                pass
            action, amount = "fold", None

        try:
            um = _monologue_user_message_after_play(pc, ctx, action, amount)
            mono = _monologue(pc, key, model, user_message=um)
            recorder.append_monologue(pc.display_name, pc.player_id, ctx, mono)
        except Exception as e:
            sys.stderr.write(f"[{pc.player_id}] monologue error: {e}\n")


def _hand_watcher(
    client: PokerClient,
    table_id: str,
    recorder: GameRecorder,
    shared: dict[str, Any],
    stop: threading.Event,
) -> None:
    prev_status: str | None = None
    hand_seq = 0
    while not stop.is_set():
        try:
            state = client.get_table_state(table_id)
        except Exception as e:
            sys.stderr.write(f"[watcher] {e}\n")
            time.sleep(0.5)
            continue
        h = state.get("hand") or {}
        st = h.get("status")
        if st == "active":
            shared["last_pot_active"] = int(h.get("pot") or 0)
            if prev_status != "active":
                hand_seq += 1
                shared["hand_seq"] = hand_seq
            shared["hand_label"] = f"Hand {hand_seq} · {h.get('street') or '?'}"
        if prev_status == "active" and st == "idle":
            recorder.maybe_record_hand_end(
                h.get("last_winners"),
                shared.get("last_pot_active"),
            )
        prev_status = st
        time.sleep(0.35)


def _actor_pid_from_state(state: dict) -> str | None:
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


def _seat_for_player(state: dict, player_id: str) -> int | None:
    seats = state.get("seats") or []
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id") == player_id:
            return i
    return None


def _print_step_banner(
    pc: PlayerConfig,
    state: dict,
    shared: dict[str, Any],
) -> None:
    h = state.get("hand") or {}
    seat = _seat_for_player(state, pc.player_id)
    hs = shared.get("hand_seq", "?")
    sys.stdout.write(
        f"\n{'='*60}\n"
        f"[LLM] {pc.display_name}  ·  player_id={pc.player_id}  ·  seat {seat}\n"
        f"      street={h.get('street')}  ·  pot={h.get('pot')}  ·  "
        f"Hand {hs} (watcher)\n"
        f"{'='*60}\n"
    )
    sys.stdout.flush()


def _interactive_step(phase: str, pc: PlayerConfig, detail: str, stop: threading.Event) -> bool:
    sys.stdout.write(
        f"\n{phase} — {pc.display_name} ({pc.player_id})\n"
        f"  {detail}\n"
        f"  Enter = continue  ·  q = quit: "
    )
    sys.stdout.flush()
    try:
        line = input()
    except EOFError:
        return False
    if stop.is_set():
        return False
    if line.strip().lower() in ("q", "quit", "exit"):
        return False
    return True


def _poll_until_llm_turn(
    client: PokerClient,
    table_id: str,
    player_by_id: dict[str, PlayerConfig],
    stop: threading.Event,
) -> tuple[dict | None, PlayerConfig | None]:
    while not stop.is_set():
        try:
            state = client.get_table_state(table_id)
        except Exception as e:
            sys.stderr.write(f"[step] poll: {e}\n")
            time.sleep(0.5)
            continue
        pid = _actor_pid_from_state(state)
        if pid and pid in player_by_id:
            return state, player_by_id[pid]
        time.sleep(0.35)
    return None, None


def run_step(args: argparse.Namespace) -> None:
    """Interactive stepping: no LLM API calls until you confirm each phase (saves tokens)."""
    out_dir = os.path.abspath(args.out_dir)
    game_id = resolve_game_id(out_dir, args.new_game)
    recorder = GameRecorder(game_id, out_dir)
    recorder.ensure_headers()

    players: tuple[PlayerConfig, ...] = tuple(DEFAULT_PLAYERS)
    if args.players:
        wanted = set(args.players.split(","))
        players = tuple(p for p in DEFAULT_PLAYERS if p.player_id in wanted)

    if not players:
        sys.stderr.write("No players selected.\n")
        sys.exit(1)

    base_url = args.url
    table_id = args.table
    stop = threading.Event()

    def _sig(_a: Any, _b: Any) -> None:
        stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    shared: dict[str, Any] = {"hand_label": "—", "hand_seq": 0, "last_pot_active": 0}
    clients: list[PokerClient] = []
    joined: list[PlayerConfig] = []

    for pc in players:
        key = os.environ.get(pc.env_api_key) or ""
        if not key.strip():
            sys.stderr.write(
                f"Skipping {pc.player_id}: set {pc.env_api_key} in the environment.\n"
            )
            continue
        c = PokerClient(base_url, timeout=120.0)
        try:
            c.join_table(table_id, player_id=pc.player_id, chips=args.chips)
        except (PokerError, TransportError) as e:
            sys.stderr.write(f"Join failed for {pc.player_id}: {e}\n")
            continue
        clients.append(c)
        joined.append(pc)

    if not clients:
        sys.stderr.write("No players joined — check API keys and table availability.\n")
        sys.exit(1)

    player_by_id = {pc.player_id: pc for pc in joined}
    env = os.environ

    watch_client = clients[0]
    watcher = threading.Thread(
        target=_hand_watcher,
        args=(watch_client, table_id, recorder, shared, stop),
        name="hand_watcher",
        daemon=True,
    )
    watcher.start()

    poll_client = clients[0]
    sys.stdout.write(
        "\n*** Step mode (default) — no LLM calls until you press Enter on each prompt. ***\n"
        "*** Order per turn: (1) PLAY — tools + action  (2) MONOLOGUE  (3) NEXT — next actor ***\n"
        "*** Use --auto for continuous multi-threaded play. ***\n\n"
    )
    sys.stderr.write(
        f"[step mode] game_id={game_id} — transcript {recorder.transcript_path} — "
        f"results {recorder.results_path}\n"
    )

    while not stop.is_set():
        state, pc = _poll_until_llm_turn(poll_client, table_id, player_by_id, stop)
        if stop.is_set() or state is None or pc is None:
            break

        h = state.get("hand") or {}
        st_name = h.get("street") or "?"
        shared["hand_label"] = f"Hand {shared.get('hand_seq', 0)} · {st_name}"
        _print_step_banner(pc, state, shared)

        if not _interactive_step(
            "[1/3 PLAY]",
            pc,
            "Calls the LLM (tools + submit_poker_action) and sends the move to the server.",
            stop,
        ):
            break

        state = poll_client.get_table_state(table_id)
        key = env.get(pc.env_api_key) or ""
        model = resolve_model_env(pc, env)
        try:
            action, amount = _decide(pc, key, model, state)
        except Exception as e:
            sys.stderr.write(f"[{pc.player_id}] decide error: {e}\n")
            action, amount = "fold", None

        action = (action or "fold").lower()
        try:
            poll_client.send_action(
                table_id,
                player_id=pc.player_id,
                action=action,
                amount=amount,
                queue=False,
            )
        except PokerError as e:
            sys.stderr.write(f"[{pc.player_id}] action {action} failed: {e}\n")
            try:
                poll_client.send_action(
                    table_id,
                    player_id=pc.player_id,
                    action="fold",
                    queue=False,
                )
            except Exception:
                pass
            action, amount = "fold", None

        ctx = shared.get("hand_label") or "unknown street"

        if not _interactive_step(
            "[2/3 MONOLOGUE]",
            pc,
            "Calls the LLM for the Death Note–style monologue after this play.",
            stop,
        ):
            break

        try:
            um = _monologue_user_message_after_play(pc, ctx, action, amount)
            mono = _monologue(pc, key, model, user_message=um)
            recorder.append_monologue(pc.display_name, pc.player_id, ctx, mono)
        except Exception as e:
            sys.stderr.write(f"[{pc.player_id}] monologue error: {e}\n")

        if not _interactive_step(
            "[3/3 NEXT]",
            pc,
            "Done with this turn. Wait for the next LLM actor (or continue polling).",
            stop,
        ):
            break

    time.sleep(0.2)


def run_auto(args: argparse.Namespace) -> None:
    out_dir = os.path.abspath(args.out_dir)
    game_id = resolve_game_id(out_dir, args.new_game)
    recorder = GameRecorder(game_id, out_dir)
    recorder.ensure_headers()

    players: tuple[PlayerConfig, ...] = tuple(DEFAULT_PLAYERS)
    if args.players:
        wanted = set(args.players.split(","))
        players = tuple(p for p in DEFAULT_PLAYERS if p.player_id in wanted)

    if not players:
        sys.stderr.write("No players selected.\n")
        sys.exit(1)

    base_url = args.url
    table_id = args.table
    stop = threading.Event()

    def _sig(_a: Any, _b: Any) -> None:
        stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    shared: dict[str, Any] = {"hand_label": "—", "hand_seq": 0, "last_pot_active": 0}

    threads: list[threading.Thread] = []
    clients: list[PokerClient] = []

    for pc in players:
        key = os.environ.get(pc.env_api_key) or ""
        if not key.strip():
            sys.stderr.write(
                f"Skipping {pc.player_id}: set {pc.env_api_key} in the environment.\n"
            )
            continue
        c = PokerClient(base_url, timeout=120.0)
        try:
            c.join_table(table_id, player_id=pc.player_id, chips=args.chips)
        except (PokerError, TransportError) as e:
            sys.stderr.write(f"Join failed for {pc.player_id}: {e}\n")
            continue
        clients.append(c)
        t = threading.Thread(
            target=_player_loop,
            args=(pc, c, table_id, recorder, shared, stop),
            name=pc.player_id,
            daemon=True,
        )
        threads.append(t)

    if not threads:
        sys.stderr.write("No players joined — check API keys and table availability.\n")
        sys.exit(1)

    watch_client = clients[0]
    watcher = threading.Thread(
        target=_hand_watcher,
        args=(watch_client, table_id, recorder, shared, stop),
        name="hand_watcher",
        daemon=True,
    )
    watcher.start()

    for t in threads:
        t.start()

    sys.stderr.write(
        f"[auto mode] game_id={game_id} — transcript {recorder.transcript_path} — "
        f"results {recorder.results_path}\n"
    )
    while not stop.is_set():
        time.sleep(0.5)
    time.sleep(0.3)


def run(args: argparse.Namespace) -> None:
    if args.auto:
        run_auto(args)
    else:
        run_step(args)


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Run configured LLM players against the poker server. "
            "Default: step mode — press Enter to run each LLM play, then monologue, then next turn "
            "(no API calls until prompted). Use --auto for continuous play."
        ),
    )
    p.add_argument(
        "--auto",
        action="store_true",
        help="Multi-threaded automatic play (monologue after each action; no stepping).",
    )
    p.add_argument(
        "--url",
        default=os.environ.get("POKER_SERVER_URL", "http://127.0.0.1:8080"),
        help="Server base URL",
    )
    p.add_argument(
        "--table",
        default=os.environ.get("POKER_LLM_TABLE", DEFAULT_TABLE_ID),
        help=f"Table id (default: {DEFAULT_TABLE_ID}, server table for LLM runs)",
    )
    p.add_argument("--chips", type=int, default=1000, help="Buy-in per LLM player")
    p.add_argument(
        "--out-dir",
        default=".",
        help="Directory for poker_game_transcript_#.txt and poker_game_#.txt",
    )
    p.add_argument(
        "--new-game",
        action="store_true",
        help="Increment persisted game id (new transcript / results pair)",
    )
    p.add_argument(
        "--players",
        default="",
        help="Comma-separated player_ids to include (default: all seven)",
    )
    return p


def main() -> None:
    args = build_arg_parser().parse_args()
    run(args)


