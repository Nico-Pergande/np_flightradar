/* np_flightradar — np_phone custom app (html/phone.html, shown by the phone in an iframe).
 *
 * Data:  client/phone.lua -> exports.np_phone:sendAppMessage('flightradar', 'contacts', payload)
 *        -> phone.on('contacts', fn). payload = the NUI `contacts` shape ({ self, range, contacts, mode?, denied? }).
 * GPS:   phone.nui('select', { id }) -> RegisterNUICallback('select') in client/nui.lua (the SDK posts to
 *        https://<this resource>/select, the documented way to reach the owning resource's client).
 * Dev:   phone.html?dev=1 (framed phone + simulated traffic), &sheet=<id> opens the detail sheet,
 *        &frame=0 renders the bare app. The SDK is only loaded in game / inside the phone.
 */
(function () {
  'use strict';

  var QS = new URLSearchParams(location.search);
  var DEV = QS.has('dev') && typeof window.GetParentResourceName !== 'function';
  var SDK_URL = 'https://cfx-nui-np_phone/web/dist/sdk/np-phone.js';
  var MAX_ROWS = 50;

  /* ------------------------------------------------------------------ strings (phone payload has no locale) */
  var STR = {
    en: {
      title: 'Flightradar', live: 'Live', waiting: 'Waiting for data', contacts: 'Contacts', all: 'All',
      filter_heli: 'Helicopters', filter_plane: 'Planes', emergency: 'Emergency',
      no_contacts: 'No aircraft in range', no_access: 'No radar access', close: 'Close',
      unidentified: 'Unidentified', unlicensed: 'Unlicensed pilot', camera: 'Camera active', xpdr_off: 'Transponder off',
      kind_heli: 'Helicopter', kind_plane: 'Plane', altitude: 'Altitude', speed: 'Speed', vertical_speed: 'Vertical speed',
      heading: 'Heading', distance: 'Distance', bearing: 'Bearing', set_waypoint: 'Set waypoint', waypoint_set: 'Waypoint set to %s',
      sq_7500: 'Hijack', sq_7600: 'Radio failure', sq_7700: 'General emergency',
      org_police: 'Police', org_ems: 'EMS', org_fire: 'Fire', org_military: 'Military', range_unlimited: 'Unlimited'
    },
    de: {
      title: 'Flugradar', live: 'Live', waiting: 'Warte auf Daten', contacts: 'Kontakte', all: 'Alle',
      filter_heli: 'Hubschrauber', filter_plane: 'Flugzeuge', emergency: 'Notfall',
      no_contacts: 'Keine Luftfahrzeuge in Reichweite', no_access: 'Kein Zugriff auf das Radar', close: 'Schließen',
      unidentified: 'Unidentifiziert', unlicensed: 'Pilot ohne Lizenz', camera: 'Kamera aktiv', xpdr_off: 'Transponder aus',
      kind_heli: 'Hubschrauber', kind_plane: 'Flugzeug', altitude: 'Höhe', speed: 'Geschwindigkeit', vertical_speed: 'Steigrate',
      heading: 'Kurs', distance: 'Entfernung', bearing: 'Peilung', set_waypoint: 'Wegpunkt setzen', waypoint_set: 'Wegpunkt auf %s gesetzt',
      sq_7500: 'Entführung', sq_7600: 'Funkausfall', sq_7700: 'Allgemeiner Notfall',
      org_police: 'Polizei', org_ems: 'Rettungsdienst', org_fire: 'Feuerwehr', org_military: 'Militär', range_unlimited: 'Unbegrenzt'
    }
  };
  var lang = 'en';
  function L(k) {
    var s = (STR[lang] && STR[lang][k]) || STR.en[k] || k;
    for (var i = 1; i < arguments.length; i++) s = s.replace(/%[sd]/, String(arguments[i]));
    return s;
  }

  function $(id) { return document.getElementById(id); }
  function el(tag, cls) { var e = document.createElement(tag); if (cls) e.className = cls; return e; }
  function setText(e, v) { v = v === null || v === undefined ? '' : String(v); if (e.textContent !== v) e.textContent = v; }
  function toggleClass(e, c, on) { if (e.classList.contains(c) !== !!on) e.classList.toggle(c, !!on); }
  function pad3(n) { n = String(n); while (n.length < 3) n = '0' + n; return n; }

  /* ------------------------------------------------------------------ state */
  var phone = null;
  var S = { contacts: [], self: null, range: 0, filter: 'all', selected: null, units: FR.units(QS.get('units') === 'metric' ? 'metric' : 'aviation'), last: 0, denied: false };
  var rows = new Map();
  var list = $('list');

  /* ------------------------------------------------------------------ dev frame */
  var framed = DEV && QS.get('frame') !== '0';
  if (framed) {
    document.documentElement.classList.add('ph-framed');
    if (window.top !== window) document.documentElement.classList.add('ph-embedded');
    var root = $('root');
    var stage = el('div', 'ph-stage');
    var ph = el('div', 'nb-phone');
    var scr = el('div', 'nb-phone__screen');
    var status = el('div', 'ph-status');
    var clock = el('span'); clock.textContent = '09:41';
    var icons = el('span');
    ['fa-signal', 'fa-wifi', 'fa-battery-three-quarters'].forEach(function (n) { icons.appendChild(el('i', 'fa-solid ' + n)); });
    status.appendChild(clock); status.appendChild(icons);
    var island = el('div', 'nb-island');
    root.parentNode.insertBefore(stage, root);
    stage.appendChild(ph); ph.appendChild(scr);
    scr.appendChild(root); scr.appendChild(status); scr.appendChild(island); scr.appendChild(el('div', 'ph-homebar'));
    document.documentElement.style.setProperty('--np-safe-top', '50px');
    document.documentElement.style.setProperty('--np-safe-bottom', '22px');
  }

  /* ------------------------------------------------------------------ scope */
  var scope = new FR.Scope($('scope'), {
    compact: true, units: S.units, labels: { unident: '?' },
    onPick: function (id) { openSheet(id); },
    onHover: function () {}
  });
  scope.filter = passes;

  function passes(c) {
    if (!c) return false;
    if (S.filter === 'heli') return c.kind === 'heli';
    if (S.filter === 'plane') return c.kind !== 'heli';
    if (S.filter === 'emerg') return !!(c.flags && c.flags.emergency);
    return true;
  }

  Array.prototype.forEach.call($('filters').children, function (b) {
    b.addEventListener('click', function () {
      S.filter = b.dataset.f;
      Array.prototype.forEach.call($('filters').children, function (x) { toggleClass(x, 'is-on', x === b); });
      render();
    });
  });

  function applyStrings() {
    setText($('title'), L('title'));
    setText($('fAll'), L('all'));
    $('fHeli').title = L('filter_heli');
    $('fPlane').title = L('filter_plane');
    $('fEmerg').title = L('emergency');
    setText($('listTitle'), L('contacts'));
    setText($('sheetClose'), L('close'));
    setText($('lAlt'), L('altitude')); setText($('lSpd'), L('speed')); setText($('lVs'), L('vertical_speed'));
    setText($('lHdg'), L('heading')); setText($('lDist'), L('distance')); setText($('lBrg'), L('bearing'));
    setText($('gpsText'), L('set_waypoint'));
    document.title = L('title');
  }

  /* ------------------------------------------------------------------ list */
  function badgeList(c) {
    var f = c.flags || {}, out = [];
    if (f.emergency) out.push({ t: 'red', i: 'fa-triangle-exclamation', txt: L('emergency') });
    if (f.xpdrOff) out.push({ t: '', i: 'fa-tower-broadcast', txt: L('xpdr_off') });
    if (f.unlicensed) out.push({ t: 'orange', i: 'fa-id-card', txt: L('unlicensed') });
    if (f.camera) out.push({ t: '', i: 'fa-video', txt: L('camera') });
    if (f.org && FR.ORG_TINT[f.org]) out.push({ t: FR.ORG_TINT[f.org], i: '', txt: L('org_' + f.org) });
    return out;
  }
  function fillBadges(box, c) {
    while (box.firstChild) box.removeChild(box.firstChild);
    badgeList(c).forEach(function (b) {
      var e = el('span', 'fr-badge' + (b.t ? ' fr-badge--' + b.t : ''));
      if (b.i) e.appendChild(el('i', 'fa-solid ' + b.i));
      e.appendChild(document.createTextNode(b.txt));
      box.appendChild(e);
    });
  }
  function nameOf(c) { return c.flags && c.flags.xpdrOff ? L('unidentified') : (c.callsign || '—'); }
  function kindName(c) { return L(c.kind === 'heli' ? 'kind_heli' : 'kind_plane'); }

  function buildRow(id) {
    var r = el('div', 'nb-row nb-row--lead ph-row');
    r.setAttribute('role', 'button');
    var tile = el('span', 'nb-tile nb-tile--sm'); var g = el('i', 'fa-solid fa-plane'); tile.appendChild(g);
    var body = el('div', 'nb-row__body');
    var title = el('div', 'nb-row__title'); var cs = el('span'); var sq = el('span', 'fr-sq');
    title.appendChild(cs); title.appendChild(sq);
    var sub = el('div', 'nb-row__sub');
    body.appendChild(title); body.appendChild(sub);
    var meta = el('div', 'ph-meta'); var d = el('b'); var b = el('span'); meta.appendChild(d); meta.appendChild(b);
    r.appendChild(tile); r.appendChild(body); r.appendChild(meta);
    r.addEventListener('click', function () { openSheet(id); });
    return { el: r, tile: tile, g: g, cs: cs, sq: sq, sub: sub, d: d, b: b, sig: '' };
  }
  function fillRow(row, c) {
    var st = FR.contactStyle(c), f = c.flags || {};
    var sig = st.tint + st.icon;
    if (row.sig !== sig) { row.sig = sig; row.tile.className = 'nb-tile nb-tile--sm' + (st.tint ? ' nb-tile--' + st.tint : ''); row.g.className = 'fa-solid ' + st.icon; }
    setText(row.cs, nameOf(c));
    setText(row.sq, f.xpdrOff ? '' : (c.squawk || ''));
    toggleClass(row.sq, 'is-emerg', !!f.emergency);
    var t = S.units.trend(c.vs);
    setText(row.sub, (f.xpdrOff ? kindName(c) : (c.model || kindName(c))) + ' · ' +
      (f.xpdrOff ? '' : S.units.alt(c.alt) + ' · ') + S.units.speed(c.speed) + (t > 0 ? ' ↑' : t < 0 ? ' ↓' : ''));
    setText(row.d, S.units.dist(c.dist));
    setText(row.b, pad3(Math.round(+c.bearing || 0) % 360) + '°');
    toggleClass(row.el, 'is-selected', S.selected === String(c.id));
  }

  function render() {
    var vis = S.contacts.filter(passes).sort(function (a, b) { return (+a.dist || 0) - (+b.dist || 0); });
    if (vis.length > MAX_ROWS) vis.length = MAX_ROWS;
    var keep = new Set(), prev = null;
    for (var i = 0; i < vis.length; i++) {
      var c = vis[i], id = String(c.id);
      keep.add(id);
      var row = rows.get(id);
      if (!row) { row = buildRow(id); rows.set(id, row); }
      fillRow(row, c);
      var want = prev ? prev.nextSibling : list.firstChild;
      if (want !== row.el) list.insertBefore(row.el, want);
      prev = row.el;
    }
    rows.forEach(function (row, id) { if (!keep.has(id)) { if (row.el.parentNode) row.el.parentNode.removeChild(row.el); rows.delete(id); } });
    list.parentNode.hidden = vis.length === 0;
    $('empty').hidden = vis.length > 0;
    setText($('emptyText'), S.denied ? L('no_access') : L('no_contacts'));
    var rng = scope.effectiveRange();
    setText($('scopeRange'), S.range > 0 ? S.units.ring(rng) : 'MAX · ' + S.units.ring(rng));
    setText($('scopeOrient'), S.self ? (scope.northUp ? 'N↑' : 'HDG ' + pad3(Math.round(+S.self.heading || 0) % 360) + '°') : '');
    if (S.selected) fillSheet();
  }

  /* ------------------------------------------------------------------ detail sheet */
  function findContact(id) { for (var i = 0; i < S.contacts.length; i++) if (String(S.contacts[i].id) === id) return S.contacts[i]; return null; }
  function openSheet(id) {
    S.selected = String(id);
    scope.setSelected(S.selected);
    $('scrim').hidden = false; $('sheet').hidden = false;
    fillSheet();
    rows.forEach(function (row, rid) { toggleClass(row.el, 'is-selected', rid === S.selected); });
  }
  function closeSheet() {
    S.selected = null; scope.setSelected(null);
    $('scrim').hidden = true; $('sheet').hidden = true;
    rows.forEach(function (row) { toggleClass(row.el, 'is-selected', false); });
  }
  var lastBadges = '';
  function fillSheet() {
    var c = findContact(S.selected);
    if (!c) { closeSheet(); return; }
    var st = FR.contactStyle(c), f = c.flags || {};
    $('dTile').className = 'nb-tile nb-tile--lg' + (st.tint ? ' nb-tile--' + st.tint : '');
    $('dGlyph').className = 'fa-solid ' + st.icon;
    setText($('sheetTitle'), nameOf(c));
    setText($('dCs'), nameOf(c));
    setText($('dModel'), f.xpdrOff ? kindName(c) : (c.model || kindName(c)) + ' · ' + kindName(c));
    setText($('dSq'), f.xpdrOff ? '' : (c.squawk || ''));
    toggleClass($('dSq'), 'is-emerg', !!f.emergency);
    var sig = JSON.stringify(badgeList(c));
    if (sig !== lastBadges) { lastBadges = sig; fillBadges($('dBadges'), c); }
    $('dBadges').hidden = !badgeList(c).length;
    setText($('dAlt'), f.xpdrOff ? '—' : S.units.alt(c.alt));
    setText($('dSpd'), S.units.speed(c.speed));
    setText($('dVs'), f.xpdrOff ? '—' : S.units.vs(c.vs));
    setText($('dHdg'), pad3(Math.round(+c.heading || 0) % 360) + '°');
    setText($('dDist'), S.units.dist(c.dist));
    setText($('dBrg'), pad3(Math.round(+c.bearing || 0) % 360) + '°');
  }
  $('scrim').addEventListener('click', closeSheet);
  $('sheetClose').addEventListener('click', closeSheet);

  var flashTimer = 0;
  function flash(text) {
    var old = document.querySelector('.ph-flash'); if (old) old.parentNode.removeChild(old);
    var f = el('div', 'ph-flash'); f.appendChild(el('i', 'fa-solid fa-location-dot')); f.appendChild(document.createTextNode(text));
    $('app').appendChild(f);
    clearTimeout(flashTimer); flashTimer = setTimeout(function () { if (f.parentNode) f.parentNode.removeChild(f); }, 2600);
  }
  $('gpsBtn').addEventListener('click', function () {
    var c = findContact(S.selected); if (!c) return;
    var p = phone ? phone.nui('select', { id: c.id }) : Promise.resolve();
    Promise.resolve(p).catch(function () {}).then(function () { flash(L('waypoint_set', nameOf(c))); });
  });

  /* ------------------------------------------------------------------ data */
  function onContacts(p) {
    if (!p || typeof p !== 'object') return;
    S.denied = !!p.denied;
    S.contacts = Array.isArray(p.contacts) ? p.contacts : [];
    S.self = p.self || null;
    S.range = Math.max(0, +p.range || 0);
    if (p.units === 'metric' || p.units === 'aviation') { S.units = FR.units(p.units); scope.setUnits(S.units); }
    S.last = Date.now();
    scope.update({ self: p.self || {}, range: S.range, contacts: S.contacts });
    render();
    toggleClass($('live'), 'is-stale', false);
    setText($('live'), L('live'));
  }
  // stale marker when updates stop (phone put away, radar access lost)
  setInterval(function () {
    var stale = !S.last || Date.now() - S.last > 4000;
    toggleClass($('live'), 'is-stale', stale);
    setText($('live'), stale ? L('waiting') : L('live'));
  }, 1000);

  function start() { scope.start(); }
  function stop() { scope.stop(); }
  document.addEventListener('visibilitychange', function () { if (document.hidden) stop(); else start(); });

  /* ------------------------------------------------------------------ boot */
  function boot() {
    applyStrings();
    render();
    start();
  }

  if (DEV) {
    lang = QS.get('lang') === 'de' ? 'de' : 'en';
    boot();
    var s = document.createElement('script');
    s.src = 'dev/mock.js';
    s.onload = function () {
      var sim = new window.FRDev.Sim('ground');
      var range = 8000;
      onContacts(sim.payload(range));
      var last = performance.now();
      setInterval(function () { var now = performance.now(); sim.step((now - last) / 1000); last = now; onContacts(sim.payload(range)); }, 1000);
      if (QS.get('sheet')) openSheet(QS.get('sheet'));
    };
    document.body.appendChild(s);
    return;
  }

  // In game / inside the phone: load the SDK from np_phone; without it the page still renders.
  import(SDK_URL).then(function (mod) {
    phone = mod.default || window.NPPhone;
    return phone.ready();
  }).then(function () {
    lang = String(phone.locale || 'en').slice(0, 2).toLowerCase();
    if (!STR[lang]) lang = 'en';
    boot();
    phone.on('contacts', onContacts);
    phone.on('visibility', function (v) { if (v && v.visible && !v.locked) start(); else stop(); });
  }).catch(function (err) {
    if (window.console) console.warn('[np_flightradar] phone SDK unavailable', err);
    boot();
  });
})();
