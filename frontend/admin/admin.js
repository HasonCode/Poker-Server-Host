(function () {
  "use strict";

  const $ = (sel, el) => (el || document).querySelector(sel);
  const $$ = (sel, el) => [...(el || document).querySelectorAll(sel)];

  const loginPanel   = $("#loginPanel");
  const dashboard    = $("#dashboard");
  const adminEmail   = $("#adminEmail");
  const logoutBtn    = $("#logoutBtn");
  const refreshBtn   = $("#refreshBtn");

  const requestLogTbody = $("#requestLogTbody");
  const requestLogErr = $("#requestLogErr");
  const requestLogEmpty = $("#requestLogEmpty");
  const requestLogDownloadBtn = $("#requestLogDownloadBtn");

  const tablesList   = $("#tablesList");
  const createTableForm = $("#createTableForm");
  const createErr    = $("#createErr");

  const tablePanel   = $("#tablePanel");
  const selectedTableName = $("#selectedTableName");
  const deleteTableBtn = $("#deleteTableBtn");

  const statSeated   = $("#statSeated");
  const statMaxSeats = $("#statMaxSeats");
  const statChips    = $("#statChips");
  const statHand     = $("#statHand");
  const statStreet   = $("#statStreet");
  const statPot      = $("#statPot");

  const playersTbody = $("#playersTbody");
  const noPlayers    = $("#noPlayers");

  const settingsForm = $("#settingsForm");
  const setSB        = $("#setSB");
  const setBB        = $("#setBB");
  const resetBtn     = $("#resetBtn");
  const settingsErr  = $("#settingsErr");

  const botList      = $("#botList");
  const noBots       = $("#noBots");
  const botErr       = $("#botErr");

  let isLoggedIn = false;
  let selectedTable = null;
  let pollTimer = null;
  const POLL_INTERVAL = 3000;
  let spectateTimer = null;
  const SPECTATE_INTERVAL = 1500;
  const spectateEnabled = $("#spectateEnabled");
  const spectateErr = $("#spectateErr");
  const specCommunity = $("#specCommunity");
  const specSeats = $("#specSeats");
  const specLog = $("#specLog");
  const specStatus = $("#specStatus");
  const specStreet = $("#specStreet");
  const specPot = $("#specPot");
  const specActor = $("#specActor");
  const openTableSpectate = $("#openTableSpectate");
  const spectateOpenFeedback = $("#spectateOpenFeedback");

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s;
    return d.innerHTML;
  }

  async function apiFetch(method, path, body) {
    const opts = { method, headers: { Accept: "application/json" }, credentials: "same-origin" };
    if (body !== undefined) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    const res = await fetch(path, opts);
    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { data = null; }
    if (res.status === 401) {
      showLogin();
      throw new Error("Session expired. Please log in again.");
    }
    if (!res.ok) {
      throw new Error(data?.error?.message || res.statusText);
    }
    return data;
  }

  function stopPoll() {
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
  }

  function stopSpectatePoll() {
    if (spectateTimer) { clearInterval(spectateTimer); spectateTimer = null; }
  }

  function startSpectatePoll() {
    stopSpectatePoll();
    if (!spectateEnabled || !spectateEnabled.checked || !selectedTable) return;
    loadSpectateSnapshot();
    spectateTimer = setInterval(loadSpectateSnapshot, SPECTATE_INTERVAL);
  }

  function startPoll() {
    stopPoll();
    pollTimer = setInterval(() => {
      if (isLoggedIn) loadTables();
    }, POLL_INTERVAL);
  }

  function showLogin() {
    isLoggedIn = false;
    stopPoll();
    stopSpectatePoll();
    loginPanel.classList.remove("hidden");
    dashboard.classList.add("hidden");
    logoutBtn.classList.add("hidden");
    adminEmail.textContent = "Not logged in";
  }

  function showDashboard(email) {
    isLoggedIn = true;
    loginPanel.classList.add("hidden");
    dashboard.classList.remove("hidden");
    logoutBtn.classList.remove("hidden");
    adminEmail.textContent = email;
    startPoll();
  }

  async function checkSession() {
    try {
      const data = await apiFetch("GET", "/admin/api/session");
      if (data.ok && data.email) {
        showDashboard(data.email);
        await loadTables();
      } else {
        showLogin();
      }
    } catch {
      showLogin();
    }
  }

  /* ── Tables list ──────────────────────────────────── */

  async function loadTables() {
    try {
      const data = await apiFetch("GET", "/admin/api/tables");
      renderTablesList(data.tables || []);
      if (selectedTable) {
        await loadTableStats(selectedTable);
      }
      await loadRequestLog();
    } catch (e) {
      createErr.textContent = e.message;
    }
  }

  function renderRequestLog(entries) {
    if (requestLogErr) requestLogErr.textContent = "";
    if (!requestLogTbody) return;
    requestLogTbody.replaceChildren();
    const list = entries || [];
    if (requestLogEmpty) {
      requestLogEmpty.classList.toggle("hidden", list.length > 0);
    }
    list.forEach((row) => {
      const tr = document.createElement("tr");
      const path = String(row.path || "");
      const tdTs = document.createElement("td");
      tdTs.className = "mono";
      tdTs.textContent = row.timestamp || "—";
      const tdM = document.createElement("td");
      tdM.textContent = String(row.method || "");
      const tdP = document.createElement("td");
      tdP.className = "mono api-log-path";
      tdP.textContent = path;
      tdP.setAttribute("title", path);
      const tdTbl = document.createElement("td");
      tdTbl.className = "mono";
      tdTbl.textContent = row.table_id != null && row.table_id !== "" ? String(row.table_id) : "—";
      const tdPl = document.createElement("td");
      tdPl.className = "mono";
      tdPl.textContent = row.player_id != null && row.player_id !== "" ? String(row.player_id) : "—";
      const tdSt = document.createElement("td");
      tdSt.textContent = String(row.status ?? "");
      const tdMs = document.createElement("td");
      tdMs.className = "mono";
      tdMs.textContent = row.ms != null ? String(row.ms) : "—";
      const tdK = document.createElement("td");
      tdK.textContent = String(row.kind || "");
      tr.appendChild(tdTs);
      tr.appendChild(tdM);
      tr.appendChild(tdP);
      tr.appendChild(tdTbl);
      tr.appendChild(tdPl);
      tr.appendChild(tdSt);
      tr.appendChild(tdMs);
      tr.appendChild(tdK);
      requestLogTbody.appendChild(tr);
    });
  }

  async function loadRequestLog() {
    if (!isLoggedIn || !requestLogTbody) return;
    try {
      const data = await apiFetch("GET", "/admin/api/request-log");
      renderRequestLog(data.entries || []);
    } catch (e) {
      if (requestLogErr) requestLogErr.textContent = e.message;
    }
  }

  async function downloadRequestLogJson() {
    if (!isLoggedIn) return;
    if (requestLogErr) requestLogErr.textContent = "";
    try {
      const res = await fetch("/admin/api/request-log/download", { credentials: "same-origin" });
      if (res.status === 401) {
        showLogin();
        throw new Error("Session expired. Please log in again.");
      }
      if (!res.ok) {
        const text = await res.text();
        let msg = res.statusText;
        try {
          const j = JSON.parse(text);
          if (j.error && j.error.message) msg = j.error.message;
        } catch { /* ignore */ }
        throw new Error(msg);
      }
      const blob = await res.blob();
      let name = "poker-request-log.json";
      const disp = res.headers.get("Content-Disposition");
      if (disp) {
        const m = disp.match(/filename="([^"]+)"/i) || disp.match(/filename=([^;\s]+)/i);
        if (m) name = m[1].replace(/^["']|["']$/g, "");
      }
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = name;
      a.rel = "noopener";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch (e) {
      if (requestLogErr) requestLogErr.textContent = e.message;
    }
  }

  function renderTablesList(tables) {
    tablesList.replaceChildren();
    if (tables.length === 0) {
      tablesList.innerHTML = '<p class="sub">No tables. Create one below.</p>';
      tablePanel.classList.add("hidden");
      return;
    }
    tables.sort((a, b) => a.table_id.localeCompare(b.table_id));
    tables.forEach(t => {
      const div = document.createElement("div");
      div.className = "table-entry" + (selectedTable === t.table_id ? " selected" : "");
      const policyLabel = t.zero_chips === "eject" ? "eject" : "rebuy";
      const hiddenTag = t.hidden
        ? '<span class="pill pill-muted">hidden</span>'
        : "";
      div.innerHTML =
        '<span class="table-entry-left">' +
        '<span class="table-entry-id">' + esc(t.table_id) + '</span>' +
        hiddenTag +
        '</span>' +
        '<span class="sub">' + t.seated + '/' + t.max_seats + ' seats · ' +
        'SB/BB ' + t.sb_amount + '/' + t.bb_amount + ' · buy-in ' + (t.buy_in_chips ?? "—") +
        ' · act ' + (t.action_timeout_sec != null ? t.action_timeout_sec + "s" : "—") + ' · ' +
        policyLabel + ' · ' + t.running_bots + ' bots</span>';
      div.addEventListener("click", () => selectTable(t.table_id));
      tablesList.appendChild(div);
    });

    if (!selectedTable && tables.length > 0) {
      selectTable(tables[0].table_id);
    }
  }

  async function selectTable(tid) {
    selectedTable = tid;
    $$(".table-entry").forEach(el => {
      el.classList.toggle("selected", el.querySelector(".table-entry-id").textContent === tid);
    });
    selectedTableName.textContent = tid;
    tablePanel.classList.remove("hidden");
    await loadTableStats(tid);
    startSpectatePoll();
  }

  async function loadTableStats(tid) {
    try {
      const data = await apiFetch("GET", "/admin/api/stats?table_id=" + encodeURIComponent(tid));
      statSeated.textContent = data.seated || 0;
      statMaxSeats.textContent = data.max_seats || 10;
      statChips.textContent = data.total_chips || 0;
      statHand.textContent = data.hand_status || "idle";
      statStreet.textContent = data.street || "—";
      statPot.textContent = data.pot || 0;
      setSB.value = data.sb_amount || 2;
      setBB.value = data.bb_amount || 5;
      const setZeroChips = $("#setZeroChips");
      const setRebuyAmt = $("#setRebuyAmt");
      if (setZeroChips) setZeroChips.value = data.zero_chips || "rebuy";
      if (setRebuyAmt) setRebuyAmt.value = data.rebuy_amount || 500;
      const setBuyIn = $("#setBuyIn");
      const setActionTimeout = $("#setActionTimeout");
      const setActionTimeoutMode = $("#setActionTimeoutMode");
      if (setBuyIn) setBuyIn.value = data.buy_in_chips || 500;
      if (setActionTimeout) {
        setActionTimeout.value = data.action_timeout_sec != null ? data.action_timeout_sec : 60;
      }
      if (setActionTimeoutMode) {
        setActionTimeoutMode.value = data.action_timeout_mode || "eject";
      }

      renderPlayers(data.players || [], data.ai_players || {});
      renderBots(data.running_bots || []);
    } catch (e) {
      settingsErr.textContent = e.message;
    }
  }

  /* ── Spectate (full cards) ─────────────────────────── */

  function parseCard(str) {
    if (!str || str === "?") return null;
    const suit = str.slice(-1);
    const rank = str.slice(0, -1);
    return { rank, suit };
  }

  function isRed(suit) {
    return suit === "♥" || suit === "♦";
  }

  function makeSpecCard(str) {
    const el = document.createElement("span");
    const parsed = parseCard(str);
    if (!parsed) {
      el.className = "spec-card placeholder";
      el.textContent = "?";
      return el;
    }
    el.className = "spec-card" + (isRed(parsed.suit) ? " red" : "");
    const r = document.createElement("span");
    r.className = "spec-card-rank";
    r.textContent = parsed.rank;
    const s = document.createElement("span");
    s.className = "spec-card-suit";
    s.textContent = parsed.suit;
    el.appendChild(r);
    el.appendChild(s);
    return el;
  }

  function makeSpecFacedown() {
    const el = document.createElement("span");
    el.className = "spec-card facedown";
    el.textContent = "🂠";
    return el;
  }

  async function loadSpectateSnapshot() {
    if (!selectedTable || !spectateEnabled || !spectateEnabled.checked) return;
    spectateErr.textContent = "";
    try {
      const data = await apiFetch(
        "GET",
        "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/snapshot"
      );
      renderSpectate(data);
    } catch (e) {
      spectateErr.textContent = e.message;
    }
  }

  function renderSpectate(data) {
    const tbl = data.table || {};
    const hand = tbl.hand || {};
    const bustMap = data.bust_counts || {};
    const seats = tbl.seats || [];
    const max = tbl.max_seats || 10;
    const hc = hand.hole_cards || {};
    const folded = hand.folded || {};

    specStatus.textContent = hand.status || "idle";
    specStatus.className = "pill spec-pill " + (hand.status === "active" ? "active" : "idle");
    specStreet.textContent = hand.street || "—";
    specPot.textContent = hand.pot != null ? hand.pot : 0;

    const ats = hand.action_to_seat;
    if (hand.status === "active" && ats && seats[ats - 1] && typeof seats[ats - 1] === "object") {
      specActor.textContent = seats[ats - 1].player_id + " (seat " + ats + ")";
    } else {
      specActor.textContent = "—";
    }

    specCommunity.replaceChildren();
    const comm = hand.community || [];
    if (comm.length === 0 && hand.status === "active") {
      for (let i = 0; i < 5; i++) specCommunity.appendChild(makeSpecFacedown());
    } else if (comm.length === 0) {
      specCommunity.innerHTML = '<span class="sub">—</span>';
    } else {
      comm.forEach(c => specCommunity.appendChild(makeSpecCard(String(c))));
      for (let i = comm.length; i < 5; i++) specCommunity.appendChild(makeSpecFacedown());
    }

    specSeats.replaceChildren();
    for (let i = 1; i <= max; i++) {
      const cell = document.createElement("div");
      cell.className = "spec-seat";
      const s = seats[i - 1];
      const pid = s && s.player_id;
      if (!pid) {
        cell.innerHTML = '<span class="spec-seat-empty">Seat ' + i + "</span>";
        specSeats.appendChild(cell);
        continue;
      }
      const bustN = bustMap[pid] != null ? bustMap[pid] : 0;
      const isFolded = folded && folded[String(i)];
      if (ats === i && hand.status === "active") cell.classList.add("acting");
      if (isFolded) cell.classList.add("folded");

      const head = document.createElement("div");
      head.className = "spec-seat-head";
      head.innerHTML =
        "<span class='spec-seat-name'>" + esc(pid) + "</span>" +
        "<span class='mono spec-seat-stack'>" + s.stack + "</span>" +
        "<span class='spec-busts' title='Times reached 0 chips (end of hand)'>💥 " + (bustN || 0) + "</span>";

      const tags = [];
      if (hand.button_seat === i) tags.push("BTN");
      if (hand.sb_seat === i) tags.push("SB");
      if (hand.bb_seat === i) tags.push("BB");
      if (isFolded) tags.push("FOLD");

      const cardsRow = document.createElement("div");
      cardsRow.className = "spec-hole";
      const cards = hc[String(i)];
      if (cards && cards.length) {
        cards.forEach(c => cardsRow.appendChild(makeSpecCard(String(c))));
      } else if (hand.status === "active" && !isFolded) {
        cardsRow.appendChild(makeSpecFacedown());
        cardsRow.appendChild(makeSpecFacedown());
      }
      cell.appendChild(head);
      if (tags.length) {
        const tg = document.createElement("div");
        tg.className = "spec-tags";
        tg.textContent = tags.join(" · ");
        cell.appendChild(tg);
      }
      cell.appendChild(cardsRow);
      specSeats.appendChild(cell);
    }

    specLog.replaceChildren();
    const log = hand.action_log || [];
    if (log.length === 0) {
      const li = document.createElement("li");
      li.className = "sub";
      li.textContent = "No actions yet.";
      specLog.appendChild(li);
      return;
    }
    log.slice(-24).forEach(entry => {
      const li = document.createElement("li");
      const amt = entry.amount != null ? " " + entry.amount : "";
      li.innerHTML =
        "<b>" + esc(entry.player_id) + "</b> " + esc(entry.action) + amt +
        " <span class='sub'>[" + esc(entry.street || "") + "]</span>";
      specLog.appendChild(li);
    });
  }

  /* ── Create / Delete ──────────────────────────────── */

  createTableForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    createErr.textContent = "";
    const tid = $("#newTableId").value.trim();
    if (!tid) { createErr.textContent = "Table ID required."; return; }
    try {
      await apiFetch("POST", "/admin/api/tables", {
        table_id: tid,
        max_seats: parseInt($("#newMaxSeats").value, 10) || 10,
        sb_amount: parseInt($("#newSB").value, 10) || 2,
        bb_amount: parseInt($("#newBB").value, 10) || 5,
        with_ais: $("#newWithAIs").checked,
        hidden: $("#newHidden").checked,
        zero_chips: $("#newZeroChips").value,
        rebuy_amount: parseInt($("#newRebuyAmt").value, 10) || 500,
        buy_in_chips: parseInt($("#newBuyIn").value, 10) || 500,
        action_timeout_sec: (() => {
          const v = parseInt($("#newActionTimeout").value, 10);
          return Number.isFinite(v) ? v : 60;
        })(),
        action_timeout_mode: $("#newActionTimeoutMode").value,
      });
      selectedTable = tid;
      await loadTables();
    } catch (err) {
      createErr.textContent = err.message;
    }
  });

  deleteTableBtn.addEventListener("click", async () => {
    if (!selectedTable) return;
    if (!confirm("Delete table '" + selectedTable + "'? All players and bots will be removed.")) return;
    try {
      await apiFetch("POST", "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/delete");
      selectedTable = null;
      tablePanel.classList.add("hidden");
      await loadTables();
    } catch (err) {
      settingsErr.textContent = err.message;
    }
  });

  /* ── Players ──────────────────────────────────────── */

  function renderPlayers(players, aiMap) {
    playersTbody.replaceChildren();
    if (players.length === 0) {
      noPlayers.classList.remove("hidden");
      return;
    }
    noPlayers.classList.add("hidden");
    players.forEach(p => {
      const tr = document.createElement("tr");
      const isAI = aiMap && (typeof aiMap === "object")
        && (Array.isArray(aiMap) ? aiMap.includes(p.player_id) : aiMap[p.player_id]);
      tr.innerHTML =
        "<td>" + p.seat + "</td>" +
        "<td>" + esc(p.player_id) + "</td>" +
        "<td class='mono'>" + p.stack + "</td>" +
        "<td class='mono'>" + (p.busts != null ? p.busts : 0) + "</td>" +
        "<td>" + (isAI ? "Yes" : "") + "</td>" +
        "<td></td>";
      const kickBtn = document.createElement("button");
      kickBtn.className = "btn btn-danger btn-sm";
      kickBtn.textContent = "Kick";
      kickBtn.addEventListener("click", () => kickPlayer(p.player_id));
      tr.lastChild.appendChild(kickBtn);
      playersTbody.appendChild(tr);
    });
  }

  async function kickPlayer(playerId) {
    if (!selectedTable) return;
    settingsErr.textContent = "";
    try {
      await apiFetch("POST", "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/kick", { player_id: playerId });
      await loadTables();
    } catch (e) {
      settingsErr.textContent = "Kick failed: " + e.message;
    }
  }

  /* ── Settings / Reset ─────────────────────────────── */

  settingsForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!selectedTable) return;
    settingsErr.textContent = "";
    try {
      await apiFetch("POST", "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/settings", {
        sb_amount: parseInt(setSB.value, 10),
        bb_amount: parseInt(setBB.value, 10),
        zero_chips: $("#setZeroChips").value,
        rebuy_amount: parseInt($("#setRebuyAmt").value, 10) || 500,
        buy_in_chips: parseInt($("#setBuyIn").value, 10) || 500,
        action_timeout_sec: (() => {
          const v = parseInt($("#setActionTimeout").value, 10);
          return Number.isFinite(v) ? v : 60;
        })(),
        action_timeout_mode: $("#setActionTimeoutMode").value,
      });
      await loadTables();
    } catch (err) {
      settingsErr.textContent = err.message;
    }
  });

  resetBtn.addEventListener("click", async () => {
    if (!selectedTable) return;
    settingsErr.textContent = "";
    if (!confirm("Reset table '" + selectedTable + "'? This ends the hand and resets stacks.")) return;
    try {
      await apiFetch("POST", "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/reset", {});
      await loadTables();
    } catch (err) {
      settingsErr.textContent = err.message;
    }
  });

  /* ── Bots ─────────────────────────────────────────── */

  function renderBots(bots) {
    botList.replaceChildren();
    if (bots.length === 0) {
      noBots.classList.remove("hidden");
      return;
    }
    noBots.classList.add("hidden");
    bots.forEach(b => {
      const div = document.createElement("div");
      div.className = "bot-entry";
      const pill = document.createElement("span");
      pill.className = "pill";
      pill.textContent = b.lang;
      const label = document.createElement("span");
      label.textContent = b.player_id + " (pid " + b.pid + ")";
      const stopBtn = document.createElement("button");
      stopBtn.className = "btn btn-danger btn-sm";
      stopBtn.textContent = "Stop";
      stopBtn.addEventListener("click", () => stopBot(b.player_id));
      div.appendChild(pill);
      div.appendChild(label);
      div.appendChild(stopBtn);
      botList.appendChild(div);
    });
  }

  async function stopBot(playerId) {
    if (!selectedTable) return;
    botErr.textContent = "";
    try {
      await apiFetch("POST", "/admin/api/bot/stop", { table_id: selectedTable, player_id: playerId });
      await loadTables();
    } catch (err) {
      botErr.textContent = err.message;
    }
  }

  /* ── Global ───────────────────────────────────────── */

  logoutBtn.addEventListener("click", () => {
    window.location.href = "/admin/oauth/logout";
  });

  refreshBtn.addEventListener("click", () => {
    if (isLoggedIn) loadTables();
    else checkSession();
  });

  if (requestLogDownloadBtn) {
    requestLogDownloadBtn.addEventListener("click", () => downloadRequestLogJson());
  }

  if (spectateEnabled) {
    spectateEnabled.addEventListener("change", () => {
      if (spectateEnabled.checked) startSpectatePoll();
      else stopSpectatePoll();
    });
  }

  if (openTableSpectate) {
    openTableSpectate.addEventListener("click", () => {
      if (!selectedTable) {
        if (spectateOpenFeedback) {
          spectateOpenFeedback.classList.add("hidden");
          spectateOpenFeedback.textContent = "";
        }
        spectateErr.textContent = "Select a table in the list above first.";
        return;
      }
      spectateErr.textContent = "";
      if (spectateOpenFeedback) {
        spectateOpenFeedback.classList.remove("hidden");
        spectateOpenFeedback.textContent = "Opening…";
      }
      openTableSpectate.disabled = true;
      const path = "/admin/spectate.html?table=" + encodeURIComponent(selectedTable);
      const fullUrl = location.origin + path;
      /* Two-arg window.open avoids popup blockers treating this as a chrome-less popup. */
      const w = window.open(path, "_blank");
      window.setTimeout(() => {
        openTableSpectate.disabled = false;
      }, 800);
      if (!w) {
        if (spectateOpenFeedback) {
          spectateOpenFeedback.classList.add("hidden");
          spectateOpenFeedback.textContent = "";
        }
        spectateErr.replaceChildren();
        spectateErr.appendChild(document.createTextNode("Could not open a new tab (often blocked). Open this link: "));
        const a = document.createElement("a");
        a.href = fullUrl;
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.textContent = fullUrl;
        spectateErr.appendChild(a);
        return;
      }
      if (spectateOpenFeedback) {
        spectateOpenFeedback.textContent =
          "Spectate tab opened. If it fails, sign in at /admin in this browser, then reload.";
      }
      window.setTimeout(() => {
        if (spectateOpenFeedback) {
          spectateOpenFeedback.classList.add("hidden");
          spectateOpenFeedback.textContent = "";
        }
      }, 8000);
    });
  }

  checkSession();
})();
