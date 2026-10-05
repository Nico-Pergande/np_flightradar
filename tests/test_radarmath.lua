-- Run from repo root: lua tests/test_radarmath.lua
dofile('shared/radarmath.lua')

local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; print('FAIL: ' .. name) end
end
local function near(a, b, eps) return type(a) == 'number' and math.abs(a - b) <= (eps or 1e-6) end
local R = RadarMath

-- ===== distance ======================================================================================
ok(near(R.dist2d(0, 0, 3, 4), 5), 'dist2d 3-4-5')
ok(near(R.dist3d(0, 0, 0, 1, 2, 2), 3), 'dist3d 1-2-2')
ok(R.inRange(10000, 0) and R.inRange(10000, nil), 'range 0/nil is unlimited')
ok(R.inRange(500, 500) and not R.inRange(501, 500), 'range boundary inclusive')

-- ===== bearing / headings ============================================================================
ok(near(R.bearing(0, 0, 0, 10), 0), 'north = 0')
ok(near(R.bearing(0, 0, 10, 0), 90), 'east = 90')
ok(near(R.bearing(0, 0, 0, -10), 180), 'south = 180')
ok(near(R.bearing(0, 0, -10, 0), 270), 'west = 270')
ok(near(R.bearing(0, 0, 10, 10), 45), 'north-east = 45')
ok(R.bearing(5, 5, 5, 5) == 0, 'same point = 0')
ok(near(R.compass(90), 270), 'GTA 90 (west) = compass 270')
ok(near(R.compass(0), 0) and near(R.compass(270), 90), 'GTA 0 / 270')
ok(near(R.norm360(-30), 330) and near(R.norm360(720), 0), 'norm360')
do
  local vx, vy = R.headingVelocity(90, 10) -- GTA 90 = west
  ok(near(vx, -10) and near(vy, 0, 1e-9), 'heading velocity west')
  vx, vy = R.headingVelocity(0, 10)
  ok(near(vx, 0, 1e-9) and near(vy, 10), 'heading velocity north')
end

-- ===== dead reckoning ================================================================================
do
  local x, y, z = R.deadReckon(0, 0, 100, 10, -5, 2, 2)
  ok(near(x, 20) and near(y, -10) and near(z, 104), 'dead reckoning 2 s')
  x = R.deadReckon(0, 0, 0, 10, 0, 0, 5, 1.5)
  ok(near(x, 15), 'dead reckoning clamped to maxDt')
  x = R.deadReckon(0, 0, 0, 10, 0, 0, -3, 1.5)
  ok(near(x, 0), 'negative dt -> 0')
  x = R.deadReckon(0, 0, 0, 10, 0, 0, 0 / 0, 1.5)
  ok(near(x, 0), 'NaN dt -> 0')
end

-- ===== CPA / threat ==================================================================================
do
  -- head-on, 1000 m apart, closing at 100 m/s, same altitude: CPA in 10 s, miss 0
  local t, mh, mv, d = R.cpa({ x = 0, y = 0, z = 100 }, { x = 0, y = 50, z = 0 },
    { x = 0, y = 1000, z = 100 }, { x = 0, y = -50, z = 0 })
  ok(near(t, 10) and near(mh, 0) and near(mv, 0) and near(d, 1000), 'head-on CPA')
  ok(R.threat(t, mh, mv, { horizontal = 600, vertical = 150, lookahead = 25 }) == 'RA', 'head-on is RA')

  -- parallel offset 400 m, intruder 100 m above, closing: TA (inside box, not inside half box)
  t, mh, mv = R.cpa({ x = 0, y = 0, z = 100 }, { x = 0, y = 50, z = 0 },
    { x = 400, y = 1000, z = 200 }, { x = 0, y = -50, z = 0 })
  ok(near(mh, 400) and near(mv, 100), 'offset CPA miss distances')
  ok(R.threat(t, mh, mv, { horizontal = 600, vertical = 150, lookahead = 25 }) == 'TA', 'offset is TA')

  -- diverging: t clamps to 0, current geometry decides
  t, mh = R.cpa({ x = 0, y = 0, z = 0 }, { x = 0, y = -50, z = 0 }, { x = 0, y = 2000, z = 0 }, { x = 0, y = 50, z = 0 })
  ok(t == 0 and near(mh, 2000), 'diverging t = 0')
  ok(R.threat(t, mh, 0, { horizontal = 600, vertical = 150, lookahead = 25 }) == nil, 'diverging no threat')

  -- far away in time
  ok(R.threat(60, 0, 0, { horizontal = 600, vertical = 150, lookahead = 25 }) == nil, 'beyond lookahead')
  -- same velocity, close: t = 0, inside box
  t, mh, mv = R.cpa({ x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 }, { x = 100, y = 0, z = 50 }, { x = 10, y = 0, z = 0 })
  ok(t == 0 and near(mh, 100) and near(mv, 50), 'formation flight')
  ok(R.threat(t, mh, mv, { horizontal = 600, vertical = 150, lookahead = 25 }) == 'RA', 'formation inside half box = RA')
  ok(R.threat(5, 100, -200, { horizontal = 600, vertical = 150, lookahead = 25 }) == nil, 'vertical separation clears')
end

-- ===== squawk ========================================================================================
ok(R.squawk('7000') == '7000', 'squawk string')
ok(R.squawk(' 1200 ') == '1200', 'squawk trimmed')
ok(R.squawk(7700) == '7700', 'squawk integer')
ok(R.squawk(17) == '0017', 'squawk integer padded')
ok(R.squawk('7800') == nil, '8 is not octal')
ok(R.squawk('700') == nil and R.squawk('70000') == nil, 'length 4 only')
ok(R.squawk('7a00') == nil and R.squawk(nil) == nil and R.squawk({}) == nil, 'junk rejected')
ok(R.squawk(7000.5) == nil and R.squawk(-1) == nil and R.squawk(99999) == nil, 'bad numbers rejected')
ok(R.emergency('7500') == '7500' and R.emergency('7600') == '7600' and R.emergency('7700') == '7700', 'emergency codes')
ok(R.emergency('7000') == nil and R.emergency(nil) == nil and R.emergency(7700) == nil, 'non-emergency')

-- ===== callsign ======================================================================================
ok(R.callsign('n123ab') == 'N123AB', 'callsign upper-cased')
ok(R.callsign('Air 1') == 'AIR-1', 'spaces become dashes')
ok(R.callsign('<b>x</b>') == 'BXB', 'markup stripped')
ok(R.callsign('ABCDEFGHIJK') == 'ABCDEFGH', 'max 8')
ok(R.callsign('ABCDEFG-X') == 'ABCDEFG', 'trailing dash after cut trimmed')
ok(R.callsign('--a--b--') == 'A-B', 'dashes collapsed and trimmed')
ok(R.callsign('ÄÖÜ') == nil and R.callsign('') == nil and R.callsign('   ') == nil, 'empty -> nil')
ok(R.callsign(nil) == nil and R.callsign({}) == nil, 'non-string -> nil')
ok(R.callsign(42) == '42', 'number accepted')
ok(R.callsign('abcdefghijkl', 12) == 'ABCDEFGHIJKL', 'custom max')

-- ===== pack / unpack =================================================================================
do
  local p = R.pack(77, 100.4, -200.6, 50.5, 359.7, 30, 40, -2.34)
  ok(p.id == 77 and p.x == 100 and p.y == -201 and p.z == 51, 'pack rounds coords')
  ok(p.h == 0, 'pack heading wraps 360 -> 0')
  ok(p.s == 500 and p.vs == -23, 'pack speed * 10')
  for _, k in ipairs({ 'x', 'y', 'z', 'h', 's', 'vs' }) do ok(math.type(p[k]) == 'integer', 'packed ' .. k .. ' is integer') end
  local u = R.unpack(p)
  ok(u.id == 77 and near(u.speed, 50) and near(u.vs, -2.3), 'unpack speeds')
  ok(near(u.vx, 0, 1e-9) and near(u.vy, 50), 'unpack velocity from heading')
  ok(R.unpack(nil) == nil and R.unpack({ id = 1, x = 0, y = 0 }) == nil, 'unpack rejects missing fields')
  ok(R.unpack({ id = 1, x = 0 / 0, y = 0, z = 0 }) == nil, 'unpack rejects NaN')
  local u2 = R.unpack({ id = 1, x = 1, y = 2, z = 3 })
  ok(u2 and u2.speed == 0 and u2.h == 0, 'unpack defaults')
  ok(R.pack(1, 0 / 0, 0, 0, nil).x == 0, 'pack NaN -> 0')
end

print(('test_radarmath: %d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
