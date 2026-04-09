"""Diagnose LLM API keys, DNS, and minimal chat/tool requests for each configured player."""

from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any

from .config import DEFAULT_PLAYERS, PlayerConfig
from . import poker_tools as pt
from .providers import _normalize_base, _post_json, resolve_model_env


def _openai_compat_headers(base_url: str, api_key: str) -> dict[str, str]:
    h: dict[str, str] = {"Content-Type": "application/json"}
    if "generativelanguage.googleapis.com" in base_url:
        h["Authorization"] = f"Bearer {api_key}"
        h["x-goog-api-key"] = api_key
    else:
        h["Authorization"] = f"Bearer {api_key}"
    return h


def _models_get_headers(_base_url: str, api_key: str) -> dict[str, str]:
    """Bearer auth for GET /models (Gemini OpenAI compat expects this; x-goog-api-key alone returns 400)."""
    return {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }


def _resolve_base(pc: PlayerConfig) -> str:
    if pc.base_url:
        return pc.base_url
    if pc.provider == "anthropic":
        return "https://api.anthropic.com/v1"
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


def _netloc_from_base(base: str) -> str | None:
    try:
        u = urllib.parse.urlparse(base)
        if u.netloc:
            return u.netloc.split("@")[-1]
    except Exception:
        pass
    return None


def _dns_check(host: str) -> tuple[bool, str]:
    try:
        infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
        if not infos:
            return False, "no addresses"
        addrs = sorted({x[4][0] for x in infos})
        return True, f"resolved ({addrs[0]}{'…' if len(addrs) > 1 else ''})"
    except OSError as e:
        return False, str(e)


def _get_json(
    url: str,
    headers: dict[str, str],
    timeout: float,
) -> tuple[int, dict[str, Any] | None, str]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
            code = getattr(resp, "status", resp.getcode())
        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return code, None, raw.decode("utf-8", errors="replace")[:400]
        return code, data, ""
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            data = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            return e.code, None, raw.decode("utf-8", errors="replace")[:800]
        return e.code, data, ""
    except Exception as e:
        return -1, None, str(e)


@dataclass
class StepResult:
    name: str
    ok: bool
    detail: str


def _check_env(pc: PlayerConfig) -> StepResult:
    key = os.environ.get(pc.env_api_key) or ""
    if not key.strip():
        return StepResult("env", False, f"{pc.env_api_key} unset or empty")
    return StepResult("env", True, f"{pc.env_api_key} set ({len(key)} chars)")


def _check_anthropic_chat(pc: PlayerConfig, api_key: str, model: str, timeout: float) -> StepResult:
    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    body = {
        "model": model,
        "max_tokens": 24,
        "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    }
    try:
        _post_json(url, headers, body, timeout=timeout)
        return StepResult("chat", True, "messages completion OK")
    except Exception as e:
        return StepResult("chat", False, str(e))


def _check_openai_compat_chat(
    pc: PlayerConfig,
    base: str,
    api_key: str,
    model: str,
    timeout: float,
) -> StepResult:
    url = _normalize_base(base) + "/chat/completions"
    headers = _openai_compat_headers(base, api_key)
    body: dict[str, Any] = {
        "model": model,
        "temperature": 0,
        "max_tokens": 24,
        "messages": [{"role": "user", "content": "Reply with exactly: ok"}],
    }
    try:
        _post_json(url, headers, body, timeout=timeout)
        return StepResult("chat", True, "chat/completions OK")
    except Exception as e:
        return StepResult("chat", False, str(e))


def _check_openai_compat_models(
    base: str,
    api_key: str,
    timeout: float,
) -> StepResult:
    url = _normalize_base(base) + "/models"
    headers = _models_get_headers(base, api_key)
    code, data, err = _get_json(url, headers, timeout)
    if code == 200:
        n = 0
        if isinstance(data, dict) and isinstance(data.get("data"), list):
            n = len(data["data"])
        return StepResult("models", True, f"GET /models OK ({n} entries)" if n else "GET /models OK")
    if code in (404, 405):
        return StepResult("models", True, f"GET /models not available HTTP {code} (skipped)")
    if code == -1:
        return StepResult("models", False, err or "GET /models failed")
    detail = err
    if isinstance(data, dict):
        detail = str(data.get("error") or data)[:500]
    return StepResult("models", False, f"HTTP {code}: {detail}")


def _check_openai_compat_tools(
    pc: PlayerConfig,
    base: str,
    api_key: str,
    model: str,
    timeout: float,
) -> StepResult:
    url = _normalize_base(base) + "/chat/completions"
    headers = _openai_compat_headers(base, api_key)
    body: dict[str, Any] = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 256,
        "messages": [
            {
                "role": "user",
                "content": (
                    "You are testing the API. Call submit_poker_action once with "
                    '{"action":"fold"} and no other tool calls.'
                ),
            }
        ],
        "tools": pt.OPENAI_STYLE_TOOLS,
        "tool_choice": "auto",
    }
    try:
        data = _post_json(url, headers, body, timeout=timeout)
        ch = (data.get("choices") or [None])[0]
        if not ch:
            return StepResult("tools", False, f"No choices: {data!r}"[:800])
        msg = ch.get("message") or {}
        tcs = msg.get("tool_calls")
        if not tcs:
            return StepResult(
                "tools",
                False,
                "Response had no tool_calls (provider may not support tools or model ignored them)",
            )
        return StepResult("tools", True, f"tool_calls present ({len(tcs)})")
    except Exception as e:
        return StepResult("tools", False, str(e))


def _check_gpt_openai(pc: PlayerConfig, api_key: str, model: str, timeout: float) -> StepResult:
    base = _resolve_base(pc)
    return _check_openai_compat_chat(pc, base, api_key, model, timeout)


def run_player(
    pc: PlayerConfig,
    *,
    timeout: float,
    skip_models: bool,
    with_tools: bool,
) -> list[StepResult]:
    env = os.environ
    model = resolve_model_env(pc, env)
    out: list[StepResult] = []

    r = _check_env(pc)
    out.append(r)
    if not r.ok:
        return out

    api_key = (env.get(pc.env_api_key) or "").strip()
    base = _resolve_base(pc)
    host = _netloc_from_base(base)
    if host:
        ok, detail = _dns_check(host)
        out.append(StepResult("dns", ok, f"{host} — {detail}"))
    else:
        out.append(StepResult("dns", False, "could not parse host from base URL"))

    if pc.provider == "anthropic":
        out.append(_check_anthropic_chat(pc, api_key, model, timeout))
        if with_tools:
            out.append(
                StepResult(
                    "tools",
                    False,
                    "Anthropic tool round-trip not run here (use provider dashboard); chat covers auth.",
                )
            )
        return out

    if not skip_models:
        out.append(_check_openai_compat_models(base, api_key, timeout))

    if pc.provider == "openai":
        out.append(_check_gpt_openai(pc, api_key, model, timeout))
    else:
        out.append(_check_openai_compat_chat(pc, base, api_key, model, timeout))

    if with_tools and pc.provider == "openai_compat":
        out.append(_check_openai_compat_tools(pc, base, api_key, model, timeout))

    return out


def _fmt_steps(steps: list[StepResult] | list[dict[str, Any]]) -> str:
    lines = []
    for s in steps:
        if isinstance(s, dict):
            ok = bool(s.get("ok"))
            name = str(s.get("name", ""))
            detail = str(s.get("detail", ""))
        else:
            ok = s.ok
            name = s.name
            detail = s.detail
        tag = "OK " if ok else "FAIL"
        lines.append(f"  [{tag}] {name}: {detail}")
    return "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser(
        description=(
            "Run layered checks per player: env → DNS → optional GET /models → "
            "minimal chat/completions (and optional tool call test for openai_compat)."
        ),
    )
    p.add_argument(
        "--players",
        default="",
        help="Comma-separated player_ids (default: all in DEFAULT_PLAYERS)",
    )
    p.add_argument(
        "--timeout",
        type=float,
        default=90.0,
        help="Per-request timeout in seconds (default: 90)",
    )
    p.add_argument(
        "--skip-models",
        action="store_true",
        help="Skip GET /models (faster; chat still validates auth)",
    )
    p.add_argument(
        "--tools",
        action="store_true",
        help="Also POST chat/completions with poker tool definitions (heavier)",
    )
    p.add_argument(
        "--json",
        action="store_true",
        help="Machine-readable JSON on stdout",
    )
    args = p.parse_args()

    if args.players.strip():
        wanted = set(args.players.split(","))
        players = tuple(x for x in DEFAULT_PLAYERS if x.player_id in wanted)
    else:
        players = DEFAULT_PLAYERS

    if not players:
        sys.stderr.write("No players selected.\n")
        sys.exit(2)

    results: dict[str, dict[str, Any]] = {}
    any_fail = False

    for pc in players:
        steps = run_player(
            pc,
            timeout=args.timeout,
            skip_models=args.skip_models,
            with_tools=args.tools,
        )
        ok_all = all(s.ok for s in steps)
        if not ok_all:
            any_fail = True
        results[pc.player_id] = {
            "display_name": pc.display_name,
            "provider": pc.provider,
            "model": resolve_model_env(pc, os.environ),
            "ok": ok_all,
            "steps": [{"name": s.name, "ok": s.ok, "detail": s.detail} for s in steps],
        }

    if args.json:
        sys.stdout.write(json.dumps(results, indent=2) + "\n")
    else:
        sys.stdout.write("LLM API diagnostics\n")
        sys.stdout.write(f"timeout={args.timeout}s  skip_models={args.skip_models}  tools={args.tools}\n\n")
        for pc in players:
            sys.stdout.write(f"--- {pc.player_id} ({pc.display_name}) ---\n")
            sys.stdout.write(_fmt_steps(results[pc.player_id]["steps"]) + "\n\n")

        sys.stdout.write(
            "Hints:\n"
            "  • FAIL env: export the key listed in llm_players/config.py\n"
            "  • FAIL dns: network / DNS / firewall blocking outbound HTTPS\n"
            "  • FAIL models: wrong base URL or key; some APIs omit /models (try without --skip-models?)\n"
            "  • FAIL chat: quota, billing, wrong model id (set PLAYER_ID_MODEL), or regional block\n"
            "  • FAIL tools: provider rejects tool schema or does not support OpenAI-style tool_calls\n"
        )

    sys.exit(1 if any_fail else 0)


if __name__ == "__main__":
    main()
