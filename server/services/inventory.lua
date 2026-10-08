-- Society storage on feather-inventory: one shared container per society,
-- linked through the `bcc_society` foreign key. Slots are the base inv_limit
-- plus every unlocked upgrade stage. Members open it through a short temporary
-- access grant after the rank permission check.

local foreignKeyReady = false

local function Inventory()
    return exports['feather-inventory'].initiate().Inventory
end

local function StagesOf(society)
    local ok, stages = pcall(json.decode, society.inventory_upgrade_stages)
    return ok and type(stages) == "table" and stages or {}
end

local function SlotLimit(society)
    local limit = tonumber(society.inv_limit) or 0
    local current = tonumber(society.inventory_current_stage) or 0
    for _, stage in pairs(StagesOf(society)) do
        if tonumber(stage.stage) and tonumber(stage.stage) <= current then
            limit = limit + (tonumber(stage.slotIncrease) or 0)
        end
    end
    -- feather-inventory stores the slot count in a SMALLINT; never ask for more than the configured cap.
    return math.max(1, math.min(limit, Config.MaxStorageSlots or 500))
end

-- Registers (or resizes) the society's container. Returns uuid, id.
local function EnsureStorage(society)
    local inventory = Inventory()
    if not foreignKeyReady then
        local registered = inventory.RegisterForeignKey('bcc_society', 'INT', 'business_id')
        if type(registered) ~= 'table' or registered.ok ~= true then
            return nil, nil, 'foreign_key_failed'
        end
        foreignKeyReady = true
    end
    local registered = inventory.RegisterInventory('bcc_society', society.business_id, society.business_name,
        false, nil, nil, society.owner_id, false, SlotLimit(society))
    if type(registered) ~= 'table' or registered.ok ~= true then
        return nil, nil, 'register_failed'
    end
    if society.inventory_id ~= registered.value.uuid then
        DB.exec("UPDATE bcc_society SET inventory_id = ? WHERE business_id = ?", registered.value.uuid, society.business_id)
    end
    return registered.value.uuid, registered.value.id
end

RegisterServerEvent('bcc-society:openInventory', function(businessId)
    local _source = source
    local allowed, _, society = HasSocietyPermission(_source, businessId, "rank_can_open_inventory")
    if not allowed then
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end
    local info = society:GetSocietyInfo()

    local called, uuid, id, failure = pcall(EnsureStorage, info)
    if not called or not uuid then
        print(('[bcc-society] storage for %s unavailable: %s'):format(tostring(businessId), tostring(called and failure or uuid)))
        return NotifyClient(_source, _U("storageUnavailable"), "error", 4000)
    end

    local inventory = Inventory()
    local granted = inventory.GrantTemporaryAccess(_source, id, 60)
    local opened = type(granted) == 'table' and granted.ok and inventory.OpenInventory(_source, uuid, 'bcc_society') or granted
    if type(opened) ~= 'table' or opened.ok ~= true then
        NotifyClient(_source, _U("storageUnavailable"), "error", 4000)
    end
end)

FeatherRPC:Register("bcc-society:UpgradeInventory", function(params, cb, recSource)
    local allowed, char, society = HasSocietyPermission(recSource, params.socId, "rank_can_open_inventory")
    if not allowed then return cb(false) end
    local info = society:GetSocietyInfo()

    -- Cost and slots come from the stored stage plan, never from the client.
    local nextStage
    for _, stage in pairs(StagesOf(info)) do
        if tonumber(stage.stage) == (tonumber(info.inventory_current_stage) or 0) + 1 then nextStage = stage end
    end
    local cost = nextStage and ParseAmount(nextStage.cost)
    if not cost then return cb(false) end

    local wallet = SocietyEconomy.GetWallet(char.charIdentifier)
    local sink = SocietyEconomy.GetSystemSink()
    if not wallet.ok or not sink.ok then return cb(false) end

    local paid = SocietyEconomy.Transfer(wallet.value, sink.value, cost, 'society.storage_upgrade',
        { type = 'bcc_society', id = info.business_id },
        ('society:storage:%s:%s'):format(info.business_id, tonumber(nextStage.stage)), char)
    if not paid.ok then return cb(false) end

    DB.exec("UPDATE bcc_society SET inventory_current_stage = ? WHERE business_id = ?",
        tonumber(nextStage.stage), info.business_id)
    info.inventory_current_stage = tonumber(nextStage.stage)
    pcall(EnsureStorage, info) -- resize now; opening resizes too
    return cb(true)
end)

FeatherRPC:Register("bcc-society:GetInventoryStages", function(params, cb, recSource)
    if not IsSocietyMember(recSource, params.socId) then return cb(false) end
    local retval = DB.query("SELECT * FROM bcc_society WHERE business_id = ?", params.socId)
    if #retval > 0 then
        local stageData = nil
        local foundNextStage = false
        for _, v in pairs(StagesOf(retval[1])) do
            if tonumber(v.stage) == tonumber(retval[1].inventory_current_stage) + 1 then
                foundNextStage = true
                stageData = { nextStage = v, inventory_current_stage = retval[1].inventory_current_stage }
                break
            end
        end
        if not foundNextStage then
            stageData = { nextStage = false, inventory_current_stage = retval[1].inventory_current_stage }
        end
        return cb(stageData)
    else
        return cb(false)
    end
end)
