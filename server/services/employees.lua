FeatherRPC:Register("bcc-society:GetAllEmployeesData", function(params, cb, recSource)
    if not IsSocietyMember(recSource, params.socId) then return cb(false) end
    local society = SocietyAPI:GetSociety(params.socId)
    local employees = society and society:GetSocietyEmployees()
    if employees and type(employees) == "table" and #employees > 0 then
        local employeesCharIds = {}
        for k, v in pairs(employees) do
            table.insert(employeesCharIds,
                { charId = v.employee_id, employeeName = v.employee_name, employeeRank = v.employee_rank, status = v.status })
        end
        if params.recType ~= "viewEmployees" then
            local ownerId = society:GetSocietyOwnerCharacterId()
            if ownerId then
                table.insert(employeesCharIds, { charId = ownerId })
            end
        end
        return cb(employeesCharIds)
    else
        local employeesCharIds = {}
        if params.recType ~= 'viewEmployees' and society then
            local ownerId = society:GetSocietyOwnerCharacterId()
            if ownerId then
                table.insert(employeesCharIds, { charId = ownerId })
                return cb(employeesCharIds)
            else
                return cb(false)
            end
        else
            return cb(false)
        end
    end
end)

-- The entry rank for new hires: the rank mapped to the lowest grade ordinal.
local function EntryRank(society)
    local info = society:GetSocietyInfo()
    local job = SocietyJobs.JobConfig(info.society_job)
    local ranks = society:GetAllRanks()
    if not job or not ranks then return nil end
    local ordinals = {}
    for _, grade in ipairs(job.grades) do ordinals[grade.key] = grade.ordinal end
    table.sort(ranks, function(a, b)
        return (ordinals[a.job_grade] or math.huge) < (ordinals[b.job_grade] or math.huge)
    end)
    return ranks[1]
end

RegisterServerEvent('bcc-society:PlayerHired', function(businessId, playerCharId, playerSource)
    local _source = source
    local allowed, hiringChar, society = HasSocietyPermission(_source, businessId, "rank_can_manage_employees")
    if not allowed then
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    -- The new employee must be online; their character comes from their session.
    local employeeChar = SocietyCharacters.Get(playerSource)
    if not employeeChar or employeeChar.charIdentifier ~= playerCharId then
        return NotifyClient(_source, _U("playerNotOnline"), "error", 4000)
    end
    local societyData = society:GetSocietyInfo()
    local employeeFullName = employeeChar.firstname .. " " .. employeeChar.lastname

    local employee = DB.query("SELECT * FROM bcc_society_employees WHERE employee_id = ? AND business_id = ?", playerCharId, businessId)
    if #employee > 0 or societyData.owner_id == playerCharId then
        return NotifyClient(_source, _U("playerCanNotBeHired"), "error", 4000)
    end

    if not Config.employeeWorksAtMultiple then
        local elsewhere = DB.query("SELECT * FROM bcc_society_employees WHERE employee_id = ?", playerCharId)
        local owner = DB.query("SELECT * FROM bcc_society WHERE owner_id = ? AND status = 'active'", playerCharId)
        if #elsewhere > 0 or #owner > 0 then
            return NotifyClient(_source, _U("playerCanNotBeHired"), "error", 4000)
        end
    end

    local rankInfo = EntryRank(society)
    if not rankInfo then
        return NotifyClient(_source, _U("noRanks"), "error", 4000)
    end

    -- Membership first (pending), then the durable feather-jobs workflow.
    -- New employees start off duty; duty lives on the Jobs assignment.
    DB.exec(
        "INSERT INTO bcc_society_employees (employee_id, business_id, employee_name, employee_rank, status) VALUES (?, ?, ?, ?, 'pending_assignment')",
        playerCharId, businessId, employeeFullName, rankInfo.rank_name
    )
    SocietyJobs.Enqueue(businessId, playerCharId, 'hire', rankInfo.job_grade, _source)
    DBG:Info("[PlayerHired]", hiringChar.charIdentifier, "hired", playerCharId, "at", businessId)
    NotifyClient(_source, _U("hirePending"), "info", 4000)
end)

RegisterServerEvent('bcc-society:FireEmployee', function(businessId, playerCharId)
    local _source = source
    local allowed, fireChar, society = HasSocietyPermission(_source, businessId, "rank_can_manage_employees")
    if not allowed then
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end
    local societyData = society:GetSocietyInfo()
    if playerCharId == societyData.owner_id then
        return NotifyClient(_source, _U("cannotFireOwner"), "error", 4000)
    end
    local employee = society:GetEmployeeData(playerCharId)
    if not employee then
        return NotifyClient(_source, _U("employeeNotFound"), "error", 4000)
    end

    DB.exec("UPDATE bcc_society_employees SET status = 'pending_removal' WHERE employee_id = ? AND business_id = ?",
        playerCharId, businessId)
    SocietyJobs.Enqueue(businessId, playerCharId, 'fire', nil, _source)

    local target = SocietyCharacters.FindSource(playerCharId)
    if target then
        NotifyClient(target, _U("youWereFired") .. societyData.business_name, "error", 4000)
        TriggerClientEvent('bcc-society:FiredFrom:' .. businessId, target)
    end
    DBG:Info("[FireEmployee]", fireChar.charIdentifier, "fired", playerCharId, "from", businessId)
    NotifyClient(_source, _U("employeeFired"), "success", 4000)
end)

RegisterServerEvent('bcc-society:ChangeEmployeeRank', function(businessId, rankName, employeeId)
    local _source = source
    local allowed, _, society = HasSocietyPermission(_source, businessId, "rank_can_manage_employees")
    if not allowed then
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    local employee = society:GetEmployeeData(employeeId)
    if not employee or employee.status == 'pending_removal' then
        return NotifyClient(_source, _U("employeeNotFound"), "error", 4000)
    end
    local rankData = society:GetRankInfo(rankName)
    if not rankData then
        return NotifyClient(_source, _U("rankNotFound"), "error", 4000)
    end

    DB.exec("UPDATE bcc_society_employees SET employee_rank = ? WHERE business_id = ? AND employee_id = ?",
        rankName, businessId, employeeId)
    -- The Jobs grade follows the rank's explicit mapping.
    SocietyJobs.Enqueue(businessId, employeeId, 'promote', rankData.job_grade, _source)

    local target = SocietyCharacters.FindSource(employeeId)
    if target then
        local businessName = society:GetSocietyInfo().business_name
        NotifyClient(target, _U("yourRankWasChanged") .. rankName .. " " .. _U("yourRankWasChangedAt") .. businessName, "success", 4000)
        TriggerClientEvent('bcc-society:UpdateEmployeeData:' .. businessId, target)
    end
    NotifyClient(_source, _U("employeeRankChanged"), "success", 4000)
end)

FeatherRPC:Register("bcc-society:GetEmployeeData", function(params, cb, recSource)
    local char = SocietyCharacters.Get(recSource)
    if not char then
        return cb(false)
    end

    local charId = char.charIdentifier

    local society = SocietyAPI:GetSociety(params.socId)

    if not society then
        return cb(false)
    end

    local employeeData = society:GetEmployeeData(charId)
    if employeeData and employeeData.status ~= 'active' then employeeData = false end

    if params.recType == "employeeData" then
        cb(employeeData)
    elseif params.recType == "rankData" then
        if employeeData then
            local employeeRankName = society:GetEmployeeRank(charId)
            if employeeRankName then
                local rankData = society:GetRankInfo(employeeRankName)
                cb(rankData)
            else
                cb(false)
            end
        else
            cb(false)
        end
    else
        cb(false)
    end
end)
