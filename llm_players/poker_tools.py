"""
Tool implementations — read-only views of table state for the acting player.
"""

from __future__ import annotations

from typing import Any


def _seat_for_player(state: dict, player_id: str) -> int | None:
    seats = state.get("seats") or []
    for i, s in enumerate(seats, 1):
        if isinstance(s, dict) and s.get("player_id") == player_id:
            return i
    return None


def build_visible_state(state: dict, player_id: str) -> dict[str, Any]:
    """Everything an LLM is allowed to know (no opponent hole cards)."""
    hand = state.get("hand") or {}
    seats = state.get("seats") or []
    my_seat = _seat_for_player(state, player_id)
    hc = hand.get("hole_cards") or {}
    my_cards: list[str] | None = None
    if my_seat is not None and isinstance(hc, dict):
        raw = hc.get(str(my_seat))
        if isinstance(raw, list):
            my_cards = [str(c) for c in raw]

    folded = hand.get("folded") or {}
    contrib = hand.get("contribution") or {}
    opponents: list[dict[str, Any]] = []
    for i, s in enumerate(seats, 1):
        if not isinstance(s, dict):
            continue
        pid = s.get("player_id")
        if pid == player_id:
            continue
        opponents.append(
            {
                "seat": i,
                "player_id": pid,
                "stack": s.get("stack"),
                "contribution_this_street": contrib.get(str(i), 0)
                if isinstance(contrib, dict)
                else 0,
                "folded": bool(
                    isinstance(folded, dict) and folded.get(str(i))
                ),
            }
        )

    return {
        "table_id": state.get("table_id"),
        "max_seats": state.get("max_seats"),
        "hand_status": hand.get("status"),
        "street": hand.get("street"),
        "pot": hand.get("pot"),
        "current_bet": hand.get("current_bet"),
        "min_raise_increment": hand.get("min_raise_increment"),
        "button_seat": hand.get("button_seat"),
        "sb_seat": hand.get("sb_seat"),
        "bb_seat": hand.get("bb_seat"),
        "action_to_seat": hand.get("action_to_seat"),
        "my_seat": my_seat,
        "my_hole_cards": my_cards,
        "community_cards": [str(c) for c in (hand.get("community") or [])],
        "opponents": opponents,
        "recent_actions": (hand.get("action_log") or [])[-12:],
    }


def execute_tool(
    name: str,
    state: dict,
    player_id: str,
    _args: dict[str, Any],
) -> dict[str, Any]:
    """Dispatcher for tool names used in LLM prompts."""
    vis = build_visible_state(state, player_id)
    if name == "get_my_hole_cards":
        return {"cards": vis.get("my_hole_cards")}
    if name == "get_community_cards":
        return {"community_cards": vis.get("community_cards")}
    if name == "get_opponents_state":
        return {"opponents": vis.get("opponents")}
    if name == "get_betting_context":
        return {
            "pot": vis.get("pot"),
            "current_bet": vis.get("current_bet"),
            "min_raise_increment": vis.get("min_raise_increment"),
            "street": vis.get("street"),
            "button_seat": vis.get("button_seat"),
            "sb_seat": vis.get("sb_seat"),
            "bb_seat": vis.get("bb_seat"),
            "action_to_seat": vis.get("action_to_seat"),
            "my_seat": vis.get("my_seat"),
        }
    if name == "get_full_visible_snapshot":
        return vis
    return {"error": "unknown_tool", "name": name}


# Strict JSON Schema helps OpenAI-compatible providers (incl. Gemini) accept tool definitions.
# Empty-parameter tools: explicit required=[] and additionalProperties=false.
_PARAMS_EMPTY: dict[str, Any] = {
    "type": "object",
    "properties": {},
    "required": [],
    "additionalProperties": False,
}

OPENAI_STYLE_TOOLS: list[dict[str, Any]] = [
    {
        "type": "function",
        "function": {
            "name": "get_my_hole_cards",
            "description": "Your private hole cards (only you can see these).",
            "parameters": _PARAMS_EMPTY,
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_community_cards",
            "description": "Board / community cards currently dealt.",
            "parameters": _PARAMS_EMPTY,
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_opponents_state",
            "description": "Other players: stacks, folded, contribution this street (not their hole cards).",
            "parameters": _PARAMS_EMPTY,
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_betting_context",
            "description": "Pot, current bet, min raise increment, positions, whose turn.",
            "parameters": _PARAMS_EMPTY,
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_full_visible_snapshot",
            "description": "Single call: all of the above combined (faster than many calls).",
            "parameters": _PARAMS_EMPTY,
        },
    },
    {
        "type": "function",
        "function": {
            "name": "submit_poker_action",
            "description": (
                "Submit your legal move. For raise/bet, amount is your TOTAL contribution "
                "on this street (not the delta). Example: current_bet 20, you contributed 10, "
                "min_raise_increment 10 → a legal raise sets amount to at least 30."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["fold", "check", "call", "raise", "bet", "all_in"],
                    },
                    "amount": {
                        "type": "integer",
                        "description": "Required for raise/bet: total street contribution.",
                    },
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
]
