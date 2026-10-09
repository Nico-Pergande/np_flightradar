Config = {}

-- ===== General =====================================================================================
Config.Locale = 'en'            -- 'en' | 'de'
Config.Debug = false
Config.Framework = 'auto'       -- 'auto' (esx > qbx > qb > standalone) | 'esx' | 'qbx' | 'qb' | 'standalone'
Config.UpdateInterval = 1000    -- ms between radar updates sent to subscribers (clamped to 250..5000)
Config.Units = 'aviation'       -- 'aviation' (ft, kt, fpm, NM) | 'metric' (m, km/h, m/s, km)

-- Radar range per access mode in metres (0 = unlimited)
Config.Ranges = {
  air = 6000,       -- sitting in an aircraft
  ground = 12000,   -- allowed job (police, ATC ...) anywhere on the map
  item = 4000,      -- handheld 'flight_radar' scanner item
  station = 0,      -- at a radar station (tower), includes primary radar
  phone = 8000,     -- np_phone app
  admin = 0,
}
-- Range steps offered by the panel (0 = unlimited, capped at the granted range)
Config.RangeSteps = { 2000, 4000, 8000, 16000, 0 }

-- Which aircraft count as "traffic" and show up on radar
Config.Traffic = {
  requirePilot = true,    -- someone in the pilot seat ...
  requireEngine = false,  -- ... AND (requireEngine) / OR (not requireEngine) the engine running
  minSpeed = 0,           -- m/s; aircraft slower than this are hidden (0 = off)
  includeParked = false,  -- true: every heli/plane is shown, parked or not
}

-- ===== Access ======================================================================================
Config.Access = {
  inAircraft = true,                                 -- everyone in an aircraft seat gets the onboard radar
  jobs = { police = 0, sheriff = 0, ambulance = 0, atc = 0 }, -- job = minimum grade for the ground radar
  requireDuty = true,                                -- qb/qbx duty flag (ESX has no duty: having the job counts)
  item = 'flight_radar',                             -- handheld scanner item (false = off)
  discordRoles = {},                                 -- np_discord role ids/names that grant the ground radar
}

-- Admins see everything incl. primary radar. Permissions are np_admin nodes (np_flightradar.admin / .ground).
-- This list only counts while np_admin is NOT running, next to the convars np_admin_fallback (identifiers) and
-- np_admin_fallback_groups (ESX groups). No ACE.
Config.Admin = {
  identifiers = {},                       -- e.g. 'license:abc...', 'discord:123...'
  groups = { 'admin', 'superadmin' },     -- ESX xPlayer.getGroup()
}

-- Radar stations (tower consoles): stand within `radius` to get the station radar (unlimited range +
-- primary radar). `jobs` = job -> minimum grade (nil = anyone with the ground radar job list).
Config.Stations = {
  { label = 'LSIA Tower', coords = vec3(-1037.0, -2963.0, 13.9), radius = 25.0, jobs = { atc = 0, police = 0 } },
  { label = 'Sandy Shores Airfield', coords = vec3(1692.0, 3287.0, 41.1), radius = 20.0, jobs = { atc = 0, police = 0, sheriff = 0 } },
  { label = 'McKenzie Field', coords = vec3(2121.0, 4784.0, 41.0), radius = 20.0, jobs = { atc = 0, sheriff = 0 } },
}

-- Primary radar: stations and admins also see aircraft with the transponder off, as "unidentified"
Config.PrimaryRadar = { enabled = true, range = 8000 }

-- ===== Transponder =================================================================================
Config.Transponder = {
  defaultOn = true,
  defaultSquawk = '7000',
  copilotCanEdit = true,  -- seat 0 may change squawk / callsign too
  rate = 1000,            -- ms between transponder changes per player
}

Config.Emergency = {
  codes = { ['7500'] = 'hijack', ['7600'] = 'radio', ['7700'] = 'emergency' },
  notifyJobs = { 'police', 'ambulance', 'atc' },
  discordChannel = nil,   -- np_discord log channel name, e.g. 'aviation'
}

-- TCAS-lite for pilots: traffic advisory (TA) and resolution advisory (RA = half the TA box)
Config.Proximity = {
  enabled = true,
  horizontal = 600.0,   -- m
  vertical = 150.0,     -- m
  lookahead = 25.0,     -- s until closest point of approach
  sound = true,
}

-- ===== Blips =======================================================================================
Config.Blips = {
  heli = { sprite = 64, scale = 0.8 },
  plane = { sprite = 423, scale = 0.8 },
  scale = 0.8,
  shortRange = false,
  lerpMs = 100,           -- dead-reckoning step for blips of aircraft outside your scope
  showForPhone = false,   -- phone-only subscription also draws map blips
  colours = {
    default = 0,          -- white
    police = 3,           -- blue
    ems = 1,              -- red
    fire = 17,            -- orange
    military = 52,        -- dark green
    emergency = 1,        -- red + flashing
    unidentified = 39,    -- grey
    unlicensed = 5,       -- yellow
  },
}

-- Callsign fallbacks (pilot transponder > np_manufacturing vehicleCallsign > perModel > pilot callsign > plate)
Config.Callsigns = {
  perModel = { polmav = 'AIR-1' },
}

-- Pilot job -> organisation (blip colour, NUI badge)
Config.Orgs = { police = 'police', sheriff = 'police', ambulance = 'ems', fire = 'fire', army = 'military' }

-- ===== Integrations ================================================================================
Config.Identification = {
  checkPilotLicense = true,         -- flag pilots without a valid 'pilot_license' as unlicensed
  requireLicenseForAirRadar = false,
  document = 'pilot_license',
}

Config.Phone = {
  enabled = true,
  job = nil,          -- nil = everyone; 'atc' or { 'atc', 'police' }
  item = nil,         -- np_phone store gate: item required to install the app
}

Config.Keys = { panel = 'F6' }
Config.Commands = { radar = 'radar', squawk = 'squawk', transponder = 'transponder', callsign = 'callsign' }

Config.Integrations = {
  np_hud = true, np_phone = true, np_inventory = true, np_identification = true,
  np_discord = true, np_menu = true, np_manufacturing = true, np_helicam = true,
  np_faction = true,
}

-- Server-side veto hook: return false to deny a mode. function(src, mode) -> bool
Config.CanUse = nil
