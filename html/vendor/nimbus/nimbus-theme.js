/* Nimbus UI · NimbusTheme
   Turns ONE server colour into the full brand ramp and writes it as CSS vars.
   Done in JS (not CSS color-mix/relative colours) so it works in older CEF builds.

   NimbusTheme.apply({ brand: '#4f7bff', strength: 'accent' | 'tiles' | 'glass', material?: 'frosted' | 'liquid' })
   NimbusTheme.material('liquid' | 'frosted')   // optional Liquid material (needs css/liquid.css), default frosted
   NimbusTheme.reset()                          // clears the brand; the material is a separate (player) choice
   FiveM: SendNUIMessage({ action = 'theme', data = { brand = '#4f7bff', strength = 'tiles', material = 'liquid' } })
*/
(function (global) {
  'use strict';
  var STRENGTHS = { accent: 1, tiles: 1, glass: 1 };
  var MATERIALS = { frosted: 1, liquid: 1 };

  function hexToRgb(hex) {
    var h = String(hex).replace('#', '').trim();
    if (h.length === 3) h = h.replace(/./g, '$&$&');
    if (!/^[0-9a-f]{6}$/i.test(h)) throw new Error('NimbusTheme: invalid colour ' + hex);
    var n = parseInt(h, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function mix(a, b, t) { return [0, 1, 2].map(function (i) { return Math.round(a[i] + (b[i] - a[i]) * t); }); }
  function hex(c) { return '#' + c.map(function (v) { return ('0' + v.toString(16)).slice(-2); }).join(''); }
  function rgba(c, a) { return 'rgba(' + c.join(',') + ',' + a + ')'; }
  function lum(c) {
    var s = c.map(function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * s[0] + 0.7152 * s[1] + 0.0722 * s[2];
  }
  function contrastWithWhite(c) { return 1.05 / (lum(c) + 0.05); }

  var WHITE = [255, 255, 255], BLACK = [0, 0, 0];

  function ramp(brandHex) {
    var b = hexToRgb(brandHex);
    // Tile body must carry a white glyph: darken until ≥ 3:1 against white.
    var mid = b, t = 0;
    while (contrastWithWhite(mid) < 3 && t < 0.6) { t += 0.04; mid = mix(b, BLACK, t); }
    var top = mix(mid, WHITE, 0.38);
    var bot = mix(mid, BLACK, 0.28);
    var accent = mix(b, WHITE, 0.22);           // bright, for bars on dark glass
    return {
      '--nb-brand': hex(b),
      '--nb-brand-top': hex(top),
      '--nb-brand-mid': hex(mid),
      '--nb-brand-bot': hex(bot),
      '--nb-brand-accent': hex(accent),
      '--nb-brand-glow': rgba(accent, 0.55),
      '--nb-grad-brand': 'linear-gradient(180deg,' + hex(top) + ' 0%,' + hex(mid) + ' 45%,' + hex(bot) + ' 100%)',
      '--nb-fill-brand': 'linear-gradient(180deg,' + hex(mix(accent, WHITE, 0.2)) + ',' + hex(mid) + ')',
      '--nb-brand-glass-top': rgba(mix([110, 110, 110], b, 0.16), 0.62),
      '--nb-brand-glass-bot': rgba(mix([48, 48, 48], b, 0.12), 0.70),
      '--nb-brand-glass-edge': rgba(mix(WHITE, b, 0.35), 0.16),
      '--nb-brand-liquid-top': rgba(mix([92, 92, 98], b, 0.18), 0.34),
      '--nb-brand-liquid-bot': rgba(mix([34, 34, 38], b, 0.12), 0.46)
    };
  }

  function target(el) { return el || document.querySelector('.nb-ui') || document.body; }

  var NimbusTheme = {
    ramp: ramp,
    apply: function (opts) {
      opts = opts || {};
      var el = target(opts.el);
      if (opts.material) NimbusTheme.material(opts.material, el);
      if (!opts.brand) return NimbusTheme.reset(el);
      var vars = ramp(opts.brand);
      Object.keys(vars).forEach(function (k) { el.style.setProperty(k, vars[k]); });
      el.setAttribute('data-nb-brand', vars['--nb-brand']);
      el.setAttribute('data-nb-strength', STRENGTHS[opts.strength] ? opts.strength : 'accent');
      return vars;
    },
    /** 'liquid' opts into css/liquid.css; anything else (or 'frosted') is the default look. */
    material: function (name, el) {
      el = target(el);
      if (name === 'liquid') el.setAttribute('data-nb-material', 'liquid');
      else el.removeAttribute('data-nb-material');
      return MATERIALS[name] ? name : 'frosted';
    },
    reset: function (el) {
      el = target(el);
      Object.keys(ramp('#888888')).forEach(function (k) { el.style.removeProperty(k); });
      el.removeAttribute('data-nb-brand');
      el.removeAttribute('data-nb-strength');
    }
  };

  global.addEventListener('message', function (e) {
    var m = e.data;
    if (m && m.action === 'theme') NimbusTheme.apply(m.data || {});
  });
  global.NimbusTheme = NimbusTheme;
})(window);
