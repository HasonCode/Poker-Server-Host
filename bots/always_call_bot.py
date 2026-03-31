"""
Simplest possible bot: always calls (or checks if nothing to call).

Run::

    python clients/python/bot_runner.py bots/always_call_bot.py --name Caller
"""


def decide(state: dict, me: dict) -> dict:
    hand = state["hand"]
    cb = hand.get("current_bet", 0)
    contrib = me["contribution"]
    stack = me["stack"]

    call_need = cb - contrib
    if call_need > 0 and call_need <= stack:
        return {"action": "call"}
    if call_need > stack:
        return {"action": "all_in"}
    return {"action": "check"}
