/* np_flightradar — browser dev mock (never loaded in game).
 *   index.html?dev=1                 air mode, heading-up, transponder card, TA alert
 *   index.html?dev=1&mode=ground     north-up from LSIA, no transponder
 *   &units=metric  &alert=ra  &pinned=1  &empty=1
 * phone.html?dev=1 uses FRDev.sim for the same traffic.
 */
(function () {
  'use strict';
  var QS = new URLSearchParams(location.search);
  var D2R = Math.PI / 180;

  /* ------------------------------------------------------------------ traffic sim */
  var LSIA = { x: -1037, y: -2963 };
  function Sim(mode) {
    this.air = mode === 'air';
    // own ship: climbing out of LSIA heading 060, or standing at the tower
    this.self = this.air
      ? { x: LSIA.x + 300, y: LSIA.y + 900, z: 820, heading: 60, speed: 62, vs: 2.5, inAircraft: true }
      : { x: LSIA.x, y: LSIA.y, z: 14, heading: 0, speed: 0, vs: 0, inAircraft: false };
    var s = this.self;
    function at(dx, dy) { return { x: s.x + dx, y: s.y + dy }; }
    var A = [
      { id: 101, kind: 'heli', callsign: 'AIR-1', model: 'Police Maverick', p: at(-1900, 1700), z: 260, heading: 120, speed: 38, vs: 0, turn: 3, squawk: '0401', flags: { org: 'police', camera: true } },
      { id: 102, kind: 'heli', callsign: 'MEDIC-2', model: 'Maverick', p: at(2600, 2300), z: 180, heading: 210, speed: 45, vs: -2, turn: 0, squawk: '0420', flags: { org: 'ems' } },
      { id: 103, kind: 'plane', callsign: 'N737LS', model: 'Luxor Deluxe', p: at(-2800, -1700), z: 1250, heading: 35, speed: 88, vs: -6, turn: 0, squawk: '7700', flags: { emergency: '7700' } },
      { id: 104, kind: 'plane', callsign: 'SKY12', model: 'Cuban 800', p: at(1100, 700), z: 860, heading: 250, speed: 55, vs: 0, turn: 0, squawk: '7000', flags: {}, threat: this.air ? 'TA' : null },
      { id: 105, kind: 'heli', callsign: '', model: 'Buzzard', p: at(-900, -2600), z: 140, heading: 330, speed: 30, vs: 0, turn: -4, squawk: null, flags: { xpdrOff: true } },
      { id: 106, kind: 'plane', callsign: 'DUSTER9', model: 'Duster', p: at(3200, -1500), z: 210, heading: 280, speed: 42, vs: 1.5, turn: 2, squawk: '7000', flags: { unlicensed: true } },
      { id: 107, kind: 'plane', callsign: 'JET-4', model: 'Jet', p: at(-4200, 3300), z: 3700, heading: 100, speed: 140, vs: 0, turn: 0, squawk: '2341', flags: {} },
      { id: 108, kind: 'heli', callsign: 'FROG5', model: 'Frogger', p: at(600, -3400), z: 320, heading: 15, speed: 28, vs: 3, turn: 0, squawk: '7000', flags: {} },
      { id: 109, kind: 'plane', callsign: 'ARMY-1', model: 'P-996 Lazer', p: at(4800, 4200), z: 2400, heading: 230, speed: 160, vs: -4, turn: 1, squawk: '5100', flags: { org: 'military' } }
    ];
    this.ac = A;
  }
  Sim.prototype.step = function (dt) {
    function move(o, p) {
      o.heading = (o.heading + (o.turn || 0) * dt + 360) % 360;
      p.x += Math.sin(o.heading * D2R) * o.speed * dt;
      p.y += Math.cos(o.heading * D2R) * o.speed * dt;
    }
    var s = this.self;
    if (this.air) { s.heading = (s.heading + 0.6 * dt) % 360; move(s, s); s.z += s.vs * dt; }
    for (var i = 0; i < this.ac.length; i++) {
      var a = this.ac[i];
      move(a, a.p);
      a.z = Math.max(40, a.z + a.vs * dt);
      // keep traffic around the scope
      var dx = a.p.x - s.x, dy = a.p.y - s.y;
      if (Math.sqrt(dx * dx + dy * dy) > 7500) { a.heading = (Math.atan2(-dx, -dy) / D2R + 360) % 360; }
    }
  };
  Sim.prototype.payload = function (range) {
    var s = this.self, out = [];
    for (var i = 0; i < this.ac.length; i++) {
      var a = this.ac[i];
      var dx = a.p.x - s.x, dy = a.p.y - s.y;
      var dist = Math.sqrt(dx * dx + dy * dy);
      if (range > 0 && dist > range) continue;
      var off = !!a.flags.xpdrOff;
      out.push({
        id: a.id, kind: a.kind, callsign: off ? null : a.callsign, model: off ? null : a.model,
        x: a.p.x, y: a.p.y, z: a.z, alt: a.z, heading: a.heading, speed: a.speed, vs: a.vs,
        dist: dist, bearing: (Math.atan2(dx, dy) / D2R + 360) % 360,
        squawk: off ? null : a.squawk,
        flags: { emergency: a.flags.emergency || null, xpdrOff: off, unlicensed: !!a.flags.unlicensed, camera: !!a.flags.camera, org: a.flags.org || null },
        threat: a.threat || null
      });
    }
    return { self: { x: s.x, y: s.y, z: s.z, heading: s.heading, inAircraft: s.inAircraft }, range: range, contacts: out };
  };

  /* ------------------------------------------------------------------ backdrop: aerial LS stand-in */
  function backdrop() {
    var cv = document.createElement('canvas');
    cv.className = 'fr-devbg';
    document.body.insertBefore(cv, document.body.firstChild);
    var W = cv.width = innerWidth, H = cv.height = innerHeight;
    var g = cv.getContext('2d');
    var seed = 11;
    function rnd() { seed = (seed * 16807) % 2147483647; return seed / 2147483647; }
    // land
    var land = g.createLinearGradient(0, 0, W, H);
    land.addColorStop(0, '#3b4038'); land.addColorStop(1, '#2e332f');
    g.fillStyle = land; g.fillRect(0, 0, W, H);
    // ocean, lower-left with a ragged coast
    g.beginPath(); g.moveTo(0, H * 0.48);
    for (var x = 0; x <= W * 0.62; x += 24) g.lineTo(x, H * 0.48 + x * 0.55 + Math.sin(x / 70) * 18 + rnd() * 10);
    g.lineTo(W * 0.62, H); g.lineTo(0, H); g.closePath();
    var sea = g.createLinearGradient(0, H * 0.5, 0, H); sea.addColorStop(0, '#1f3640'); sea.addColorStop(1, '#152730');
    g.fillStyle = sea; g.fill();
    g.strokeStyle = 'rgba(210,200,170,.25)'; g.lineWidth = 6; g.stroke();
    // city blocks (upper right)
    g.save();
    g.beginPath(); g.rect(W * 0.18, 0, W, H * 0.55); g.clip();
    g.translate(W * 0.55, H * 0.2); g.rotate(-0.18);
    for (var bx = -30; bx < 30; bx++) for (var by = -14; by < 14; by++) {
      if (rnd() < 0.12) continue;
      var c = 52 + Math.floor(rnd() * 26);
      g.fillStyle = 'rgb(' + c + ',' + (c + 2) + ',' + (c + 4) + ')';
      g.fillRect(bx * 64 + 6, by * 58 + 6, 52 - rnd() * 12, 46 - rnd() * 10);
    }
    g.restore();
    // highways
    g.strokeStyle = 'rgba(160,160,150,.35)'; g.lineWidth = 9;
    g.beginPath(); g.moveTo(W * 0.1, H * 0.15); g.bezierCurveTo(W * 0.35, H * 0.3, W * 0.5, H * 0.32, W, H * 0.62); g.stroke();
    g.beginPath(); g.moveTo(W * 0.45, 0); g.bezierCurveTo(W * 0.42, H * 0.4, W * 0.6, H * 0.7, W * 0.72, H); g.stroke();
    // airport (LSIA-ish) on the coast: apron + two runways
    g.save(); g.translate(W * 0.36, H * 0.74); g.rotate(-0.5);
    g.fillStyle = 'rgba(95,98,96,.9)'; g.fillRect(-260, -120, 520, 240);
    g.fillStyle = '#2b2d2e'; g.fillRect(-300, -70, 600, 34); g.fillRect(-300, 40, 600, 34);
    g.strokeStyle = 'rgba(255,255,255,.55)'; g.lineWidth = 2; g.setLineDash([16, 14]);
    g.beginPath(); g.moveTo(-290, -53); g.lineTo(290, -53); g.moveTo(-290, 57); g.lineTo(290, 57); g.stroke();
    g.restore();
    // golden-hour haze + vignette so the glass has something to sit on
    var haze = g.createLinearGradient(0, 0, 0, H);
    haze.addColorStop(0, 'rgba(120,130,150,.25)'); haze.addColorStop(0.5, 'rgba(0,0,0,0)'); haze.addColorStop(1, 'rgba(0,0,0,.25)');
    g.fillStyle = haze; g.fillRect(0, 0, W, H);
    var vig = g.createRadialGradient(W / 2, H / 2, H * 0.3, W / 2, H / 2, W * 0.75);
    vig.addColorStop(0, 'rgba(0,0,0,0)'); vig.addColorStop(1, 'rgba(0,0,0,.5)');
    g.fillStyle = vig; g.fillRect(0, 0, W, H);
  }

  window.FRDev = { Sim: Sim, backdrop: backdrop };

  /* ------------------------------------------------------------------ panel wiring (index.html) */
  if (!document.getElementById('panel')) return;
  document.documentElement.style.background = '#1a1d1f';
  backdrop();

  var mode = QS.get('mode') || 'air';
  var sim = new Sim(mode === 'air' ? 'air' : 'ground');
  if (QS.has('empty')) sim.ac = [];
  var range = 8000;
  var xpdr = { on: true, squawk: '7000', callsign: 'NP-421', canEdit: true };
  function send(m) { window.postMessage(m, '*'); }

  window.FRDev.onPost = function (name, data) {
    if (window.console) console.log('[dev] POST', name, JSON.stringify(data));
    if (name === 'setRange') range = +data.range || 0;
    if (name === 'transponder') {
      for (var k in data) xpdr[k] = data[k];
      setTimeout(function () { send({ action: 'transponder', state: xpdr }); }, 120);
    }
    if (name === 'close') setTimeout(openPanel, 1500);
    if (name === 'focus' && !data.on) setTimeout(function () { send({ action: 'focus', on: true }); }, 4000);
  };

  function openPanel() {
    send({
      action: 'open', mode: mode, focus: !QS.has('pinned'),
      locale: {},
      config: { ranges: [2000, 4000, 8000, 16000, 0], range: range, units: QS.get('units') === 'metric' ? 'metric' : 'aviation', canTransponder: mode === 'air', key: 'F6' }
    });
    send({ action: 'transponder', state: mode === 'air' ? xpdr : null });
    send(Object.assign({ action: 'contacts' }, sim.payload(range)));
  }
  openPanel();
  if (mode === 'air') {
    var ra = QS.get('alert') === 'ra';
    send({ action: 'alert', level: ra ? 'RA' : 'TA', id: 104, text: ra ? 'Climb, climb now' : 'Traffic, traffic · SKY12 2 o’clock' });
  }
  // fast-forward a little so the sweep and dead reckoning have history
  var last = performance.now();
  setInterval(function () {
    var now = performance.now();
    sim.step((now - last) / 1000); last = now;
    send(Object.assign({ action: 'contacts' }, sim.payload(range)));
  }, 500);
})();
