-- Client bridge: the local job, for UI hints only. The server never trusts anything from here; it asks
-- its own bridge (bridge/server.lua) and pushes the resulting access summary (np_flightradar:access).
Bridge = {}

local job = nil
local changeHandlers = {}

function Bridge.job() return job end
function Bridge.onJobChange(fn) changeHandlers[#changeHandlers + 1] = fn end

local function setJob(name)
  if type(name) ~= 'string' or name == job then return end
  job = name
  for _, fn in ipairs(changeHandlers) do pcall(fn, job) end
end

-- es_extended
RegisterNetEvent('esx:playerLoaded', function(xPlayer)
  if type(xPlayer) == 'table' and type(xPlayer.job) == 'table' then setJob(xPlayer.job.name) end
end)
RegisterNetEvent('esx:setJob', function(j)
  if type(j) == 'table' then setJob(j.name) end
end)

-- qbx_core / qb-core
RegisterNetEvent('QBCore:Client:OnJobUpdate', function(j)
  if type(j) == 'table' then setJob(j.name) end
end)
RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
  if GetResourceState('qbx_core') == 'started' then
    local ok, pd = pcall(function() return exports.qbx_core:GetPlayerData() end)
    if ok and type(pd) == 'table' and type(pd.job) == 'table' then setJob(pd.job.name) end
  end
end)
