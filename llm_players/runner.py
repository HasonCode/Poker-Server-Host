"""Multi-threaded LLM players at one table + hand / transcript logging."""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_CLIENT_PY = os.path.join(_ROOT, "clients", "python")
if _CLIENT_PY not in sys.path:
    sys.path.insert(0, _CLIENT_PY)

from poker_client import PokerClient, PokerError, TransportError  # noqa: E402

from . import poker_tools as _pt
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


def _stderr(msg: str) -> None:
    sys.stderr.write(msg)
    sys.stderr.flush()


def _stdout(msg: str) -> None:
    sys.stdout.write(msg)
    sys.stdout.flush()


def _extra_headers_for_openai_compat(base_url: str, api_key: str) -> dict[str, str]:
    # Gemini OpenAI-compat /chat/completions requires Authorization: Bearer; x-goog-api-key alone
    # yields "Missing or invalid Authorization header" from the gateway.
    if "generativelanguage.googleapis.com" in base_url:
        return {
            "Authorization": f"Bearer {api_key}",
            "x-goog-api-key": api_key,
        }
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


def _try_tts(
    enabled: bool,
    engine: str,
    max_chars: int,
    player_id: str,
    mono: str,
) -> None:
    if not enabled:
        return
    t = (mono or "").strip()
    if not t:
        return
    from .tts import speak_monologue

    speak_monologue(player_id, t, engine=engine, max_chars=max_chars)


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


def _demo_mode_env() -> bool:
    v = os.environ.get("LLM_DEMO_MODE", "").strip().lower()
    return v in ("1", "true", "yes")


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
    tts: bool = False,
    tts_engine: str = "espeak",
    tts_max_chars: int = 6000,
) -> None:
    env = os.environ
    key = env.get(pc.env_api_key) or ""
    if not key.strip():
        _stderr(f"[llm_players] Missing env {pc.env_api_key} for {pc.player_id}\n")
        return
    model = resolve_model_env(pc, env)

    while not stop.is_set():
        try:
            state = client.wait_for_turn(
                table_id, pc.player_id, poll_interval=0.4, timeout=None
            )
        except (PokerError, TransportError) as e:
            _stderr(f"[{pc.player_id}] wait_for_turn: {e}\n")
            time.sleep(1.0)
            continue

        if stop.is_set():
            break

        ctx = shared.get("hand_label") or "unknown street"
        try:
            action, amount = _decide(pc, key, model, state)
        except Exception as e:
            _stderr(f"[{pc.player_id}] decide error: {e}\n")
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
            _stderr(f"[{pc.player_id}] action {action} failed: {e}\n")
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

        mono = ""
        try:
            um = _monologue_user_message_after_play(pc, ctx, action, amount)
            mono = _monologue(pc, key, model, user_message=um)
            recorder.append_monologue(pc.display_name, pc.player_id, ctx, mono)
        except Exception as e:
            _stderr(f"[{pc.player_id}] monologue error: {e}\n")
        else:
            _try_tts(tts, tts_engine, tts_max_chars, pc.player_id, mono)


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
            _stderr(f"[watcher] {e}\n")
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
    _stdout(
        f"\n{'='*60}\n"
        f"[LLM] {pc.display_name}  ·  player_id={pc.player_id}  ·  seat {seat}\n"
        f"      street={h.get('street')}  ·  pot={h.get('pot')}  ·  "
        f"Hand {hs} (watcher)\n"
        f"{'='*60}\n"
    )


def _compact_table_line(state: dict, player_by_id: dict[str, PlayerConfig]) -> str:
    h = state.get("hand") or {}
    st = h.get("status") or "?"
    street = h.get("street") or "?"
    pot = h.get("pot")
    pid = _actor_pid_from_state(state)
    if pid and pid in player_by_id:
        actor = f"to_act={player_by_id[pid].player_id}"
    elif pid:
        actor = f"to_act={pid}"
    else:
        actor = "to_act=—"
    return f"[table] status={st} street={street} pot={pot} {actor}"


def _table_status_poll(
    client: PokerClient,
    table_id: str,
    player_by_id: dict[str, PlayerConfig],
    stop: threading.Event,
    interval: float,
) -> None:
    while not stop.is_set():
        try:
            state = client.get_table_state(table_id)
        except Exception as e:
            _stderr(f"[table poll] {e}\n")
            if stop.wait(interval):
                break
            continue
        _stderr(_compact_table_line(state, player_by_id) + "\n")
        if stop.wait(interval):
            break


def _interactive_next_llm_move(pc: PlayerConfig, stop: threading.Event) -> bool:
    _stdout(
        f"\n[Next LLM move] — {pc.display_name} ({pc.player_id})\n"
        f"  Runs decide (tools) → send action → monologue in one step.\n"
        f"  Enter = run  ·  q = quit: "
    )
    try:
        line = input()
    except EOFError:
        return False
    if stop.is_set():
        return False
    if line.strip().lower() in ("q", "quit", "exit"):
        return False
    return True


def _join_players_parallel(
    players: tuple[PlayerConfig, ...],
    base_url: str,
    table_id: str,
    chips: int,
    *,
    allow_without_key: bool = False,
) -> tuple[list[PokerClient], list[PlayerConfig]]:
    """Join all players with keys concurrently so the server can accept every /join before tick() starts a hand."""
    to_join: list[PlayerConfig] = []
    for pc in players:
        key = os.environ.get(pc.env_api_key) or ""
        if not key.strip() and not allow_without_key:
            _stderr(
                f"Skipping {pc.player_id}: set {pc.env_api_key} in the environment.\n"
            )
            continue
        to_join.append(pc)

    if not to_join:
        return [], []

    def _one(pc: PlayerConfig) -> tuple[str, PokerClient | None, Exception | None]:
        c = PokerClient(base_url, timeout=120.0)
        try:
            c.join_table(table_id, player_id=pc.player_id, chips=chips)
            return pc.player_id, c, None
        except (PokerError, TransportError) as e:
            return pc.player_id, None, e

    results: dict[str, tuple[PokerClient | None, Exception | None]] = {}
    n = len(to_join)
    with ThreadPoolExecutor(max_workers=max(1, n)) as ex:
        futures = {ex.submit(_one, pc): pc for pc in to_join}
        for fut in as_completed(futures):
            pid, c, err = fut.result()
            results[pid] = (c, err)

    clients: list[PokerClient] = []
    joined: list[PlayerConfig] = []
    for pc in to_join:
        c, err = results[pc.player_id]
        if err is not None:
            _stderr(f"Join failed for {pc.player_id}: {err}\n")
            continue
        if c is not None:
            clients.append(c)
            joined.append(pc)
    return clients, joined


def _emit_step_json(d: dict[str, Any]) -> None:
    """One JSON object per line (trailing newline so shells don’t glue the next prompt to `}`)."""
    _stdout(json.dumps(d) + "\n")


def _fail_step(code: str, message: str) -> None:
    _stderr(f"[llm-step] FAIL {code}: {message}\n")
    _emit_step_json({"ok": False, "error": message, "error_code": code})
    sys.exit(1)


def _step_log(msg: str) -> None:
    _stderr(f"[llm-step] {msg}\n")


def _single_step_post_start_hand(base_url: str, table_id: str) -> bool:
    """
    POST /v1/tables/:id/start-hand for manual_start_only tables (e.g. llm_bots).
    Uses POKER_LLM_SPECTATE_PASSWORD or default 1234 to match server defaults.
    Returns True if server returned 200 OK.
    """
    pw = (os.environ.get("POKER_LLM_SPECTATE_PASSWORD") or "1234").strip()
    path = "/v1/tables/" + urllib.parse.quote(table_id, safe="") + "/start-hand"
    url = base_url.rstrip("/") + path
    body = json.dumps({"spectate_password": pw}).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
            code = getattr(resp, "status", None) or resp.getcode()
            return code == 200
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        if e.code == 409:
            _step_log("start-hand: hand already in progress (409) — OK")
            return True
        if e.code == 401:
            _step_log(
                "start-hand: 401 — set POKER_LLM_SPECTATE_PASSWORD to match the server "
                "(default is often 1234)."
            )
        else:
            _step_log(f"start-hand: HTTP {e.code} {raw[:400]}")
        return False
    except Exception as ex:
        _step_log(f"start-hand: {ex}")
        return False


def _decide_demo(pc: PlayerConfig, state: dict, player_id: str) -> tuple[str, int | None]:
    """
    No provider HTTP: run local poker_tools (same code path as real decide() tool execution)
    and print a short trace to stderr. Safe action: fold.
    """
    _step_log("DEMO: simulating tool calls (no OpenAI/Anthropic/Gemini HTTP)")
    for name in ("get_full_visible_snapshot", "get_betting_context"):
        _step_log(f"DEMO: tool {name}")
        out = _pt.execute_tool(name, state, player_id, {})
        if isinstance(out, dict):
            keys = list(out.keys())[:10]
            _step_log(f"DEMO:   -> keys={keys!r}")
        else:
            _step_log(f"DEMO:   -> {type(out)!r}")
    _step_log("DEMO: submit_poker_action fold (no real LLM call)")
    return "fold", None


def _single_step_stdio_setup() -> None:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(line_buffering=True)
            except Exception:
                pass


def run_single_step(args: argparse.Namespace) -> None:
    """One LLM turn: rejoin all keyed players, decide + action + monologue for the current actor; JSON on stdout."""
    _single_step_stdio_setup()
    demo = bool(getattr(args, "demo_tools", False)) or _demo_mode_env()
    _step_log(
        f"start table={args.table!r} url={args.url!r} out_dir={os.path.abspath(args.out_dir)!r}"
        + ("  [DEMO_TOOLS]" if demo else "")
    )
    out_dir = os.path.abspath(args.out_dir)
    game_id = resolve_game_id(out_dir, args.new_game)
    recorder = GameRecorder(game_id, out_dir)
    recorder.ensure_headers()

    players: tuple[PlayerConfig, ...] = tuple(DEFAULT_PLAYERS)
    if args.players:
        wanted = set(args.players.split(","))
        players = tuple(p for p in DEFAULT_PLAYERS if p.player_id in wanted)

    if not players:
        _fail_step("no_players", "No players selected.")

    base_url = args.url
    table_id = args.table
    env = os.environ

    clients, joined = _join_players_parallel(
        players, base_url, table_id, args.chips, allow_without_key=demo
    )
    if not clients:
        _fail_step(
            "join_failed",
            "No players could join (API keys / server). Use --demo-tools to join without keys for a local tool demo.",
        )

    _step_log(f"joined {len(joined)} player(s): {[p.player_id for p in joined]!r}")
    player_by_id = {pc.player_id: pc for pc in joined}
    pid_to_client = {pc.player_id: c for pc, c in zip(joined, clients)}
    probe = clients[0]

    try:
        state = probe.get_table_state(table_id)
    except (PokerError, TransportError) as e:
        _fail_step("state_error", str(e))

    if state.get("manual_start_only") and (state.get("hand") or {}).get("status") != "active":
        _step_log(
            "hand idle on manual-deal table — POST start-hand "
            "(POKER_LLM_SPECTATE_PASSWORD or default 1234)…"
        )
        _single_step_post_start_hand(base_url, table_id)
        try:
            state = probe.get_table_state(table_id)
        except (PokerError, TransportError) as e:
            _fail_step("state_error", str(e))

    h = state.get("hand") or {}
    st = h.get("status")
    _step_log(f"hand.status={st!r} street={h.get('street')!r} action_to_seat={h.get('action_to_seat')!r}")
    if st != "active":
        _fail_step(
            "no_active_hand",
            "No active hand after start-hand — need at least two seated players with chips, "
            "or fix spectate password (POKER_LLM_SPECTATE_PASSWORD).",
        )

    pid = _actor_pid_from_state(state)
    if not pid:
        _fail_step("no_actor", "No player to act.")
    if pid not in player_by_id:
        _fail_step(
            "not_llm_actor",
            f"Current actor is {pid!r}, not one of the configured LLM players for this run.",
        )

    _step_log(
        f"actor={pid!r} (will call {'demo tools' if demo else 'decide (provider)'} + send_action + optional monologue)"
    )
    act_client = pid_to_client[pid]
    try:
        state = act_client.get_table_state(table_id)
    except (PokerError, TransportError) as e:
        _fail_step("state_error", str(e))

    pc = player_by_id[pid]
    key = env.get(pc.env_api_key) or ""
    model = resolve_model_env(pc, env)
    h2 = state.get("hand") or {}
    hand_ctx = f"{h2.get('street') or '?'} pot={h2.get('pot')}"
    _step_log(f"model={model!r} context={hand_ctx!r}")

    if not key.strip() and not demo:
        _fail_step(
            "no_api_key",
            f"Missing API key for {pc.player_id}: export {pc.env_api_key} before starting the poker server "
            "(or source a script that sets it). Or run with --demo-tools to exercise local tools only.",
        )

    if demo:
        _step_log("demo: skipping provider HTTP; exercising poker_tools.execute_tool only")
        try:
            action, amount = _decide_demo(pc, state, pc.player_id)
        except Exception as e:
            _stderr(f"[{pc.player_id}] demo decide error: {e}\n")
            action, amount = "fold", None
    else:
        _step_log("calling LLM decide() (tools + chat) — may take a while…")
        try:
            action, amount = _decide(pc, key, model, state)
        except Exception as e:
            _stderr(f"[{pc.player_id}] decide error: {e}\n")
            action, amount = "fold", None

    action = (action or "fold").lower()
    _step_log(f"decide -> action={action!r} amount={amount!r}")
    try:
        act_client.send_action(
            table_id,
            player_id=pc.player_id,
            action=action,
            amount=amount,
            queue=False,
        )
    except PokerError as e:
        _stderr(f"[{pc.player_id}] action {action} failed: {e}\n")
        try:
            act_client.send_action(
                table_id,
                player_id=pc.player_id,
                action="fold",
                queue=False,
            )
        except Exception:
            pass
        action, amount = "fold", None

    _step_log("send_action OK; calling monologue…")
    mono = ""
    skip_mono = demo or (
        os.environ.get("LLM_SINGLE_STEP_SKIP_MONOLOGUE", "").strip().lower()
        in ("1", "true", "yes")
    )
    if skip_mono:
        _step_log(
            "skipping monologue (demo or LLM_SINGLE_STEP_SKIP_MONOLOGUE=1)"
        )
    else:
        try:
            um = _monologue_user_message_after_play(pc, hand_ctx, action, amount)
            mono = _monologue(pc, key, model, user_message=um)
            recorder.append_monologue(pc.display_name, pc.player_id, hand_ctx, mono)
            _step_log(f"monologue length={len(mono)} chars")
        except Exception as e:
            _stderr(f"[{pc.player_id}] monologue error: {e}\n")
        else:
            _try_tts(
                bool(getattr(args, "tts", False)),
                str(getattr(args, "tts_engine", "espeak")),
                int(getattr(args, "tts_max_chars", 6000) or 6000),
                pc.player_id,
                mono,
            )

    _step_log("emitting JSON on stdout (single line)")
    _emit_step_json(
        {
            "ok": True,
            "player_id": pc.player_id,
            "display_name": pc.display_name,
            "action": action,
            "amount": amount,
            "transcript": recorder.transcript_path,
            "monologue": mono,
        }
    )
    sys.exit(0)


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
            _stderr(f"[step] poll: {e}\n")
            time.sleep(0.5)
            continue
        pid = _actor_pid_from_state(state)
        if pid and pid in player_by_id:
            return state, player_by_id[pid]
        time.sleep(0.35)
    return None, None


def run_step(args: argparse.Namespace) -> None:
    """Interactive stepping: one Enter per LLM turn (decide + action + monologue); optional table poll on stderr."""
    out_dir = os.path.abspath(args.out_dir)
    game_id = resolve_game_id(out_dir, args.new_game)
    recorder = GameRecorder(game_id, out_dir)
    recorder.ensure_headers()

    players: tuple[PlayerConfig, ...] = tuple(DEFAULT_PLAYERS)
    if args.players:
        wanted = set(args.players.split(","))
        players = tuple(p for p in DEFAULT_PLAYERS if p.player_id in wanted)

    if not players:
        _stderr("No players selected.\n")
        sys.exit(1)

    base_url = args.url
    table_id = args.table
    stop = threading.Event()

    def _sig(_a: Any, _b: Any) -> None:
        stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    shared: dict[str, Any] = {"hand_label": "—", "hand_seq": 0, "last_pot_active": 0}
    clients, joined = _join_players_parallel(players, base_url, table_id, args.chips)

    if not clients:
        _stderr("No players joined — check API keys and table availability.\n")
        sys.exit(1)

    player_by_id = {pc.player_id: pc for pc in joined}
    pid_to_client = {pc.player_id: c for pc, c in zip(joined, clients)}
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
    if not args.no_table_poll:
        poller = threading.Thread(
            target=_table_status_poll,
            args=(poll_client, table_id, player_by_id, stop, 1.5),
            name="table_status_poll",
            daemon=True,
        )
        poller.start()

    _stdout(
        "\n*** Step mode — stderr logs table status (~1.5s); press Enter once per LLM to run play + monologue. ***\n"
        "*** Use --auto for continuous multi-threaded play. Use --no-table-poll to silence table lines. ***\n\n"
    )
    _stderr(
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

        if not _interactive_next_llm_move(pc, stop):
            break

        # Must use this actor's PokerClient: X-Player-Token is tied to who joined on that instance.
        act_client = pid_to_client.get(pc.player_id)
        if act_client is None:
            _stderr(f"[{pc.player_id}] internal: no client for actor — skipping.\n")
            continue
        state = act_client.get_table_state(table_id)
        key = env.get(pc.env_api_key) or ""
        model = resolve_model_env(pc, env)
        try:
            action, amount = _decide(pc, key, model, state)
        except Exception as e:
            _stderr(f"[{pc.player_id}] decide error: {e}\n")
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
            _stderr(f"[{pc.player_id}] action {action} failed: {e}\n")
            try:
                act_client.send_action(
                    table_id,
                    player_id=pc.player_id,
                    action="fold",
                    queue=False,
                )
            except Exception:
                pass
            action, amount = "fold", None

        ctx = shared.get("hand_label") or "unknown street"

        mono = ""
        try:
            um = _monologue_user_message_after_play(pc, ctx, action, amount)
            mono = _monologue(pc, key, model, user_message=um)
            recorder.append_monologue(pc.display_name, pc.player_id, ctx, mono)
        except Exception as e:
            _stderr(f"[{pc.player_id}] monologue error: {e}\n")
        else:
            _try_tts(
                bool(args.tts),
                str(args.tts_engine),
                int(args.tts_max_chars or 6000),
                pc.player_id,
                mono,
            )

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
        _stderr("No players selected.\n")
        sys.exit(1)

    base_url = args.url
    table_id = args.table
    stop = threading.Event()

    def _sig(_a: Any, _b: Any) -> None:
        stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    shared: dict[str, Any] = {"hand_label": "—", "hand_seq": 0, "last_pot_active": 0}

    clients, joined = _join_players_parallel(players, base_url, table_id, args.chips)
    threads: list[threading.Thread] = []
    for pc, c in zip(joined, clients):
        threads.append(
            threading.Thread(
                target=_player_loop,
                args=(
                    pc,
                    c,
                    table_id,
                    recorder,
                    shared,
                    stop,
                    bool(args.tts),
                    str(args.tts_engine),
                    int(args.tts_max_chars or 6000),
                ),
                name=pc.player_id,
                daemon=True,
            )
        )

    if not threads:
        _stderr("No players joined — check API keys and table availability.\n")
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

    _stderr(
        f"[auto mode] game_id={game_id} — transcript {recorder.transcript_path} — "
        f"results {recorder.results_path}\n"
    )
    while not stop.is_set():
        time.sleep(0.5)
    time.sleep(0.3)


def run(args: argparse.Namespace) -> None:
    if getattr(args, "tts", False):
        from .tts import tts_available

        eng = str(getattr(args, "tts_engine", "espeak"))
        if not tts_available(eng):
            _stderr(
                "[tts] Warning: "
                + ("`say` not found — use espeak-ng on Linux, or install voices on macOS.\n"
                   if eng.lower() == "say"
                   else "espeak-ng/espeak not in PATH — install (e.g. dnf install espeak-ng) or use --tts-engine say on macOS.\n")
            )
    if args.single_step:
        run_single_step(args)
        return
    if args.auto:
        run_auto(args)
    else:
        run_step(args)


def build_arg_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Run configured LLM players against the poker server. "
            "Default: step mode — press Enter once per LLM turn to run play + monologue "
            "(table status on stderr ~1.5s). Use --auto for continuous play."
        ),
    )
    p.add_argument(
        "--single-step",
        action="store_true",
        help="Run one LLM turn (tools + action + monologue) if it is an LLM's turn, then exit. Prints JSON to stdout.",
    )
    p.add_argument(
        "--demo-tools",
        action="store_true",
        help="With --single-step: no API keys; exercises local poker_tools + HTTP actions only (fast sanity check).",
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
    p.add_argument(
        "--no-table-poll",
        action="store_true",
        help="Step mode: do not print periodic table status lines to stderr.",
    )
    p.add_argument(
        "--tts",
        action="store_true",
        help="After each monologue, speak it with text-to-speech (distinct voice per player_id).",
    )
    p.add_argument(
        "--tts-engine",
        default="espeak",
        choices=("espeak", "say"),
        help="TTS backend: espeak-ng/espeak (Linux default) or macOS `say`.",
    )
    p.add_argument(
        "--tts-max-chars",
        type=int,
        default=6000,
        metavar="N",
        help="Max characters spoken per monologue (rest truncated). Default: 6000.",
    )
    return p


def main() -> None:
    args = build_arg_parser().parse_args()
    if args.demo_tools and not args.single_step:
        _stderr("error: --demo-tools only applies with --single-step\n")
        sys.exit(2)
    run(args)


