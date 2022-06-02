local blip = {}

RegisterNetEvent("np_flightradar:sendData")
AddEventHandler("np_flightradar:sendData", function(vehicles)
    local playerPed = PlayerPedId()

    if #vehicles >= 1 then
        for k, v in pairs(vehicles) do
            local plate = v[3]
            if (IsPedInAnyHeli(playerPed) or IsPedInAnyPlane(playerPed)) and #vehicles >= 1 then
                if blip[plate] then
                    RemoveBlip(blip[plate])
                    drawBlip(v[1], v[2], plate)
                else
                    drawBlip(v[1], v[2], plate)
                end
            else
                RemoveBlip(blip[plate])
            end
        end
    end
end)

function drawBlip(veh, type, plate)
    blip[plate] = AddBlipForCoord(veh)
                        
    if type == "heli" then
        SetBlipSprite(blip[plate], 64)
    elseif type == "plane" then
        SetBlipSprite(blip[plate], 307)
    end
    
    SetBlipScale(blip[plate] , 0.7)
    SetBlipColour(blip[plate] , 5)
    SetBlipAsShortRange(blip[plate], true)
    
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(plate)
    EndTextCommandSetBlipName(blip[plate])
end