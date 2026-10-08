RegisterServerEvent("bcc-society:InsertSocietyToDB", function(name, ownerCharId, ownerSource, taxAmount, invLimit, coords, blipHash, stages, societyJob)
    local _source = source
    if not IsSocietyAdmin(_source) then
        DBG:Warning("[InsertSocietyToDB] denied for source", _source)
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    -- The owner must be online; their character comes from their session, not the client.
    local ownerChar = SocietyCharacters.Get(ownerSource)
    if not ownerChar or ownerChar.charIdentifier ~= ownerCharId then
        return NotifyClient(_source, _U("ownerNotOnline"), "error", 4000)
    end
    ownerCharId = ownerChar.charIdentifier

    name = type(name) == "string" and name:match("^%s*(.-)%s*$") or ""
    if name == "" or #name > 100 then
        return NotifyClient(_source, _U("fillAllFields"), "error", 4000)
    end
    if not SocietyJobs.JobConfig(societyJob) then
        return NotifyClient(_source, _U("invalidSocietyJob"), "error", 4000)
    end
    taxAmount = tonumber(taxAmount) or 0
    invLimit = tonumber(invLimit) or 0
    if taxAmount < 0 or invLimit < 0 then
        return NotifyClient(_source, _U("fillAllFields"), "error", 4000)
    end
    local maxSlots = Config.MaxStorageSlots or 500
    if invLimit > maxSlots then
        return NotifyClient(_source, _U("storageLimitTooHigh") .. maxSlots, "error", 4000)
    end
    if type(stages) ~= "string" or stages == "" then stages = "none" end

    -- The society stands where the creating admin stands.
    local ped = GetPlayerPed(_source)
    local position = ped and ped ~= 0 and GetEntityCoords(ped) or coords
    coords = { x = position.x, y = position.y, z = position.z }

    local getAllSocieties = DB.query("SELECT * FROM bcc_society WHERE status = 'active'")
    local exist = false
    if #getAllSocieties > 0 then
        for k, v in pairs(getAllSocieties) do
            if v.business_name == name then
                exist = true
                NotifyClient(_source, _U("societyNameAlreadyExists"), "warning", 4000) break
            end
        end
    end
    if exist then return end

    if not Config.employeeWorksAtMultiple then
        local ownedSocieties = DB.query("SELECT * FROM bcc_society WHERE owner_id = ? AND status = 'active'", ownerCharId)
        if #ownedSocieties > 0 then
            return NotifyClient(_source, _U("alreadyOwnSociety"), "error", 4000)
        end
        local employedAtSocieties = DB.query("SELECT * FROM bcc_society_employees WHERE employee_id = ?", ownerCharId)
        if #employedAtSocieties > 0 then
            return NotifyClient(_source, _U("alreadyEmployed"), "error", 4000)
        end
    end

    local businessId = DB.insert("INSERT INTO bcc_society (business_name, owner_id, tax_amount, inv_limit, coords, blip_hash, inventory_upgrade_stages, society_job) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        name, ownerCharId, taxAmount, invLimit, json.encode(coords), blipHash, stages, societyJob)
    local retval = DB.query("SELECT * FROM bcc_society WHERE business_id = ?", businessId)
    if #retval == 0 then
        return NotifyClient(_source, _U("societyCreateFailed"), "error", 4000)
    end

    -- Identity in feather-organizations; the owner's feather-jobs assignment follows.
    local linked = SocietyOrganizations.Ensure(retval[1])
    if not linked.ok then
        print(('[bcc-society] society %s created but not linked yet: %s'):format(tostring(businessId), tostring(linked.code)))
    end

    NotifyClient(_source, _U("societyCreated"), "success", 4000)
    DBG:Success("[InsertSocietyToDB] created society", businessId, "by", _source, "owner", ownerCharId)
    TriggerClientEvent("bcc-society:SocietyStart", tonumber(ownerSource), true, retval[1])
end)
