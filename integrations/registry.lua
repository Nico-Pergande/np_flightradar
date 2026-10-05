-- Tiny integration registry (pattern from np_gangs): every optional sibling is wrapped so a missing,
-- stopped, restarting or switched-off resource degrades to the built-in fallback instead of an error.
--
--   local hud = NpFR.Integration.define('np_hud', { fallback = 'native notifications' })
--   if hud.active() then local ok, id = hud.call('Notify', data) end
--   hud.onStart(function() ... end)   -- runs now if started, and every time the sibling (re)starts
NpFR = NpFR or {}
NpFR.Integration = NpFR.Integration or { list = {}, order = {} }
local Integration = NpFR.Integration

function NpFR.debug(...)
  if Config and Config.Debug then print('^5[np_flightradar]^0', ...) end
end

function NpFR.warn(fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  print('^3[np_flightradar] ' .. (ok and msg or tostring(fmt)) .. '^0')
end

function Integration.define(name, spec)
  spec = spec or {}
  local self = { name = name, resource = spec.resource or name, fallback = spec.fallback or 'built-in fallback', starters = {} }

  function self.enabled()
    local cfg = Config.Integrations
    return not (cfg and cfg[name] == false)
  end

  function self.active()
    return self.enabled() and GetResourceState(self.resource) == 'started'
  end

  -- -> ok, ...results. Never throws.
  function self.call(export, ...)
    if not self.active() then return false end
    local args = table.pack(...)
    local res = table.pack(pcall(function()
      return exports[self.resource][export](nil, table.unpack(args, 1, args.n))
    end))
    if res[1] then return true, table.unpack(res, 2, res.n) end
    NpFR.debug(('%s.%s failed: %s'):format(name, export, tostring(res[2])))
    return false
  end

  -- fn runs once now (if active) and again whenever the sibling (re)starts
  function self.onStart(fn)
    self.starters[#self.starters + 1] = fn
    if self.active() then
      CreateThread(function() pcall(fn) end)
    end
  end

  function self.status()
    if not self.enabled() then return 'disabled' end
    return self.active() and 'active' or 'fallback'
  end

  Integration.order[#Integration.order + 1] = name
  Integration.list[name] = self
  return self
end

function Integration.get(name) return Integration.list[name] end

AddEventHandler(IsDuplicityVersion() and 'onServerResourceStart' or 'onClientResourceStart', function(res)
  for _, name in ipairs(Integration.order) do
    local i = Integration.list[name]
    if i.resource == res and i.enabled() then
      for _, fn in ipairs(i.starters) do
        CreateThread(function()
          Wait(500) -- let the sibling register its exports
          local ok, err = pcall(fn)
          if not ok then NpFR.warn('%s start hook failed: %s', name, tostring(err)) end
        end)
      end
    end
  end
end)

function Integration.print()
  for _, name in ipairs(Integration.order) do
    local i = Integration.list[name]
    local st = i.status()
    local colour = st == 'active' and '^2' or '^3'
    print(('%s[np_flightradar] %s: %s%s^0'):format(colour, name, st, st == 'active' and '' or (' (' .. i.fallback .. ')')))
  end
end
