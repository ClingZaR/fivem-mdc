/* ============================================================
   mdc - NUI logic (REDESIGN2)
   Talks to the client relay via fetch(https://mdc/<cb>).

   Server callbacks (role-gated server-side, by NAME only - NO citizen IDs):
     getDashboard {}                         -> { units:[{callsign, members:[name], unassigned?}] }
     searchPerson {name}                     -> { found,name,mugshot,phone,totals,outstanding[],history[],prints }
     searchVehicle {plate}                   -> { found,owner,model,plate,vin,phone }
     getPenalCode {}                         -> { charges, modifiers }
     placeCharges {name,items[{code,modifiers[]}]} -> { success, message }
     getBolos {}                             -> { items[] }
     createBolo {type,title,description,images[]} / cancelBolo {id}
     getWarrants {}                          -> { items:[{name,charges,months,fine}] }
   Client-only callbacks:
     screenshot-basic on toggle + every 60s, we downscale it here and hand it
   Messages: {action:'open', role:'leo'|'court'} {action:'close'}
   Roles: 'court' (judge/lawyer) is read-only - the Arrest Calculator and
   Units tabs, BOLO create form and every action button are hidden (CSS
   .role-court .leo-only). The server enforces the same role on
   every callback, so hiding here is presentation only.
   ============================================================ */
(function () {
  'use strict';

  const RESOURCE =
    (typeof GetParentResourceName === 'function') ? GetParentResourceName() : 'mdc';

  // ------------------------------------------------------------------
  // State
  // ------------------------------------------------------------------
  const state = {
    penal: { charges: [], modifiers: [] },
    chargeByCode: {},
    modByIdMap: {},
    cart: [],                 // [{code,title,class,months,fine,blockedModifiers,mods:[id]}]
    targets: [],              // [name] - one incident can cover several suspects (NO cids)
    personName: null,         // last person searched, offered to the calculator
    canDismiss: false,        // supervisor / justice: may dismiss a charge
    role: 'leo',              // 'leo' | 'court' (read-only)
    loadingPenal: false,
    loaded: { dashboard: false, bolos: false, warrants: false, weapons: false },
    lightbox: { images: [], index: 0 }    // images of the BOLO currently in the viewer
  };

  // ------------------------------------------------------------------
  // Icons (inner SVG paths) for JS-rendered empty states
  // ------------------------------------------------------------------
  const ICON = {
    units:  '<circle cx="9" cy="8" r="3.2"/><path d="M3 19c0-3.2 2.7-5.4 6-5.4"/><path d="M15 13.8c2.6.5 4.5 2.6 4.5 5.2"/><path d="M16 5.6a3 3 0 0 1 0 5.4"/>',
    eye:    '<path d="M2 12s3.5-6.5 10-6.5S22 12 22 12s-3.5 6.5-10 6.5S2 12 2 12z"/><circle cx="12" cy="12" r="2.8"/>',
    shield: '<path d="M12 3l7 3v5c0 4.5-3 7.8-7 9-4-1.2-7-4.5-7-9V6l7-3z"/><path d="M9.5 12l1.8 1.8L15 10"/>',
    file:   '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>',
    image:  '<rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="8.5" cy="9.5" r="1.6"/><path d="M5 17l4.5-4.5 3 3L16 11l3 3"/>'
  };

  // ------------------------------------------------------------------
  // DOM helpers
  // ------------------------------------------------------------------
  const $  = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const app = $('#app');

  const escapeHtml = (s) =>
    String(s == null ? '' : s).replace(/[&<>"']/g, (c) =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  const money = (n) => '$' + (Number(n) || 0).toLocaleString('en-US');

  const fmtDate = (s) => (!s ? '-' : String(s).replace('T', ' ').slice(0, 16));

  function emptyHTML(iconInner, title, sub) {
    return `<div class="empty-state">` +
      `<svg class="ic empty-ic" viewBox="0 0 24 24" width="40" height="40">${iconInner}</svg>` +
      `<p class="empty-title">${escapeHtml(title)}</p>` +
      (sub ? `<p class="empty-sub">${escapeHtml(sub)}</p>` : '') +
      `</div>`;
  }

  function spinnerHTML(label) {
    return `<div class="loading-box"><div class="spinner"></div><span>${escapeHtml(label || 'Loading...')}</span></div>`;
  }

  // shows a spinner into el only if work takes > 300ms (no flicker on fast calls)
  function delayedSpinner(el, label) {
    let done = false;
    const t = setTimeout(() => { if (!done && el) el.innerHTML = spinnerHTML(label); }, 300);
    return () => { done = true; clearTimeout(t); };
  }

  // class normaliser -> { key, label }
  function classMeta(cls) {
    const c = String(cls || '').toLowerCase();
    if (c.indexOf('fel') >= 0) return { key: 'felony', label: 'Felony' };
    if (c.indexOf('mis') >= 0) return { key: 'misdemeanor', label: 'Misd.' };
    if (c.indexOf('cit') >= 0) return { key: 'citation', label: 'Citation' };
    if (!c) return { key: 'other', label: '-' };
    return { key: 'other', label: cls.charAt(0).toUpperCase() + cls.slice(1) };
  }

  // base64 / url / data-uri -> usable <img> src
  function mugSrc(s) {
    if (!s) return '';
    const v = String(s);
    if (v.startsWith('data:') || v.startsWith('http')) return v;
    return 'data:image/png;base64,' + v;
  }

  // comma-joined modifier ids -> readable labels (falls back to raw)
  function modLabels(str) {
    if (!str) return '';
    return String(str).split(',').map((id) => {
      const m = state.modByIdMap[id.trim()];
      return m ? (m.label || id) : id;
    }).filter(Boolean).join(', ');
  }

  // ------------------------------------------------------------------
  // NUI fetch wrapper
  // ------------------------------------------------------------------
  async function nui(name, data = {}) {
    try {
      const res = await fetch(`https://${RESOURCE}/${name}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(data)
      });
      if (!res.ok) return null;
      const txt = await res.text();
      if (!txt) return null;
      try { return JSON.parse(txt); } catch (_) { return txt; }
    } catch (err) {
      console.error('[mdc] nui error:', name, err);
      return null;
    }
  }

  function setBusy(sel, busy) {
    const el = $(sel);
    if (!el) return;
    el.classList.toggle('is-busy', !!busy);
    el.disabled = !!busy;
  }

  // ------------------------------------------------------------------
  // Toast
  // ------------------------------------------------------------------
  let toastTimer;
  function toast(msg, type = 'ok') {
    const t = $('#toast');
    t.textContent = msg;
    t.className = 'toast show ' + type;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = 'toast'; }, 3800);
  }

  // ------------------------------------------------------------------
  // Open / close
  // ------------------------------------------------------------------
  function openMdc(plate, role, boloExpiry, sections, boloText) {
    if (boloText) boloTextCfg = boloText;
    buildExpirySelect(boloExpiry);
    applySections(sections);
    const newRole = (role === 'court') ? 'court' : 'leo';
    if (state.role !== newRole) {
      // role changed since last open (job change) -> stale caches must reload
      state.loaded = { dashboard: false, bolos: false, warrants: false, weapons: false };
    }
    state.role = newRole;
    app.classList.toggle('role-court', newRole === 'court');
    app.classList.remove('hidden');
    {
      loadPenalCode();          // static; needed by calculator + modifier labels
      if (newRole === 'court') {
        showTab('person');      // court landing tab (Units is LEO-only)
      } else {
        // leo keeps its last tab across opens
        loadDashboard(true);
      }
    }
    if (plate) {                // radar HUD: jump to the vehicle tab + run the plate
      showTab('vehicle');
      const pi = document.querySelector('#vehicle-plate');
      if (pi) { pi.value = plate; }
      searchVehicle();
    }
  }
  function hideMdc() {
    app.classList.add('hidden');
  }
  function closeMdc() {
    hideMdc();
    nui('closeMdc', {});
  }

  window.addEventListener('message', (e) => {
    const d = e.data || {};
    if (d.action === 'open') openMdc(d.plate, d.role, d.boloExpiry, d.sections, d.boloText);
    else if (d.action === 'close') hideMdc();
    else if (d.action === 'downscaleMugshot') {   // raw booking photo -> resize -> return small
      downscaleMugshot(d.src);
    }
  });

  // Resize a raw screenshot data URI down to a small image and hand it back to
  // the client via the named NUI callback (which sends it to the server). Runs
  // entirely in our own NUI, so it never depends on screenshot-basic's page
  // being patched. Used by booking mugshots.
  function downscaleImage(src, cbName, maxW, quality) {
    const done = (small) => nui(cbName, { src: small || '' });
    if (!src) { done(''); return; }
    const im = new Image();
    im.onload = () => {
      try {
        const w = maxW || 512;
        const scale = Math.min(1, w / (im.width || w));
        const c = document.createElement('canvas');
        c.width = Math.max(1, Math.round((im.width || w) * scale));
        c.height = Math.max(1, Math.round((im.height || w) * scale));
        c.getContext('2d').drawImage(im, 0, 0, c.width, c.height);
        done(c.toDataURL('image/jpeg', quality || 0.82));
      } catch (e) { done(''); }
    };
    im.onerror = () => done('');
    im.src = src;
  }
  function downscaleMugshot(src) { downscaleImage(src, 'mugProcessed', 512, 0.82); }

  document.addEventListener('keydown', (e) => {
    if (app.classList.contains('hidden')) return;
    // F11 toggles the MDC shut from inside (the game keymapping cannot fire while the NUI is focused).
    if (e.key === 'F11') {
      e.preventDefault();
      closeMdc();
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      // The lightbox owns Esc first so it closes the image, not the MDC.
      if (isLightboxOpen()) { closeLightbox(); return; }
      // Esc closes the MDC. Cam-mode has no NUI focus, so this only fires with
      closeMdc();
    }
  });

  // click the area OUTSIDE the panel closes the MDC. (Cam-mode has no cursor, so
  // this only fires with the panel up.)
  app.addEventListener('mousedown', (e) => {
    if (e.target !== app) return;
    closeMdc();
  });

  // ------------------------------------------------------------------
  // Tabs
  // ------------------------------------------------------------------
  // Tabs the court role can never land on (their rail buttons are hidden by
  // CSS; this guard also covers programmatic showTab calls).
  // Sections disabled in config.lua are hidden outright - rail button and panel
  // both - and showTab refuses to route to them. The server still gates every
  // callback, so this is presentation, not the security boundary.
  const disabledSections = {};

  function applySections(sections) {
    if (!sections || typeof sections !== 'object') return;
    Object.keys(disabledSections).forEach((k) => delete disabledSections[k]);

    Object.entries(sections).forEach(([tab, on]) => {
      const enabled = on !== false;
      if (!enabled) disabledSections[tab] = true;
      $$(`.rail-btn[data-tab="${tab}"]`).forEach((b) => b.classList.toggle('hidden', !enabled));
      $$(`.tab-panel[data-tab="${tab}"]`).forEach((p) => p.classList.toggle('section-off', !enabled));
    });

    // If the tab we are sitting on just got switched off, move somewhere real.
    const active = $('.tab-panel.active');
    if (active && disabledSections[active.dataset.tab]) {
      const first = $$('.rail-btn').find((b) => !b.classList.contains('hidden'));
      showTab(first ? first.dataset.tab : 'person');
    }
  }

  const COURT_BLOCKED_TABS = {
    dashboard: true, calculator: true,
    weaponlist: true, weaponsearch: true,
  };

  function showTab(tab) {
    if (disabledSections[tab]) {                     // section switched off in config
      const first = $$('.rail-btn').find((b) => !b.classList.contains('hidden'));
      tab = first ? first.dataset.tab : 'person';
    }
    if (state.role === 'court' && COURT_BLOCKED_TABS[tab]) tab = 'person';
    $$('.rail-btn').forEach((b) => b.classList.toggle('active', b.dataset.tab === tab));
    $$('.tab-panel').forEach((p) => p.classList.toggle('active', p.dataset.tab === tab));

    if (tab === 'dashboard' && !state.loaded.dashboard) loadDashboard();
    else if (tab === 'calculator') loadPenalCode();
    else if (tab === 'bolos' && !state.loaded.bolos) loadBolos();
    else if (tab === 'warrants') loadWarrants();   // auto-refresh every open
    else if (tab === 'weaponlist' && !state.loaded.weapons) loadWeaponList();
  }

  // ------------------------------------------------------------------
  // Dashboard - Active Units
  // ------------------------------------------------------------------
  async function loadDashboard(silent) {
    const list = $('#dash-list');
    const stop = delayedSpinner(list, 'Loading units...');
    const data = await nui('getDashboard', {});
    stop();
    state.loaded.dashboard = true;
    const units = (data && Array.isArray(data.units)) ? data.units : [];
    if (!units.length) {
      list.innerHTML = emptyHTML(ICON.units, 'No units on duty', 'No LEO officers are currently clocked in.');
      return;
    }
    const frag = document.createDocumentFragment();
    units.forEach((u) => {
      const row = document.createElement('div');
      row.className = 'list-row';
      const members = Array.isArray(u.members) ? u.members : [];
      // The callsign chip on the left already names the unit, so repeating it
      // as "Unit 3-U-16" above the officer was saying the same thing twice.
      // Officers sit directly beside the chip at one size.
      const membersHtml = members.length ? members.map(escapeHtml).join(', ') : 'No members';
      const count = members.length + (members.length === 1 ? ' officer' : ' officers');
      row.innerHTML =
        `<span class="callsign">${escapeHtml(u.unassigned ? '-' : (u.callsign || '-'))}</span>` +
        `<div class="list-main">` +
          `<span class="unit-officers${members.length ? '' : ' dim'}">${membersHtml}</span>` +
        `</div>` +
        `<span class="pill green"><span class="duty-dot"></span>${count}</span>`;
      frag.appendChild(row);
    });
    list.innerHTML = '';
    list.appendChild(frag);
    if (!silent) { /* no-op: refresh handled by caller */ }
  }

  // ------------------------------------------------------------------
  // Penal code
  // ------------------------------------------------------------------
  async function loadPenalCode() {
    if (state.loadingPenal || state.penal.charges.length) return;
    state.loadingPenal = true;
    const data = await nui('getPenalCode', {});
    state.loadingPenal = false;
    if (data && Array.isArray(data.charges)) {
      state.penal.charges = data.charges;
      state.penal.modifiers = Array.isArray(data.modifiers) ? data.modifiers : [];
      indexPenal();
    }
    renderAvailable();
  }

  function indexPenal() {
    state.chargeByCode = {};
    state.modByIdMap = {};
    state.penal.charges.forEach((c) => { if (c.code) state.chargeByCode[c.code] = c; });
    state.penal.modifiers.forEach((m) => { if (m.id) state.modByIdMap[m.id] = m; });
  }

  // ------------------------------------------------------------------
  // Vehicle search
  // ------------------------------------------------------------------
  async function searchVehicle() {
    const plate = $('#vehicle-plate').value.trim();
    if (!plate) { toast('Enter a plate to search.', 'warn'); return; }
    $('#veh-empty').classList.add('hidden');
    $('#veh-results').classList.add('hidden');
    setBusy('#veh-search-btn', true);
    const stop = searchLoading($('#veh-body'));
    const data = await nui('searchVehicle', { plate });
    stop();
    setBusy('#veh-search-btn', false);
    renderVehicle(data);
  }

  function renderVehicle(data) {
    const empty = $('#veh-empty');
    const results = $('#veh-results');
    if (!data || !data.found) {
      results.classList.add('hidden');
      empty.classList.remove('hidden');
      empty.innerHTML = data
        ? emptyHTML(ICON.image, 'No vehicle found', 'No registration matches that plate.')
        : emptyHTML(ICON.image, 'Search unavailable', 'Are you on duty as an officer?');
      return;
    }
    empty.classList.add('hidden');
    results.classList.remove('hidden');
    vehCurrent = data;
    state.canDismiss = !!data.canDismiss;

    const records = Number(data.plateRecords) || 0;
    $('#veh-owner').textContent = data.owner || '-';
    $('#veh-model').textContent = vehicleLabel(data.model);
    $('#veh-plate').textContent = data.plate || '-';
    // Plate provenance folded into one field: current plate and how many
    // plates this VIN has carried. 0 means it has never been re-plated.
    $('#veh-plate-rec').textContent = `${data.plate || '-'} (${records})`;
    $('#veh-vin').textContent = data.vin || '-';
    $('#veh-phone').textContent = data.phone || '-';

    const t = data.totals || {};
    $('#veh-tot-charges').textContent       = t.charges || 0;
    $('#veh-tot-citations').textContent     = t.citations || 0;
    $('#veh-tot-imprisonments').textContent = t.imprisonments || 0;

    renderVehicleRecord();
  }

  // Owner's record under a plate. Outstanding charges and each class are
  // independently toggleable, so the same table serves "what are they wanted
  // for right now" and the full rap sheet.
  const VEH_FILTER = { outstanding: true, felony: true, misdemeanor: true, citation: true };

  function renderVehicleRecord() {
    const body = $('#veh-rec-body');
    if (!body || !vehCurrent) return;

    const rows = [];
    if (VEH_FILTER.outstanding) {
      (vehCurrent.outstanding || []).forEach((c) => rows.push({ ...c, outstanding: true }));
    }
    (vehCurrent.history || []).forEach((h) => rows.push({ ...h, outstanding: false }));

    const shown = rows.filter((r) => VEH_FILTER[r.class] !== false);
    $('#veh-rec-count').textContent = String(shown.length);

    if (!shown.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="5">No charges on record</td></tr>`;
      return;
    }

    const frag = document.createDocumentFragment();
    shown.forEach((r) => {
      let plea;
      if (r.outstanding)     plea = 'Pending';
      else if (r.dismissed)  plea = 'Dismissed by ' + (r.dismissedBy || 'unknown');
      else                   plea = pleaLabel(r.plea);

      const tr = document.createElement('tr');
      if (r.outstanding) tr.className = 'row-outstanding';
      tr.innerHTML =
        `<td class="mono">${escapeHtml(r.date || '-')}</td>` +
        `<td><span class="badge ${escapeHtml(r.class || '')}">${escapeHtml(r.code || '')}</span> ${escapeHtml(r.title || '')}</td>` +
        `<td>${escapeHtml(r.officer || '-')}</td>` +
        `<td>${escapeHtml(plea)}</td>` +
        `<td class="act-col">` +
          (r.outstanding && state.canDismiss && r.id
            ? `<button class="btn-ghost small danger dismiss-btn" title="Dismiss this charge">Dismiss</button>`
            : '') +
        `</td>`;

      const btn = tr.querySelector('.dismiss-btn');
      if (btn) btn.addEventListener('click', () => dismissCharge(r, btn));
      frag.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(frag);
  }

  function pleaLabel(p) {
    if (p === 'guilty') return 'Guilty';
    if (p === 'not_guilty') return 'Not guilty';
    if (p === 'pending') return 'Pending';
    return 'N/A';
  }

  // GTA model names are database rows, not something to show an officer.
  // Config-free: title-case the model and let servers add exceptions here.
  const VEHICLE_NAMES = {
    sultan: 'Karin Sultan', coquette: 'Invetero Coquette', coquette4: 'Coquette D5',
    police: 'Police Cruiser', police2: 'Police Cruiser', police3: 'Police Interceptor',
    sheriff: 'Sheriff Cruiser', sheriff2: 'Sheriff SUV', fbi: 'Unmarked Cruiser',
    ambulance: 'Ambulance', firetruk: 'Fire Truck',
  };

  function vehicleLabel(model) {
    const key = String(model || '').toLowerCase();
    if (!key) return '-';
    if (VEHICLE_NAMES[key]) return VEHICLE_NAMES[key];
    return key.charAt(0).toUpperCase() + key.slice(1);
  }

  // Clipboard inside CEF: the async API is often unavailable, so fall back to a
  // hidden textarea + execCommand, which still works in the NUI.
  function copyText(text, what) {
    const done = () => toast((what || 'Text') + ' copied.', 'ok');
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(() => legacyCopy(text, done));
        return;
      }
    } catch (e) { /* fall through */ }
    legacyCopy(text, done);
  }

  function legacyCopy(text, done) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;left:-9999px;top:0;';
    document.body.appendChild(ta);
    ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    ok ? done() : toast('Could not copy to clipboard.', 'err');
  }

  // Print Info goes to CHAT, so the whole channel sees the record rather than it
  // landing silently on one officer's clipboard.
  function vehicleInfoLines() {
    if (!vehCurrent) return [];
    const d = vehCurrent, t = d.totals || {};
    return [
      ['Owner', d.owner || '-'],
      ['Vehicle', vehicleLabel(d.model)],
      ['Plate', d.plate || '-'],
      ['Plate record', (d.plate || '-') + ' (' + (Number(d.plateRecords) || 0) + ')'],
      ['VIN', d.vin || '-'],
      ['Phone', d.phone || '-'],
      ['Charges', String(t.charges || 0)],
      ['Citations', String(t.citations || 0)],
      ['Imprisonments', String(t.imprisonments || 0)],
    ];
  }

  // BOLO line, built from the template in config.lua so a server can change the
  // wording without touching this file. Tokens: {time} {date} {detail} {model}
  // {plate} {owner} {vin} {phone} {charges} {extra}
  function vehicleBoloText() {
    if (!vehCurrent) return '';
    const d = vehCurrent;
    const cfg = boloTextCfg;
    const now = new Date();
    const p2 = (n) => String(n).padStart(2, '0');
    const MON = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];

    const tokens = {
      time:    `${p2(now.getHours())}:${p2(now.getMinutes())} ${now.getHours() < 12 ? 'AM' : 'PM'}`,
      date:    `${p2(now.getDate())}/${MON[now.getMonth()]}`,
      detail:  cfg.detail,
      model:   vehicleLabel(d.model),
      plate:   d.plate || 'UNKNOWN',
      owner:   d.owner || 'UNKNOWN',
      vin:     d.vin || 'UNKNOWN',
      phone:   d.phone || 'UNKNOWN',
      charges: String((d.outstanding || []).length),
      extra:   cfg.extra,
    };

    return String(cfg.template).replace(/\{(\w+)\}/g, (m, k) =>
      Object.prototype.hasOwnProperty.call(tokens, k) ? tokens[k] : m);
  }

  // ------------------------------------------------------------------
  // Person search
  // ------------------------------------------------------------------
  async function searchPerson() {
    const name = $('#person-name').value.trim();
    if (!name) { toast('Enter a name to search.', 'warn'); return; }
    $('#per-empty').classList.add('hidden');
    $('#per-results').classList.add('hidden');
    setBusy('#per-search-btn', true);
    const stop = searchLoading($('#per-body'));
    const data = await nui('searchPerson', { name });
    stop();
    setBusy('#per-search-btn', false);
    renderPerson(data);
  }

  function renderPerson(data) {
    const empty = $('#per-empty');
    const results = $('#per-results');
    if (!data || !data.found) {
      results.classList.add('hidden');
      empty.classList.remove('hidden');
      empty.innerHTML = data
        ? emptyHTML(ICON.units, 'No citizen found', 'No record matches that name.')
        : emptyHTML(ICON.units, 'Search unavailable', 'Are you on duty as an officer?');
      return;
    }
    empty.classList.add('hidden');
    results.classList.remove('hidden');

    $('#per-name').textContent = data.name || '-';
    $('#per-phone').textContent = data.phone || '-';

    // Fingerprints on file? Boolean only (no cid is ever sent); green = on file, red = not.
    const prints = $('#per-prints');
    if (prints) {
      if (data.prints) { prints.textContent = 'On File'; prints.className = 'prints-yes'; }
      else { prints.textContent = 'Not on File'; prints.className = 'prints-no'; }
    }

    // mugshot (reserved box; downscaled small at capture so it returns inline)
    const img = $('#per-mug');
    const ph = $('#per-mug-ph');
    const phText = ph.querySelector('span');
    const src = mugSrc(data.mugshot);
    if (src) {
      img.onerror = () => {
        img.classList.add('hidden'); ph.classList.remove('hidden');
        if (phText) phText.textContent = 'No photo on record';
      };
      img.src = src;
      img.classList.remove('hidden');
      ph.classList.add('hidden');
    } else {
      img.removeAttribute('src');
      img.classList.add('hidden');
      ph.classList.remove('hidden');
      if (phText) phText.textContent = 'No photo on record';
    }

    const t = data.totals || {};
    $('#per-total-charges').textContent = t.charges || 0;
    $('#per-total-citations').textContent = t.citations || 0;
    $('#per-total-imprisonments').textContent = t.imprisonments || 0;

    renderOutstanding(Array.isArray(data.outstanding) ? data.outstanding : []);
    renderHistory(Array.isArray(data.history) ? data.history : []);

    // carry the NAME as the arrest target (NO cid anywhere)
    state.canDismiss = !!data.canDismiss;
    setHistoryVisible(false);   // every new record starts collapsed

    state.personName = data.name;   // offered to the calculator by the button below
  }

  // Record History is collapsed by default on every new search: outstanding
  // charges are what an officer needs at a glance, prior record is opt-in.
  function setHistoryVisible(show) {
    const wrap = $('#per-history-wrap');
    const btn = $('#per-history-toggle');
    if (!wrap || !btn) return;
    wrap.classList.toggle('hidden', !show);
    btn.setAttribute('aria-expanded', show ? 'true' : 'false');
    btn.classList.toggle('open', show);
    const label = $('#per-history-toggle-label');
    if (label) label.textContent = show ? 'Hide history' : 'Show history';
  }

  function renderOutstanding(rows) {
    const body = $('#per-outstanding-body');
    $('#per-out-count').textContent = String(rows.length);
    if (!rows.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="7">No outstanding charges.</td></tr>`;
      return;
    }
    const frag = document.createDocumentFragment();
    rows.forEach((r) => {
      const cm = classMeta(r.class);
      const mods = modLabels(r.modifiers);
      const tr = document.createElement('tr');
      tr.innerHTML =
        `<td class="mono">${escapeHtml(r.code || '-')}</td>` +
        `<td>${escapeHtml(r.title || '-')}</td>` +
        `<td><span class="badge ${cm.key}">${escapeHtml(cm.label)}</span></td>` +
        `<td class="num mono">${Number(r.months) || 0}</td>` +
        `<td class="num mono">${money(r.fine)}</td>` +
        `<td class="mods-cell">${mods ? escapeHtml(mods) : '-'}</td>` +
        `<td class="act-col">` +
          (state.canDismiss && r.id
            ? `<button class="btn-ghost small danger dismiss-btn" title="Dismiss this charge">Dismiss</button>`
            : '') +
        `</td>`;

      const btn = tr.querySelector('.dismiss-btn');
      if (btn) btn.addEventListener('click', () => dismissCharge(r, btn));
      frag.appendChild(tr);
    });
    body.innerHTML = '';
    body.appendChild(frag);
  }

  // Dismissing clears the charge from outstanding but keeps it on the record,
  // stamped with who did it. It cannot be undone from the UI, so the button
  // arms itself first: one click to arm, a second within four seconds to
  // commit. An inline confirm rather than window.confirm, which CEF handles
  // badly and which blocks the render thread.
  async function dismissCharge(charge, btn) {
    if (btn.dataset.armed !== '1') {
      btn.dataset.armed = '1';
      btn.classList.add('armed');
      btn.textContent = 'Confirm?';
      btn.title = 'Click again to dismiss. Reverts in a few seconds.';
      clearTimeout(btn._disarm);
      btn._disarm = setTimeout(() => {
        btn.dataset.armed = '0';
        btn.classList.remove('armed');
        btn.textContent = 'Dismiss';
        btn.title = 'Dismiss this charge';
      }, 4000);
      return;
    }

    clearTimeout(btn._disarm);
    btn.disabled = true;
    btn.textContent = 'Dismissing...';
    const res = await nui('dismissCharge', { id: charge.id });

    if (res && res.success) {
      toast(res.message || 'Charge dismissed.', 'ok');
      refreshCurrentRecord();
    } else {
      btn.disabled = false;
      btn.dataset.armed = '0';
      btn.classList.remove('armed');
      btn.textContent = 'Dismiss';
      toast((res && res.message) || 'Could not dismiss that charge.', 'err');
    }
  }

  // Re-run whichever lookup is on screen so the row moves from outstanding
  // into history without the user searching again.
  function refreshCurrentRecord() {
    const active = $('.tab-panel.active');
    const tab = active && active.dataset.tab;
    if (tab === 'vehicle' && vehCurrent) searchVehicle();
    else if (state.personName) searchPerson();
    state.loaded.warrants = false;   // a dismissal can clear a warrant
  }

  // Record History (rap sheet): PAST processed charges/citations, most-recent
  // first. Mirrors renderOutstanding; reuses classMeta + the .plea-badge mapping.
  // The plea per charge comes from its imprisonment case (N/A for citations).
  // NO citizen ids - name-only, like the rest of the tab.
  // Record History class filter (sticky across person searches).
  const HIST_FILTER = { felony: true, misdemeanor: true, citation: true };
  function histShown(key) { return (key in HIST_FILTER) ? HIST_FILTER[key] : true; } // 'other' always shown

  function applyHistoryFilter() {
    const body = $('#per-history-body');
    if (!body) return;
    const rows = body.querySelectorAll('tr.hist-row');
    let shown = 0;
    rows.forEach((tr) => {
      const on = histShown(tr.dataset.cls || 'other');
      tr.classList.toggle('hidden', !on);
      if (on) shown++;
    });
    const emptyTr = body.querySelector('.hist-empty');
    if (emptyTr) emptyTr.classList.toggle('hidden', shown > 0 || rows.length === 0);
    $('#per-history-count').textContent = rows.length ? (shown + ' / ' + rows.length) : '0';
  }

  function renderHistory(rows) {
    const body = $('#per-history-body');
    if (!rows.length) {
      body.innerHTML = `<tr class="empty-row"><td colspan="4">No record history.</td></tr>`;
      $('#per-history-count').textContent = '0';
      return;
    }
    const frag = document.createDocumentFragment();
    rows.forEach((r) => {
      const cm = classMeta(r.class);

      // plea: 'na' on citations (no plea applies) -> muted N/A; otherwise the plea-badge.
      const plea = String(r.plea || 'pending').toLowerCase();
      let pleaCell;
      if (r.dismissed) {
        pleaCell = `<span class="plea-badge dismissed" title="Dismissed by ${escapeHtml(r.dismissedBy || 'unknown')}">` +
                   `DISMISSED by ${escapeHtml(r.dismissedBy || 'UNKNOWN')}</span>`;
      } else if (plea === 'na') {
        pleaCell = `<span class="dim">N/A</span>`;
      } else {
        const pleaMeta = ({
          guilty:     { key: 'guilty',     label: 'Guilty' },
          not_guilty: { key: 'not_guilty', label: 'Not Guilty' },
          pending:    { key: 'pending',    label: 'Pending' }
        })[plea] || { key: 'pending', label: 'Pending' };
        pleaCell = `<span class="plea-badge ${pleaMeta.key}">${escapeHtml(pleaMeta.label.toUpperCase())}</span>`;
      }

      const tr = document.createElement('tr');
      tr.className = 'hist-row';
      tr.dataset.cls = cm.key;
      tr.innerHTML =
        `<td class="mono">${escapeHtml(r.code || '-')}</td>` +
        `<td>${escapeHtml(r.title || '-')}</td>` +
        `<td><span class="badge ${cm.key}">${escapeHtml(cm.label)}</span></td>` +
        `<td>${pleaCell}</td>`;
      frag.appendChild(tr);
    });
    const emptyTr = document.createElement('tr');
    emptyTr.className = 'empty-row hist-empty hidden';
    emptyTr.innerHTML = `<td colspan="4">No records match the selected filters.</td>`;
    frag.appendChild(emptyTr);
    body.innerHTML = '';
    body.appendChild(frag);
    applyHistoryFilter();
  }

  // search loading overlay (appended to a panel-body)
  function searchLoading(bodyEl) {
    let done = false, node = null;
    const t = setTimeout(() => {
      if (done || !bodyEl) return;
      node = document.createElement('div');
      node.className = 'loading-box';
      node.innerHTML = '<div class="spinner"></div><span>Searching...</span>';
      bodyEl.appendChild(node);
    }, 300);
    return () => { done = true; clearTimeout(t); if (node) node.remove(); };
  }

  // ------------------------------------------------------------------
  // Arrest calculator - available list
  // ------------------------------------------------------------------
  function renderAvailable() {
    const list = $('#available-list');
    if (!list) return;
    const q = $('#charge-search').value.trim().toLowerCase();

    if (!state.penal.charges.length) {
      list.innerHTML = `<div class="empty pad">${state.loadingPenal ? 'Loading penal code...' : 'Penal code unavailable.'}</div>`;
      $('#available-count').textContent = '0';
      return;
    }

    const charges = state.penal.charges.filter((c) =>
      !q || (`${c.code} ${c.title} ${c.category || ''} ${c.description || ''}`).toLowerCase().includes(q));

    $('#available-count').textContent = String(charges.length);

    if (!charges.length) {
      list.innerHTML = `<div class="empty pad">No charges match "${escapeHtml(q)}".</div>`;
      return;
    }

    const inCart = new Set(state.cart.map((c) => c.code));
    const frag = document.createDocumentFragment();

    charges.forEach((c) => {
      const added = inCart.has(c.code);
      const cm = classMeta(c.class);
      const row = document.createElement('div');
      row.className = 'charge-row';
      row.innerHTML =
        `<div class="charge-row-main">` +
          `<span class="code">${escapeHtml(c.code)}</span>` +
          `<span class="charge-row-title">${escapeHtml(c.title)}</span>` +
          `<span class="badge ${cm.key}">${escapeHtml(cm.label)}</span>` +
        `</div>` +
        `<div class="charge-row-meta">` +
          `<span class="meta-pill">${Number(c.months) || 0} min</span>` +
          `<span class="meta-pill">${money(c.fine)}</span>` +
          `<button class="btn-ghost desc-toggle">Details</button>` +
          `<button class="btn-add ${added ? 'is-added' : ''}" ${added ? 'disabled' : ''}>${added ? 'Added' : 'Add'}</button>` +
        `</div>` +
        `<div class="charge-desc hidden">${escapeHtml(c.description || 'No description on file.')}</div>`;

      row.querySelector('.desc-toggle').addEventListener('click', () => {
        row.querySelector('.charge-desc').classList.toggle('hidden');
      });
      if (!added) row.querySelector('.btn-add').addEventListener('click', () => addToCart(c.code));
      frag.appendChild(row);
    });

    list.innerHTML = '';
    list.appendChild(frag);
  }

  // ------------------------------------------------------------------
  // Cart
  // ------------------------------------------------------------------
  function addToCart(code) {
    if (state.cart.some((c) => c.code === code)) return;
    const base = state.chargeByCode[code];
    if (!base) return;
    state.cart.push({
      code: base.code,
      title: base.title,
      class: base.class,
      months: Number(base.months) || 0,
      fine: Number(base.fine) || 0,
      blockedModifiers: base.blockedModifiers || [],
      mods: []
    });
    renderCart(); renderAvailable(); recompute();
  }

  function removeFromCart(code) {
    state.cart = state.cart.filter((c) => c.code !== code);
    renderCart(); renderAvailable(); recompute();
  }

  function clearCart() {
    if (!state.cart.length) return;
    state.cart = [];
    renderCart(); renderAvailable(); recompute();
  }

  function toggleMod(code, modId) {
    const item = state.cart.find((c) => c.code === code);
    if (!item) return;
    const i = item.mods.indexOf(modId);
    if (i >= 0) item.mods.splice(i, 1); else item.mods.push(modId);
    renderCart(); recompute();
  }

  function multFor(mods) {
    let m = 1;
    mods.forEach((id) => {
      const mod = state.modByIdMap[id];
      if (mod && Number(mod.mult)) m *= Number(mod.mult);
    });
    return m;
  }

  // mirrors the server's authoritative floor(x*mult + 0.5)
  function itemValues(item) {
    const mult = multFor(item.mods);
    return {
      months: Math.floor((item.months || 0) * mult + 0.5),
      fine: Math.floor((item.fine || 0) * mult + 0.5)
    };
  }

  function renderCart() {
    const list = $('#cart-list');
    if (!state.cart.length) {
      list.innerHTML = emptyHTML(ICON.file, 'No charges added', 'Add charges from the list to build a record.');
      return;
    }
    const frag = document.createDocumentFragment();

    state.cart.forEach((item) => {
      const v = itemValues(item);
      const cm = classMeta(item.class);
      const blocked = item.blockedModifiers || [];
      const chips = state.penal.modifiers
        .filter((m) => !blocked.includes(m.id))
        .map((m) => {
          const on = item.mods.includes(m.id);
          const tip = `${m.description || ''} (x${m.mult})`;
          return `<button class="mod-chip ${on ? 'active' : ''}" data-mod="${escapeHtml(m.id)}" title="${escapeHtml(tip)}">${escapeHtml(m.label)}</button>`;
        }).join('');

      const row = document.createElement('div');
      row.className = 'cart-row';
      row.innerHTML =
        `<div class="cart-head">` +
          `<span class="code">${escapeHtml(item.code)}</span>` +
          `<span class="cart-title">${escapeHtml(item.title)}</span>` +
          `<span class="badge ${cm.key}">${escapeHtml(cm.label)}</span>` +
          `<button class="btn-remove" title="Remove">&times;</button>` +
        `</div>` +
        `<div class="cart-mods">${chips || '<span class="dim small">No modifiers available for this charge.</span>'}</div>` +
        `<div class="cart-calc"><span>${v.months} min jail</span><span>${money(v.fine)} fine</span></div>`;

      row.querySelector('.btn-remove').addEventListener('click', () => removeFromCart(item.code));
      row.querySelectorAll('.mod-chip').forEach((chip) =>
        chip.addEventListener('click', () => toggleMod(item.code, chip.dataset.mod)));
      frag.appendChild(row);
    });

    list.innerHTML = '';
    list.appendChild(frag);
  }

  function recompute() {
    let jail = 0, fine = 0;
    state.cart.forEach((item) => { const v = itemValues(item); jail += v.months; fine += v.fine; });
    $('#summary-jail').textContent = String(jail);
    $('#summary-fine').textContent = money(fine);
    $('#summary-count').textContent = String(state.cart.length);
    updatePlaceBtn();
  }

  // Targets are held as plain names. The server resolves each to a citizen id
  // and never sends one back, so the NUI stays free of identifiers.
  // Returns a STATUS, not a boolean, and never toasts on its own. "Already on
  // the list" is not a failure - a caller sending you to the calculator should
  // still take you there - so each caller decides what to say and whether to
  // navigate. Returns: 'added' | 'duplicate' | 'full' | 'invalid'.
  function addTarget(name) {
    const clean = String(name || '').replace(/_/g, ' ').trim();
    if (!clean) return 'invalid';
    if (state.targets.some((t) => t.toLowerCase() === clean.toLowerCase())) return 'duplicate';
    if (state.targets.length >= 10) return 'full';

    state.targets.push(clean);
    updateTargetChip();
    return 'added';
  }

  // Shared by the two "open the calculator with this person" buttons. Always
  // lands you on the calculator unless the name itself was unusable.
  function targetAndOpenCalculator(name, label) {
    const res = addTarget(name);
    if (res === 'invalid') { toast('Search a ' + label + ' first.', 'warn'); return; }

    if (res === 'added')          toast('Target added: ' + name, 'ok');
    else if (res === 'duplicate') toast(name + ' is already a target.', 'inform');
    else if (res === 'full')      toast('Maximum 10 targets - remove one to add another.', 'warn');

    showTab('calculator');
  }

  function removeTarget(name) {
    state.targets = state.targets.filter((t) => t !== name);
    updateTargetChip();
  }

  function updateTargetChip() {
    const list = $('#target-list');
    const count = $('#target-count');
    if (count) count.textContent = String(state.targets.length);
    if (!list) { updatePlaceBtn(); return; }

    if (!state.targets.length) {
      list.innerHTML = '<div class="target-empty">No targets - add a name, or use Arrest Calculator on a person record.</div>';
      updatePlaceBtn();
      return;
    }

    list.innerHTML = '';
    state.targets.forEach((name) => {
      const chip = document.createElement('span');
      chip.className = 'target-chip';
      chip.innerHTML =
        '<svg class="ic" width="14" height="14" aria-hidden="true"><use href="#i-user"/></svg>' +
        `<span>${escapeHtml(name)}</span>` +
        '<button type="button" class="target-x" aria-label="Remove target">' +
          '<svg class="ic" width="12" height="12" aria-hidden="true"><use href="#i-x"/></svg></button>';
      chip.querySelector('.target-x').addEventListener('click', () => removeTarget(name));
      list.appendChild(chip);
    });
    updatePlaceBtn();
  }

  function updatePlaceBtn() {
    const n = state.targets.length;
    $('#btn-place').disabled = !(n && state.cart.length);
    const label = $('#btn-place-label');
    if (label) {
      label.textContent = n > 1 ? `Place Charges on ${n} People` : 'Place Charges';
    }
  }

  // ------------------------------------------------------------------
  // Place charges (records OUTSTANDING only - no jail, no fine)
  // ------------------------------------------------------------------
  async function placeCharges() {
    if (!state.targets.length) { toast('Add at least one target.', 'warn'); return; }
    if (!state.cart.length) { toast('Add at least one charge.', 'warn'); return; }

    const items = state.cart.map((c) => ({ code: c.code, modifiers: c.mods.slice() }));
    setBusy('#btn-place', true);
    const res = await nui('placeCharges', { names: state.targets.slice(), items });
    setBusy('#btn-place', false);
    updatePlaceBtn();

    if (res && res.success) {
      toast(res.message || 'Charges recorded as outstanding.', 'ok');
      clearCart();
      state.targets = [];      // incident closed - start the next one clean
      updateTargetChip();
    } else {
      toast((res && res.message) || 'Failed to place charges.', 'err');
    }
  }

  // ------------------------------------------------------------------
  // Inline create-form toggling
  // ------------------------------------------------------------------
  function toggleForm(formSel, show) {
    const f = $(formSel);
    if (!f) return false;
    const willShow = (show === undefined) ? f.classList.contains('hidden') : show;
    f.classList.toggle('hidden', !willShow);
    return willShow;
  }

  // ------------------------------------------------------------------
  // BOLOs
  // ------------------------------------------------------------------
  async function loadBolos() {
    const list = $('#bolo-list');
    if (state.role === 'court') {
      // court cannot read BOLOs (server denies getBolos); show an honest
      // notice instead of a misleading "no active BOLOs" empty state
      state.loaded.bolos = true;
      list.innerHTML = emptyHTML(ICON.eye, 'Restricted section', 'BOLO alerts are limited to law enforcement.');
      return;
    }
    const stop = delayedSpinner(list, 'Loading BOLOs...');
    const data = await nui('getBolos', {});
    stop();
    state.loaded.bolos = true;
    const items = (data && Array.isArray(data.items)) ? data.items : [];
    if (!items.length) {
      list.innerHTML = emptyHTML(ICON.eye, 'No active BOLOs', 'Create one to alert other officers.');
      return;
    }
    const frag = document.createDocumentFragment();
    items.forEach((b) => {
      const imgs = Array.isArray(b.images) ? b.images.filter((u) => /^https?:\/\//.test(u)) : [];
      const card = document.createElement('div');
      card.className = 'bolo-card';

      // Fixed 16:9 media box: ONE image at a time so differing image heights
      // never change the card/description layout. Inline prev/next + counter
      // only when this bolo has more than one image.
      const multi = imgs.length > 1;
      const media =
        '<div class="bolo-media">' +
          (imgs.length
            ? '<img class="bolo-img" loading="lazy" alt="BOLO image" src="' + escapeHtml(imgs[0]) + '" />'
            : '') +
          '<span class="bolo-img-ph' + (imgs.length ? ' hidden' : '') + '">' +
            '<svg class="ic" viewBox="0 0 24 24" width="26" height="26">' + ICON.image + '</svg>' +
          '</span>' +
          (multi
            ? '<button type="button" class="bolo-img-nav prev" aria-label="Previous image">' +
                '<svg class="ic" viewBox="0 0 24 24" width="18" height="18"><path d="M15 6l-6 6 6 6"/></svg></button>' +
              '<button type="button" class="bolo-img-nav next" aria-label="Next image">' +
                '<svg class="ic" viewBox="0 0 24 24" width="18" height="18"><path d="M9 6l6 6-6 6"/></svg></button>' +
              '<span class="bolo-img-count tnum">1 / ' + imgs.length + '</span>'
            : '') +
        '</div>';

      card.innerHTML =
        media +
        `<div class="bolo-body">` +
          `<div class="bolo-top">` +
            `<span class="chip">${escapeHtml(b.type || 'other')}</span>` +
            `<span class="bolo-title">${escapeHtml(b.title || 'Untitled')}</span>` +
          `</div>` +
          `<div class="bolo-desc">${escapeHtml(b.description || 'No details provided.')}</div>` +
          `<div class="bolo-foot">` +
            `<span class="bolo-meta">${escapeHtml(b.officer || 'Unknown')} - ${escapeHtml(fmtDate(b.created_at))}</span>` +
            (b.expires_in === null || b.expires_in === undefined
              ? `<span class="bolo-expiry none">No expiry</span>`
              : `<span class="bolo-expiry${Number(b.expires_in) < 3600 ? ' soon' : ''}">Expires in ${escapeHtml(fmtRemaining(b.expires_in))}</span>`) +
            `<button class="btn danger sm">Cancel</button>` +
          `</div>` +
        `</div>`;

      // Per-card inline gallery: a closure index `cur` keeps THIS card's
      // current image independent of every other card. Clicking the image
      // opens the lightbox scoped to THIS bolo's images at `cur`; a bad URL
      // swaps to the themed placeholder inside the SAME fixed box.
      if (imgs.length) {
        const box = card.querySelector('.bolo-media');
        const im  = box.querySelector('.bolo-img');
        const ph  = box.querySelector('.bolo-img-ph');
        const cnt = box.querySelector('.bolo-img-count');
        let cur = 0;
        const show = (i) => {
          cur = (i + imgs.length) % imgs.length;
          im.classList.remove('hidden'); ph.classList.add('hidden');
          im.src = imgs[cur];
          if (cnt) cnt.textContent = (cur + 1) + ' / ' + imgs.length;
        };
        im.addEventListener('error', () => { im.classList.add('hidden'); ph.classList.remove('hidden'); });
        im.addEventListener('click', () => openLightbox(imgs, cur));
        const prev = box.querySelector('.bolo-img-nav.prev');
        const next = box.querySelector('.bolo-img-nav.next');
        if (prev) prev.addEventListener('click', (e) => { e.stopPropagation(); show(cur - 1); });
        if (next) next.addEventListener('click', (e) => { e.stopPropagation(); show(cur + 1); });
      }
      card.querySelector('.btn.danger').addEventListener('click', (e) => cancelBolo(b.id, e.currentTarget));
      frag.appendChild(card);
    });
    list.innerHTML = '';
    list.appendChild(frag);
  }

  // ---- BOLO image-link rows (repeatable; each row has its own remove button) ----
  function addBoloLinkRow(value) {
    const wrap = $('#bolo-images');
    if (!wrap) return;
    const row = document.createElement('div');
    row.className = 'link-row';
    row.innerHTML =
      '<input type="text" class="bolo-link" placeholder="https://... image URL" autocomplete="off" spellcheck="false" />' +
      '<button type="button" class="btn-remove link-del" title="Remove link" aria-label="Remove link">&times;</button>';
    if (value) row.querySelector('.bolo-link').value = value;
    // Removal is handled by a single delegated listener on #bolo-images
    // (bound in init) so dynamically created rows can never lose their handler.
    wrap.appendChild(row);
  }
  function resetBoloLinks() {
    const wrap = $('#bolo-images');
    if (!wrap) return;
    wrap.innerHTML = '';
    addBoloLinkRow();
  }
  function boloLinkValues() {
    return $$('#bolo-images .bolo-link')
      .map((i) => i.value.trim())
      .filter((v) => /^https:\/\//.test(v)); // https-only client pre-filter; the server re-validates
  }

  // ---- Fullscreen lightbox: one BOLO's images, contain on a dark scrim ----
  function isLightboxOpen() { return !$('#lightbox').classList.contains('hidden'); }
  function renderLightbox() {
    const lb = state.lightbox, n = lb.images.length;
    if (!n) { closeLightbox(); return; }
    if (lb.index < 0) lb.index = n - 1;
    if (lb.index >= n) lb.index = 0;
    const img = $('#lb-img');
    img.onerror = () => { img.removeAttribute('src'); }; // contain box stays, blank on bad URL
    img.src = lb.images[lb.index];
    $('#lb-index').textContent = (lb.index + 1) + ' / ' + n;
    $('#lb-prev').classList.toggle('hidden', n < 2);
    $('#lb-next').classList.toggle('hidden', n < 2);
  }
  function openLightbox(images, index) {
    state.lightbox.images = (images || []).slice();
    state.lightbox.index = Number(index) || 0;
    $('#lightbox').classList.remove('hidden');
    renderLightbox();
  }
  function closeLightbox() { $('#lightbox').classList.add('hidden'); }
  function lightboxStep(dir) { state.lightbox.index += dir; renderLightbox(); }

  // The expiry choices come from config.lua via the open message, so a server
  // changes them in one place. Built once, then left alone.
  let expiryBuilt = false;

  function expiryLabel(hours) {
    if (hours === 0) return 'Never';
    if (hours < 24) return hours + (hours === 1 ? ' hour' : ' hours');
    const days = hours / 24;
    if (Number.isInteger(days)) return days + (days === 1 ? ' day' : ' days');
    return hours + ' hours';
  }

  function buildExpirySelect(cfg) {
    const sel = $('#bolo-expiry');
    if (!sel || expiryBuilt) return;
    const opts = (cfg && Array.isArray(cfg.options) && cfg.options.length)
      ? cfg.options : [1, 6, 12, 24, 48, 72, 168, 0];
    const def = (cfg && typeof cfg.default === 'number') ? cfg.default : 24;

    sel.innerHTML = opts.map((h) => {
      const n = Number(h) || 0;
      const label = expiryLabel(n) + (n === def ? ' (default)' : '');
      return `<option value="${n}"${n === def ? ' selected' : ''}>${escapeHtml(label)}</option>`;
    }).join('');
    sel.value = String(def);
    expiryBuilt = true;
  }


  // Seconds remaining -> "2d 4h" / "23h 12m" / "45m" / "<1m".
  function fmtRemaining(sec) {
    sec = Number(sec) || 0;
    if (sec <= 0) return 'expired';
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (d > 0) return d + 'd' + (h ? ' ' + h + 'h' : '');
    if (h > 0) return h + 'h' + (m ? ' ' + m + 'm' : '');
    return m > 0 ? m + 'm' : '<1m';
  }

  async function createBolo() {
    const type = $('#bolo-type').value;
    const title = $('#bolo-title').value.trim();
    const description = $('#bolo-desc').value.trim();
    const images = boloLinkValues();
    const expiryHours = Number($('#bolo-expiry').value);
    if (!title) { toast('Enter a BOLO title.', 'warn'); return; }
    setBusy('#bolo-create', true);
    const res = await nui('createBolo', { type, title, description, images, expiryHours });
    setBusy('#bolo-create', false);
    if (res && res.success) {
      toast(res.message || 'BOLO created.', 'ok');
      $('#bolo-title').value = '';
      $('#bolo-desc').value = '';
      $('#bolo-expiry').selectedIndex = Math.max(0,
        Array.from($('#bolo-expiry').options).findIndex((o) => o.textContent.includes('(default)')));
      resetBoloLinks();
      toggleForm('#bolo-form', false);
      loadBolos();
    } else {
      toast((res && res.message) || 'Failed to create BOLO.', 'err');
    }
  }

  async function cancelBolo(id, btn) {
    if (btn) { btn.disabled = true; btn.classList.add('is-busy'); }
    const res = await nui('cancelBolo', { id });
    if (res && res.success) {
      toast(res.message || 'BOLO cancelled.', 'ok');
      loadBolos();
    } else {
      toast((res && res.message) || 'Failed to cancel BOLO.', 'err');
      if (btn) { btn.disabled = false; btn.classList.remove('is-busy'); }
    }
  }

  // ------------------------------------------------------------------
  // Warrants (derived, read-only) - name - charges - months - fine
  // ------------------------------------------------------------------
  async function loadWarrants() {
    const list = $('#warrant-list');
    const stop = delayedSpinner(list, 'Loading warrants...');
    const data = await nui('getWarrants', {});
    stop();
    state.loaded.warrants = true;
    const items = (data && Array.isArray(data.items)) ? data.items : [];
    if (!items.length) {
      list.innerHTML = emptyHTML(ICON.shield, 'No active warrants', 'Suspects with outstanding charges.');
      return;
    }
    const frag = document.createDocumentFragment();
    items.forEach((w) => {
      const row = document.createElement('div');
      row.className = 'list-row';
      row.innerHTML =
        `<div class="list-main">` +
          `<div class="list-top"><span class="list-title">${escapeHtml(w.name || 'Unknown')}</span></div>` +
          `<div class="list-meta">Outstanding charges on record</div>` +
        `</div>` +
        `<div class="list-right">` +
          `<div class="row-stats">` +
            `<span class="stat"><span>Charges</span><b class="tnum danger">${Number(w.charges) || 0}</b></span>` +
            `<span class="stat"><span>Min</span><b class="tnum warn">${Number(w.months) || 0}</b></span>` +
            `<span class="stat"><span>Fine</span><b class="tnum">${money(w.fine)}</b></span>` +
          `</div>` +
          `<div class="row-actions">` +
            `<button class="btn-ghost small view-rec">View Record</button>` +
          `</div>` +
        `</div>`;
      row.querySelector('.view-rec').addEventListener('click', () => openWarrantRecord(w.name));
      frag.appendChild(row);
    });
    list.innerHTML = '';
    list.appendChild(frag);
  }

  // Open a warrant suspect in Person Search (NAME only - never any id).
  function openWarrantRecord(name) {
    if (!name) return;
    showTab('person');
    $('#person-name').value = name;
    searchPerson();
  }






  // ------------------------------------------------------------------
  // Global key + wheel navigation (each mode owns its keys; never hijack typing)
  // ------------------------------------------------------------------
  // Left/Right: lightbox image when open. (BOLOs are a plain scrollable
  // grid now - no page-level card stepping.)
  document.addEventListener('keydown', (e) => {
    if (app.classList.contains('hidden')) return;
    // Lightbox owns Left/Right (Esc is handled by the Escape listener).
    if (isLightboxOpen()) {
      if (e.key === 'ArrowLeft') { e.preventDefault(); lightboxStep(-1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); lightboxStep(1); }
    }
  });

  // WEAPON_PISTOL50 reads like a database row, not a police record. Map the
  // common models and fall back to title-casing the suffix for anything else,
  // so a server that adds custom weapons still gets something legible.
  const WEAPON_NAMES = {
    WEAPON_PISTOL: 'Pistol', WEAPON_PISTOL50: 'Pistol .50',
    WEAPON_COMBATPISTOL: 'Combat Pistol', WEAPON_SNSPISTOL: 'SNS Pistol',
    WEAPON_HEAVYPISTOL: 'Heavy Pistol', WEAPON_VINTAGEPISTOL: 'Vintage Pistol',
    WEAPON_APPISTOL: 'AP Pistol', WEAPON_REVOLVER: 'Heavy Revolver',
    WEAPON_MICROSMG: 'Micro SMG', WEAPON_SMG: 'SMG', WEAPON_ASSAULTSMG: 'Assault SMG',
    WEAPON_PUMPSHOTGUN: 'Pump Shotgun', WEAPON_SAWNOFFSHOTGUN: 'Sawn-off Shotgun',
    WEAPON_ASSAULTRIFLE: 'Assault Rifle', WEAPON_CARBINERIFLE: 'Carbine Rifle',
    WEAPON_SPECIALCARBINE: 'Special Carbine', WEAPON_SNIPERRIFLE: 'Sniper Rifle',
    WEAPON_MARKSMANRIFLE: 'Marksman Rifle', WEAPON_STUNGUN: 'Stun Gun',
    WEAPON_FLASHLIGHT: 'Flashlight', WEAPON_NIGHTSTICK: 'Nightstick',
  };

  function weaponLabel(raw) {
    const key = String(raw || '').toUpperCase();
    if (WEAPON_NAMES[key]) return WEAPON_NAMES[key];
    const bare = key.replace(/^WEAPON_/, '').toLowerCase();
    if (!bare) return '-';
    return bare.charAt(0).toUpperCase() + bare.slice(1);
  }

  // ------------------------------------------------------------------
  // Citizen ID - driver licence record + licences on file
  // ------------------------------------------------------------------
  async function searchCitizenId() {
    const q = $('#cid-query').value.trim();
    if (!q) { toast('Enter a name.', 'warn'); return; }
    setBusy('#cid-search-btn', true);
    const data = await nui('searchCitizenId', { query: q });
    setBusy('#cid-search-btn', false);

    if (!data || !data.found) {
      $('#cid-results').classList.add('hidden');
      $('#cid-empty').classList.remove('hidden');
      toast((data && data.message) || 'No citizen on record.', 'warn');
      return;
    }

    $('#cid-empty').classList.add('hidden');
    $('#cid-results').classList.remove('hidden');
    $('#cid-dl').textContent    = data.dl || '-';
    $('#cid-name').textContent  = data.name || '-';
    $('#cid-dob').textContent   = data.dob || '-';
    $('#cid-sex').textContent   = data.gender || '-';
    $('#cid-phone').textContent = data.phone || '-';
    $('#cid-online').classList.toggle('hidden', !data.online);

    // Licence portrait, not the mugshot. No fallback on purpose.
    const img = $('#cid-mug'), ph = $('#cid-mug-ph');
    const src = mugSrc(data.photo);
    if (src) { img.src = src; img.classList.remove('hidden'); ph.classList.add('hidden'); }
    else { img.classList.add('hidden'); ph.classList.remove('hidden'); }

    const rows = Array.isArray(data.licences) ? data.licences : [];
    $('#cid-lic-count').textContent = String(rows.length);
    const body = $('#cid-lic-body');
    body.innerHTML = rows.length
      ? rows.map((l) => {
          const st = String(l.status || 'none').toLowerCase();
          const cls = st === 'valid' ? 'green' : (st === 'suspended' || st === 'revoked' ? 'danger' : 'warn');
          return `<tr><td>${escapeHtml(l.type || '-')}</td>` +
                 `<td><span class="pill ${cls}">${escapeHtml(st.toUpperCase())}</span></td>` +
                 `<td class="mono">${escapeHtml(l.issued || '-')}</td>` +
                 `<td class="mono">${escapeHtml(l.expires || '-')}</td>` +
                 `<td>${escapeHtml(l.issuer || '-')}</td></tr>`;
        }).join('')
      : `<tr class="empty-row"><td colspan="5">No licences on record</td></tr>`;
  }

  // ------------------------------------------------------------------
  // Weapon List - registered firearms by owner
  // ------------------------------------------------------------------
  async function loadWeaponList() {
    const body = $('#wl-body');
    if (!body) return;
    const name = ($('#wl-name') && $('#wl-name').value.trim()) || '';
    const data = await nui('getWeapons', { name });
    state.loaded.weapons = true;
    const items = (data && Array.isArray(data.items)) ? data.items : [];
    $('#wl-count').textContent = String(items.length);

    body.innerHTML = items.length
      ? items.map((w) => {
          const st = String(w.status || 'clean').toLowerCase();
          const label = st === 'clean' ? 'Not Reported Missing' : st.toUpperCase();
          const cls = st === 'clean' ? 'green' : 'danger';
          return `<tr><td class="mono">${escapeHtml(w.registered_at || '-')}</td>` +
                 `<td class="mono">${escapeHtml(w.serial || '-')}</td>` +
                 `<td>${escapeHtml(w.owner || '-')}</td>` +
                 `<td class="mods-cell">${escapeHtml(w.source || '-')}</td>` +
                 `<td>${escapeHtml(weaponLabel(w.weapon))}</td>` +
                 `<td><span class="pill ${cls}">${escapeHtml(label)}</span></td></tr>`;
        }).join('')
      : `<tr class="empty-row"><td colspan="6">No registered weapons found</td></tr>`;
  }

  // ------------------------------------------------------------------
  // Weapon Search - one registration by serial
  // ------------------------------------------------------------------
  let wsCurrent = null;
  let vehCurrent = null;
  let boloTextCfg = { template: '{time} {date} | {detail} {model} | LP: {plate} | RO: {owner} | {extra}', detail: 'DETAIL_HERE', extra: 'EXTRA_INFO' };

  async function searchWeaponSerial() {
    const serial = $('#ws-serial').value.trim();
    if (!serial) { toast('Enter a serial number.', 'warn'); return; }
    setBusy('#ws-search-btn', true);
    const data = await nui('searchWeapon', { serial });
    setBusy('#ws-search-btn', false);

    if (!data || !data.found) {
      wsCurrent = null;
      $('#ws-results').classList.add('hidden');
      $('#ws-empty').classList.remove('hidden');
      toast((data && data.message) || 'No weapon on that serial.', 'warn');
      return;
    }
    wsCurrent = data;
    $('#ws-empty').classList.add('hidden');
    $('#ws-results').classList.remove('hidden');
    $('#ws-owner').textContent      = data.owner || '-';
    $('#ws-weapon').textContent     = weaponLabel(data.weapon);
    $('#ws-serial-out').textContent = data.serial || '-';
    $('#ws-dl').textContent         = data.dl || '-';
    $('#ws-source').textContent     = data.source || '-';
    $('#ws-date').textContent       = data.registered_at || '-';
    renderWeaponStatus(data.status);
  }

  function renderWeaponStatus(status) {
    const st = String(status || 'clean').toLowerCase();
    const el = $('#ws-status');
    el.textContent = st === 'clean' ? 'Not Reported Missing' : st.toUpperCase();
    el.className = 'pill ' + (st === 'clean' ? 'green' : 'danger');
  }

  // One button. Anything that is not 'missing' becomes missing; 'missing'
  // becomes clean. A stolen weapon therefore flips to missing first, which is
  // the honest reading: it is still not accounted for.
  async function toggleWeaponMissing() {
    if (!wsCurrent) { toast('Search a serial first.', 'warn'); return; }
    const next = String(wsCurrent.status || 'clean').toLowerCase() === 'missing' ? 'clean' : 'missing';

    setBusy('#ws-toggle-missing', true);
    const res = await nui('setWeaponStatus', { serial: wsCurrent.serial, status: next });
    setBusy('#ws-toggle-missing', false);

    if (res && res.success) {
      wsCurrent.status = res.status;
      renderWeaponStatus(res.status);
      toast(res.message || 'Status updated.', 'ok');
      state.loaded.weapons = false;
    } else {
      toast((res && res.message) || 'Could not update status.', 'err');
    }
  }





  // ------------------------------------------------------------------
  // Init / wiring
  // ------------------------------------------------------------------
  function init() {
    $$('.rail-btn').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));

    // Criminal Record: reveal / hide the prior-record table
    const histToggle = $('#per-history-toggle');
    if (histToggle) {
      histToggle.addEventListener('click', () => {
        setHistoryVisible($('#per-history-wrap').classList.contains('hidden'));
      });
    }
    $('#close-btn').addEventListener('click', closeMdc);

    // Dashboard
    $('#dash-refresh').addEventListener('click', () => loadDashboard());

    // Vehicle
    $('#veh-search-btn').addEventListener('click', searchVehicle);
    $('#vehicle-plate').addEventListener('keydown', (e) => { if (e.key === 'Enter') searchVehicle(); });

    // Person
    $('#per-search-btn').addEventListener('click', searchPerson);
    $('#person-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') searchPerson(); });

    // Record History show/hide filter chips (sticky across searches).
    $('#per-history-filters').addEventListener('click', (e) => {
      const chip = e.target.closest('.filter-chip');
      if (!chip || !(chip.dataset.filter in HIST_FILTER)) return;
      const key = chip.dataset.filter;
      HIST_FILTER[key] = !HIST_FILTER[key];
      chip.classList.toggle('off', !HIST_FILTER[key]);
      chip.setAttribute('aria-pressed', String(HIST_FILTER[key]));
      applyHistoryFilter();
    });
    // Adds to the incident rather than replacing it, so an officer can walk
    // several people through Person Search and charge them together.
    $('#per-to-calc').addEventListener('click', () => {
      targetAndOpenCalculator(state.personName, 'person');
    });

    // Manual target entry (add several suspects without searching each one)
    const addTargetFromInput = () => {
      const inp = $('#target-input');
      const res = addTarget(inp.value);
      if (res === 'added')          inp.value = '';
      else if (res === 'duplicate') toast(inp.value.trim() + ' is already a target.', 'inform');
      else if (res === 'full')      toast('Maximum 10 targets per incident.', 'warn');
      inp.focus();
    };
    $('#target-add-btn').addEventListener('click', addTargetFromInput);
    $('#target-input').addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); addTargetFromInput(); }
    });


    // Calculator
    let searchTimer;
    $('#charge-search').addEventListener('input', () => {
      clearTimeout(searchTimer);
      searchTimer = setTimeout(renderAvailable, 120);
    });
    $('#cart-clear').addEventListener('click', clearCart);
    $('#btn-place').addEventListener('click', placeCharges);

    // BOLOs
    $('#bolo-refresh').addEventListener('click', loadBolos);
    $('#bolo-new-btn').addEventListener('click', () => toggleForm('#bolo-form'));
    $('#bolo-cancel').addEventListener('click', () => toggleForm('#bolo-form', false));
    $('#bolo-form').addEventListener('submit', (e) => { e.preventDefault(); createBolo(); });
    $('#bolo-add-link').addEventListener('click', () => addBoloLinkRow());
    // Delegated removal so dynamically added rows always work; never leave zero rows.
    $('#bolo-images').addEventListener('click', (e) => {
      const del = e.target.closest('.link-del');
      if (!del) return;
      const row = del.closest('.link-row');
      if (row) row.remove();
      if (!$$('#bolo-images .link-row').length) addBoloLinkRow();
    });
    resetBoloLinks();   // start the create form with one empty link row

    // Lightbox (fullscreen BOLO image viewer)
    $('#lb-close').addEventListener('click', closeLightbox);
    $('#lb-prev').addEventListener('click', () => lightboxStep(-1));
    $('#lb-next').addEventListener('click', () => lightboxStep(1));
    $('#lightbox').addEventListener('mousedown', (e) => { if (e.target.id === 'lightbox') closeLightbox(); });

    // Warrants auto-refresh on tab open (no manual refresh button)

    // Reports


    // Plate Search: owner-record filters + record actions
    $('#veh-filters').addEventListener('click', (e) => {
      const chip = e.target.closest('.filter-chip');
      if (!chip || !(chip.dataset.filter in VEH_FILTER)) return;
      const key = chip.dataset.filter;
      VEH_FILTER[key] = !VEH_FILTER[key];
      chip.classList.toggle('off', !VEH_FILTER[key]);
      chip.setAttribute('aria-pressed', String(VEH_FILTER[key]));
      renderVehicleRecord();
    });
    $('#veh-print').addEventListener('click', () => {
      if (!vehCurrent) { toast('Run a plate first.', 'warn'); return; }
      nui('printPlate', { title: 'VEHICLE REGISTRATION', rows: vehicleInfoLines() });
      toast('Printed to chat.', 'ok');
    });
    $('#veh-bolo').addEventListener('click', () => {
      if (!vehCurrent) { toast('Run a plate first.', 'warn'); return; }
      copyText(vehicleBoloText(), 'BOLO text');
    });
    $('#veh-to-calc').addEventListener('click', () => {
      if (!vehCurrent) { toast('Run a plate first.', 'warn'); return; }
      targetAndOpenCalculator(vehCurrent.owner, 'plate');
    });

    // Citizen ID
    $('#cid-search-btn').addEventListener('click', searchCitizenId);
    $('#cid-query').addEventListener('keydown', (e) => { if (e.key === 'Enter') searchCitizenId(); });

    // Weapon list / serial search
    $('#wl-search-btn').addEventListener('click', loadWeaponList);
    $('#wl-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') loadWeaponList(); });
    $('#ws-search-btn').addEventListener('click', searchWeaponSerial);
    $('#ws-serial').addEventListener('keydown', (e) => { if (e.key === 'Enter') searchWeaponSerial(); });
    $('#ws-toggle-missing').addEventListener('click', toggleWeaponMissing);
    $('#ws-to-calc').addEventListener('click', () => {
      if (!wsCurrent) { toast('Search a serial first.', 'warn'); return; }
      targetAndOpenCalculator(wsCurrent.owner, 'serial');
    });


    renderCart();
    recompute();
    updateTargetChip();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
