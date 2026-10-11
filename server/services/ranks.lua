local function Flag(value)
    return value == "true" and "true" or "false"
end

RegisterServerEvent("bcc-society:RankManagement", function(type, businessId, rankName, rankLabel, rankPay, payIncrement, toggleBlip, withdraw, deposit, editRanks, manageEmployees, openInventory, canManageStore, rankJobGrade, rankCanBillPlayers, rankCanSwitchJob)
    local _source = source
    DBG:Info("[RankManagement] source", _source, type, "rank", rankName, "society", businessId, "pay", rankPay,
        "every", payIncrement, "min, grade", rankJobGrade)
    local allowed, char, society = HasSocietyPermission(_source, businessId, "rank_can_edit_ranks")
    if not allowed then
        DBG:Warning("[RankManagement] source", _source, "lacks rank_can_edit_ranks")
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end
    local info = society:GetSocietyInfo()

    if _G.type(rankName) ~= "string" or rankName == "" or #rankName > 100 then
        DBG:Warning("[RankManagement] invalid rank name")
        return NotifyClient(_source, _U("fillAllFields"), "error", 4000)
    end

    if type == "add" or type == "update" then
        rankPay = tonumber(rankPay)
        payIncrement = tonumber(payIncrement)
        if not rankPay or rankPay < 0 or rankPay % 1 ~= 0 or not payIncrement or payIncrement < 1 or payIncrement % 1 ~= 0 then
            DBG:Warning("[RankManagement] pay must be a whole number >= 0 and the interval a whole number >= 1")
            return NotifyClient(_source, _U("fillAllFields"), "error", 4000)
        end
        if _G.type(rankLabel) ~= "string" or rankLabel == "" then rankLabel = rankName end

        -- The rank maps to an explicit grade of the society's job type. The owner
        -- grade is reserved for the owner.
        local job = SocietyJobs.JobConfig(info.society_job)
        if not SocietyJobs.HasGrade(info.society_job, rankJobGrade) or (job and rankJobGrade == job.ownerGrade) then
            DBG:Warning("[RankManagement] grade", rankJobGrade, "is not a valid non-owner grade of", info.society_job)
            return NotifyClient(_source, _U("invalidRankGrade"), "error", 4000)
        end
    end

    DBG:Info(("[RankManagement] %s rank '%s' society %s by %s"):format(tostring(type), rankName, tostring(businessId), char.charIdentifier))

    if type == "add" then
        if society:GetRankInfo(rankName) then
            return NotifyClient(_source, _U("rankExists"), "error", 4000)
        end
        DB.exec("INSERT INTO bcc_society_ranks (business_id, rank_name, rank_label, rank_pay, rank_pay_increment, rank_can_toggle_blip, rank_can_withdraw, rank_can_deposit, rank_can_edit_ranks, rank_can_manage_employees, rank_can_open_inventory, rank_can_manage_store, job_grade, rank_can_bill_players, rank_can_switch_job) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            businessId, rankName, rankLabel, rankPay, payIncrement, Flag(toggleBlip), Flag(withdraw), Flag(deposit), Flag(editRanks), Flag(manageEmployees), Flag(openInventory), Flag(canManageStore), rankJobGrade, Flag(rankCanBillPlayers), Flag(rankCanSwitchJob))
        NotifyClient(_source, _U("rankCreated"), "success", 4000)

    elseif type == "update" then
        local existing = society:GetRankInfo(rankName)
        if not existing then
            return NotifyClient(_source, _U("rankNotFound"), "error", 4000)
        end
        DB.exec("UPDATE bcc_society_ranks SET rank_label = ?, rank_pay = ?, rank_pay_increment = ?, rank_can_toggle_blip = ?, rank_can_withdraw = ?, rank_can_deposit = ?, rank_can_edit_ranks = ?, rank_can_manage_employees = ?, rank_can_open_inventory = ?, rank_can_manage_store = ?, job_grade = ?, rank_can_bill_players = ?, rank_can_switch_job = ? WHERE business_id = ? AND rank_name = ?",
            rankLabel, rankPay, payIncrement, Flag(toggleBlip), Flag(withdraw), Flag(deposit), Flag(editRanks), Flag(manageEmployees), Flag(openInventory), Flag(canManageStore), rankJobGrade, Flag(rankCanBillPlayers), Flag(rankCanSwitchJob), businessId, rankName)

        -- A new grade mapping re-grades everyone holding the rank in feather-jobs.
        if existing.job_grade ~= rankJobGrade then
            for _, employee in ipairs(DB.query("SELECT employee_id FROM bcc_society_employees WHERE business_id = ? AND employee_rank = ? AND status = 'active'", businessId, rankName) or {}) do
                SocietyJobs.Enqueue(businessId, employee.employee_id, 'promote', rankJobGrade, _source)
            end
        end
        DBG:Success("[RankManagement] rank", rankName, "saved: pay", rankPay, "every", payIncrement, "min")
        NotifyClient(_source, _U("rankUpdated"), "success", 4000)

    elseif type == "delete" then
        if not society:GetRankInfo(rankName) then
            return NotifyClient(_source, _U("rankNotFound"), "error", 4000)
        end
        local holders = DB.value("SELECT COUNT(*) FROM bcc_society_employees WHERE business_id = ? AND employee_rank = ?", businessId, rankName)
        if (tonumber(holders) or 0) > 0 then
            return NotifyClient(_source, _U("rankInUse"), "error", 4000)
        end
        DB.exec("DELETE FROM bcc_society_ranks WHERE business_id = ? AND rank_name = ?", businessId, rankName)
        NotifyClient(_source, _U("rankDeleted"), "success", 4000)
    end
end)

FeatherRPC:Register("bcc-society:GetAllRanks", function(params, cb, recSource)
    if not IsSocietyMember(recSource, params.socId) then return cb(false) end
    local society = SocietyAPI:GetSociety(params.socId)
    local societyRanks = society and society:GetAllRanks()
    if societyRanks then
        return cb(societyRanks)
    else
        return cb(false)
    end
end)

-- Grades a rank may map to: the society job's grades, minus the owner grade.
FeatherRPC:Register("bcc-society:GetRankGrades", function(params, cb, recSource)
    if not IsSocietyMember(recSource, params.socId) then return cb(false) end
    local society = SocietyAPI:GetSociety(params.socId)
    local info = society and society:GetSocietyInfo()
    local job = info and SocietyJobs.JobConfig(info.society_job)
    if not job then return cb(false) end
    local grades = {}
    for _, grade in ipairs(job.grades) do
        if grade.key ~= job.ownerGrade then
            grades[#grades + 1] = { key = grade.key, label = grade.label, ordinal = grade.ordinal }
        end
    end
    table.sort(grades, function(a, b) return a.ordinal < b.ordinal end)
    return cb(grades)
end)
