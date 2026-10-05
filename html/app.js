/* np_flightradar — radar panel NUI.
 *
 * Lua -> NUI (SendNUIMessage, field `action`): open, close, contacts, transponder, alert (+ optional focus)
 * NUI -> Lua (POST https://<resource>/<name>, JSON): close, focus, setRange, setFilter, transponder, select
 *
 * All text goes through textContent; list rows are keyed by contact id and reused between updates.
 * Dev mode: index.html?dev=1[&mode=ground] loads dev/mock.js (mock backdrop + simulated traffic).
 */
(function () {
  'use strict';

  var QS = new URLSearchParams(location.search);
  var IN_GAME = typeof window.GetParentResourceName === 'function';
  var DEV = !IN_GAME && QS.has('dev');
  var RES = IN_GAME ? window.GetParentResourceName() : 'np_flightradar';
  var MAX_ROWS = 60;

  /* ------------------------------------------------------------------ locale */
  var EN = {
    title: 'Flight radar', contacts: 'Contacts', range: 'Range', range_unlimited: 'Unlimited',
    filters: 'Filters', filter_heli: 'Helicopters', filter_plane: 'Planes', filter_emergency: 'Emergencies only',
    transponder: 'Transponder', squawk: 'Squawk', callsign: 'Callsign', on: 'On', off: 'Off', apply: 'Apply',
    close: 'Close', focus: 'Interact', no_contacts: 'No aircraft in range', unidentified: 'Unidentified',
    unlicensed: 'Unlicensed pilot', camera: 'Camera active', xpdr_off: 'Transponder off', emergency: 'Emergency',
    kind_heli: 'Helicopter', kind_plane: 'Plane', model: 'Model', altitude: 'Altitude', speed: 'Speed',
    heading: 'Heading', vertical_speed: 'Vertical speed', distance: 'Distance', bearing: 'Bearing',
    set_waypoint: 'Set waypoint', waypoint_set: 'Waypoint set to %s',
    sq_7500: 'Hijack', sq_7600: 'Radio failure', sq_7700: 'General emergency',
    org_police: 'Police', org_ems: 'EMS', org_fire: 'Fire', org_military: 'Military',
    ta: 'TA', ra: 'RA', ta_title: 'Traffic advisory', ra_title: 'Resolution advisory',
    ta_text: 'Traffic, traffic', clear_text: 'Clear of conflict',
    mode_air: 'Onboard', mode_ground: 'Ground', mode_station: 'Tower', mode_item: 'Scanner',
    mode_phone: 'Phone', mode_admin: 'Admin',
    squawk_hint: 'Four digits, 0-7', callsign_hint: 'A-Z, 0-9 and -, max. 8'
  };
  var locale = {};
  function L(key) {
    var s = locale[key];
    if (typeof s !== 'string' || !s) s = EN[key] || key;
    for (var i = 1; i < arguments.length; i++) s = s.replace(/%[sd]/, String(arguments[i]));
    return s;
  }

  /* ------------------------------------------------------------------ helpers */
  function $(id) { return document.getElementById(id); }
  function post(name, data) {
    if (!IN_GAME) {
      if (window.FRDev && window.FRDev.onPost) window.FRDev.onPost(name, data || {});
      return Promise.resolve({ ok: true });
    }
    return fetch('https://' + RES + '/' + name, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data || {})
    }).then(function (r) { return r.json(); }).catch(function () { return null; });
  }
  function setText(el, v) { v = v === null || v === undefined ? '' : String(v); if (el.textContent !== v) el.textContent = v; }
  function toggleClass(el, c, on) { if (el.classList.contains(c) !== !!on) el.classList.toggle(c, !!on); }
  function el(tag, cls) { var e = document.createElement(tag); if (cls) e.className = cls; return e; }
  function icon(name) { var i = el('i', 'fa-solid ' + name); return i; }

  /* ------------------------------------------------------------------ state */
  var S = {
    open: false, mode: 'air', focus: true, pinned: false,
    ranges: [2000, 4000, 8000, 16000, 0], range: 0,
    units: FR.units('aviation'), canTransponder: false, key: 'F6',
    filters: { heli: true, plane: true, emergencyOnly: false },
    contacts: [], self: null,
    selected: null, hover: null,
    xpdr: null, alertTimer: 0
  };
  try { S.pinned = localStorage.getItem('np_flightradar:pinned') === '1'; } catch (e) { /* storage blocked */ }

  var MODES = {
    air: { icon: 'fa-plane-up', key: 'mode_air' },
    ground: { icon: 'fa-satellite-dish', key: 'mode_ground' },
    station: { icon: 'fa-tower-observation', key: 'mode_station' },
    item: { icon: 'fa-tower-broadcast', key: 'mode_item' },
    phone: { icon: 'fa-mobile-screen', key: 'mode_phone' },
    admin: { icon: 'fa-user-shield', key: 'mode_admin', tint: 'red' }
  };

  var panel = $('panel');
  var list = $('list');
  var rows = new Map();          // id -> { el, refs, sig }

  var scope = new FR.Scope($('scope'), {
    units: S.units,
    labels: { unident: 'UNIDENT' },
    onPick: function (id) { select(id); },
    onHover: function (id) { setHover(id); }
  });
  scope.filter = passes;

  /* ------------------------------------------------------------------ layout scale */
  function layout() {
    var z = Math.max(0.75, window.innerHeight / 1080);
    panel.style.zoom = z;
    panel.style.height = Math.max(560, Math.floor(window.innerHeight / z - 40)) + 'px';
  }
  window.addEventListener('resize', layout);
  layout();

  /* ------------------------------------------------------------------ static text */
  function applyLocale() {
    setText($('title'), L('title'));
    setText($('listTitle'), L('contacts'));
    setText($('emptyText'), L('no_contacts'));
    setText($('xpdrTitle'), L('transponder'));
    setText($('sqLabel'), L('squawk'));
    setText($('csLabel'), L('callsign'));
    setText($('hintText'), L('focus'));
    $('closeBtn').title = L('close');
    $('pinBtn').title = L('focus');
    $('fHeli').title = L('filter_heli');
    $('fPlane').title = L('filter_plane');
    $('fEmerg').title = L('filter_emergency');
    $('sqInput').title = L('squawk_hint');
    $('sqInput').placeholder = '7000';
    $('csInput').title = L('callsign_hint');
    scope.labels.unident = L('unidentified').toUpperCase().slice(0, 14);
  }

  function renderMode() {
    var m = MODES[S.mode] || MODES.air;
    $('modeIcon').className = 'fa-solid ' + m.icon;
    $('modeTile').className = 'nb-tile nb-tile--xs' + (m.tint ? ' nb-tile--' + m.tint : '');
    setText($('modeLabel'), L(m.key));
  }

  function renderRanges() {
    var box = $('ranges');
    while (box.firstChild) box.removeChild(box.firstChild);
    S.ranges.forEach(function (r) {
      var b = el('button');
      b.type = 'button';
      b.dataset.range = String(r);
      if (r > 0) b.textContent = S.units.ring(r);
      else { b.appendChild(icon('fa-infinity')); b.title = L('range_unlimited'); }
      if (r === S.range) b.classList.add('is-on');
      b.addEventListener('click', function () {
        if (S.range === r) return;
        S.range = r;
        scope.setRange(r);
        markRange();
        post('setRange', { range: r });
        renderHeader();
      });
      box.appendChild(b);
    });
  }
  function markRange() {
    var bs = $('ranges').children;
    for (var i = 0; i < bs.length; i++) toggleClass(bs[i], 'is-on', +bs[i].dataset.range === S.range);
  }

  function renderFocus() {
    var pinnedOverlay = !S.focus;
    toggleClass(panel, 'is-pinned', pinnedOverlay);
    $('hint').hidden = !pinnedOverlay;
    setText($('hintKey'), S.key);
    toggleClass($('pinBtn'), 'is-on', S.pinned);
  }

  function renderHeader() {
    var n = visibleContacts().length;
    var r = S.range > 0 ? S.units.ring(S.range) : L('range_unlimited');
    setText($('subtitle'), n + ' ' + L('contacts') + ' · ' + L('range') + ' ' + r);
    setText($('count'), n);
    var rng = scope.effectiveRange();
    setText($('scopeRange'), S.range > 0 ? S.units.ring(rng) : 'MAX · ' + S.units.ring(rng));
    if (S.self) {
      setText($('scopeOrient'), scope.northUp ? 'N↑' : 'HDG ' + pad3(Math.round(FR.toCompass(S.self.heading)) % 360) + '°');
      setText($('scopeSelf'), S.self.inAircraft ? S.units.alt(S.self.z) : '');
    } else { setText($('scopeOrient'), ''); setText($('scopeSelf'), ''); }
  }
  function pad3(n) { n = String(n); while (n.length < 3) n = '0' + n; return n; }

  /* ------------------------------------------------------------------ filters */
  function passes(c) {
    if (!c) return false;
    var f = S.filters;
    if (f.emergencyOnly && !(c.flags && c.flags.emergency)) return false;
    if (c.kind === 'heli' && !f.heli) return false;
    if (c.kind !== 'heli' && !f.plane) return false;
    return true;
  }
  function visibleContacts() { return S.contacts.filter(passes); }
  function bindFilter(id, key) {
    var b = $(id);
    b.addEventListener('click', function () {
      S.filters[key] = !S.filters[key];
      toggleClass(b, 'is-on', S.filters[key]);
      post('setFilter', { heli: S.filters.heli, plane: S.filters.plane, emergencyOnly: S.filters.emergencyOnly });
      renderList();
      renderHeader();
    });
  }
  bindFilter('fHeli', 'heli');
  bindFilter('fPlane', 'plane');
  bindFilter('fEmerg', 'emergencyOnly');
  function syncFilterButtons() {
    toggleClass($('fHeli'), 'is-on', S.filters.heli);
    toggleClass($('fPlane'), 'is-on', S.filters.plane);
    toggleClass($('fEmerg'), 'is-on', S.filters.emergencyOnly);
  }

  /* ------------------------------------------------------------------ contact list */
  function buildRow(id) {
    var r = el('div', 'fr-row');
    r.setAttribute('role', 'listitem');
    r.tabIndex = 0;
    r.dataset.id = id;
    var tile = el('span', 'nb-tile nb-tile--sm');
    var glyph = el('i', 'fa-solid fa-plane');
    tile.appendChild(glyph);
    var main = el('div', 'fr-row__main');
    var top = el('div', 'fr-row__top');
    var cs = el('span', 'fr-row__cs');
    var sq = el('span', 'fr-sq');
    top.appendChild(cs); top.appendChild(sq);
    var sub = el('div', 'fr-row__sub');
    var model = el('span', 'fr-row__model');
    var badges = el('span', 'fr-badges');
    sub.appendChild(model); sub.appendChild(badges);
    main.appendChild(top); main.appendChild(sub);
    var stats = el('div', 'fr-row__num');
    var alt = el('b'); var spd = el('span');
    var vsI = el('i', 'fr-vs fa-solid'); var spdT = document.createTextNode('');
    spd.appendChild(spdT); spd.appendChild(document.createTextNode(' ')); spd.appendChild(vsI);
    stats.appendChild(alt); stats.appendChild(spd);
    var dist = el('div', 'fr-row__num');
    var d = el('b'); var brg = el('span');
    dist.appendChild(d); dist.appendChild(brg);
    r.appendChild(tile); r.appendChild(main); r.appendChild(stats); r.appendChild(dist);
    r.addEventListener('click', function () { select(id); });
    r.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); select(id); } });
    r.addEventListener('mouseenter', function () { setHover(id); });
    r.addEventListener('mouseleave', function () { if (S.hover === id) setHover(null); });
    return { el: r, tile: tile, glyph: glyph, cs: cs, sq: sq, model: model, badges: badges, alt: alt, spdT: spdT, vsI: vsI, d: d, brg: brg, sig: '', bsig: '' };
  }

  function badgeList(c) {
    var f = c.flags || {}, out = [];
    if (f.emergency) out.push({ t: 'red', i: 'fa-triangle-exclamation', txt: L('emergency'), title: f.emergency + ' \u00b7 ' + L('sq_' + f.emergency) });
    if (f.xpdrOff) out.push({ t: '', i: 'fa-tower-broadcast', txt: L('off'), title: L('xpdr_off') });
    if (f.unlicensed) out.push({ t: 'orange', i: 'fa-id-card', txt: '', title: L('unlicensed') });
    if (f.camera) out.push({ t: '', i: 'fa-video', txt: '', title: L('camera') });
    if (f.org && FR.ORG_TINT[f.org]) out.push({ t: FR.ORG_TINT[f.org], i: '', txt: L('org_' + f.org), title: L('org_' + f.org) });
    return out;
  }

  function fillRow(row, c) {
    var f = c.flags || {};
    var st = FR.contactStyle(c);
    var sig = st.tint + '|' + st.icon;
    if (row.sig !== sig) {
      row.sig = sig;
      row.tile.className = 'nb-tile nb-tile--sm' + (st.tint ? ' nb-tile--' + st.tint : '');
      row.glyph.className = 'fa-solid ' + st.icon;
    }
    setText(row.cs, f.xpdrOff ? L('unidentified') : (c.callsign || '—'));
    setText(row.sq, f.xpdrOff ? '' : (c.squawk || ''));
    toggleClass(row.sq, 'is-emerg', !!f.emergency);
    setText(row.model, f.xpdrOff ? L(c.kind === 'heli' ? 'kind_heli' : 'kind_plane') : (c.model || L(c.kind === 'heli' ? 'kind_heli' : 'kind_plane')));
    var bl = badgeList(c);
    var bsig = JSON.stringify(bl);
    if (row.bsig !== bsig) {
      row.bsig = bsig;
      while (row.badges.firstChild) row.badges.removeChild(row.badges.firstChild);
      bl.forEach(function (b) {
        var e = el('span', 'fr-badge' + (b.t ? ' fr-badge--' + b.t : ''));
        e.title = b.title;
        if (b.i) e.appendChild(icon(b.i));
        if (b.txt) e.appendChild(document.createTextNode(b.txt));
        row.badges.appendChild(e);
      });
    }
    setText(row.alt, f.xpdrOff ? '—' : S.units.alt(c.alt));
    setText(row.spdT, S.units.speed(c.speed));
    var tr = S.units.trend(c.vs);
    var vcls = 'fr-vs fa-solid ' + (tr > 0 ? 'fa-arrow-up is-up' : tr < 0 ? 'fa-arrow-down is-down' : 'fa-minus');
    if (row.vsI.className !== vcls) row.vsI.className = vcls;
    row.vsI.title = S.units.vs(c.vs);
    setText(row.d, S.units.dist(c.dist));
    setText(row.brg, pad3(Math.round(+c.bearing || 0) % 360) + '°');
    toggleClass(row.el, 'is-emerg', !!f.emergency);
    toggleClass(row.el, 'is-selected', S.selected === String(c.id));
    toggleClass(row.el, 'is-hover', S.hover === String(c.id));
  }

  function renderList() {
    var vis = visibleContacts().slice().sort(function (a, b) { return (+a.dist || 0) - (+b.dist || 0); });
    if (vis.length > MAX_ROWS) vis.length = MAX_ROWS;
    var keep = new Set();
    var prev = null;
    for (var i = 0; i < vis.length; i++) {
      var c = vis[i], id = String(c.id);
      keep.add(id);
      var row = rows.get(id);
      if (!row) { row = buildRow(id); rows.set(id, row); }
      fillRow(row, c);
      // move only when out of order (no rebuild, no thrash)
      var want = prev ? prev.nextSibling : list.firstChild;
      if (want !== row.el) list.insertBefore(row.el, want);
      prev = row.el;
    }
    rows.forEach(function (row, id) {
      if (!keep.has(id)) { if (row.el.parentNode) row.el.parentNode.removeChild(row.el); rows.delete(id); }
    });
    $('empty').hidden = vis.length > 0;
  }

  function select(id) {
    id = id === null || id === undefined ? null : String(id);
    S.selected = id;
    scope.setSelected(id);
    rows.forEach(function (row, rid) { toggleClass(row.el, 'is-selected', rid === id); });
    if (id !== null) {
      var row = rows.get(id);
      if (row && row.el.scrollIntoView) row.el.scrollIntoView({ block: 'nearest' });
      var c = S.contacts.find(function (x) { return String(x.id) === id; });
      post('select', { id: c ? c.id : id });
    }
  }
  function setHover(id) {
    id = id === null || id === undefined ? null : String(id);
    if (S.hover === id) return;
    S.hover = id;
    scope.setHover(id, false);
    rows.forEach(function (row, rid) { toggleClass(row.el, 'is-hover', rid === id); });
  }

  /* ------------------------------------------------------------------ transponder */
  var armed = null, armTimer = 0;
  function renderXpdr() {
    var x = S.xpdr;
    var card = $('xpdr');
    card.hidden = !x;
    if (!x) return;
    var can = !!x.canEdit;
    toggleClass(card, 'is-locked', !can);
    var sw = $('xpdrSwitch');
    toggleClass(sw, 'is-on', !!x.on);
    sw.setAttribute('aria-checked', x.on ? 'true' : 'false');
    sw.disabled = !can;
    var emerg = /^7[567]00$/.test(x.squawk || '');
    $('xpdrTile').className = 'nb-tile nb-tile--sm' + (!x.on ? '' : emerg ? ' nb-tile--red' : ' nb-tile--green');
    setText($('xpdrState'), (x.on ? L('on') : L('off')) + ' · ' + L('squawk') + ' ' + (x.squawk || '----') +
      (emerg ? ' · ' + L('sq_' + x.squawk) : ''));
    var sq = $('sqInput'), cs = $('csInput');
    if (document.activeElement !== sq) { sq.value = x.squawk || ''; sq.classList.remove('is-bad'); }
    if (document.activeElement !== cs) cs.value = x.callsign || '';
    sq.disabled = !can; cs.disabled = !can;
    var qb = $('quick').children;
    for (var i = 0; i < qb.length; i++) {
      qb[i].disabled = !can;
      toggleClass(qb[i], 'is-current', qb[i].dataset.sq === x.squawk);
      if (qb[i].dataset.sq === armed) qb[i].classList.add('is-armed'); else qb[i].classList.remove('is-armed');
      if (!qb[i].dataset.label) { qb[i].dataset.label = qb[i].textContent; }
      qb[i].title = qb[i].dataset.sq === '7000' ? '' : L('sq_' + qb[i].dataset.sq);
    }
  }
  function sendXpdr(patch) {
    if (!S.xpdr || !S.xpdr.canEdit) return;
    // optimistic: Lua answers with a fresh `transponder` message
    for (var k in patch) S.xpdr[k] = patch[k];
    renderXpdr();
    post('transponder', patch);
  }
  $('xpdrSwitch').addEventListener('click', function () { if (S.xpdr) sendXpdr({ on: !S.xpdr.on }); });
  var sqIn = $('sqInput');
  sqIn.addEventListener('input', function () {
    var v = sqIn.value.replace(/[^0-7]/g, '').slice(0, 4);
    if (v !== sqIn.value) sqIn.value = v;
    sqIn.classList.toggle('is-bad', v.length > 0 && v.length < 4);
  });
  function commitSquawk() {
    var v = sqIn.value;
    if (!/^[0-7]{4}$/.test(v)) { if (S.xpdr) sqIn.value = S.xpdr.squawk || ''; sqIn.classList.remove('is-bad'); return; }
    if (S.xpdr && v === S.xpdr.squawk) return;
    sendXpdr({ squawk: v });
  }
  sqIn.addEventListener('keydown', function (e) { if (e.key === 'Enter') { commitSquawk(); sqIn.blur(); } });
  sqIn.addEventListener('blur', commitSquawk);
  var csIn = $('csInput');
  csIn.addEventListener('input', function () {
    var v = csIn.value.toUpperCase().replace(/[^A-Z0-9-]/g, '').slice(0, 8);
    if (v !== csIn.value) csIn.value = v;
  });
  function commitCallsign() {
    var v = csIn.value.toUpperCase().replace(/[^A-Z0-9-]/g, '').slice(0, 8);
    if (!v) { if (S.xpdr) csIn.value = S.xpdr.callsign || ''; return; }
    if (S.xpdr && v === S.xpdr.callsign) return;
    sendXpdr({ callsign: v });
  }
  csIn.addEventListener('keydown', function (e) { if (e.key === 'Enter') { commitCallsign(); csIn.blur(); } });
  csIn.addEventListener('blur', commitCallsign);
  Array.prototype.forEach.call($('quick').children, function (b) {
    b.addEventListener('click', function () {
      var code = b.dataset.sq;
      if (!S.xpdr || !S.xpdr.canEdit || code === S.xpdr.squawk) return;
      if (code !== '7000' && armed !== code) {
        // emergency codes need a second click within 3 s
        armed = code;
        clearTimeout(armTimer);
        armTimer = setTimeout(function () { armed = null; renderXpdr(); }, 3000);
        renderXpdr();
        return;
      }
      armed = null; clearTimeout(armTimer);
      sendXpdr({ squawk: code });
    });
  });

  /* ------------------------------------------------------------------ alert */
  function showAlert(m) {
    var box = $('alert');
    clearTimeout(S.alertTimer);
    if (!m || m.level === 'clear' || (m.level !== 'TA' && m.level !== 'RA')) {
      box.hidden = true;
      scope.setAlert(null);
      return;
    }
    var ra = m.level === 'RA';
    box.className = 'fr-alert ' + (ra ? 'is-ra' : 'is-ta');
    $('alertTile').className = 'nb-tile nb-tile--sm ' + (ra ? 'nb-tile--red' : 'nb-tile--orange');
    setText($('alertTitle'), ra ? L('ra_title') : L('ta_title'));
    setText($('alertText'), m.text || (ra ? '' : L('ta_text')));
    box.hidden = false;
    scope.setAlert({ id: m.id, level: m.level });
    // safety net: a lost 'clear' must not leave the banner up forever
    S.alertTimer = setTimeout(function () { showAlert(null); }, 20000);
  }

  /* ------------------------------------------------------------------ open / close */
  function open(m) {
    locale = (m.locale && typeof m.locale === 'object') ? m.locale : {};
    var cfg = m.config || {};
    if (cfg.headingFormat === 'gta' || cfg.headingFormat === 'compass') FR.headingFormat = cfg.headingFormat;
    S.mode = MODES[m.mode] ? m.mode : 'air';
    S.units = FR.units(cfg.units);
    scope.setUnits(S.units);
    if (Array.isArray(cfg.ranges) && cfg.ranges.length) {
      S.ranges = cfg.ranges.map(function (r) { return Math.max(0, +r || 0); }).slice(0, 6);
    }
    S.range = cfg.range !== undefined ? Math.max(0, +cfg.range || 0) : S.range;
    if (S.ranges.indexOf(S.range) === -1) S.ranges = S.ranges.concat([S.range]).sort(function (a, b) { return (a || 1e12) - (b || 1e12); });
    scope.setRange(S.range);
    S.canTransponder = !!cfg.canTransponder;
    if (typeof cfg.key === 'string' && cfg.key) S.key = cfg.key.slice(0, 12);
    if (cfg.filters && typeof cfg.filters === 'object') {
      ['heli', 'plane', 'emergencyOnly'].forEach(function (k) { if (typeof cfg.filters[k] === 'boolean') S.filters[k] = cfg.filters[k]; });
    }
    S.focus = m.focus !== false;
    if (!S.canTransponder) S.xpdr = null;
    applyLocale();
    renderMode();
    renderRanges();
    syncFilterButtons();
    renderFocus();
    renderXpdr();
    renderHeader();
    renderList();
    if (!S.open) {
      S.open = true;
      panel.hidden = false;
      layout();
      scope.resize();
    }
    scope.start();
  }
  function close(fromLua) {
    if (!S.open) return;
    S.open = false;
    panel.hidden = true;
    scope.stop();
    showAlert(null);
    if (!fromLua) post('close', {});
  }

  $('closeBtn').addEventListener('click', function () { close(false); });
  $('pinBtn').addEventListener('click', function () {
    S.pinned = !S.pinned;
    try { localStorage.setItem('np_flightradar:pinned', S.pinned ? '1' : '0'); } catch (e) { /* ignore */ }
    renderFocus();
  });
  document.addEventListener('keydown', function (e) {
    if (!S.open || !S.focus) return;
    // with NUI focus the game never sees the panel key, so its third press (focused -> close) lands here
    if (e.key && S.key && e.key.toUpperCase() === S.key.toUpperCase() &&
        !(document.activeElement && document.activeElement.tagName === 'INPUT' && e.key.length === 1)) {
      e.preventDefault();
      close(false);
      return;
    }
    if (e.key !== 'Escape') return;
    var a = document.activeElement;
    if (a && (a.tagName === 'INPUT')) { a.blur(); return; }
    if (S.pinned) {
      // pinned: Escape hands focus back to the game, the panel stays as an overlay
      S.focus = false;
      renderFocus();
      post('focus', { on: false });
    } else close(false);
  });
  document.addEventListener('visibilitychange', function () { if (!document.hidden) scope.kick(); });

  /* ------------------------------------------------------------------ messages */
  var HANDLERS = {
    open: open,
    close: function () { close(true); },
    focus: function (m) { S.focus = !!m.on; renderFocus(); },
    contacts: function (m) {
      S.contacts = Array.isArray(m.contacts) ? m.contacts : [];
      S.self = m.self || null;
      if (m.range !== undefined && S.ranges.indexOf(Math.max(0, +m.range || 0)) !== -1) {
        S.range = Math.max(0, +m.range || 0);
        markRange();
      }
      scope.update({ self: m.self || {}, range: S.range, contacts: S.contacts });
      if (S.selected && !S.contacts.some(function (c) { return String(c.id) === S.selected; })) { S.selected = null; scope.setSelected(null); }
      renderList();
      renderHeader();
    },
    transponder: function (m) {
      var st = m.state;
      if (st && typeof st === 'object') {
        S.xpdr = {
          on: !!st.on,
          squawk: /^[0-7]{4}$/.test(String(st.squawk || '')) ? String(st.squawk) : '7000',
          callsign: String(st.callsign || '').toUpperCase().replace(/[^A-Z0-9-]/g, '').slice(0, 8),
          canEdit: st.canEdit !== false
        };
      } else S.xpdr = null;
      renderXpdr();
    },
    alert: showAlert
  };

  window.addEventListener('message', function (e) {
    var m = e.data;
    if (!m || typeof m.action !== 'string') return;
    var fn = HANDLERS[m.action];
    if (!fn) return;
    try { fn(m); } catch (err) { if (window.console) console.error('[np_flightradar]', m.action, err); }
  });

  if (DEV) {
    document.documentElement.classList.add('is-dev');
    var sc = document.createElement('script');
    sc.src = 'dev/mock.js';
    document.body.appendChild(sc);
  }
})();
