# Admin table spectate (“ghost” view)

This document records **repair attempts**, the **intended behavior**, and **how to run** admin spectate: same **main table UI** as a seated player (felt, seats, board, log), **all hole cards visible for every occupied seat**, **no** join/leave/actions/bots, independent of how many players are at the table.

---

## Canonical admin spectate (recommended)

**`GET /admin/spectate.html`** (static page under `/admin/`) uses the **same admin session cookie** as `/admin` and does **not** rely on `/v1/tables/.../state` or cookie path to `/`. It polls **`GET /admin/api/tables/:id/snapshot`** every **1.5s**, renders the full felt (same layout as the public UI), and includes a **table switcher** (all tables). Open from the admin header **“Table spectate”** or **“Open spectate page”** after selecting a table.

---

## Intended behavior

| Requirement | Implementation |
|-------------|----------------|
| Same overall page as a normal user | **Preferred:** dedicated **`/admin/spectate.html`** (full felt, all cards, table dropdown). **Legacy:** Main UI (`/`) with `?spectate=1` (and `?table=…`). `body.spectate-mode` shows the **game area**; join panel and interactive panels are hidden. |
| All players’ hole cards revealed | Server returns **unfiltered** `table_snapshot` on `GET /v1/tables/:id/state?spectate=1` when authorized (see below). `renderSeats` uses `hand.hole_cards` for each seat. |
| Works for any player count | No seat limit in spectate logic; empty seats render as usual; occupied seats show cards when the hand supplies them. |
| No interaction with the game | `spectateMode` disables turn detection, action buttons stay disabled, leave hidden, join hidden, bot panel hidden. |
| Ghost / non-player identity | “Your” strip shows **Spectator** + short note; no `playerId` / token for game actions. |

---

## Repair attempts (chronology)

### 1. Initial design

- **GET** `/v1/tables/:id/state?spectate=1` gated by admin auth; response **without** `filter_snapshot_for_player` so all `hole_cards` keys are present.
- **Frontend:** `spectate=1` enables `credentials: "include"` so the **admin session cookie** is sent to `/v1/...`.
- **Cookie `Path=/`** so the cookie is not limited to `/admin` only (required for `/v1/tables/...`).

### 2. “Nothing happens” / no feedback (admin button)

- **Issue:** `window.open(url, "_blank", "features")` with a non-empty third argument behaved like a popup and was often blocked; no success/error message.
- **Fix:** Use `window.open(path, "_blank")` only; show “Opening…”, then success or **popup blocked** with a **clickable URL**; optional `spectateOpenFeedback` text.

### 3. Errors swallowed as “Invalid JSON”

- **Issue:** On 401/403, error bodies sometimes failed JSON parse; UI showed a generic parse error instead of auth messaging.
- **Fix:** `apiFetch` parses errors leniently and surfaces `error.message` / status text.

### 4. Spectate auth tied only to `require_admin` (503 without OAuth)

- **Issue:** Spectate used **`require_admin`**, which returns **503** when `ADMIN_EMAIL` / Google OAuth is not configured—so spectate could **never** succeed in minimal/dev setups.
- **Fix:** Introduced **`spectate_authorized(req)`** in `main.lua` (must be defined **before** route registration) that allows either:
  - Valid **admin session** (`admin_auth.validate_session` with `ADMIN_EMAIL`), or
  - **`POKER_SPECTATE_SECRET`** matching **`X-Spectate-Secret`** / **`X-Spectate-Key`** header or query **`spectate_key`** / **`key`**.

### 5. Lua scope / ordering bug

- **Issue:** `spectate_authorized` was initially placed **after** routes that referenced it; in Lua local functions are not visible above their declaration in the same block.
- **Fix:** Define **`spectate_authorized`** immediately after the HTTP server is created (`if not srv then return end`) and **before** any `srv:route` that calls it.

### 6. Cookie lookup robustness

- **Issue:** Rare browser/cookie name casing mismatches.
- **Fix:** `parse_cookies` lowercases cookie **names**; `validate_session` can fall back to lowercase key lookup.

### 7. Frontend secret handoff (no OAuth)

- **Issue:** Browsers cannot set `HttpOnly` cookies from JS; devs need another way when OAuth is off.
- **Fix:** Optional **`?spectate_key=`** once → `sessionStorage`; persistent option **`localStorage.pokerSpectateSecret`**; requests send **`X-Spectate-Secret`** and append **`&spectate_key=`** on the state URL when set.

### 8. Same-origin / host mismatch

- **Issue:** Admin at `https://a.example` and spectate at `http://localhost` (or different host) → cookie not sent.
- **Fix:** Documented clearly; error copy in `poll()` points to same origin + OAuth or `POKER_SPECTATE_SECRET`.

---

## Current server behavior (`main.lua`)

1. **`spectate_authorized(req)`** (defined **before** routes):
   - If `ADMIN_EMAIL` is set: `admin_auth.validate_session(req, admin_email)` → success allows spectate.
   - Else if `POKER_SPECTATE_SECRET` is set: match header or query (see grep in repo).

2. **`GET /v1/tables/:id/state`**
   - Query `spectate=1` or `spectate=true` → if `spectate_authorized`, return **`table_snapshot(c)`** (full hole cards).
   - Otherwise normal **`filter_snapshot_for_player`** for player token.

3. **Admin panel snapshot** (unchanged): **`GET /admin/api/tables/:id/snapshot`** still returns full state for logged-in admin.

---

## Current client behavior

### Dedicated page (`frontend/admin/spectate.html`, `frontend/admin/spectate.js`)

- URL: **`/admin/spectate.html?table=<id>`** (optional; table can be chosen in the UI).
- Session: **`credentials: "same-origin"`** to **`/admin/api/session`** and **`/admin/api/tables/.../snapshot`** only — no spectate secret required when OAuth admin login works.
- Poll: **1.5s** full table snapshot; switch tables via dropdown.

### Main app (`frontend/app.js`)

- URL: **`/?table=<id>&spectate=1`** (optional **`&spectate_key=...`** once if using env secret).
- **`spectateMode`:** hides join, shows game area, spectator strip, disables actions, polls **`spectateStateUrl()`** (~1.5s).
- **`credentials: "include"`** + optional **`X-Spectate-Secret`** / query key.

---

## Operator checklist (make it work)

1. **Same origin** as admin: e.g. if admin is `https://poker.example.org/admin`, open  
   `https://poker.example.org/?table=demo&spectate=1`  
   (not another host or mixed http/https).

2. **Sign in** at `/admin` in **this browser** so `poker_admin_session` is set for that origin.

3. **Or** set on the server:  
   `export POKER_SPECTATE_SECRET="$(openssl rand -hex 32)"`  
   then open once:  
   `https://yoursite/?table=demo&spectate=1&spectate_key=<same-secret>`  
   (key is stored in `sessionStorage` and stripped from the URL).

4. **Restart** the Lua process after changing environment variables.

5. From **Admin → Table spectate** or **Open spectate page** after selecting a table, or open **`/admin/spectate.html`** directly. Legacy: bookmark **`/?table=…&spectate=1`** as above.

---

## Manual verification

- [ ] Header shows **Spectating (admin)** (or connecting / error text if failed).
- [ ] On **`/admin/spectate.html`**, footer shows `.../admin/api/tables/.../snapshot`. Legacy main UI: `.../state?spectate=1` (and `spectate_key` if secret used).
- [ ] With 2+ seated players in an active hand, **each occupied seat** shows **face-up** hole cards on the felt (not only facedown).
- [ ] Action buttons are **disabled**; Leave / Join / bot controls **not** usable.
- [ ] **Admin panel** “Live spectate” still works as a separate JSON/card view (`/admin/api/tables/.../snapshot`).

---

## Files touched (reference)

| Area | Files |
|------|--------|
| Server auth & route | `main.lua` |
| Cookies / session | `src/poker/admin_auth.lua`, `src/poker/http_server.lua` (`parse_cookies`) |
| Main UI | `frontend/app.js`, `frontend/styles.css` (`.spectate-mode`, errors) |
| Admin UI | `frontend/admin/admin.js`, `frontend/admin/index.html`, `frontend/admin/admin.css` |
| Admin spectate page | `frontend/admin/spectate.html`, `frontend/admin/spectate.js`, `frontend/admin/spectate-page.css` |

---

## Known limitations

- Spectator is **not** a seated player; the top strip says **Spectator** rather than duplicating a random seat’s “you” row—that is intentional for clarity.
- **Security:** Anyone who can pass `POKER_SPECTATE_SECRET` or hijack an admin session can see all cards; treat the secret like a password and use HTTPS in production.
