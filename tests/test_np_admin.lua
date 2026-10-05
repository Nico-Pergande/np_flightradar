-- np_admin integration: NpAdmin.can delegation + fallback, registered nodes / settings / actions, live
-- settings, log forwarding. A fake np_admin resource answers the lib's exports. Run from repo root.
local H = dofile('tests/harness.lua')
local ok = H.ok

-- ===== ESX stub (as in test_server.lua) ==============================================================
local jobs, groups = {}, {}
local ESX = {
  GetPlayerFromId = function(src)
    if not H.players[src] then return nil end
    return {
      getJob = function() return jobs[src] or { name = 'unemployed', grade = 0 } end,
      getGroup = function() return groups[src] or 'user' end,
      getInventoryItem = function(name) return { name = name, count = 0 } end,
    }
  end,
  RegisterUsableItem = function() end,
}
H.resources.es_extended = 'started'
H.siblings.es_extended = { getSharedObject = function() return ESX end }

-- ===== fake np_admin =================================================================================
local NA = { perms = {}, nodes = nil, settings = nil, actions = {}, logs = {}, fail = false }
H.siblings.np_admin = {
  can = function(src, node)
    if NA.fail then error('np_admin broke') end
    return NA.perms[src] and NA.perms[src][node] == true or false
  end,
  registerPermissions = function(res, list) NA.nodes = { res = res, list = list } end,
  registerSettings = function(res, schema) NA.settings = { res = res, schema = schema } return NA.overrides end,
  registerAction = function(def) NA.actions[def.name] = def end,
  log = function(category, entry) NA.logs[#NA.logs + 1] = { category = category, entry = entry } end,
}
H.resources.np_admin = 'started'
NA.overrides = { ['Ranges.item'] = 3000 } -- a value saved in np_admin before this resource started

H.addPlayer(1)                                         -- civilian
H.addPlayer(2, { ids = { 'license:staff2' } })         -- np_admin staff
H.addPlayer(3, { ids = { 'license:conv3' } })          -- listed in the convar
H.addPlayer(4)                                         -- ESX admin group
H.addPlayer(5, { ids = { 'license:cfg5' } })           -- Config.Admin.identifiers
H.addPlayer(6)                                         -- pilot
groups[4] = 'admin'
H.convars.np_admin_fallback = 'license:conv3, discord:1'

H.boot({ config = function(c) c.Admin.identifiers = { 'license:cfg5' } end })
local B, A = NpFR.Broadcast, NpFR.Access

-- ===== registration with np_admin running ============================================================
do
  ok(NA.nodes and NA.nodes.res == 'np_flightradar', 'permissions registered for the resource')
  local set = {}
  for _, n in ipairs(NA.nodes.list) do set[n.node] = n end
  ok(set['np_flightradar.admin'] and set['np_flightradar.ground'] and #NA.nodes.list == 2, 'nodes admin + ground')
  ok(set['np_flightradar.admin'].label and set['np_flightradar.admin'].category == 'Flight radar', 'node label + category')
  ok(NA.actions['np_flightradar.open'] and NA.actions['np_flightradar.transponder'], 'staff actions registered')
  ok(NA.actions['np_flightradar.transponder'].perm == 'np_flightradar.admin'
    and NA.actions['np_flightradar.transponder'].target == 'player', 'transponder action perm + target')
  ok(Config.Ranges.item == 3000, 'override from np_admin applied at registration')
end

-- ===== settings schema ===============================================================================
do
  local schema = NA.settings and NA.settings.schema
  ok(schema and NA.settings.res == 'np_flightradar', 'settings registered')
  local TYPES = { toggle = 1, number = 1, slider = 1, select = 1, multiselect = 1, text = 1, textarea = 1, color = 1,
    list = 1, keybind = 1, coords = 1, secret = 1, json = 1 }
  local cats = {}
  for _, c in ipairs(schema.categories) do cats[c] = true end
  local n, seen, bad = #schema.fields, {}, {}
  for _, f in ipairs(schema.fields) do
    local why
    if seen[f.key] then why = 'duplicate' end
    seen[f.key] = true
    if NpAdmin.getPath(Config, f.key) == nil and f.key ~= 'Emergency.discordChannel' then why = 'key missing in Config' end
    if not TYPES[f.type] then why = 'type' end
    if f.apply ~= 'live' and f.apply ~= 'reload' and f.apply ~= 'restart' then why = 'apply' end
    if f.scope ~= 'shared' and f.scope ~= 'server' then why = 'scope' end
    if not cats[f.category] then why = 'category' end
    if not f.label then why = 'label' end
    local d = f.default
    if type(d) == 'function' or (type(d) == 'table' and getmetatable(d)) then why = 'function / vector default' end
    if (f.type == 'select') then
      local found = false
      for _, o in ipairs(f.options) do if (type(o) == 'table' and o.value or o) == d then found = true end end
      if not found then why = 'default not an option' end
    end
    if f.type == 'number' and type(d) == 'number' and f.step then
      local k = (d - (f.min or 0)) / f.step
      if math.abs(k - math.floor(k + 0.5)) > 1e-6 or (f.min and d < f.min) or (f.max and d > f.max) then why = 'default off step / range' end
    end
    if why then bad[#bad + 1] = f.key .. ': ' .. why end
  end
  ok(n >= 10 and n <= 40, 'between 10 and 40 settings (' .. n .. ')')
  ok(#bad == 0, 'schema valid ' .. table.concat(bad, ', '))
end

-- ===== NpAdmin.can delegates while np_admin runs =====================================================
do
  NA.perms[2] = { ['np_flightradar.admin'] = true }
  ok(Bridge.isAdmin(2) == true, 'np_admin grants admin')
  ok(Bridge.isAdmin(4) == false, 'ESX admin group ignored while np_admin decides')
  ok(Bridge.isAdmin(5) == false, 'Config.Admin ignored while np_admin decides')
  ok(Bridge.isAdmin(3) == false, 'convar ignored while np_admin decides')
  NA.fail = true
  ok(Bridge.isAdmin(2) == false, 'failing export denies (no fallback bypass)')
  NA.fail = false

  H.fromClient('np_flightradar:subscribe', 2, 'admin', 1)
  ok(B.subs[2] and B.subs[2].mode == 'admin' and B.subs[2].primary, 'staff gets the admin radar')
  H.fromClient('np_flightradar:subscribe', 1, 'ground', 1)
  ok(B.subs[1] == nil, 'civilian denied ground')
  H.advance(300)
  NA.perms[1] = { ['np_flightradar.ground'] = true }
  local mark = #H.clientEvents
  TriggerEvent('np_admin:permissionsChanged', 1)
  ok(H.lastClient('np_flightradar:access', 1, mark) ~= nil, 'permissionsChanged pushes a new access summary')
  ok(H.lastClient('np_flightradar:access', 1, mark)[1].modes.ground == true, 'ground node shows in the summary')
  H.fromClient('np_flightradar:subscribe', 1, 'ground', 2)
  ok(B.subs[1] and B.subs[1].mode == 'ground' and B.subs[1].range == 12000, 'ground node grants the ground radar')

  -- revoked in np_admin -> subscription dropped
  NA.perms[2] = {}
  mark = #H.clientEvents
  TriggerEvent('np_admin:permissionsChanged', 2)
  ok(B.subs[2] == nil and H.lastClient('np_flightradar:revoked', 2, mark) ~= nil, 'revoked node drops the admin radar')
end

-- ===== live settings ================================================================================
do
  H.invoking = 'np_admin'
  TriggerEvent('np_admin:settingsChanged', 'np_flightradar', { ['Ranges.ground'] = 5000 })
  H.invoking = nil
  ok(Config.Ranges.ground == 5000, 'settingsChanged applied')
  ok(B.subs[1] and B.subs[1].range == 5000, 'ground subscriber re-resolved at once')
  H.invoking = 'evil'
  TriggerEvent('np_admin:settingsChanged', 'np_flightradar', { ['Ranges.ground'] = 0 })
  H.invoking = nil
  ok(Config.Ranges.ground == 5000, 'settingsChanged from another resource refused')
  H.invoking = 'np_admin'
  TriggerEvent('np_admin:settingsChanged', 'np_flightradar', { ['Ranges.ground'] = { __null = true }, ['Admin.groups'] = {} })
  H.invoking = nil
  ok(Config.Ranges.ground == 12000, 'reset restores the config.lua default')
  ok(#Config.Admin.groups == 2, 'keys outside the schema ignored')
end

-- ===== staff actions + logs ==========================================================================
do
  local heli = H.spawnAircraft({ vtype = 'heli', coords = vector3(0, 100, 200) })
  TriggerEvent('entityCreated', heli)
  H.seat(6, heli, -1)
  local act = NA.actions['np_flightradar.transponder']
  local r, err = act.handler(2, 1, { squawk = '1200' })
  ok(r == false and type(err) == 'string', 'player on foot: error')
  r, err = act.handler(2, 6, { squawk = '', callsign = '', power = 'unchanged' })
  ok(r == false, 'nothing to change')
  local logs = #NA.logs
  r, err = act.handler(2, 6, { squawk = '7700', callsign = 'medevac1', power = 'unchanged' })
  ok(r == true and err.squawk == '7700' and err.callsign == 'MEDEVAC1', 'transponder set by staff')
  ok(H.entities[heli].state.np_fr_xpdr.squawk == '7700', 'state bag published')
  local log = NA.logs[logs + 1]
  ok(log and log.category == 'np_flightradar' and log.entry.action == 'emergency' and log.entry.data.squawk == '7700'
    and log.entry.resource == 'np_flightradar', 'emergency forwarded to the np_admin log')
  r = act.handler(2, 6, { callsign = '-', power = 'off' })
  ok(r == true and H.entities[heli].state.np_fr_xpdr.on == false and H.entities[heli].state.np_fr_xpdr.callsign == nil,
    'callsign reset + power off')

  local mark = #H.clientEvents
  ok(NA.actions['np_flightradar.open'].handler(2) == true, 'open action ok')
  local ev = H.lastClient('np_flightradar:openRadar', 2, mark)
  ok(ev and ev[1] == 'admin', 'open action asks the client to open the admin radar')
end

-- ===== np_admin restart re-registers ================================================================
do
  NA.nodes, NA.settings, NA.actions = nil, nil, {}
  TriggerEvent('np_admin:ready')
  ok(NA.nodes and NA.settings and NA.actions['np_flightradar.open'], 'np_admin:ready re-registers everything')
end

-- ===== fallback without np_admin =====================================================================
do
  H.resources.np_admin = 'stopped'
  TriggerEvent('onServerResourceStop', 'np_admin')
  ok(NpAdmin.can(0, 'np_flightradar.admin') == true, 'fallback: console')
  ok(Bridge.isAdmin(3) == true, 'fallback: identifier in np_admin_fallback')
  ok(Bridge.isAdmin(4) == true, 'fallback: ESX group in np_admin_fallback_groups')
  ok(Bridge.isAdmin(5) == true, 'fallback: Config.Admin.identifiers')
  ok(Bridge.isAdmin(1) == false and Bridge.isAdmin(2) == false, 'fallback: everyone else refused')
  ok(Bridge.can(1, 'np_flightradar.ground') == false, 'fallback: ground node refused for players')
  ok(NpAdmin.log('np_flightradar', { action = 'x' }) == false, 'log returns false without np_admin')
  ok(B.subs[1] == nil, 'np_admin stopped: node-only ground grant dropped')
end

-- ===== no ACE anywhere ===============================================================================
do
  local found = {}
  for _, f in ipairs({ 'bridge/server.lua', 'server/access.lua', 'server/np_admin.lua', 'shared/access.lua',
    'shared/np_admin_settings.lua', 'config.lua', 'fxmanifest.lua' }) do
    local fh = io.open(f, 'r')
    local src = fh:read('a')
    fh:close()
    if src:find('IsPlayerAceAllowed', 1, true) or src:find('add_ace', 1, true) then found[#found + 1] = f end
  end
  ok(#found == 0, 'no ACE calls ' .. table.concat(found, ', '))
end

H.done('test_np_admin')
