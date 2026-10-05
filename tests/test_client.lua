-- Client smoke test: boots the client files with stubbed natives, then drives subscribe -> meta ->
-- contacts -> removal, the panel and the transponder request path. Run from repo root.
local H = dofile('tests/harness.lua')
local ok = H.ok

function IsDuplicityVersion() return false end

-- ===== client natives ================================================================================
local C = {
  ped = 1, veh = 0, class = 0, seat = {}, coords = vector3(0, 0, 0), heading = 0.0,
  blips = {}, nextBlip = 0, nui = {}, focus = false, server = {}, nuiCb = {}, commands = {}, keymaps = {},
  netEnts = {}, waypoint = nil, bags = {}, handlers = {},
}
function PlayerPedId() return C.ped end
function PlayerId() return 0 end
function NetworkIsPlayerActive() return true end
function GetVehiclePedIsIn() return C.veh end
function IsPedInAnyVehicle() return C.veh ~= 0 end
function GetVehicleClass() return C.class end
function GetPedInVehicleSeat(_, s) return C.seat[s] or 0 end
function DoesEntityExist(h) return h == C.ped or (h ~= 0 and (h == C.veh or C.netEnts[h] ~= nil)) end
function GetEntityCoords() return C.coords end
function GetEntityHeading() return C.heading end
function GetEntityVelocity() return vector3(0, 0, 0) end
function NetworkDoesNetworkIdExist(id) return C.netEnts[id + 100000] ~= nil end
function NetToVeh(id) return C.netEnts[id + 100000] and (id + 100000) or 0 end
function GetDisplayNameFromVehicleModel() return 'POLMAV' end
function GetLabelText() return 'Police Maverick' end
local function addBlip(kind, a)
  C.nextBlip = C.nextBlip + 1
  C.blips[C.nextBlip] = { kind = kind, target = a }
  return C.nextBlip
end
function AddBlipForCoord(x, y, z) return addBlip('coord', { x, y, z }) end
function AddBlipForEntity(e) return addBlip('entity', e) end
function DoesBlipExist(b) return C.blips[b] ~= nil end
function RemoveBlip(b)
  assert(C.blips[b], 'RemoveBlip on a stale handle')
  C.blips[b] = nil
end
function SetBlipCoords(b, x, y, z) if C.blips[b] then C.blips[b].pos = { x, y, z } end end
function SetBlipColour(b, c) if C.blips[b] then C.blips[b].colour = c end end
function SetBlipFlashes(b, on) if C.blips[b] then C.blips[b].flash = on end end
for _, n in ipairs({ 'SetBlipSprite', 'SetBlipScale', 'SetBlipAsShortRange', 'SetBlipAlpha', 'ShowHeadingIndicatorOnBlip',
  'SetBlipRotation', 'BeginTextCommandSetBlipName', 'AddTextComponentSubstringPlayerName', 'EndTextCommandSetBlipName',
  'BeginTextCommandThefeedPost', 'EndTextCommandThefeedPostTicker', 'PlaySoundFrontend', 'SetNuiFocusKeepInput' }) do
  _G[n] = function() end
end
function SendNUIMessage(m) C.nui[#C.nui + 1] = m end
function SetNuiFocus(a) C.focus = a end
function RegisterNUICallback(name, fn) C.nuiCb[name] = fn end
function RegisterCommand(name, fn) C.commands[name] = fn end
function RegisterKeyMapping(cmd, _, _, key) C.keymaps[cmd] = key end
function TriggerServerEvent(name, ...) C.server[#C.server + 1] = { name = name, args = table.pack(...) } end
function SetNewWaypoint(x, y) C.waypoint = { x, y } end
function AddStateBagChangeHandler(key, _, fn) C.handlers[key] = fn end
function GetEntityFromStateBagName() return C.veh end
function Entity(h)
  C.bags[h] = C.bags[h] or {}
  return { state = C.bags[h] }
end

local function lastServer(name)
  for i = #C.server, 1, -1 do if C.server[i].name == name then return C.server[i].args end end
end
local function lastNui(action)
  for i = #C.nui, 1, -1 do if C.nui[i].action == action then return C.nui[i] end end
end
local function blipCount() local n = 0 for _ in pairs(C.blips) do n = n + 1 end return n end
local function fromServer(name, ...) H.fromClient(name, '', ...) end

-- ===== boot ==========================================================================================
GlobalState = {}
-- minimal json.encode (the np_admin lib compares values with it); keys sorted for a stable result
local function enc(v)
  if type(v) ~= 'table' then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. '=' .. enc(v[k] ~= nil and v[k] or v[tonumber(k)]) end
  return '{' .. table.concat(out, ',') .. '}'
end
json = { encode = enc }
for _, f in ipairs({ 'config.lua', 'bridge/np_admin.lua', 'shared/np_admin_settings.lua', 'shared/locale.lua', 'locales/en.lua', 'locales/de.lua', 'shared/radarmath.lua',
  'shared/access.lua', 'integrations/registry.lua', 'bridge/client.lua', 'integrations/client.lua', 'client/blips.lua',
  'client/radar.lua', 'client/transponder.lua', 'client/proximity.lua', 'client/nui.lua', 'client/phone.lua', 'client/main.lua' }) do
  H.load(f)
end
TriggerEvent('onClientResourceStart', 'np_flightradar')
H.advance(100)

ok(C.keymaps.radar == 'F6', 'F6 key mapping')
ok(lastServer('np_flightradar:hello') ~= nil, 'hello sent on start')
ok(NpFR.Radar.sub == nil and #C.server == 1, 'not subscribed on foot')
for _, name in ipairs({ 'OpenRadar', 'CloseRadar', 'IsRadarOpen', 'GetContacts', 'GetTransponder', 'SetSquawk', 'useScanner' }) do
  ok(type(H.exports[name]) == 'function', 'export ' .. name)
end

-- ===== panel: /radar -> subscribe auto -> open ======================================================
C.commands.radar()
local sub = lastServer('np_flightradar:subscribe')
ok(sub and sub[1] == 'auto', '/radar subscribes with auto')
fromServer('np_flightradar:subscribed', { mode = 'ground', range = 12000, primary = false, reqId = sub[2] })
local open = lastNui('open')
ok(open and open.mode == 'ground' and open.focus == true and open.locale.title == 'Flight radar', 'panel opened')
ok(open.config.range == 12000 and open.config.units == 'aviation', 'open config')
ok(C.focus == true, 'mouse focus on foot')

-- ===== meta + contacts -> blips + NUI ================================================================
fromServer('np_flightradar:meta', {
  [11] = { kind = 'heli', model = 123, callsign = 'AIR-1', squawk = '7000', org = 'police', flags = { xpdrOff = false } },
  [12] = { kind = 'plane', model = 456, callsign = 'N12', squawk = '7700', flags = { emergency = '7700' } },
})
H.advance(600)
fromServer('np_flightradar:contacts', { t = 1, c = {
  { id = 11, x = 0, y = 1000, z = 200, h = 0, s = 400, vs = 0 },
  { id = 12, x = 1000, y = 0, z = 300, h = 90, s = 600, vs = -20 },
  { id = 13, x = 5, y = 5, z = 5, h = 0, s = 0, vs = 0 }, -- no meta: skipped
} })
ok(#NpFR.Radar.contacts == 2, 'contacts merged with meta')
ok(blipCount() == 2, 'one blip per contact')
local cts = lastNui('contacts')
ok(cts and #cts.contacts == 2 and cts.self and cts.range == 12000, 'NUI contacts pushed')
local c11
for _, c in ipairs(cts.contacts) do if c.id == 11 then c11 = c end end
ok(c11 and c11.bearing == 0 and c11.dist == 1000 and c11.speed == 40 and c11.model == 'Police Maverick', 'contact shape')
ok(c11.flags.org == 'police' and c11.squawk == '7000' and c11.kind == 'heli', 'contact flags')
local emerg
for _, b in pairs(C.blips) do if b.flash then emerg = b end end
ok(emerg and emerg.colour == 1, 'emergency blip red + flashing')

-- second update without 12 -> blip removed (no ghosts); 11 streamed in -> entity blip
C.netEnts[100011] = true
H.advance(600)
fromServer('np_flightradar:contacts', { t = 2, c = { { id = 11, x = 0, y = 960, z = 200, h = 0, s = 400, vs = 0 } } })
ok(blipCount() == 1, 'missing contact blip removed')
local only = select(2, next(C.blips))
ok(only.kind == 'entity', 'streamed-in aircraft uses an entity blip')
ok(NpFR.Radar.meta[12] == nil, 'meta of missing contact forgotten')

-- select -> waypoint
C.nuiCb.select({ id = 11 }, function() end)
ok(C.waypoint and C.waypoint[2] == 960, 'select sets waypoint')
-- setRange clamps to the granted range
C.nuiCb.setRange({ range = 50000 }, function() end)
ok(NpFR.NUI.range == 12000, 'setRange clamped')

-- ===== close -> unsubscribe + clear ==================================================================
C.commands.radar() -- focused -> close
ok(lastNui('close') ~= nil and C.focus == false, 'second /radar closes when focused')
ok(lastServer('np_flightradar:unsubscribe') ~= nil and blipCount() == 0, 'closed: unsubscribed, blips cleared')

-- ===== denied ========================================================================================
C.commands.radar()
sub = lastServer('np_flightradar:subscribe')
local nNui = #C.nui
fromServer('np_flightradar:denied', { mode = 'auto', reqId = sub[2] })
ok(#C.nui == nNui and not NpFR.NUI.open, 'denied: panel stays closed')
ok(NpFR.Radar.wanting('panel') == nil, 'denied wish dropped')

-- ===== aircraft: auto subscribe air, transponder ====================================================
C.veh, C.class = 500, 15
C.seat[-1] = C.ped
TriggerEvent('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 0, 500 })
H.advance(50)
sub = lastServer('np_flightradar:subscribe')
ok(sub and sub[1] == 'air', 'entering a heli subscribes air')
fromServer('np_flightradar:subscribed', { mode = 'air', range = 6000, primary = false, reqId = sub[2] })
ok(NpFR.Radar.sub and NpFR.Radar.sub.mode == 'air', 'air granted')
local x = NpFR.Xpdr.current()
ok(x and x.on and x.squawk == '7000' and x.canEdit, 'default transponder, pilot can edit')
C.commands.squawk(nil, { '7800' })
ok(lastServer('np_flightradar:setTransponder') == nil, 'invalid squawk not sent')
C.commands.squawk(nil, { '7700' })
local tx = lastServer('np_flightradar:setTransponder')
ok(tx and tx[1].squawk == '7700', '/squawk sends request')
C.commands.callsign(nil, { 'air', '2' })
ok(lastServer('np_flightradar:setTransponder')[1].callsign == 'AIR-2', '/callsign sanitised')
C.seat[-1] = nil
C.seat[1] = C.ped
ok(NpFR.Xpdr.current().canEdit == false, 'passenger cannot edit')

-- proximity: head-on traffic -> RA through the local event
C.seat[1], C.seat[-1] = nil, C.ped
local prox
AddEventHandler('np_flightradar:proximity', function(level) prox = level end)
fromServer('np_flightradar:meta', { [21] = { kind = 'plane', callsign = 'X1', squawk = '7000', flags = {} } })
fromServer('np_flightradar:contacts', { t = 3, c = { { id = 21, x = 0, y = 300, z = 0, h = 180, s = 500, vs = 0 } } })
H.advance(10)
ok(prox == 'RA', 'TCAS RA raised for head-on traffic')
ok(NpFR.Proximity.threatOf(21) == 'RA', 'threat stored per contact')

-- leaving the aircraft unsubscribes
C.veh, C.class = 0, 0
H.advance(1500)
ok(NpFR.Radar.sub == nil and lastServer('np_flightradar:unsubscribe') ~= nil, 'leaving the aircraft unsubscribes')
ok(prox == 'clear', 'TCAS cleared')
ok(blipCount() == 0, 'no blips left')

-- ===== phone =========================================================================================
TriggerEvent('np_phone:appState', 'flightradar', 'open')
sub = lastServer('np_flightradar:subscribe')
ok(sub and sub[1] == 'phone', 'phone app subscribes as phone')
TriggerEvent('np_phone:appState', 'flightradar', 'close')
ok(NpFR.Radar.wanting('phone') == nil, 'phone close drops the wish')

-- ===== review fixes ==================================================================================
do
  -- a second /radar while the request is unanswered cancels it (never stuck)
  C.commands.radar()
  ok(NpFR.Radar.wanting('panel') == 'auto', 'panel requested')
  C.commands.radar()
  ok(NpFR.Radar.wanting('panel') == nil, 'second press cancels the unanswered request')

  -- open, pick a range; a re-emitted subscription keeps it; a server-side update changes the grant
  C.commands.radar()
  sub = lastServer('np_flightradar:subscribe')
  fromServer('np_flightradar:subscribed', { mode = 'ground', range = 12000, primary = false, reqId = sub[2] })
  ok(NpFR.NUI.open and lastNui('open').config.key == 'F6', 'open carries the panel key')
  C.nuiCb.setRange({ range = 4000 }, function() end)
  TriggerEvent('np_phone:appState', 'flightradar', 'open') -- lower wish: re-emits 'subscribed'
  ok(NpFR.NUI.range == 4000, 'picked range survives a re-emitted subscription')
  local nOpen = 0 for _, m in ipairs(C.nui) do if m.action == 'open' then nOpen = nOpen + 1 end end
  fromServer('np_flightradar:subscribed', { mode = 'item', range = 4000, primary = false, reqId = sub[2], update = true })
  local o = lastNui('open')
  local nOpen2 = 0 for _, m in ipairs(C.nui) do if m.action == 'open' then nOpen2 = nOpen2 + 1 end end
  ok(NpFR.Radar.sub.mode == 'item' and nOpen2 == nOpen + 1 and o.mode == 'item' and o.config.range == 4000,
    'server update of the grant reaches the panel')

  -- revoked: only the panel wish goes, the phone app is asked for again
  local n = #C.server
  fromServer('np_flightradar:revoked', 'access_lost')
  ok(not NpFR.NUI.open and NpFR.Radar.wanting('phone') == 'phone', 'revoke keeps the phone wish')
  local again = lastServer('np_flightradar:subscribe')
  ok(#C.server > n and again[1] == 'phone', 'phone re-subscribes after the revoke')
  fromServer('np_flightradar:subscribed', { mode = 'phone', range = 8000, primary = false, reqId = again[2] })

  -- phone payload carries the units; a pocketed phone pauses the subscription
  local sent
  H.siblings.np_phone = { sendAppMessage = function(app, ev, data) sent = data end }
  H.resources.np_phone = 'started'
  fromServer('np_flightradar:meta', { [31] = { kind = 'heli', callsign = 'P1', squawk = '7000', flags = {} } })
  fromServer('np_flightradar:contacts', { t = 5, c = { { id = 31, x = 10, y = 10, z = 10, h = 0, s = 0, vs = 0 } } })
  ok(sent and sent.units == 'aviation' and #sent.contacts == 1, 'phone payload with units')
  TriggerEvent('np_phone:closed')
  ok(NpFR.Radar.wanting('phone') == nil and lastServer('np_flightradar:unsubscribe') ~= nil, 'phone put away: unsubscribed')
  TriggerEvent('np_phone:opened')
  ok(NpFR.Radar.wanting('phone') == 'phone', 'phone taken out: subscribed again')
  TriggerEvent('np_phone:appState', 'flightradar', 'close')
  H.resources.np_phone = nil

  -- air outranks phone; a denied first 'air' request (server has not seen the seat yet) is retried
  C.veh, C.class = 600, 16
  C.seat[-1] = C.ped
  TriggerEvent('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 0, 600 })
  H.advance(50)
  local a = lastServer('np_flightradar:subscribe')
  ok(a and a[1] == 'air', 'boarding requests air')
  fromServer('np_flightradar:denied', { mode = 'air', reqId = a[2] })
  ok(NpFR.Radar.wanting('air') == nil, 'air wish dropped on denial')
  H.advance(1600)
  local a2 = lastServer('np_flightradar:subscribe')
  ok(a2 and a2[1] == 'air' and a2[2] ~= a[2], 'air retried while still seated')
  fromServer('np_flightradar:subscribed', { mode = 'air', range = 6000, primary = false, reqId = a2[2] })
  TriggerEvent('np_phone:appState', 'flightradar', 'open')
  ok(NpFR.Radar.sub.mode == 'air' and NpFR.Radar.pending == nil, 'phone app does not replace the air subscription')
  TriggerEvent('np_phone:appState', 'flightradar', 'close')
  C.veh, C.class, C.seat[-1] = 0, 0, nil
  H.advance(1500)
end

-- ===== np_admin shared settings (GlobalState npcfg:np_flightradar) ==================================
do
  local handler = C.handlers['npcfg:np_flightradar']
  ok(type(handler) == 'function', 'np_admin settings bag handler registered')
  NpFR.Blips.list[-1] = { style = 'x' }
  handler('global', 'npcfg:np_flightradar', { ['Proximity.enabled'] = false, ['Blips.heli.scale'] = 1.2, ['Ranges.air'] = 1 })
  ok(Config.Proximity.enabled == false and Config.Blips.heli.scale == 1.2, 'shared settings applied on the client')
  ok(NpFR.Blips.list[-1].style == nil, 'blip change forces a restyle')
  handler('global', 'npcfg:np_flightradar', {})
  ok(Config.Proximity.enabled == true and Config.Blips.heli.scale == 0.8, 'cleared bag restores the defaults')
  NpFR.Blips.list[-1] = nil
end

-- ===== resource stop =================================================================================
TriggerEvent('onResourceStop', 'np_flightradar')
ok(blipCount() == 0 and C.focus == false, 'stop cleans up')

H.done('test_client')
