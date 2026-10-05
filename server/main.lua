-- Net events, lifecycle and start-up. Every client request is validated and rate-limited; the mode a
-- client asks for is only a wish: server/access.lua decides what it actually gets.
local B, A, R, S = NpFR.Broadcast, NpFR.Access, NpFR.Registry, NpFR.Server

local function reqIdOf(v)
  local n = math.tointeger(tonumber(v) or 0)
  if not n or n < 0 or n > 2 ^ 31 then return 0 end
  return n
end

-- Rate limit: at most one subscription change per 250 ms per player. Requests inside the window are
-- coalesced (latest wins) and answered when it ends, so the client always gets a reply.
local SUB_MS = 250
local deferred = {} -- [src] = { mode, reqId } | false (unsubscribe)

local function handleSub(src, req)
  if req then B.subscribe(src, req.mode, req.reqId) else B.unsubscribe(src) end
end

local function request(src, req)
  if deferred[src] ~= nil then deferred[src] = req return end
  if Bridge.throttle(src, 'sub', SUB_MS) then handleSub(src, req) return end
  deferred[src] = req
  SetTimeout(SUB_MS, function()
    local latest = deferred[src]
    deferred[src] = nil
    if latest == nil or not Bridge.validSrc(src) then return end
    Bridge.throttle(src, 'sub', 0)
    handleSub(src, latest)
  end)
end

RegisterNetEvent('np_flightradar:subscribe', function(mode, reqId)
  local src = source
  if not Bridge.validSrc(src) then return end
  if mode ~= 'auto' and not Access.VALID[mode] then return end
  request(src, { mode = mode, reqId = reqIdOf(reqId) })
end)

RegisterNetEvent('np_flightradar:unsubscribe', function()
  local src = source
  if not Bridge.validSrc(src) then return end
  request(src, false)
end)

-- Client asks for its access summary (start-up, spawn, radial)
RegisterNetEvent('np_flightradar:hello', function()
  local src = source
  if not Bridge.validSrc(src) then return end
  if not Bridge.throttle(src, 'hello', 2000) then return end
  A.push(src)
end)

AddEventHandler('playerDropped', function()
  deferred[source] = nil
  B.unsubscribe(source)
end)

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  for src in pairs(B.subs) do B.subs[src] = nil end
  B.count = 0
end)

CreateThread(function()
  R.start()
  print(('^2[np_flightradar] v%s: %d aircraft tracked^0'):format(
    GetResourceMetadata(GetCurrentResourceName(), 'version', 0) or '1.0.0', R.count))
  if GetConvar('onesync', 'off') == 'off' then
    NpFR.warn('OneSync is off: the flight radar needs OneSync (set onesync on)')
  end
  NpFR.Integration.print()
end)
