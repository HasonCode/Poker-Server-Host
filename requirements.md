# Poker Server — Requirements (Planning)

This document captures goals, functional requirements, and constraints for a server-side poker game engine with a client-facing API. It is intended for implementation planning; details may be refined as the design solidifies.

---

## 1. Goals

- Provide a **single source of truth** for an active poker table: pot size, per-player stacks and bets, betting history for the current hand, hole and community cards (subject to visibility rules), and valid next actions.
- Support **up to 10 seated players** per table for any given betting round.
- Maintain **chip continuity** across hands: stacks persist; only pots, antes, blinds, and voluntary bets move chips during play.
- Allow **players to join and leave** the table without corrupting game state, with clear rules for mid-hand vs between-hand transitions.
- Prefer implementation in **Lua** for the server core (runtime choice—e.g. OpenResty, Luvit, or standalone Lua with an HTTP layer—left to a later technical design).

---

## 2. Scope (In Scope)

### 2.1 Game model (minimum viable)

- **Table**: fixed max seats (10), ordered seats, one active hand at a time (or explicit “no hand” state).
- **Stacks**: integer chip counts per seated player; server-authoritative.
- **Pot & side pots**: track main pot and side pots when players are all-in for different amounts (required for correctness if “chip continuity” includes real poker rules).
- **Street / phase**: preflop, flop, turn, river, showdown (or equivalent labels).
- **Betting round state**: current actor, minimum legal raise (or N/A), whether check is allowed, call amount to stay in, etc.
- **Actions**: fold, check (when legal), call, bet (if no bet facing), raise (when legal), and possibly all-in as a raise/call variant—exact set to match chosen rules (e.g. No-Limit Hold’em).

### 2.2 Data the API must expose (read/query)

Clients (or other services) must be able to retrieve, per table/session:

| Area | Requirement |
|------|-------------|
| **Pot** | Total chips in the pot (and optionally breakdown by side pot). |
| **Per-hand bets** | Chips committed by each player **during the current hand** (street totals and/or cumulative; format TBD). |
| **Betting actions** | Sequence or snapshot of actions: fold, check, call, raise (with sizes), etc., associated with player identity and order. |
| **Hole cards** | Each player’s private cards **only to authorized viewers** (typically that player; optionally dealer/observer if product requires). |
| **Community cards** | Board cards currently dealt for the hand. |
| **Stacks** | Each seated player’s **current stack** (chips not yet committed to the pot this hand, or total wealth + committed—define one consistent model in the API). |
| **Legal actions** | For the current player (or for a given seat when polling): what actions are allowed and parameters (e.g. min/max raise). |

### 2.3 Data the API must accept (write/commands)

- **Player actions**: submit intended action—fold, check, call, raise (with amount), etc.—validated against game rules and current state.
- **Table lifecycle** (as needed): create table, seat player, leave seat, possibly reconnect with session token (exact auth model TBD).

### 2.4 Concurrency & sessions

- **10 players**: enforce max seats; reject or queue operations that would exceed capacity.
- **Join / leave**:
  - Between hands: seat assignment, buy-in/stack updates, removal from seat.
  - Mid-hand: define behavior (e.g. leave = fold + remove after hand; join = wait for next hand; sit-out flags).
- **Chip continuity**: no unexplained chip creation/destruction; all changes traceable to blinds, antes, bets, folds, wins, and approved buy-ins/cash-outs.

---

## 3. Out of Scope (Initial Phase — Explicit)

- Official licensing, real-money compliance, geolocation.
- Full anti-cheat, collusion detection, or RNG certification (though **shuffle fairness** should be specified before implementation).
- Rich tournament structures (multi-table, payouts)—unless later promoted to requirements.
- Persistent user accounts across devices—optional; can be session-only at first.

---

## 4. Non-Functional Requirements

- **Authoritative server**: clients may not set pot, stacks, or cards directly; only actions and administrative commands allowed by policy.
- **Deterministic rules engine**: given the same sequence of actions and RNG seeds (if used), outcomes are reproducible for tests.
- **API clarity**: versioned REST and/or WebSocket events (choice TBD); errors return rule violations in a machine-readable form.
- **Performance**: support at least one full table with low-latency action submission; exact SLAs TBD.

---

## 5. Open Design Decisions (To Resolve Before Implementation)

1. **Variant**: No-Limit Texas Hold’em vs Pot-Limit vs Limit; ante/straddle rules.
2. **Lua stack**: OpenResty (HTTP + Lua), Luvit, or embedded Lua behind another process.
3. **Transport**: HTTP-only polling vs WebSocket push for state updates.
4. **Identity**: anonymous seat tokens vs registered users; reconnection after disconnect.
5. **Hole card visibility**: strict per-player vs table-level testing mode.
6. **Money movement**: single global “wallet” per player vs table-only chips only.

---

## 6. Success Criteria (Acceptance — High Level)

- A client can create or join a table, receive current state (pot, bets, board, own cards, stacks, action history), submit valid actions, and observe updates through a hand completion.
- With 10 seated players, the server enforces turn order, pot/side-pot correctness, and chip conservation.
- Players can leave and join according to documented rules without desynchronizing stacks or the pot.

---

## 7. Document History

| Version | Date | Notes |
|---------|------|--------|
| 0.1 | 2026-03-29 | Initial planning outline from project goals. |
