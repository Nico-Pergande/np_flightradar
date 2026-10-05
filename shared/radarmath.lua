-- Pure radar maths: no natives, no globals besides RadarMath. Loaded on both sides and unit tested
-- (tests/test_radarmath.lua).
--
-- Conventions
--   * world x = east, y = north, z = up (GTA world space), metres
--   * GTA headings (GetEntityHeading) turn counter-clockwise: 0 = north, 90 = west
--   * compass headings/bearings (what the NUI shows) turn clockwise: 0 = north, 90 = east
RadarMath = {}

local sqrt, floor, abs, atan, rad, sin, cos = math.sqrt, math.floor, math.abs, math.atan, math.rad, math.sin, math.cos

local function finite(n) return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge end
RadarMath.finite = finite

function RadarMath.round(n)
  if not finite(n) then return 0 end
  return floor(n + 0.5)
end

function RadarMath.clamp(n, lo, hi)
  if n < lo then return lo end
  if n > hi then return hi end
  return n
end

-- Horizontal distance
function RadarMath.dist2d(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  return sqrt(dx * dx + dy * dy)
end

function RadarMath.dist3d(ax, ay, az, bx, by, bz)
  local dx, dy, dz = bx - ax, by - ay, bz - az
  return sqrt(dx * dx + dy * dy + dz * dz)
end

-- Range check where 0 / nil means unlimited
function RadarMath.inRange(d, range)
  if not range or range <= 0 then return true end
  return d <= range
end

-- Normalise any angle to [0, 360)
function RadarMath.norm360(a)
  a = a % 360
  if a < 0 then a = a + 360 end
  return a
end

-- Compass bearing from A to B, clockwise from north, [0, 360)
function RadarMath.bearing(ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  if dx == 0 and dy == 0 then return 0 end
  return RadarMath.norm360(math.deg(atan(dx, dy)))
end

-- GTA heading (ccw) <-> compass heading (cw)
function RadarMath.compass(gtaHeading)
  return RadarMath.norm360(360 - (gtaHeading or 0))
end

-- Horizontal velocity of something flying along GTA heading `h` at ground speed `s`
function RadarMath.headingVelocity(h, s)
  local r = rad(h or 0)
  return -sin(r) * (s or 0), cos(r) * (s or 0)
end

-- Dead reckoning: position after dt seconds, dt clamped to [0, maxDt]
function RadarMath.deadReckon(x, y, z, vx, vy, vz, dt, maxDt)
  if not finite(dt) or dt < 0 then dt = 0 end
  if maxDt and dt > maxDt then dt = maxDt end
  return x + (vx or 0) * dt, y + (vy or 0) * dt, z + (vz or 0) * dt
end

-- Closest point of approach between own (p1, v1) and intruder (p2, v2), all 3D tables {x,y,z}.
-- Returns tCPA (s, >= 0), horizontal miss distance (m), vertical miss distance (m, signed:
-- intruder above = positive), current horizontal distance and current vertical offset.
function RadarMath.cpa(p1, v1, p2, v2)
  local rx, ry, rz = p2.x - p1.x, p2.y - p1.y, p2.z - p1.z
  local vx, vy, vz = (v2.x or 0) - (v1.x or 0), (v2.y or 0) - (v1.y or 0), (v2.z or 0) - (v1.z or 0)
  local vv = vx * vx + vy * vy
  local t = 0
  -- time of horizontal closest approach (vertical is judged at that moment)
  if vv > 1e-6 then
    t = -(rx * vx + ry * vy) / vv
    if t < 0 then t = 0 end
  end
  local mx, my, mz = rx + vx * t, ry + vy * t, rz + vz * t
  return t, sqrt(mx * mx + my * my), mz, sqrt(rx * rx + ry * ry), rz
end

-- TCAS-lite classification. cfg = { horizontal, vertical, lookahead }.
-- Returns 'RA' | 'TA' | nil. Already inside the box counts regardless of closure.
function RadarMath.threat(t, missH, missV, cfg)
  if not cfg then return nil end
  local h, v, look = cfg.horizontal or 600, cfg.vertical or 150, cfg.lookahead or 25
  if t > look then return nil end
  local av = abs(missV)
  if missH < h * 0.5 and av < v * 0.5 then return 'RA' end
  if missH < h and av < v then return 'TA' end
  return nil
end

-- ===== squawk / callsign ============================================================================

RadarMath.EMERGENCY = { ['7500'] = true, ['7600'] = true, ['7700'] = true }

-- Accepts '7000', 7000, ' 1200 '. Returns the normalised 4-digit octal string or nil.
function RadarMath.squawk(v)
  if math.type(v) == 'integer' then
    if v < 0 or v > 7777 then return nil end
    v = ('%04d'):format(v)
  end
  if type(v) ~= 'string' then return nil end
  v = v:match('^%s*(.-)%s*$')
  if #v ~= 4 or not v:match('^[0-7][0-7][0-7][0-7]$') then return nil end
  return v
end

-- '7500' | '7600' | '7700' | nil
function RadarMath.emergency(sq)
  if type(sq) == 'string' and RadarMath.EMERGENCY[sq] then return sq end
  return nil
end

-- Upper-cases, keeps [A-Z0-9-], collapses dashes, trims leading/trailing dashes, max `max` (8) chars.
function RadarMath.callsign(v, max)
  if type(v) == 'number' and finite(v) then v = tostring(math.tointeger(v) or v) end
  if type(v) ~= 'string' then return nil end
  max = max or 8
  local s = v:upper():gsub('%s+', '-'):gsub('[^A-Z0-9%-]', ''):gsub('%-%-+', '-'):gsub('^%-+', '')
  s = s:sub(1, max):gsub('%-+$', '')
  if s == '' then return nil end
  return s
end

-- ===== network packing ==============================================================================
-- Contacts travel as small integer tables: { id, x, y, z (m), h (GTA heading deg), s (ground speed
-- m/s * 10), vs (vertical speed m/s * 10) }.

function RadarMath.pack(netId, x, y, z, heading, vx, vy, vz)
  return {
    id = netId,
    x = RadarMath.round(x), y = RadarMath.round(y), z = RadarMath.round(z),
    h = RadarMath.round(RadarMath.norm360(heading or 0)) % 360,
    s = RadarMath.round(sqrt((vx or 0) ^ 2 + (vy or 0) ^ 2) * 10),
    vs = RadarMath.round((vz or 0) * 10),
  }
end

-- -> { id, x, y, z, h, speed (m/s), vs (m/s), vx, vy, vz } or nil when malformed
function RadarMath.unpack(c)
  if type(c) ~= 'table' then return nil end
  local id, x, y, z = c.id, c.x, c.y, c.z
  if not (finite(id) and finite(x) and finite(y) and finite(z)) then return nil end
  local h = finite(c.h) and c.h or 0
  local speed = (finite(c.s) and c.s or 0) / 10
  local vs = (finite(c.vs) and c.vs or 0) / 10
  local vx, vy = RadarMath.headingVelocity(h, speed)
  return { id = id, x = x + 0.0, y = y + 0.0, z = z + 0.0, h = h, speed = speed, vs = vs, vx = vx, vy = vy, vz = vs }
end

return RadarMath
