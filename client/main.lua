-- Main page of client
AdminAllowed = nil
local blips = {}
local OwnedSocieties = {} -- key = business_id, value = true
local generation = 0      -- bumps on every character change; society loops stop when it moves
local Toolkit = exports['feather-toolkit']

function IsSocietyOwner(businessId)
    return OwnedSocieties[businessId] == true
end

local function StartForCharacter()
    generation = generation + 1
    OwnedSocieties = {}
    AdminAllowed = FeatherRPC:CallAsync("BCC-Society:AdminCheck") == true
    DBG:Info("[RPC] Admin check result: " .. tostring(AdminAllowed))
    TriggerServerEvent("bcc-society:CheckIfInSociety")
end

local function StopForCharacter()
    generation = generation + 1
    OwnedSocieties = {}
    AdminAllowed = false
    BCCSocietyMenu:Close()
end

RegisterNetEvent('Feather:Character:Spawned', function()
    StartForCharacter()
end)

RegisterNetEvent('Feather:Character:Logout', function()
    StopForCharacter()
end)

-- Feather:Character:Spawned fires once; catch up after a resource restart.
CreateThread(function()
    Wait(2000)
    local ok, active = pcall(function() return exports['feather-character']:HasActiveCharacter() end)
    if ok and active == true then StartForCharacter() end
end)

RegisterNetEvent("bcc-society:ReceiveSocietyData", function(result)
    if result then
        for _, v in ipairs(result.societiesOwned) do
            OwnedSocieties[v.business_id] = true
            DBG:Info("[ReceiveSocietyData] Registered owner of:" .. v.business_name .. " (ID: " .. v.business_id .. ")")
            TriggerEvent("bcc-society:SocietyStart", true, v)
        end

        for _, v in ipairs(result.societiesEmployed) do
            DBG:Info("[ReceiveSocietyData] Registered employee at:" .. v.business_name .. " (ID: " .. v.business_id .. ")")
            TriggerEvent("bcc-society:SocietyStart", false, v)
        end
    end
end)

RegisterNetEvent("bcc-society:SocietyStart", function(isOwner, societyData)
    DBG:Info("[SocietyStart] Triggered for society:" .. societyData.business_name .. "| IsOwner:" .. tostring(isOwner))
    local started = generation

    if isOwner then OwnedSocieties[societyData.business_id] = true end
    local isOwner = IsSocietyOwner(societyData.business_id)
    RegisterCommand(Config.billCommandName, function()
        DBG:Info("[BillingCommand] Executed command:" .. Config.billCommandName)

        if isOwner then
            DBG:Info("[BillingCommand] Confirmed as owner for society:" .. societyData.business_name)
            OpenBillingMenu(societyData)
            return
        end

        FeatherRPC:Call("bcc-society:GetEmployeeData", {
            socId = societyData.business_id,
            recType = "rankData"
        }, function(billData)
            if billData then
                DBG:Info("[BillingCommand] Received employee billData:" .. json.encode(billData))
                if billData.rank_can_bill_players == "true" then
                    DBG:Info("[BillingCommand] Employee rank allows billing.")
                    OpenBillingMenu(societyData)
                else
                    DBG:Info("[BillingCommand] Employee rank does NOT allow billing.")
                    Notify(_U("noBillPerms"), "error", 4000)
                end
            else
                DBG:Info("[BillingCommand] No employee rank data found.")
                Notify(_U("noRankData"), "error", 4000)
            end
        end)
    end)

    -- Fired handling
    local isFired = false
    RegisterNetEvent('bcc-society:FiredFrom:' .. societyData.business_id, function()
        isFired = true
    end)

    -- Blip setup
    local societyCoords = json.decode(societyData.coords)
    local societyCoordsVector3 = vector3(societyCoords.x, societyCoords.y, societyCoords.z)
    if societyData.show_blip == "true" and Config.allowBlips and societyData.blip_hash ~= "none" then
        TriggerServerEvent("bcc-society:ServerSyncBlips", societyData.business_id, false)
    end

    -- Prompt setup (feather-toolkit)
    local promptGroup = GetRandomIntInRange(0, 0xffffff)
    local created = Toolkit:CreatePrompt({
        control = Config.manageSocietyPromptKey,
        label = _U("manage"),
        groupId = promptGroup,
        mode = 'hold',
        holdMode = 'MEDIUM_TIMED_EVENT'
    })
    local promptId = type(created) == 'table' and created.ok and created.value.id or nil
    if not promptId then
        print('[bcc-society] prompt creation failed: ' .. tostring(type(created) == 'table' and created.code))
        return
    end

    while true do
        if isFired or started ~= generation then break end
        local playerCoords = GetEntityCoords(PlayerPedId())
        local dist = #(societyCoordsVector3 - playerCoords)

        if dist < 50 then
            if dist < Config.openMenuRadius then
                Toolkit:ShowPromptGroup(promptGroup, societyData.business_name)
                local completed = Toolkit:IsPromptCompleted(promptId)
                if type(completed) == 'table' and completed.ok and completed.value.completed then
                    ManageSocietyMenu(societyData, societyCoordsVector3, isOwner)
                end
            end
        else
            Wait(1000)
        end
        Wait(5)
    end
    Toolkit:RemovePrompt(promptId)
end)

RegisterNetEvent('bcc-society:ClientSyncBlips', function(blipName, blipHash, blipVector3, blipSocietyId, delete)
    for k, v in pairs(blips) do
        if v.blipSocietyId == blipSocietyId then
            Toolkit:RemoveBlip(v.societyBlip)
            table.remove(blips, k)
            break
        end
    end
    if not delete then
        local created = Toolkit:CreateBlip({
            x = blipVector3.x, y = blipVector3.y, z = blipVector3.z,
            sprite = joaat(blipHash),
            name = blipName
        })
        if type(created) == 'table' and created.ok then
            table.insert(blips, { societyBlip = created.value.id, blipSocietyId = blipSocietyId }) --So we can make sure to remove it on all clients and enable it on all clients
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        for _, v in pairs(blips) do
            Toolkit:RemoveBlip(v.societyBlip)
        end
        BCCSocietyMenu:Close()
        -- Taking members off duty on shutdown is done by the server (feather-jobs).
    end
end)
