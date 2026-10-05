-- np_phone app: subscribe as 'phone' while the Flightradar app is open and forward every update with
-- exports.np_phone:sendAppMessage('flightradar', 'contacts', payload) (same shape as the NUI contacts).
-- np_phone keeps an app mounted while the phone is put away; the subscription pauses meanwhile
-- (np_phone:closed / np_phone:opened), so a pocketed phone costs the server nothing.
local Ph = { open = false, phoneVisible = true }
NpFR.Phone = Ph

local APP = 'flightradar'

local function sync()
  NpFR.Radar.want('phone', (Ph.open and Ph.phoneVisible) and 'phone' or nil)
end

AddEventHandler('np_phone:appState', function(appId, state)
  if appId ~= APP or (Config.Phone and Config.Phone.enabled == false) then return end
  Ph.open = state == 'open'
  if Ph.open then Ph.phoneVisible = true end
  sync()
end)

AddEventHandler('np_phone:closed', function() Ph.phoneVisible = false sync() end)
AddEventHandler('np_phone:opened', function() Ph.phoneVisible = true sync() end)

NpFR.Radar.on(function(kind, data)
  if not Ph.open then return end
  if kind == 'contacts' then
    local s = NpFR.Radar.sub
    local p = NpFR.Radar.payload(s and s.range or 0)
    p.mode = s and s.mode or nil
    p.units = Config.Units == 'metric' and 'metric' or 'aviation'
    NpFR.Client.phoneSend('contacts', p)
  elseif kind == 'denied' and data and data.source == 'phone' then
    NpFR.Client.phoneSend('contacts', { self = nil, range = 0, contacts = {}, denied = true })
  end
end)

AddEventHandler('onResourceStop', function(res)
  if res == 'np_phone' and Ph.open then
    Ph.open = false
    NpFR.Radar.want('phone', nil)
  end
end)
