(function () {
  "use strict";

  const $ = (sel, el) => (el || document).querySelector(sel);

  const STORAGE_KEY = "pokerLlmSpectatePassword";

  const barStatus = $("#barStatus");
  const passwordGate = $("#passwordGate");
  const passwordGateErr = $("#passwordGateErr");
  const passwordInput = $("#passwordInput");
  const passwordSubmit = $("#passwordSubmit");
  const spectateMain = $("#spectateMain");
  const tableIdInput = $("#tableIdInput");
  const spectateRefreshBtn = $("#spectateRefreshBtn");
  const startHandBtn = $("#startHandBtn");
  const llmStepBtn = $("#llmStepBtn");
  const logoutSpectateBtn = $("#logoutSpectateBtn");
  const liveUpdatesCheckbox = $("#liveUpdates");
  const endpointEl = $("#endpointEl");
  const emptyTableHint = $("#emptyTableHint");
  const stripMeta = $("#stripMeta");

  /** Matches llm_players/config.py DEFAULT_PLAYERS — for seat labels only */
  const LLM_DISPLAY = {
    gpt_5_4: "GPT 5.4",
    claude_4_6_opus: "Claude 4.6 Opus",
    gemini_3_1: "Gemini 3.1",
    llama_4: "Meta Llama 4",
    deepseek_v3_2: "DeepSeek V3.2",
    mistral_large_3: "Mistral Large 3",
    grok_ai: "Grok AI",
  };

  /** CSS classes in llm_spectate.css — one accent per model */
  const LLM_MONO_CLASS = {
    gpt_5_4: "llm-mono-gpt_5_4",
    claude_4_6_opus: "llm-mono-claude_4_6_opus",
    gemini_3_1: "llm-mono-gemini_3_1",
    llama_4: "llm-mono-llama_4",
    deepseek_v3_2: "llm-mono-deepseek_v3_2",
    mistral_large_3: "llm-mono-mistral_large_3",
    grok_ai: "llm-mono-grok_ai",
  };

  const statusPill = $("#statusPill");
  const streetVal = $("#streetVal");
  const potVal = $("#potVal");
  const betVal = $("#betVal");
  const minRaiseVal = $("#minRaiseVal");
  const communityEl = $("#community");
  const feltWrap = $("#feltWrap");
  const feltPotVal = $("#feltPotVal");
  const actionLog = $("#actionLog");
  const monologuePanel = $("#monologuePanel");
  const monologueFeed = $("#monologueFeed");

  const POLL_MS = 1500;
  let pollTimer = null;
  /** @type {object|null} */
  let lastSpectateData = null;

  const urlParams = new URLSearchParams(location.search);
  const initialTable = (urlParams.get("table") || "llm_bots").trim();
  if (tableIdInput) tableIdInput.value = initialTable;
  if (liveUpdatesCheckbox) {
    if (urlParams.get("live") === "0") {
      liveUpdatesCheckbox.checked = false;
    } else if (urlParams.get("live") === "1") {
      liveUpdatesCheckbox.checked = true;
    }
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  function spectateStateUrl(tid, pw) {
    const q = new URLSearchParams();
    q.set("spectate", "1");
    q.set("spectate_password", pw);
    return "/v1/tables/" + encodeURIComponent(tid) + "/state?" + q.toString();
  }

  function endpointLabel(tid) {
    return (
      "GET /v1/tables/" +
      encodeURIComponent(tid) +
      "/state?spectate=1&spectate_password=***"
    );
  }

  function countSeated(seats) {
    let n = 0;
    for (const s of seats || []) {
      if (s && typeof s === "object" && s.player_id) n++;
    }
    return n;
  }

  function isLiveMode() {
    return !!(liveUpdatesCheckbox && liveUpdatesCheckbox.checked);
  }

  function updatePollHint() {
    const el = $("#pollHint");
    if (!el) return;
    if (isLiveMode()) {
      el.textContent = "Live: snapshot every 1.5s";
    } else {
      el.textContent = "Step mode: click Next snapshot (or enable Live)";
    }
  }

  function updateStripMeta() {
    if (!stripMeta) return;
    if (isLiveMode()) {
      stripMeta.textContent =
        "Full table — all hole cards. Live updates on. No actions.";
    } else {
      stripMeta.textContent =
        "Step mode — click Next snapshot to advance the view. Enable Live (1.5s) for auto-updates. No actions.";
    }
  }

  function updateStripMetaForTable(data) {
    if (!stripMeta) return;
    const hand = data.hand || {};
    if (data.manual_start_only) {
      if (hand.status === "idle") {
        stripMeta.textContent =
          "LLM table — when at least two players are seated, click Deal cards to start the hand. " +
          "This view shows every player’s hole cards. " +
          (isLiveMode() ? "Live updates on." : "Use Next snapshot or enable Live.");
      } else {
        stripMeta.textContent =
          "Hand in progress — all hole cards below. Use Run AI turn to call the acting LLM (tools + action + monologue to transcript). " +
          (isLiveMode() ? "Live updates on." : "Use Next snapshot or Live.");
      }
      return;
    }
    if (hand.status === "idle") {
      updateStripMeta();
    } else {
      stripMeta.textContent =
        "Full table — all hole cards. " + (isLiveMode() ? "Live updates on." : "Use Next snapshot or Live.");
    }
  }

  function updateStartHandButton(data) {
    if (!startHandBtn) return;
    const hand = data.hand || {};
    const ns = countSeated(data.seats || []);
    const show =
      data.manual_start_only === true && hand.status === "idle" && ns >= 2;
    startHandBtn.classList.toggle("hidden", !show);
  }

  function updateLlmStepButton(data) {
    if (!llmStepBtn) return;
    const hand = data.hand || {};
    const show =
      data.manual_start_only === true && hand.status === "active";
    llmStepBtn.classList.toggle("hidden", !show);
  }

  function updateEmptyHint(data) {
    if (!emptyTableHint) return;
    const n = countSeated(data.seats || []);
    emptyTableHint.classList.toggle("hidden", n > 0);
  }

  function renderMonologueEntry(step) {
    if (!monologueFeed || !step) return;
    const pid = step.player_id || "";
    const monoCls = (pid && LLM_MONO_CLASS[pid]) || "llm-mono-default";
    const name = step.display_name || LLM_DISPLAY[pid] || pid || "LLM";
    const act = step.action ? String(step.action) : "";
    const amt = step.amount != null && step.amount !== "" ? String(step.amount) : "";
    const raw = step.monologue != null ? String(step.monologue) : "";
    const bodyText =
      raw.trim() ||
      "(No monologue text — the API call may have failed; check the server terminal.)";

    if (monologuePanel) monologuePanel.classList.remove("hidden");

    const wrap = document.createElement("article");
    wrap.className = "monologue-entry " + monoCls;
    wrap.setAttribute("data-player-id", pid || "unknown");

    const head = document.createElement("div");
    head.className = "monologue-head";
    head.textContent =
      name + (act ? " · " + act + (amt ? " · " + amt : "") : "");

    const body = document.createElement("div");
    body.className = "monologue-body";
    body.textContent = bodyText;

    wrap.appendChild(head);
    wrap.appendChild(body);
    monologueFeed.insertBefore(wrap, monologueFeed.firstChild);

    if (monologuePanel) {
      monologuePanel.scrollIntoView({ behavior: "smooth", block: "nearest" });
    }
  }

  function winnerLabel(pid) {
    if (!pid) return "?";
    const d = LLM_DISPLAY[pid];
    return d ? d + " (" + pid + ")" : String(pid);
  }

  async function fetchSpectateState(tid, pw) {
    const path = spectateStateUrl(tid, pw);
    const res = await fetch(path, {
      headers: { Accept: "application/json" },
      credentials: "omit",
    });
    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = null;
    }
    if (res.status === 401) {
      const err = new Error(
        (data && data.error && data.error.message) || "Spectate denied (wrong password?)"
      );
      err.httpStatus = 401;
      err.apiCode = data && data.error ? data.error.code : undefined;
      throw err;
    }
    if (!res.ok) {
      const msg =
        (data && data.error && (data.error.message || data.error.code)) ||
        res.statusText ||
        "Request failed";
      const err = new Error(msg);
      err.httpStatus = res.status;
      throw err;
    }
    return data;
  }

  function parseCard(str) {
    if (!str || str === "?") return null;
    const suit = str.slice(-1);
    const rank = str.slice(0, -1);
    return { rank, suit };
  }

  function isRed(suit) {
    return suit === "♥" || suit === "♦";
  }

  function makeCardEl(str, extraCls) {
    const el = document.createElement("span");
    const parsed = parseCard(str);
    if (!parsed) {
      el.className = "card placeholder" + (extraCls ? " " + extraCls : "");
      el.textContent = "?";
      return el;
    }
    el.className =
      "card" +
      (isRed(parsed.suit) ? " red" : "") +
      (extraCls ? " " + extraCls : "");
    const r = document.createElement("span");
    r.className = "card-rank";
    r.textContent = parsed.rank;
    const s = document.createElement("span");
    s.className = "card-suit";
    s.textContent = parsed.suit;
    el.appendChild(r);
    el.appendChild(s);
    return el;
  }

  function makeFacedownEl(extraCls) {
    const el = document.createElement("span");
    el.className = "card facedown" + (extraCls ? " " + extraCls : "");
    el.textContent = "🂠";
    return el;
  }

  function getContrib(hand, seat) {
    const c = hand.contribution || {};
    if (typeof c === "object" && !Array.isArray(c)) return c[String(seat)] || 0;
    return 0;
  }

  const BET_POS = {
    1: { x: 41, y: 72 },
    2: { x: 27, y: 65 },
    3: { x: 20, y: 46 },
    4: { x: 26, y: 25 },
    5: { x: 39, y: 20 },
    6: { x: 52, y: 20 },
    7: { x: 70, y: 25 },
    8: { x: 77, y: 46 },
    9: { x: 70, y: 65 },
    10: { x: 55, y: 72 },
  };

  function renderSeats(data) {
    const max = data.max_seats || 10;
    const seats = data.seats || [];
    const hand = data.hand || {};
    const holeCards = hand.hole_cards || {};
    const folded = hand.folded || {};

    feltWrap.querySelectorAll(".felt-bet").forEach((el) => el.remove());

    for (let i = 1; i <= 10; i++) {
      const el = feltWrap.querySelector('.felt-seat[data-seat="' + i + '"]');
      if (!el) continue;

      if (i > max) {
        el.classList.add("hidden");
        continue;
      }
      el.classList.remove("hidden");

      const s = seats[i - 1];
      const isFolded = typeof folded === "object" && !Array.isArray(folded) && folded[String(i)];

      const base = "felt-seat";
      el.className =
        base +
        (s && s.player_id ? " occupied" : "") +
        (hand.action_to_seat === i ? " acting" : "") +
        " spectate-ghost" +
        (isFolded ? " folded" : "");
      el.dataset.seat = i;
      el.replaceChildren();

      if (s && s.player_id) {
        const pid = s.player_id;
        const display = LLM_DISPLAY[pid];
        const name = document.createElement("div");
        name.className = "fs-name";
        name.textContent = display || pid;
        el.appendChild(name);
        if (display) {
          const sid = document.createElement("div");
          sid.className = "fs-llm-id";
          sid.textContent = pid;
          el.appendChild(sid);
          const badge = document.createElement("span");
          badge.className = "fs-llm-badge";
          badge.textContent = "LLM";
          el.appendChild(badge);
        }

        const stack = document.createElement("div");
        stack.className = "fs-stack";
        stack.textContent = s.stack;
        el.appendChild(stack);

        const tags = [];
        if (hand.button_seat === i) tags.push("D");
        if (hand.sb_seat === i) tags.push("SB");
        if (hand.bb_seat === i) tags.push("BB");
        if (isFolded) tags.push("FOLD");
        if (tags.length) {
          const t = document.createElement("div");
          t.className = "fs-tags";
          t.textContent = tags.join(" · ");
          el.appendChild(t);
        }

        const cardsDiv = document.createElement("div");
        cardsDiv.className = "fs-cards";
        const cards =
          typeof holeCards === "object" && !Array.isArray(holeCards) ? holeCards[String(i)] : null;
        if (cards && cards.length) {
          cards.forEach((c) => cardsDiv.appendChild(makeCardEl(c, "xs")));
        } else if (hand.status === "active" && !isFolded) {
          cardsDiv.appendChild(makeFacedownEl("xs"));
          cardsDiv.appendChild(makeFacedownEl("xs"));
        }
        if (cardsDiv.children.length) el.appendChild(cardsDiv);

        const contrib = getContrib(hand, i);
        if (contrib > 0 && BET_POS[i]) {
          const bp = BET_POS[i];
          const bet = document.createElement("div");
          bet.className = "felt-bet";
          bet.style.left = bp.x + "%";
          bet.style.top = bp.y + "%";
          bet.textContent = contrib;
          feltWrap.appendChild(bet);
        }
      } else {
        const empty = document.createElement("div");
        empty.className = "fs-name fs-empty";
        empty.textContent = "Seat " + i;
        el.appendChild(empty);
      }
    }
  }

  function renderLog(hand) {
    actionLog.replaceChildren();
    const log = hand.action_log || [];
    if (log.length === 0) {
      const li = document.createElement("li");
      li.textContent = "No actions yet.";
      actionLog.appendChild(li);
      return;
    }
    log.forEach((entry) => {
      const li = document.createElement("li");
      const amt = entry.amount != null ? " " + entry.amount : "";
      li.innerHTML =
        "<b>" +
        esc(entry.player_id) +
        "</b> " +
        esc(entry.action) +
        amt +
        " <span style='color:var(--muted);font-size:0.75rem'>[" +
        esc(entry.street) +
        "]</span>";
      actionLog.appendChild(li);
    });
    actionLog.scrollTop = actionLog.scrollHeight;
  }

  function renderAll(data) {
    lastSpectateData = data;
    const hand = data.hand || {};

    statusPill.textContent = hand.status || "idle";
    statusPill.className = "pill " + (hand.status === "active" ? "active" : "idle");
    streetVal.textContent = hand.street || "—";
    potVal.textContent = hand.pot != null ? hand.pot : 0;
    feltPotVal.textContent = hand.pot != null ? hand.pot : 0;
    betVal.textContent = hand.current_bet != null ? hand.current_bet : 0;
    minRaiseVal.textContent = hand.min_raise_increment != null ? hand.min_raise_increment : "—";

    communityEl.replaceChildren();
    let comm = hand.community || [];
    if (comm.length === 0 && hand.status !== "active") {
      const lc = hand.last_community || [];
      if (lc.length > 0 && hand.last_winners && hand.last_winners.length > 0) {
        comm = lc;
      }
    }
    if (comm.length === 0 && hand.status === "active") {
      for (let i = 0; i < 5; i++) communityEl.appendChild(makeFacedownEl());
    } else if (comm.length === 0) {
      for (let i = 0; i < 5; i++) {
        const ph = document.createElement("span");
        ph.className = "card placeholder";
        ph.textContent = "";
        communityEl.appendChild(ph);
      }
    } else {
      comm.forEach((c) => communityEl.appendChild(makeCardEl(String(c))));
      for (let i = comm.length; i < 5; i++) communityEl.appendChild(makeFacedownEl());
    }

    renderSeats(data);

    const winnersEl = $("#winners");
    const lw = hand.last_winners;
    if (lw && Array.isArray(lw) && lw.length > 0) {
      winnersEl.classList.remove("hidden");
      winnersEl.replaceChildren();
      lw.forEach((w) => {
        const div = document.createElement("div");
        div.className = "winner-entry";
        const hname = w.hand_name && w.hand_name !== "fold" ? " (" + esc(w.hand_name) + ")" : "";
        div.innerHTML =
          "&#127942; <b>" +
          esc(winnerLabel(w.player_id)) +
          "</b> won <b>" +
          w.amount +
          "</b> chips" +
          hname;
        winnersEl.appendChild(div);
      });
    } else {
      winnersEl.classList.add("hidden");
    }

    renderLog(hand);

    const tid = currentTableId() || data.table_id || "";
    const ns = countSeated(data.seats || []);
    const mode = isLiveMode() ? "live" : "step";
    barStatus.textContent =
      (tid ? "Table " + tid : "Set table id") +
      " · " +
      ns +
      " seated · " +
      mode;
    barStatus.className = "sub";
    endpointEl.textContent = tid ? endpointLabel(tid) : "—";
    updateEmptyHint(data);
    updateStripMetaForTable(data);
    updateStartHandButton(data);
    updateLlmStepButton(data);
  }

  function currentTableId() {
    return (tableIdInput && tableIdInput.value ? tableIdInput.value : "").trim();
  }

  function stopPoll() {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  function startPoll() {
    stopPoll();
    if (!isLiveMode()) {
      return;
    }
    const tick = () => {
      const tid = currentTableId();
      const pw = sessionStorage.getItem(STORAGE_KEY);
      if (!tid) {
        barStatus.textContent = "Set a table id.";
        endpointEl.textContent = "—";
        return;
      }
      if (!pw) {
        showPasswordGate();
        return;
      }
      loadSnapshot(tid, pw);
    };
    tick();
    pollTimer = setInterval(tick, POLL_MS);
  }

  function applyLiveMode() {
    updatePollHint();
    if (lastSpectateData) {
      updateStripMetaForTable(lastSpectateData);
      updateStartHandButton(lastSpectateData);
      updateLlmStepButton(lastSpectateData);
    } else {
      updateStripMeta();
    }
    if (isLiveMode()) {
      startPoll();
    } else {
      stopPoll();
    }
  }

  async function loadSnapshot(tid, pw) {
    try {
      const data = await fetchSpectateState(tid, pw);
      if (!data) throw new Error("Empty response");
      renderAll(data);
    } catch (e) {
      if (e.httpStatus === 401) {
        sessionStorage.removeItem(STORAGE_KEY);
        showPasswordGate(e.message || "Spectate denied");
        return;
      }
      barStatus.textContent = "Error: " + e.message;
      barStatus.className = "sub spectate-error";
    }
  }

  async function runLlmStep() {
    const tid = currentTableId();
    const pw = sessionStorage.getItem(STORAGE_KEY);
    if (!tid || !pw) {
      showPasswordGate("");
      return;
    }
    if (llmStepBtn) llmStepBtn.disabled = true;
    barStatus.textContent = "Running LLM turn (API calls on server)…";
    barStatus.className = "sub";
    const t0 = typeof performance !== "undefined" ? performance.now() : Date.now();
    const url =
      location.origin + "/v1/tables/" + encodeURIComponent(tid) + "/llm-step";
    console.info("[llm-step] POST", url, "— see terminal running poker-server for [llm-step] / [poker-server] lines");
    try {
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        credentials: "omit",
        body: JSON.stringify({ spectate_password: pw }),
      });
      const text = await res.text();
      const dt =
        (typeof performance !== "undefined" ? performance.now() : Date.now()) - t0;
      let data;
      try {
        data = text ? JSON.parse(text) : null;
      } catch {
        data = null;
      }
      console.info("[llm-step] HTTP", res.status, "in", Math.round(dt), "ms", {
        ok: res.ok,
        hasStep: !!(data && data.step),
        tableId: data && data.table && data.table.table_id,
        error: data && data.error,
      });
      if (res.status === 401) {
        sessionStorage.removeItem(STORAGE_KEY);
        showPasswordGate((data && data.error && data.error.message) || "Spectate denied");
        return;
      }
      if (!res.ok) {
        const msg =
          (data && data.error && (data.error.message || data.error.code)) ||
          res.statusText ||
          "Run failed";
        console.warn("[llm-step] failed", res.status, msg, data && data.error);
        if (data && data.error && data.error.details && data.error.details.stdout_tail) {
          console.warn(
            "[llm-step] server stdout_tail (last 2k chars from python subprocess):\n",
            data.error.details.stdout_tail
          );
        }
        barStatus.textContent = "Run AI turn failed: " + msg;
        barStatus.className = "sub spectate-error";
        return;
      }
      if (data && data.table) {
        renderAll(data.table);
      }
      const st = data && data.step;
      if (st) {
        renderMonologueEntry(st);
        console.info(
          "[llm-step] step",
          st.player_id,
          st.action,
          "monologue_chars",
          st.monologue != null ? String(st.monologue).length : 0
        );
      }
      const who = st && (st.display_name || st.player_id) ? st.display_name || st.player_id : "";
      const act = st && st.action ? st.action : "";
      const hasMono = st && st.monologue && String(st.monologue).trim();
      barStatus.textContent = who
        ? "LLM turn: " +
          who +
          (act ? " → " + act : "") +
          (hasMono ? " — monologue below." : " — transcript on server.")
        : "LLM turn completed.";
      barStatus.className = "sub";
    } catch (e) {
      console.warn("[llm-step] network/exception", e);
      barStatus.textContent = "Run AI turn failed: " + e.message;
      barStatus.className = "sub spectate-error";
    } finally {
      if (llmStepBtn) llmStepBtn.disabled = false;
    }
  }

  async function startHandDeal() {
    const tid = currentTableId();
    const pw = sessionStorage.getItem(STORAGE_KEY);
    if (!tid || !pw) {
      showPasswordGate("");
      return;
    }
    if (startHandBtn) startHandBtn.disabled = true;
    barStatus.textContent = "Dealing…";
    barStatus.className = "sub";
    try {
      const url =
        location.origin + "/v1/tables/" + encodeURIComponent(tid) + "/start-hand";
      const res = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        credentials: "omit",
        body: JSON.stringify({ spectate_password: pw }),
      });
      const text = await res.text();
      let data;
      try {
        data = text ? JSON.parse(text) : null;
      } catch {
        data = null;
      }
      if (res.status === 401) {
        sessionStorage.removeItem(STORAGE_KEY);
        showPasswordGate((data && data.error && data.error.message) || "Spectate denied");
        return;
      }
      if (!res.ok) {
        const msg =
          (data && data.error && (data.error.message || data.error.code)) ||
          res.statusText ||
          "Deal failed";
        barStatus.textContent = "Deal failed: " + msg;
        barStatus.className = "sub spectate-error";
        return;
      }
      if (data && data.table) {
        renderAll(data.table);
      }
      barStatus.textContent =
        "Hand started — spectate view shows all players’ hole cards. Run llm_players to act.";
      barStatus.className = "sub";
    } catch (e) {
      barStatus.textContent = "Deal failed: " + e.message;
      barStatus.className = "sub spectate-error";
    } finally {
      if (startHandBtn) startHandBtn.disabled = false;
    }
  }

  async function manualRefresh() {
    const btn = spectateRefreshBtn;
    if (btn) btn.disabled = true;
    barStatus.textContent = "Refreshing…";
    barStatus.className = "sub";
    const tid = currentTableId();
    const pw = sessionStorage.getItem(STORAGE_KEY);
    try {
      if (!tid) {
        barStatus.textContent = "Set a table id.";
        return;
      }
      if (!pw) {
        showPasswordGate();
        return;
      }
      await loadSnapshot(tid, pw);
    } finally {
      if (btn) btn.disabled = false;
    }
  }

  function updateUrlTable() {
    const tid = currentTableId();
    const u = new URL(location.href);
    if (tid) u.searchParams.set("table", tid);
    else u.searchParams.delete("table");
    const qs = u.searchParams.toString();
    history.replaceState({}, "", u.pathname + (qs ? "?" + qs : "") + location.hash);
  }

  function showPasswordGate(msg) {
    stopPoll();
    passwordGate.classList.remove("hidden");
    spectateMain.classList.add("hidden");
    if (passwordGateErr) passwordGateErr.textContent = msg || "";
    barStatus.textContent = "Locked — enter password";
  }

  function showMain() {
    passwordGate.classList.add("hidden");
    spectateMain.classList.remove("hidden");
    if (passwordGateErr) passwordGateErr.textContent = "";
  }

  async function unlockWithPassword(pw) {
    const tid = currentTableId() || "llm_bots";
    if (tableIdInput && !tableIdInput.value.trim()) tableIdInput.value = tid;
    barStatus.textContent = "Verifying…";
    try {
      const data = await fetchSpectateState(tid, pw);
      sessionStorage.setItem(STORAGE_KEY, pw);
      renderAll(data);
      showMain();
      updateUrlTable();
      applyLiveMode();
    } catch (e) {
      sessionStorage.removeItem(STORAGE_KEY);
      if (passwordGateErr) {
        passwordGateErr.textContent =
          e.httpStatus === 401 ? "Wrong password or spectate denied." : e.message;
      }
      showPasswordGate("");
      barStatus.textContent = "Spectate locked";
    }
  }

  async function tryResume() {
    const pw = sessionStorage.getItem(STORAGE_KEY);
    if (!pw) {
      showPasswordGate("");
      return;
    }
    barStatus.textContent = "Resuming…";
    try {
      const tid = currentTableId() || "llm_bots";
      const data = await fetchSpectateState(tid, pw);
      renderAll(data);
      showMain();
      updateUrlTable();
      applyLiveMode();
    } catch (e) {
      sessionStorage.removeItem(STORAGE_KEY);
      showPasswordGate(e.message || "");
      barStatus.textContent = "Session expired — unlock again";
    }
  }

  function init() {
    if (passwordSubmit) {
      passwordSubmit.addEventListener("click", () => {
        const pw = (passwordInput && passwordInput.value) || "";
        if (!pw.trim()) {
          if (passwordGateErr) passwordGateErr.textContent = "Enter the spectate password.";
          return;
        }
        unlockWithPassword(pw.trim());
      });
    }
    if (passwordInput) {
      passwordInput.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter") passwordSubmit && passwordSubmit.click();
      });
    }
    if (tableIdInput) {
      tableIdInput.addEventListener("change", () => {
        updateUrlTable();
        const pw = sessionStorage.getItem(STORAGE_KEY);
        if (!pw) return;
        const tid = currentTableId();
        loadSnapshot(tid, pw).then(() => applyLiveMode());
      });
    }
    if (liveUpdatesCheckbox) {
      liveUpdatesCheckbox.addEventListener("change", () => {
        updateUrlTable();
        applyLiveMode();
      });
    }
    if (spectateRefreshBtn) {
      spectateRefreshBtn.addEventListener("click", () => {
        manualRefresh();
      });
    }
    if (startHandBtn) {
      startHandBtn.addEventListener("click", () => {
        startHandDeal();
      });
    }
    if (llmStepBtn) {
      llmStepBtn.addEventListener("click", () => {
        runLlmStep();
      });
    }
    if (logoutSpectateBtn) {
      logoutSpectateBtn.addEventListener("click", () => {
        sessionStorage.removeItem(STORAGE_KEY);
        showPasswordGate("");
        barStatus.textContent = "Locked";
      });
    }

    tryResume();
  }

  init();
})();
