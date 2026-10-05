/* np_flightradar — shared radar core for the panel (app.js) and the phone app (phone.js).
 *
 *   FR.units(kind)            formatters for 'aviation' (ft/kt/fpm/NM, FL above 5000 ft) | 'metric'
 *   FR.toCompass(h)           payload heading -> compass degrees (clockwise); accepts GTA ccw via headingFormat
 *   FR.contactStyle(c)        { tint, icon, colour } for tiles / scope symbols (colour = meaning only)
 *   new FR.Scope(canvas, o)   canvas PPI scope: range rings, N marker, heading-up / north-up, sweep,
 *                             dead-reckoned contacts with data tags, selection + hover hit testing
 *
 * Plain ES5-ish JS (no build step). Nothing in here touches innerHTML.
 */
(function (global) {
  'use strict';

  var D2R = Math.PI / 180;
  var TAU = Math.PI * 2;

  /* ------------------------------------------------------------------ helpers */
  var rootStyle = null;
  function cssVar(name, fallback) {
    if (!rootStyle) rootStyle = getComputedStyle(document.documentElement);
    var v = rootStyle.getPropertyValue(name);
    return (v && v.trim()) || fallback;
  }
  function num(v, d) { v = +v; return isFinite(v) ? v : (d || 0); }
  function clamp(v, a, b) { return v < a ? a : (v > b ? b : v); }

  /* Headings: the NUI contract carries compass headings (0 = north, clockwise, see
     shared/radarmath.lua). `FR.headingFormat = 'gta'` (or open.config.headingFormat = 'gta')
     accepts raw GetEntityHeading() values (counter-clockwise) instead. */
  var FR = { headingFormat: 'compass' };
  FR.toCompass = function (h) {
    h = num(h);
    if (FR.headingFormat === 'compass') return ((h % 360) + 360) % 360;
    return ((360 - (h % 360)) % 360 + 360) % 360;
  };
  /* compass bearing (clockwise from north) of a world vector, GTA world: +x east, +y north */
  FR.bearingOf = function (dx, dy) {
    var b = Math.atan2(dx, dy) / D2R;
    return (b + 360) % 360;
  };

  /* ------------------------------------------------------------------ units */
  function group(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ','); }
  function pad3(n) { n = String(n); while (n.length < 3) n = '0' + n; return n; }

  FR.units = function (kind) {
    var metric = kind === 'metric';
    var u = { kind: metric ? 'metric' : 'aviation' };
    u.alt = function (m) {
      m = num(m);
      if (metric) return group(Math.round(m)) + ' m';
      var ft = m * 3.28084;
      if (ft > 5000) return 'FL' + pad3(Math.round(ft / 100));
      return group(Math.max(0, Math.round(ft / 10) * 10)) + ' ft';
    };
    u.speed = function (ms) {
      ms = Math.max(0, num(ms));
      return metric ? Math.round(ms * 3.6) + ' km/h' : Math.round(ms * 1.943844) + ' kt';
    };
    u.vs = function (ms) {
      ms = num(ms);
      if (metric) return (ms > 0 ? '+' : '') + ms.toFixed(1) + ' m/s';
      var f = Math.round(ms * 196.8504 / 50) * 50;
      return (f > 0 ? '+' : '') + group(f) + ' fpm';
    };
    u.dist = function (m) {
      m = Math.max(0, num(m));
      if (metric) return m < 1000 ? Math.round(m / 10) * 10 + ' m' : (m / 1000).toFixed(m < 10000 ? 1 : 0) + ' km';
      var nm = m / 1852;
      return nm.toFixed(nm < 10 ? 1 : 0) + ' NM';
    };
    /* ring / range labels: short, no trailing ".0" */
    u.ring = function (m) {
      m = Math.max(0, num(m));
      if (metric) return m < 1000 ? Math.round(m) + ' m' : +(m / 1000).toFixed(1) + ' km';
      return +(m / 1852).toFixed(1) + ' NM';
    };
    u.range = function (m) { return num(m) <= 0 ? null : u.ring(m); };
    /* vertical trend: -1 descending, 0 level, 1 climbing (dead band 1 m/s ≈ 200 fpm) */
    u.trend = function (ms) { ms = num(ms); return ms > 1 ? 1 : (ms < -1 ? -1 : 0); };
    return u;
  };

  /* ------------------------------------------------------------------ meaning -> colour */
  var ORG_TINT = { police: 'blue', ems: 'aqua', fire: 'rust', military: 'olive' };
  FR.ORG_TINT = ORG_TINT;
  FR.contactStyle = function (c) {
    var f = (c && c.flags) || {};
    if (f.xpdrOff) return { tint: '', icon: 'fa-question', key: 'neutral', unknown: true };
    if (f.emergency) return { tint: 'red', icon: c.kind === 'heli' ? 'fa-helicopter' : 'fa-plane', key: 'red' };
    var t = ORG_TINT[f.org] || '';
    return { tint: t, icon: c.kind === 'heli' ? 'fa-helicopter' : 'fa-plane', key: t || 'neutral' };
  };

  var palette = null;
  function colours() {
    if (palette) return palette;
    palette = {
      neutral: 'rgba(255,255,255,.92)',
      unknown: 'rgba(255,255,255,.55)',
      red: cssVar('--nb-red-accent', '#ef6a6a'),
      orange: cssVar('--nb-orange-accent', '#ef9a6a'),
      blue: cssVar('--nb-blue-accent', '#8aa8d8'),
      aqua: cssVar('--nb-aqua-accent', '#8cc8d4'),
      rust: cssVar('--nb-rust-accent', '#f08a5a'),
      olive: cssVar('--nb-olive-accent', '#c8b896'),
      green: cssVar('--nb-green-accent', '#8cc884'),
      font: cssVar('--nb-font', 'Quicksand, system-ui, sans-serif')
    };
    return palette;
  }

  /* ------------------------------------------------------------------ scope */
  /**
   * opts: { compact:bool, units: FR.units(), onPick(id), onHover(id|null), labels:{north,max,unident} }
   */
  function Scope(canvas, opts) {
    this.cv = canvas;
    this.ctx = canvas.getContext('2d');
    this.opts = opts || {};
    this.units = this.opts.units || FR.units('aviation');
    this.labels = this.opts.labels || {};
    this.tracks = new Map();
    this.order = [];
    this.self = null;           // { x, y, z, heading(compass), inAircraft, vx, vy, t }
    this.range = 0;             // metres, 0 = unlimited (auto-fit)
    this.fitRange = 2000;       // auto-fit radius for range 0
    this.northUp = true;
    this.selected = null;
    this.hover = null;
    this.alert = null;          // { id, level }
    this.filter = null;         // fn(contact) -> bool
    this.running = false;
    this.raf = 0;
    this.lastDraw = 0;
    this.size = 0;
    this.dpr = 1;
    this.hits = [];
    this.t0 = performance.now();
    var self = this;
    this.frame = function (now) { self.raf = 0; self.tick(now); };
    this.resize();
    if (typeof ResizeObserver === 'function') {
      this.ro = new ResizeObserver(function () { self.resize(); self.draw(performance.now()); });
      this.ro.observe(canvas);
    }
    canvas.addEventListener('mousemove', function (e) { self.pointer(e, false); });
    canvas.addEventListener('mouseleave', function () { self.setHover(null, true); });
    canvas.addEventListener('click', function (e) { self.pointer(e, true); });
  }
  FR.Scope = Scope;

  Scope.prototype.resize = function () {
    var r = this.cv.getBoundingClientRect();
    // getBoundingClientRect is post-zoom; clientWidth is the CSS (pre-zoom) size we draw in
    var css = this.cv.clientWidth || r.width || 300;
    var scale = r.width && this.cv.clientWidth ? r.width / this.cv.clientWidth : 1;
    var dpr = (global.devicePixelRatio || 1) * scale;
    dpr = clamp(dpr, 1, 3);
    this.size = css;
    this.dpr = dpr;
    var px = Math.round(css * dpr);
    if (this.cv.width !== px) { this.cv.width = px; this.cv.height = px; }
  };

  /* ---------- data in ---------- */
  Scope.prototype.setUnits = function (u) { this.units = u; };
  Scope.prototype.setRange = function (m) { this.range = Math.max(0, num(m)); };

  /** payload: the NUI `contacts` message ({ self, range, contacts }) */
  Scope.prototype.update = function (payload) {
    var now = performance.now();
    var s = payload.self || {};
    var sx = num(s.x), sy = num(s.y);
    var prev = this.self;
    var vx = 0, vy = 0;
    if (prev) {
      var dt = (now - prev.t) / 1000;
      if (dt > 0.15 && dt < 5) {
        vx = (sx - prev.bx) / dt; vy = (sy - prev.by) / dt;
        // ignore teleports / respawns
        if (Math.abs(vx) > 250 || Math.abs(vy) > 250) { vx = 0; vy = 0; }
        vx = prev.vx * 0.4 + vx * 0.6; vy = prev.vy * 0.4 + vy * 0.6;
      }
    }
    var cur = prev ? this.selfAt(now) : null;
    this.self = {
      bx: sx, by: sy, z: num(s.z), heading: FR.toCompass(s.heading), inAircraft: !!s.inAircraft,
      vx: vx, vy: vy, t: now,
      ox: cur ? cur.x - sx : 0, oy: cur ? cur.y - sy : 0
    };
    if (Math.abs(this.self.ox) > 400 || Math.abs(this.self.oy) > 400) { this.self.ox = 0; this.self.oy = 0; }
    this.northUp = !this.self.inAircraft;
    if (payload.range !== undefined) this.range = Math.max(0, num(payload.range));

    var list = Array.isArray(payload.contacts) ? payload.contacts : [];
    var seen = new Set();
    var far = 0;
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (!c || c.id === undefined || c.id === null) continue;
      var id = String(c.id);
      seen.add(id);
      var tr = this.tracks.get(id);
      var x = num(c.x), y = num(c.y), z = num(c.z);
      var hdg = FR.toCompass(c.heading);
      var spd = Math.max(0, num(c.speed));
      var p = tr ? this.trackAt(tr, now) : null;
      if (!tr) { tr = { id: id }; this.tracks.set(id, tr); }
      tr.c = c;
      tr.bx = x; tr.by = y; tr.bz = z; tr.t = now;
      tr.hdg = hdg;
      tr.vx = Math.sin(hdg * D2R) * spd; tr.vy = Math.cos(hdg * D2R) * spd; tr.vz = num(c.vs);
      // blend from where the symbol is drawn now to the fresh fix (no jumps)
      tr.ox = p ? p.x - x : 0; tr.oy = p ? p.y - y : 0;
      if (Math.abs(tr.ox) > 300 || Math.abs(tr.oy) > 300) { tr.ox = 0; tr.oy = 0; }
      var d = Math.sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy));
      if (d > far) far = d;
    }
    var self = this;
    this.tracks.forEach(function (tr, id) { if (!seen.has(id)) self.tracks.delete(id); });
    // unlimited range: fit the farthest contact into ~90 % of the scope, in tidy steps
    var steps = [1000, 2000, 4000, 6000, 8000, 12000, 16000, 24000, 32000, 48000, 64000];
    var want = far / 0.9;
    var fit = steps[steps.length - 1];
    for (var k = 0; k < steps.length; k++) { if (steps[k] >= want) { fit = steps[k]; break; } }
    this.fitRange = fit;
    if (!this.running) this.draw(now);
  };

  Scope.prototype.clear = function () { this.tracks.clear(); this.self = null; this.draw(performance.now()); };

  Scope.prototype.selfAt = function (now) {
    var s = this.self;
    if (!s) return { x: 0, y: 0 };
    var dt = Math.min((now - s.t) / 1000, 2.5);
    var k = Math.exp(-(now - s.t) / 260);
    return { x: s.bx + s.vx * dt + s.ox * k, y: s.by + s.vy * dt + s.oy * k };
  };
  Scope.prototype.trackAt = function (tr, now) {
    var dt = Math.min((now - tr.t) / 1000, 2.5);   // dead reckoning, clamped
    var k = Math.exp(-(now - tr.t) / 260);
    return { x: tr.bx + tr.vx * dt + tr.ox * k, y: tr.by + tr.vy * dt + tr.oy * k, z: tr.bz + tr.vz * dt };
  };

  Scope.prototype.effectiveRange = function () { return this.range > 0 ? this.range : this.fitRange; };

  /* ---------- loop: rAF only while running and the document is visible ---------- */
  Scope.prototype.start = function () {
    if (this.running) return;
    this.running = true;
    this.resize();
    this.kick();
  };
  Scope.prototype.stop = function () {
    this.running = false;
    if (this.raf) { cancelAnimationFrame(this.raf); this.raf = 0; }
  };
  Scope.prototype.kick = function () {
    if (this.running && !this.raf && !document.hidden) this.raf = requestAnimationFrame(this.frame);
  };
  Scope.prototype.tick = function (now) {
    if (!this.running || document.hidden) return;
    // ~30 fps is plenty for a sweep and dead reckoning, and halves the NUI cost
    if (now - this.lastDraw >= 31) { this.lastDraw = now; this.draw(now); }
    this.kick();
  };

  /* ---------- interaction ---------- */
  Scope.prototype.pointer = function (e, click) {
    var r = this.cv.getBoundingClientRect();
    var k = r.width ? this.size / r.width : 1;
    var x = (e.clientX - r.left) * k, y = (e.clientY - r.top) * k;
    var best = null, bd = 14 * 14;
    for (var i = 0; i < this.hits.length; i++) {
      var h = this.hits[i];
      var d = (h.x - x) * (h.x - x) + (h.y - y) * (h.y - y);
      if (d < bd) { bd = d; best = h.id; }
    }
    this.cv.style.cursor = best ? 'pointer' : '';
    if (click) { if (best && this.opts.onPick) this.opts.onPick(best); }
    else this.setHover(best, true);
  };
  Scope.prototype.setHover = function (id, fromScope) {
    id = id === null || id === undefined ? null : String(id);
    if (this.hover === id) return;
    this.hover = id;
    if (fromScope && this.opts.onHover) this.opts.onHover(id);
    if (!this.running) this.draw(performance.now());
  };
  Scope.prototype.setSelected = function (id) {
    this.selected = id === null || id === undefined ? null : String(id);
    if (!this.running) this.draw(performance.now());
  };
  Scope.prototype.setAlert = function (a) {
    this.alert = a && a.id !== undefined && a.id !== null ? { id: String(a.id), level: a.level } : null;
  };

  /* ---------- drawing ---------- */
  Scope.prototype.draw = function (now) {
    var g = this.ctx, S = this.size, dpr = this.dpr;
    if (!S) return;
    var P = colours();
    var compact = !!this.opts.compact;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, S, S);

    var cx = S / 2, cy = S / 2;
    var edge = compact ? 16 : 20;            // room for the compass labels
    var R = S / 2 - edge;
    var rng = this.effectiveRange();
    var k = R / rng;
    var H = this.northUp || !this.self ? 0 : this.self.heading;
    var hr = H * D2R, ch = Math.cos(hr), sh = Math.sin(hr);

    // scope disc
    var bg = g.createRadialGradient(cx, cy, R * 0.1, cx, cy, R);
    bg.addColorStop(0, 'rgba(22,26,30,.78)');
    bg.addColorStop(1, 'rgba(8,10,12,.86)');
    g.beginPath(); g.arc(cx, cy, R, 0, TAU); g.fillStyle = bg; g.fill();

    // sweep (4 s per turn)
    var sweep = ((now - this.t0) / 4000 % 1) * TAU;
    g.save();
    g.beginPath(); g.arc(cx, cy, R, 0, TAU); g.clip();
    var slices = 18, span = 0.9;
    for (var s = 0; s < slices; s++) {
      var a1 = sweep - span * (s + 1) / slices, a0 = sweep - span * s / slices;
      g.beginPath(); g.moveTo(cx, cy);
      g.arc(cx, cy, R, a1 - Math.PI / 2, a0 - Math.PI / 2);
      g.closePath();
      g.fillStyle = 'rgba(255,255,255,' + (0.075 * (1 - s / slices)).toFixed(4) + ')';
      g.fill();
    }
    g.strokeStyle = 'rgba(255,255,255,.28)'; g.lineWidth = 1;
    g.beginPath(); g.moveTo(cx, cy); g.lineTo(cx + Math.sin(sweep) * R, cy - Math.cos(sweep) * R); g.stroke();
    g.restore();

    // range rings + labels
    g.lineWidth = 1;
    g.font = '600 ' + (compact ? 9 : 10) + 'px ' + P.font;
    g.textBaseline = 'middle';
    for (var ri = 1; ri <= 4; ri++) {
      var rr = R * ri / 4;
      g.beginPath(); g.arc(cx, cy, rr, 0, TAU);
      g.strokeStyle = ri === 4 ? 'rgba(255,255,255,.22)' : 'rgba(255,255,255,.085)';
      g.stroke();
      if (ri < 4 || !compact) {
        var lab = this.units.ring(rng * ri / 4);
        var la = 135 * D2R;     // lower-right diagonal, away from the N marker and the sweep start
        var lx = cx + Math.sin(la) * rr, ly = cy - Math.cos(la) * rr;
        g.textAlign = 'left';
        g.fillStyle = 'rgba(255,255,255,.42)';
        g.fillText(lab, lx + 4, ly + 6);
      }
    }
    // cross
    g.strokeStyle = 'rgba(255,255,255,.06)';
    g.beginPath(); g.moveTo(cx - R, cy); g.lineTo(cx + R, cy); g.moveTo(cx, cy - R); g.lineTo(cx, cy + R); g.stroke();

    // compass ticks + cardinal letters (rotate with heading-up)
    for (var deg = 0; deg < 360; deg += 10) {
      var sa = (deg - H) * D2R;
      var major = deg % 30 === 0;
      var r0 = R, r1 = R + (major ? 5 : 3);
      g.strokeStyle = major ? 'rgba(255,255,255,.35)' : 'rgba(255,255,255,.18)';
      g.beginPath();
      g.moveTo(cx + Math.sin(sa) * r0, cy - Math.cos(sa) * r0);
      g.lineTo(cx + Math.sin(sa) * r1, cy - Math.cos(sa) * r1);
      g.stroke();
    }
    var cards = [['N', 0], ['E', 90], ['S', 180], ['W', 270]];
    g.textAlign = 'center';
    g.font = '700 ' + (compact ? 10 : 11) + 'px ' + P.font;
    for (var ci = 0; ci < cards.length; ci++) {
      var ca = (cards[ci][1] - H) * D2R, cr = R + (compact ? 10 : 13);
      var tx = cx + Math.sin(ca) * cr, ty = cy - Math.cos(ca) * cr;
      if (cards[ci][0] === 'N') {
        // north marker: small filled triangle + bold N
        g.fillStyle = '#fff';
        g.fillText(this.labels.north || 'N', tx, ty);
        g.save(); g.translate(cx + Math.sin(ca) * (R - 7), cy - Math.cos(ca) * (R - 7)); g.rotate(ca);
        g.beginPath(); g.moveTo(0, -4); g.lineTo(3.5, 3); g.lineTo(-3.5, 3); g.closePath();
        g.fillStyle = 'rgba(255,255,255,.8)'; g.fill(); g.restore();
      } else {
        g.fillStyle = 'rgba(255,255,255,.45)';
        g.fillText(cards[ci][0], tx, ty);
      }
    }

    // contacts
    var me = this.selfAt(now);
    var hits = [];
    var pulse = (now % 1100) / 1100;
    var self = this;
    var items = [];
    this.tracks.forEach(function (tr) {
      if (self.filter && !self.filter(tr.c)) return;
      var p = self.trackAt(tr, now);
      var dx = p.x - me.x, dy = p.y - me.y;
      var dist = Math.sqrt(dx * dx + dy * dy);
      if (dist > rng * 1.04) return;
      var e = dx * ch - dy * sh, n = dx * sh + dy * ch;
      items.push({ tr: tr, p: p, x: cx + e * k, y: cy - n * k, dist: dist });
    });
    // draw far ones first so close / selected traffic sits on top
    items.sort(function (a, b) {
      var pa = self.priority(a.tr), pb = self.priority(b.tr);
      return pa !== pb ? pa - pb : b.dist - a.dist;
    });

    g.save();
    g.beginPath(); g.arc(cx, cy, R + 1, 0, TAU); g.clip();
    this.layoutTags(g, items, P, compact, cx, cy, R);
    for (var ii = 0; ii < items.length; ii++) this.drawContact(g, items[ii], H, pulse, P, compact, R);
    for (var ti = 0; ti < items.length; ti++) this.drawTag(g, items[ti], P);
    g.restore();
    for (var hi = 0; hi < items.length; hi++) hits.push({ id: items[hi].tr.id, x: items[hi].x, y: items[hi].y });
    this.hits = hits;

    // own ship
    g.save(); g.translate(cx, cy);
    if (this.self && this.self.inAircraft) {
      g.rotate(this.northUp ? this.self.heading * D2R : 0);
      g.beginPath();
      g.moveTo(0, -9); g.lineTo(6, 6); g.lineTo(0, 3); g.lineTo(-6, 6); g.closePath();
      g.fillStyle = '#fff'; g.shadowColor = 'rgba(0,0,0,.6)'; g.shadowBlur = 4; g.fill();
    } else {
      g.beginPath(); g.arc(0, 0, 4, 0, TAU); g.fillStyle = '#fff'; g.fill();
      g.beginPath(); g.arc(0, 0, 8, 0, TAU); g.strokeStyle = 'rgba(255,255,255,.45)'; g.lineWidth = 1.2; g.stroke();
    }
    g.restore();
  };

  Scope.prototype.priority = function (tr) {
    var c = tr.c, f = c.flags || {};
    if (tr.id === this.selected) return 5;
    if (tr.id === this.hover) return 4;
    if (c.threat === 'RA' || f.emergency) return 3;
    if (c.threat === 'TA') return 2;
    return 1;
  };

  function roundRect(g, x, y, w, h, r) {
    g.beginPath();
    g.moveTo(x + r, y); g.lineTo(x + w - r, y); g.quadraticCurveTo(x + w, y, x + w, y + r);
    g.lineTo(x + w, y + h - r); g.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    g.lineTo(x + r, y + h); g.quadraticCurveTo(x, y + h, x, y + h - r);
    g.lineTo(x, y + r); g.quadraticCurveTo(x, y, x + r, y); g.closePath();
  }
  function overlaps(a, list) {
    for (var i = 0; i < list.length; i++) {
      var b = list[i];
      if (a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y) return true;
    }
    return false;
  }

  Scope.prototype.drawContact = function (g, it, H, pulse, P, compact, R) {
    var tr = it.tr, c = tr.c, f = c.flags || {};
    var st = FR.contactStyle(c);
    var col = st.unknown ? P.unknown : P[st.key] || P.neutral;
    var x = it.x, y = it.y;
    var isSel = tr.id === this.selected, isHov = tr.id === this.hover;
    var alertLvl = this.alert && this.alert.id === tr.id ? this.alert.level : null;
    var threat = c.threat || alertLvl;

    // emergency: red pulsing ring
    if (f.emergency) {
      g.beginPath(); g.arc(x, y, 9 + pulse * 12, 0, TAU);
      g.strokeStyle = 'rgba(239,106,106,' + (0.85 * (1 - pulse)).toFixed(3) + ')';
      g.lineWidth = 2; g.stroke();
    }
    // TCAS: TA orange ring, RA red ring (thicker, pulsing)
    if (threat === 'TA' || threat === 'RA') {
      var tc = threat === 'RA' ? P.red : P.orange;
      g.beginPath(); g.arc(x, y, 12 + (threat === 'RA' ? pulse * 3 : 0), 0, TAU);
      g.strokeStyle = tc; g.lineWidth = threat === 'RA' ? 2.5 : 2; g.stroke();
      g.globalAlpha = 0.18; g.fillStyle = tc; g.fill(); g.globalAlpha = 1;
    }

    // velocity leader (where it will be in ~30 s), screen-rotated
    var sa = (tr.hdg - H) * D2R;
    var spd = Math.sqrt(tr.vx * tr.vx + tr.vy * tr.vy);
    if (!st.unknown && spd > 2) {
      var len = clamp(spd * 30 * (R / this.effectiveRange()), 6, compact ? 18 : 26);
      g.beginPath(); g.moveTo(x + Math.sin(sa) * 7, y - Math.cos(sa) * 7);
      g.lineTo(x + Math.sin(sa) * (7 + len), y - Math.cos(sa) * (7 + len));
      g.strokeStyle = col; g.globalAlpha = 0.55; g.lineWidth = 1.2; g.stroke(); g.globalAlpha = 1;
    }

    // symbol
    g.save(); g.translate(x, y);
    if (st.unknown) {
      g.beginPath(); g.arc(0, 0, 6.5, 0, TAU);
      g.fillStyle = 'rgba(40,42,46,.9)'; g.fill();
      g.strokeStyle = col; g.lineWidth = 1.4; g.setLineDash([2.5, 2]); g.stroke(); g.setLineDash([]);
      g.fillStyle = col; g.font = '700 9px ' + P.font; g.textAlign = 'center'; g.textBaseline = 'middle';
      g.fillText('?', 0, 0.5);
    } else {
      g.rotate(sa);
      var sz = compact ? 0.85 : 1;
      g.beginPath();
      g.moveTo(0, -7 * sz); g.lineTo(5.5 * sz, 6 * sz); g.lineTo(0, 3 * sz); g.lineTo(-5.5 * sz, 6 * sz); g.closePath();
      g.fillStyle = col; g.shadowColor = 'rgba(0,0,0,.65)'; g.shadowBlur = 3; g.fill();
    }
    g.restore();

    // selection / hover bracket
    if (isSel || isHov) {
      g.strokeStyle = isSel ? '#fff' : 'rgba(255,255,255,.55)';
      g.lineWidth = isSel ? 1.6 : 1.2;
      var b = 11, q = 4;
      g.beginPath();
      g.moveTo(x - b, y - b + q); g.lineTo(x - b, y - b); g.lineTo(x - b + q, y - b);
      g.moveTo(x + b - q, y - b); g.lineTo(x + b, y - b); g.lineTo(x + b, y - b + q);
      g.moveTo(x + b, y + b - q); g.lineTo(x + b, y + b); g.lineTo(x + b - q, y + b);
      g.moveTo(x - b + q, y + b); g.lineTo(x - b, y + b); g.lineTo(x - b, y + b - q);
      g.stroke();
    }
  };

  /* Data tags: placed most-important first (selected, hovered, RA / emergency, TA, then nearest),
     avoiding every symbol and every tag already placed; less important tags are dropped
     (symbol only) instead of overlapping. */
  Scope.prototype.layoutTags = function (g, items, P, compact, cx, cy, R) {
    var u = this.units, self = this;
    var order = items.slice().sort(function (a, b) {
      var pa = self.priority(a.tr), pb = self.priority(b.tr);
      return pa !== pb ? pb - pa : a.dist - b.dist;
    });
    var placed = [{ x: cx - 10, y: cy - 10, w: 20, h: 20 }];
    for (var i = 0; i < items.length; i++) placed.push({ x: items[i].x - 8, y: items[i].y - 8, w: 16, h: 16 });
    var fs1 = compact ? 10 : 11, fs2 = compact ? 9 : 10;
    for (var oi = 0; oi < order.length; oi++) {
      var it = order[oi], tr = it.tr, c = tr.c, f = c.flags || {};
      var st = FR.contactStyle(c);
      var l1 = st.unknown ? (this.labels.unident || 'UNIDENT') : String(c.callsign || '----').slice(0, 10);
      var l2 = st.unknown ? u.speed(c.speed) : (compact ? u.alt(c.alt) : u.alt(c.alt) + '  ' + u.speed(c.speed));
      var trend = u.trend(c.vs);
      if (!st.unknown && trend) l2 += trend > 0 ? ' \u2191' : ' \u2193';
      g.font = '700 ' + fs1 + 'px ' + P.font;
      var w1 = g.measureText(l1).width;
      g.font = '600 ' + fs2 + 'px ' + P.font;
      var w2 = g.measureText(l2).width;
      var tw = Math.ceil(Math.max(w1, w2) + 10), th = fs1 + fs2 + 8;
      var x = it.x, y = it.y;
      var cands = [
        [10, -th - 4], [10, 4], [-tw - 10, -th - 4], [-tw - 10, 4],
        [12, -th / 2], [-tw - 12, -th / 2], [-tw / 2, -th - 12], [-tw / 2, 12],
        [22, -th - 14], [-tw - 22, 14], [22, 14], [-tw - 22, -th - 14]
      ];
      var box = null;
      for (var ci = 0; ci < cands.length; ci++) {
        var bx = { x: x + cands[ci][0], y: y + cands[ci][1], w: tw, h: th };
        var fx = Math.max(Math.abs(bx.x - cx), Math.abs(bx.x + tw - cx));
        var fy = Math.max(Math.abs(bx.y - cy), Math.abs(bx.y + th - cy));
        if (Math.sqrt(fx * fx + fy * fy) > R - 2) continue;   // keep the whole tag inside the disc
        if (!overlaps(bx, placed)) { box = bx; break; }
      }
      var threat = c.threat || (this.alert && this.alert.id === tr.id ? this.alert.level : null);
      if (!box && (tr.id === this.selected || tr.id === this.hover)) box = { x: x + 10, y: y - th - 4, w: tw, h: th };
      it.tag = box ? { box: box, l1: l1, l2: l2, fs1: fs1, fs2: fs2, st: st, threat: threat } : null;
      if (box) placed.push(box);
    }
  };

  Scope.prototype.drawTag = function (g, it, P) {
    var t = it.tag; if (!t) return;
    var box = t.box, x = it.x, y = it.y, f = it.tr.c.flags || {};
    var isSel = it.tr.id === this.selected;
    var ax = clamp(x, box.x, box.x + box.w), ay = clamp(y, box.y, box.y + box.h);
    g.beginPath(); g.moveTo(x, y); g.lineTo(ax, ay);
    g.strokeStyle = 'rgba(255,255,255,.25)'; g.lineWidth = 1; g.stroke();
    roundRect(g, box.x, box.y, box.w, box.h, 5);
    g.fillStyle = isSel ? 'rgba(70,74,80,.92)' : 'rgba(10,12,14,.66)'; g.fill();
    if (f.emergency || t.threat) {
      g.strokeStyle = f.emergency || t.threat === 'RA' ? P.red : P.orange; g.lineWidth = 1; g.stroke();
    } else if (isSel) { g.strokeStyle = 'rgba(255,255,255,.6)'; g.lineWidth = 1; g.stroke(); }
    g.textAlign = 'left'; g.textBaseline = 'top';
    g.font = '700 ' + t.fs1 + 'px ' + P.font;
    g.fillStyle = f.emergency ? P.red : (t.st.unknown ? P.unknown : '#fff');
    g.fillText(t.l1, box.x + 5, box.y + 4);
    g.font = '600 ' + t.fs2 + 'px ' + P.font;
    g.fillStyle = 'rgba(255,255,255,.72)';
    g.fillText(t.l2, box.x + 5, box.y + 5 + t.fs1);
  };

  global.FR = FR;
})(window);
