RegisterNetEvent("bcc-society:CheckIfInSociety", function()
    local _source = source
    DBG:Info("[CheckIfInSociety] Triggered by source:" .. _source)

    local char = SocietyCharacters.Get(_source)
    if not char then
        DBG:Info("[CheckIfInSociety] No character loaded for source:" .. _source)
        return
    end

    local charId = char.charIdentifier
    DBG:Info("[CheckIfInSociety] Character ID:" .. tostring(charId))

    local result = {
        societiesOwned = {},
        societiesEmployed = {}
    }

    local allSocsCharOwns = SocietyAPI.MiscAPI:GetAllSocietiesCharOwns(charId)
    DBG:Info("[CheckIfInSociety] Societies owned:" .. json.encode(allSocsCharOwns))

    if type(allSocsCharOwns) == "table" and #allSocsCharOwns > 0 then
        for _, v in pairs(allSocsCharOwns) do
            table.insert(result.societiesOwned, v)
        end
    end

    local allSocsCharEmployedAt = SocietyAPI.MiscAPI:GetAllSocietiesCharIsEmployedAt(charId)
    DBG:Info("[CheckIfInSociety] Societies employed at:" .. json.encode(allSocsCharEmployedAt))

    if type(allSocsCharEmployedAt) == "table" and #allSocsCharEmployedAt > 0 then
        for _, v in pairs(allSocsCharEmployedAt) do
            local society = SocietyAPI:GetSociety(v.business_id)
            if society then
                local societyData = society:GetSocietyInfo()
                if societyData and societyData.status == 'active' then
                    table.insert(result.societiesEmployed, societyData)
                end
            end
        end
    end

    DBG:Info("[CheckIfInSociety] Final result being sent to client:" .. json.encode(result))
    TriggerClientEvent("bcc-society:ReceiveSocietyData", _source, result)
end)

FeatherRPC:Register("bcc-society:GetAllSocieties", function(_, cb, src)
    if not IsSocietyAdmin(src) then return cb(false) end
    return cb(SocietyAPI.MiscAPI:GetAllSocieties())
end)

-- Dissolves a society: everyone (owner included) leaves through feather-jobs,
-- the organization is dissolved, and the row is kept as 'dissolved' history.
function DissolveSociety(society, actorSource)
    DB.exec("UPDATE bcc_society SET status = 'dissolved' WHERE business_id = ?", society.business_id)
    for _, employee in ipairs(DB.query("SELECT employee_id FROM bcc_society_employees WHERE business_id = ?", society.business_id) or {}) do
        DB.exec("UPDATE bcc_society_employees SET status = 'pending_removal' WHERE business_id = ? AND employee_id = ?",
            society.business_id, employee.employee_id)
        SocietyJobs.Enqueue(society.business_id, employee.employee_id, 'fire', nil, actorSource)
    end
    SocietyJobs.Enqueue(society.business_id, society.owner_id, 'fire', nil, actorSource)

    local dissolved = SocietyOrganizations.Dissolve(society)
    if not dissolved.ok then
        print(('[bcc-society] society %s organization not dissolved: %s'):format(tostring(society.business_id), tostring(dissolved.code)))
    end
end

RegisterServerEvent("bcc-society:AdminManageSociety", function(societyId, delete, societyTax, societyName, societyInvLimit, societyBlip, societyJob)
    local _source = source
    DBG:Info("[AdminManageSociety] Triggered by:" .. _source .. "Society ID:" .. tostring(societyId))

    if not IsSocietyAdmin(_source) then
        DBG:Warning("[AdminManageSociety] denied for source:" .. _source)
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    local society = DB.one("SELECT * FROM bcc_society WHERE business_id = ? AND status = 'active'", societyId)
    if not society then
        return NotifyClient(_source, _U("societyNotFound"), "error", 4000)
    end

    if delete then
        DBG:Info("[AdminManageSociety] Dissolving society:" .. societyId)
        DissolveSociety(society, _source)
    else
        DBG:Info("[AdminManageSociety] Updating society:" .. societyId)
        societyName = type(societyName) == "string" and societyName:match("^%s*(.-)%s*$") or society.business_name
        if societyName == "" or #societyName > 100 then societyName = society.business_name end

        -- The job type is fixed once people hold it: their assignments and rank
        -- grade mappings belong to that job.
        if societyJob and societyJob ~= society.society_job then
            NotifyClient(_source, _U("jobTypeFixed"), "error", 4000)
        end

        DB.exec("UPDATE bcc_society SET tax_amount = ?, business_name = ?, inv_limit = ?, blip_hash = ? WHERE business_id = ?",
            tonumber(societyTax) or society.tax_amount, societyName, tonumber(societyInvLimit) or society.inv_limit,
            type(societyBlip) == "string" and societyBlip or society.blip_hash, societyId
        )
        local renamed = SocietyOrganizations.Rename(society, societyName)
        if not renamed.ok then
            print(('[bcc-society] society %s organization rename failed: %s'):format(tostring(societyId), tostring(renamed.code)))
        end
    end

    DBG:Success("[AdminManageSociety] Operation completed for society:" .. societyId)
end)
