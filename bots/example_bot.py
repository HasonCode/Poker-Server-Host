"""
Example bot: min-raise preflop, check/call postflop.

Run::

    python clients/python/bot_runner.py bots/example_bot.py
    python clients/python/bot_runner.py bots/example_bot.py --name Raiser --chips 1000
"""


def decide(state: dict, me: dict) -> dict:
    """
    Called each time it is our turn.

    Parameters
    ----------
    state : dict
        Full table snapshot from GET /v1/tables/:id/state.
        Key fields:
          state["hand"]["status"]              - "active" / "idle"
          state["hand"]["street"]              - "preflop" / "flop" / "turn" / "river"
          state["hand"]["current_bet"]         - current bet level this street
          state["hand"]["min_raise_increment"] - minimum raise size
          state["hand"]["pot"]                 - total pot
          state["hand"]["community"]           - list of community card strings
          state["seats"]                       - list of seat dicts

    me : dict
        { "player_id", "seat", "stack", "hole_cards": ["A♠","K♥"], "contribution" }

    Returns
    -------
    dict with "action" (str) and optional "amount" (int).
        action: "fold", "check", "call", "raise", "bet", "all_in"
        amount: total street contribution for raise/bet
    """
    hand = state["hand"]
    street = hand.get("street", "preflop")
    cb = hand.get("current_bet", 0)
    mri = hand.get("min_raise_increment", 5)
    stack = me["stack"]
    contrib = me["contribution"]

    if street == "preflop":
        target = cb + mri
        need = target - contrib
        if need > 0 and need <= stack:
            return {"action": "raise", "amount": target}

    call_need = cb - contrib
    if call_need > 0 and call_need <= stack:
        return {"action": "call"}

    if contrib >= cb:
        return {"action": "check"}

    return {"action": "fold"}
