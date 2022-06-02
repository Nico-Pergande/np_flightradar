Citizen.CreateThread(function()
    while true do
        local vehicles = GetAllVehicles()
        local trackingVehicles = {}

        for k, v in pairs(vehicles) do
            local vehType = GetVehicleType(v)
            if vehType == "heli" or vehType == "plane" then
                local plate = GetVehicleNumberPlateText(v)
                local coords = GetEntityCoords(v)
                table.insert(trackingVehicles, { coords, vehType, plate })
            end
        end

        TriggerClientEvent("np_flightradar:sendData", -1, trackingVehicles)
        Citizen.Wait(3000)
    end
end)