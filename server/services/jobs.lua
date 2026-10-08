-- Duty and job switching. feather-jobs holds the facts: every membership (and
-- each owner) has a Jobs assignment with its own duty state, and the character's
-- active assignment says which society job they are working right now. The old
-- "off" prefixes on job and rank names are gone.

FeatherRPC:Register("bcc-society:GetAllSocietyJobsPlayerEmployedAt", function(params, cb, recSource)
    local char = SocietyCharacters.Get(recSource)
    if not char then return cb(false) end
    local jobs = SocietyAPI.MiscAPI:GetAllSocietyJobsFromSocietiesPlayerEmployedAtOrOwns(char.charIdentifier)
    if jobs then
        return cb(jobs)
    else
        return cb(false)
    end
end)

local function findSocietyByIdentifier(charIdentifier, identifier, employments, ownedSocieties)
    if type(identifier) ~= "string" or identifier == "" then
        return nil
    end

    local identLower = identifier:lower()
    local numericId = tonumber(identifier)

    employments = employments or SocietyAPI.MiscAPI:GetAllSocietiesCharIsEmployedAt(charIdentifier)
    if employments then
        for _, employment in ipairs(employments) do
            if numericId and employment.business_id == numericId then
                return SocietyAPI:GetSociety(employment.business_id)
            end

            if type(employment.employee_rank) == "string" and employment.employee_rank:lower() == identLower then
                return SocietyAPI:GetSociety(employment.business_id)
            end

            local society = SocietyAPI:GetSociety(employment.business_id)
            if society then
                local info = society:GetSocietyInfo()
                if info then
                    if type(info.society_job) == "string" and info.society_job:lower() == identLower then
                        return society
                    end
                    if type(info.business_name) == "string" and info.business_name:lower() == identLower then
                        return society
                    end
                end
            end
        end
    end

    ownedSocieties = ownedSocieties or SocietyAPI.MiscAPI:GetAllSocietiesCharOwns(charIdentifier)
    if ownedSocieties then
        for _, info in ipairs(ownedSocieties) do
            if numericId and info.business_id == numericId then
                return SocietyAPI:GetSociety(info.business_id)
            end
            if type(info.society_job) == "string" and info.society_job:lower() == identLower then
                return SocietyAPI:GetSociety(info.business_id)
            end
            if type(info.business_name) == "string" and info.business_name:lower() == identLower then
                return SocietyAPI:GetSociety(info.business_id)
            end
        end
    end

    return nil
end

local function resolveSocietyRank(society, rankInput, character)
    if not society or type(rankInput) ~= "string" then
        return nil, nil, "invalid"
    end

    local trimmed = rankInput:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil, nil, "invalid"
    end

    local lower = trimmed:lower()
    local ownerId = society:GetSocietyOwnerCharacterId()
    local charIdentifier = character and character.charIdentifier or nil
    local charIsOwner = ownerId and charIdentifier and ownerId == charIdentifier

    local function evaluate(rankRow)
        if not rankRow then
            return nil, nil, "notFound"
        end
        local canSwitch = tostring(rankRow.rank_can_switch_job or "false"):lower()
        if canSwitch == "true" or charIsOwner then
            return rankRow.rank_name, rankRow, "ok"
        end
        return nil, nil, "noPermission"
    end

    local name, info, reason = evaluate(society:GetRankInfo(trimmed))
    if name then
        devPrint(string.format("[resolveSocietyRank] Matched exact rank '%s' for society %s", name, tostring(society.id)))
        return name, info, reason
    elseif reason == "noPermission" then
        devPrint(string.format("[resolveSocietyRank] Rank '%s' found but lacks switch permission", trimmed))
        return nil, nil, reason
    end

    local allRanks = society:GetAllRanks()
    if allRanks then
        for _, rankData in ipairs(allRanks) do
            if type(rankData.rank_name) == "string" and rankData.rank_name:lower() == lower then
                return evaluate(rankData)
            end
            if type(rankData.rank_label) == "string" and rankData.rank_label ~= "none" and rankData.rank_label:lower() == lower then
                return evaluate(rankData)
            end
        end
    end

    devPrint(string.format("[resolveSocietyRank] Could not resolve '%s' for society %s", trimmed, tostring(society.id)))
    return nil, nil, "notFound"
end

-- The feather-jobs assignment this character holds through the society.
local function membershipAssignment(society, character)
    local info = society:GetSocietyInfo()
    if info and info.owner_id == character.charIdentifier then
        return info.owner_assignment_id
    end
    local employee = society:GetEmployeeData(character.charIdentifier)
    return employee and employee.status == 'active' and employee.assignment_id or nil
end

-- Makes the society the character's active job and puts them on duty there,
-- off duty everywhere else in bcc-society.
local function setActiveSocietyJob(src, character, society)
    if not society then
        NotifyClient(src, _U("noRankSetCanNotSwitchJob"), "error", 4000)
        return false
    end

    local assignmentId = membershipAssignment(society, character)
    if not assignmentId then
        NotifyClient(src, _U("noRankSetCanNotSwitchJob"), "error", 4000)
        devPrint(string.format("[setActiveSocietyJob] No assignment for char %s in society %s", tostring(character.charIdentifier), tostring(society.id)))
        return false
    end

    SocietyJobs.OffDutyAll(character.charIdentifier, assignmentId)
    local activated = SocietyJobs.SetActive(character.charIdentifier, assignmentId, src)
    if not activated.ok then
        NotifyClient(src, _U("jobServiceUnavailable"), "error", 4000)
        devPrint("[setActiveSocietyJob] SetActive failed", activated.code)
        return false
    end
    local duty = SocietyJobs.SetDuty(assignmentId, 'on_duty', src)
    if not duty.ok then
        NotifyClient(src, _U("jobServiceUnavailable"), "error", 4000)
        devPrint("[setActiveSocietyJob] SetDuty failed", duty.code)
        return false
    end
    devPrint(string.format("[setActiveSocietyJob] Char %s now active in society %s (assignment %s)", tostring(character.charIdentifier), tostring(society.id), assignmentId))
    return true
end

-- Applies a self-selected switchable rank (rank_can_switch_job) before switching.
local function applyRequestedRank(src, character, society, rankName)
    local employeeData = society:GetEmployeeData(character.charIdentifier)
    if not employeeData or employeeData.status ~= 'active' then
        -- Owners already hold the owner grade; they don't take a member rank.
        return society:GetSocietyOwnerCharacterId() == character.charIdentifier
    end
    if employeeData.employee_rank ~= rankName then
        local rankInfo = society:GetRankInfo(rankName)
        DB.exec("UPDATE bcc_society_employees SET employee_rank = ? WHERE business_id = ? AND employee_id = ?",
            rankName, society.id, character.charIdentifier)
        SocietyJobs.Enqueue(society.id, character.charIdentifier, 'promote', rankInfo.job_grade, src)
    end
    return true
end

local jobSwitchCooldowns = {}

RegisterServerEvent("bcc-society:UpdateJob", function(jobName, societyId, desiredRank)
    local src = source
    local character = SocietyCharacters.Get(src)
    if not character then return end

    devPrint(string.format("[UpdateJob] char %s requested job '%s' society %s desiredRank '%s'", tostring(character.charIdentifier), tostring(jobName), tostring(societyId), tostring(desiredRank)))

    if (not societyId or societyId == 0) and (not jobName or jobName == "" or jobName == "none") then
        NotifyClient(src, _U("switchJobNotFound"), "error", 4000)
        return
    end

    local society = societyId and SocietyAPI:GetSociety(societyId) or nil
    if not society and jobName and jobName ~= "" and jobName ~= "none" then
        society = findSocietyByIdentifier(character.charIdentifier, jobName)
    end
    if not society or not IsSocietyMember(src, society.id) then
        NotifyClient(src, _U("switchJobNotFound"), "error", 4000)
        return
    end

    local requestedRankName, _, rankResolutionReason
    if desiredRank then
        requestedRankName, _, rankResolutionReason = resolveSocietyRank(society, desiredRank, character)
        if not requestedRankName and rankResolutionReason == "noPermission" then
            NotifyClient(src, _U("rankNoSwitchPermission"), "error", 4000)
            return
        end
    end

    if requestedRankName and not applyRequestedRank(src, character, society, requestedRankName) then
        NotifyClient(src, _U("noRankSetCanNotSwitchJob"), "error", 4000)
        return
    end

    if setActiveSocietyJob(src, character, society) then
        NotifyClient(src, _U("jobChanged"), "success", 4000)
    end
end)

-- Puts the character on duty for their active society job (or their only one).
RegisterServerEvent("bcc-society:ToggleOnDuty", function()
    local src = source
    local character = SocietyCharacters.Get(src)
    if not character then return end

    local own, snapshot = SocietyJobs.OwnAssignments(character.charIdentifier)
    if not own then
        return NotifyClient(src, _U("jobServiceUnavailable"), "error", 4000)
    end

    local target = snapshot.value.activeAssignmentId and own[snapshot.value.activeAssignmentId] or nil
    if not target then
        local count, only = 0, nil
        for _, assignment in pairs(own) do count = count + 1; only = assignment end
        if count == 1 then target = only end
    end
    if not target then
        if next(own) == nil then
            NotifyClient(src, _U("notEmployedCannotToggle"), "error", 4000)
        else
            NotifyClient(src, _U("switchJobFirst"), "error", 4000)
        end
        return
    end
    if target.dutyState == 'on_duty' then
        return NotifyClient(src, _U("alreadyOnDuty"), "error", 4000)
    end
    if target.dutyState == 'suspended' then
        return NotifyClient(src, _U("dutySuspended"), "error", 4000)
    end

    SocietyJobs.OffDutyAll(character.charIdentifier, target.assignmentId)
    local active = SocietyJobs.SetActive(character.charIdentifier, target.assignmentId, src)
    local duty = active.ok and SocietyJobs.SetDuty(target.assignmentId, 'on_duty', src) or active
    if duty.ok then
        NotifyClient(src, _U("onDuty"), "success", 4000)
    else
        NotifyClient(src, _U("jobServiceUnavailable"), "error", 4000)
    end
end)

RegisterServerEvent("bcc-society:ToggleOffDuty", function()
    local src = source
    local character = SocietyCharacters.Get(src)
    if not character then return end

    local own = SocietyJobs.OwnAssignments(character.charIdentifier)
    if not own then
        return NotifyClient(src, _U("jobServiceUnavailable"), "error", 4000)
    end
    local onDuty = false
    for _, assignment in pairs(own) do
        if assignment.dutyState == 'on_duty' then onDuty = true end
    end
    if not onDuty then
        return NotifyClient(src, _U("alreadyOffDuty"), "error", 4000)
    end
    SocietyJobs.OffDutyAll(character.charIdentifier)
    NotifyClient(src, _U("offDuty"), "success", 4000)
end)

RegisterServerEvent("bcc-society:SwitchJobCommand", function(rawIdentifier)
    local src = source
    local character = SocietyCharacters.Get(src)
    if not character then return end

    devPrint(string.format("[SwitchJobCommand] char %s input '%s'", tostring(character.charIdentifier), tostring(rawIdentifier)))

    if type(rawIdentifier) ~= "string" then
        NotifyClient(src, _U("switchJobUsage"), "error", 4000)
        return
    end

    local identifier = rawIdentifier:match("^%s*(.-)%s*$")
    if not identifier or identifier == "" then
        NotifyClient(src, _U("switchJobUsage"), "error", 4000)
        return
    end

    local cooldownSeconds = tonumber(Config.switchJobCooldownSeconds) or 0
    local now = os.time()

    if cooldownSeconds > 0 then
        local lastSwitch = jobSwitchCooldowns[character.charIdentifier] or 0
        local remaining = cooldownSeconds - (now - lastSwitch)
        if remaining > 0 then
            NotifyClient(src, string.format(_U("switchJobCooldown"), remaining), "error", 4000)
            return
        end
    end

    local employments = SocietyAPI.MiscAPI:GetAllSocietiesCharIsEmployedAt(character.charIdentifier)
    local ownedSocieties = SocietyAPI.MiscAPI:GetAllSocietiesCharOwns(character.charIdentifier)
    local hasEmployment = type(employments) == "table" and #employments > 0
    local hasOwned = type(ownedSocieties) == "table" and #ownedSocieties > 0

    if not hasEmployment and not hasOwned then
        NotifyClient(src, _U("switchJobNoEmployment"), "error", 4000)
        return
    end

    local society = findSocietyByIdentifier(character.charIdentifier, identifier, employments, ownedSocieties)
    if not society then
        NotifyClient(src, _U("switchJobNotFound"), "error", 4000)
        return
    end

    local rankNameCandidate, _, candidateReason = resolveSocietyRank(society, identifier, character)
    if rankNameCandidate then
        if not applyRequestedRank(src, character, society, rankNameCandidate) then
            NotifyClient(src, _U("noRankSetCanNotSwitchJob"), "error", 4000)
            return
        end
    elseif candidateReason == "noPermission" then
        NotifyClient(src, _U("rankNoSwitchPermission"), "error", 4000)
        return
    end

    if setActiveSocietyJob(src, character, society) then
        NotifyClient(src, _U("jobChanged"), "success", 4000)
        if cooldownSeconds > 0 then
            jobSwitchCooldowns[character.charIdentifier] = now
        end
    end
end)

-- Logout or disconnect: the leaving character goes off duty in every society.
local leavingSubscription
local function SubscribeLeaving()
    if leavingSubscription then
        pcall(function() exports['feather-core']:UnsubscribeEvent(leavingSubscription) end)
        leavingSubscription = nil
    end
    local subscribed = exports['feather-core']:SubscribeEvent('character.leaving.v1', function(payload)
        local characterId = type(payload) == 'table' and payload.characterId or nil
        if type(characterId) ~= 'string' then return end
        CreateThread(function() SocietyJobs.OffDutyAll(characterId) end)
    end)
    if type(subscribed) == 'table' and subscribed.ok then
        leavingSubscription = subscribed.value.token
    else
        print('[bcc-society] could not subscribe to character.leaving.v1: ' .. tostring(type(subscribed) == 'table' and subscribed.code))
    end
end

CreateThread(function()
    Wait(1000)
    SubscribeLeaving()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-character' or resource == 'feather-core' then
        CreateThread(function() Wait(1000) SubscribeLeaving() end)
    end
end)

-- Shutdown: everyone on duty in a society goes off duty (online or not).
-- Everyone starts off duty after bcc-society (re)starts. This runs on start, not
-- on stop: a stopping resource cannot wait for feather-jobs to answer.
CreateThread(function()
    local waited = 0
    while not SocietyJobs.ready and waited < 60000 do
        Wait(500)
        waited = waited + 500
    end
    if not SocietyJobs.ready then return end
    local members = DB.query([[
        SELECT `owner_id` AS `character_id` FROM `bcc_society` WHERE `status` = 'active'
        UNION
        SELECT `employee_id` FROM `bcc_society_employees`
    ]]) or {}
    for _, member in ipairs(members) do
        SocietyJobs.OffDutyAll(member.character_id)
    end
    devPrint('[jobs] start-up duty reset for ' .. #members .. ' member(s)')
end)
