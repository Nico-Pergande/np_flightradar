-- Panel (html/index.html). Opens once the server granted a mode, pushes contacts at most 2 Hz and only
-- while open, claims np_hud's top-right zone while visible. /radar (F6): closed -> open, open without
-- mouse -> take mouse focus, focused -> close.
local N = { open = false, focused = false, mode = nil, range = 0, filter = { heli = true, plane = true, emergencyOnly = false }, lastPush = 0 }
NpFR.NUI = N

local PUSH_MS = 500

local function rangeSteps(granted)
  local out = {}
  for _, r in ipairs(Config.RangeSteps or {}) do
    if granted == 0 or (r > 0 and r <= granted) then out[#out + 1] = r end
  end
  if granted > 0 then
    local has = false
    for _, r in ipairs(out) do if r == granted then has = true end end
    if not has then out[#out + 1] = granted end
  end
  table.sort(out, function(a, b)
    if a == 0 then return false end
    if b == 0 then return true end
    return a < b
  end)
  return out
end

local function setFocus(on)
  N.focused = on and true or false
  SetNuiFocus(N.focused, N.focused)
  SetNuiFocusKeepInput(false)
end

function N.transponder()
  if not N.open then return end
  SendNUIMessage({ action = 'transponder', state = NpFR.Xpdr.current() })
end

function N.alert(level, text, id)
  if not N.open then return end
  SendNUIMessage({ action = 'alert', level = level, text = text, id = id })
end

function N.push(force)
  if not N.open then return end
  local now = GetGameTimer()
  if not force and now - N.lastPush < PUSH_MS then return end
  N.lastPush = now
  local p = NpFR.Radar.payload(N.range)
  p.action = 'contacts'
  SendNUIMessage(p)
end

local function panelKey() return (Config.Keys and Config.Keys.panel) or 'F6' end

-- Opens the panel, or (already open) follows a changed grant: new mode / range re-sends `open` with the
-- new range steps. The range the player picked survives a re-emitted subscription unless it no longer
-- fits the grant.
local function show(sub)
  local wasOpen, prevMode, prevGrant = N.open, N.mode, N.granted
  N.open, N.mode, N.granted = true, sub.mode, sub.range
  local changed = not wasOpen or prevMode ~= sub.mode or prevGrant ~= sub.range
  if changed then
    N.range = sub.range
    local focus = N.focused
    if not wasOpen then focus = not IsPedInAnyVehicle(PlayerPedId(), false) end
    SendNUIMessage({
      action = 'open', mode = sub.mode, focus = focus,
      locale = NpFR.locale(),
      config = {
        ranges = rangeSteps(sub.range), range = sub.range,
        units = Config.Units == 'metric' and 'metric' or 'aviation',
        canTransponder = (NpFR.Xpdr.current() or {}).canEdit == true,
        key = panelKey(),
      },
    })
    if not wasOpen then
      -- no ready callback: re-send the server theme (np_admin) in case the start-up sends beat the page
      if npAdmin then npAdmin.sendTheme() end
      setFocus(focus)
      NpFR.Client.claimZones(true)
    end
  end
  N.transponder()
  N.push(true)
end

function N.close()
  if not N.open then
    NpFR.Radar.want('panel', nil)
    return
  end
  N.open, N.mode, N.granted = false, nil, nil
  SendNUIMessage({ action = 'close' })
  setFocus(false)
  NpFR.Client.claimZones(false)
  NpFR.Radar.want('panel', nil)
end

-- mode: nil/'auto' = best granted, or 'item' (scanner)
function N.openWith(mode)
  NpFR.Radar.want('panel', mode or 'auto')
end

function N.toggle(mode)
  if not N.open then
    -- a second press while the request is still unanswered cancels it (never stuck on a lost reply)
    if NpFR.Radar.wanting('panel') then NpFR.Radar.want('panel', nil) return end
    N.openWith(mode)
  elseif not N.focused then
    setFocus(true)
    SendNUIMessage({ action = 'focus', on = true })
  else
    N.close()
  end
end

NpFR.Radar.on(function(kind, data)
  if kind == 'subscribed' then
    if NpFR.Radar.wanting('panel') and data and (data.source == 'panel') then show(data) end
  elseif kind == 'denied' then
    if data and data.source == 'panel' then
      NpFR.Client.notify({ type = 'error', message = L('no_access') })
    end
  elseif kind == 'revoked' or kind == 'unsubscribed' then
    if N.open then N.close() end
  elseif kind == 'contacts' then
    N.push(false)
  end
end)

-- ===== NUI callbacks (always answer { ok = true }) ==================================================

local function reply(cb) cb({ ok = true }) end

RegisterNUICallback('close', function(_, cb)
  reply(cb)
  N.close()
end)

RegisterNUICallback('focus', function(body, cb)
  reply(cb)
  if N.open then setFocus(type(body) == 'table' and body.on == true) end
end)

RegisterNUICallback('setRange', function(body, cb)
  reply(cb)
  local r = type(body) == 'table' and tonumber(body.range)
  if not r or r < 0 then return end
  local granted = (NpFR.Radar.sub and NpFR.Radar.sub.range) or 0
  if granted > 0 and (r == 0 or r > granted) then r = granted end
  N.range = math.floor(r)
  N.push(true)
end)

RegisterNUICallback('setFilter', function(body, cb)
  reply(cb)
  if type(body) ~= 'table' then return end
  N.filter = { heli = body.heli ~= false, plane = body.plane ~= false, emergencyOnly = body.emergencyOnly == true }
end)

RegisterNUICallback('transponder', function(body, cb)
  reply(cb)
  if type(body) ~= 'table' then return end
  NpFR.Xpdr.request({ on = body.on, squawk = body.squawk, callsign = body.callsign })
end)

RegisterNUICallback('select', function(body, cb)
  reply(cb)
  local id = type(body) == 'table' and math.tointeger(tonumber(body.id))
  local c = id and NpFR.Radar.byId[id]
  if not c then return end
  SetNewWaypoint(c.x + 0.0, c.y + 0.0)
  NpFR.Client.notify({ type = 'info', message = L('waypoint_set', c.callsign or L('unidentified')), icon = 'location-dot' })
end)

-- ===== key mapping ==================================================================================

local cmd = (Config.Commands and Config.Commands.radar) or 'radar'
RegisterCommand(cmd, function() N.toggle() end, false)
RegisterKeyMapping(cmd, L('cmd_radar'), 'keyboard', panelKey())

AddEventHandler('onResourceStop', function(res)
  if res ~= GetCurrentResourceName() then return end
  if N.focused then SetNuiFocus(false, false) end
  NpFR.Client.claimZones(false)
end)
