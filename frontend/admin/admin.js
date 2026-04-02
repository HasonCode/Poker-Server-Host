(function () {
  "use strict";

  const $ = (sel, el) => (el || document).querySelector(sel);
  const $$ = (sel, el) => [...(el || document).querySelectorAll(sel)];

  const loginPanel   = $("#loginPanel");
  const dashboard    = $("#dashboard");
  const adminEmail   = $("#adminEmail");
  const logoutBtn    = $("#logoutBtn");
  const refreshBtn   = $("#refreshBtn");

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
  const resetChips   = $("#resetChips");
  const settingsErr  = $("#settingsErr");

  const botList      = $("#botList");
  const noBots       = $("#noBots");
  const adminBotName = $("#adminBotName");
  const adminBotChips= $("#adminBotChips");
  const adminBotFile = $("#adminBotFile");
  const adminBotStart= $("#adminBotStart");
  const botErr       = $("#botErr");

  let isLoggedIn = false;
  let selectedTable = null;
  let pollTimer = null;
  const POLL_INTERVAL = 3000;

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

  function startPoll() {
    stopPoll();
    pollTimer = setInterval(() => {
      if (isLoggedIn) loadTables();
    }, POLL_INTERVAL);
  }

  function showLogin() {
    isLoggedIn = false;
    stopPoll();
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
    } catch (e) {
      createErr.textContent = e.message;
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
      div.innerHTML =
        '<span class="table-entry-id">' + esc(t.table_id) + '</span>' +
        '<span class="sub">' + t.seated + '/' + t.max_seats + ' seats · ' +
        'SB/BB ' + t.sb_amount + '/' + t.bb_amount + ' · ' +
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

      renderPlayers(data.players || [], data.ai_players || {});
      renderBots(data.running_bots || []);
    } catch (e) {
      settingsErr.textContent = e.message;
    }
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
        zero_chips: $("#newZeroChips").value,
        rebuy_amount: parseInt($("#newRebuyAmt").value, 10) || 500,
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
      await apiFetch("POST", "/admin/api/tables/" + encodeURIComponent(selectedTable) + "/reset", {
        chips: parseInt(resetChips.value, 10) || 1000,
      });
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

  adminBotStart.addEventListener("click", async () => {
    if (!selectedTable) return;
    botErr.textContent = "";
    const file = adminBotFile.files[0];
    if (!file) { botErr.textContent = "Select a bot file first."; return; }
    const name = (adminBotName.value || "").trim() || file.name.replace(/\.\w+$/, "");
    const chips = parseInt(adminBotChips.value, 10) || 500;
    const code = await file.text();
    try {
      await apiFetch("POST", "/admin/api/bot/start", {
        table_id: selectedTable, player_id: name, chips, code, filename: file.name,
      });
      await loadTables();
    } catch (err) {
      botErr.textContent = err.message;
    }
  });

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

  checkSession();
})();
