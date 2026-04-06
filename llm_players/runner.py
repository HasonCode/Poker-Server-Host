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


def _monologue(pc: PlayerConfig, api_key: str, model: str) -> str:
    if pc.provider == "anthropic":
        return monologue_anthropic(api_key=api_key, model=model, display_name=pc.display_name)
    base = _resolve_openai_base(pc)
    ex = _extra_headers_for_openai_compat(base, api_key)
    return monologue_openai_compat(
        base_url=base,
        api_key=api_key,
        model=model,
        display_name=pc.display_name,
        extra_headers=ex or None,
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
            mono = _monologue(pc, key, model)
            recorder.append_monologue(pc.display_name, pc.player_id, ctx, mono)
        except Exception as e:
            sys.stderr.write(f"[{pc.player_id}] monologue error: {e}\n")
            mono = "(monologue failed)"

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


def run(args: argparse.Namespace) -> None:
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
        f"LLM table game_id={game_id} — transcript {recorder.transcript_path} — "
        f"results {recorder.results_path}\n"
    )
    while not stop.is_set():
        time.sleep(0.5)
    time.sleep(0.3)


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Run configured LLM players against the poker server (tools + monologue logging).",
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


