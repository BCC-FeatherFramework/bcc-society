-- Development tools (server console only, Config.devMode only).
--
-- Stand in for a second player: hire, promote, fire, duty, job switch and
-- disconnect for any character, online or offline, through the same paths the
-- menus use (membership rows plus the feather-jobs workflow). A character is
-- given as a connected server ID or a character UUID.
--
--   SocietyDevChars                                  list online players and society members
--   SocietyDevStatus <character>                     feather-jobs assignments of a character
--   SocietyDevHire   <society id> <character> [rank] hire (entry rank when omitted)
--   SocietyDevRank   <society id> <character> <rank> change rank (and Jobs grade)
--   SocietyDevFire   <society id> <character>        fire
--   SocietyDevDuty   <character> <on|off> [society id]
--   SocietyDevSwitch <character> <society id>        make that society's job the active one
--   SocietyDevLeave  <character>                     what a disconnect does: everything off duty

if not Config.devMode then return end

local UUID = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'

local function out(...)
    print('[SocietyDev] ' .. table.concat({ ... }, ' '))
end

-- Server ID of a connected player or a character UUID -> character UUID.
local function Resolve(value)
    if type(value) == 'string' and value:match(UUID) then return value:lower() end
    local character = tonumber(value) and SocietyCharacters.Get(tonumber(value))
    return character and character.charIdentifier or nil
end

local function ActiveSociety(id)
    local society = tonumber(id) and SocietyAPI:GetSociety(tonumber(id))
    if not society then return nil end
    if society:GetSocietyInfo().status ~= 'active' then return nil end
    return society
end

local function Describe(result)
    if type(result) ~= 'table' then return 'invalid_result' end
    return tostring(result.code or (result.ok and 'ok')) .. ' ' .. tostring(result.message or '')
end

-- Lowest rank by feather-jobs grade ordinal (the menu's entry rank).
local function EntryRank(society)
    local job = SocietyJobs.JobConfig(society:GetSocietyInfo().society_job)
    local ranks = society:GetAllRanks()
    if not job or not ranks or #ranks == 0 then return nil end
    local ordinals = {}
    for _, grade in ipairs(job.grades) do ordinals[grade.key] = grade.ordinal end
    table.sort(ranks, function(a, b)
        return (ordinals[a.job_grade] or math.huge) < (ordinals[b.job_grade] or math.huge)
    end)
    return ranks[1]
end

-- The character's bcc-society assignment for one society (matched by its organization).
local function AssignmentFor(characterId, society)
    local own = SocietyJobs.OwnAssignments(characterId)
    if not own then return nil end
    local organizationId = society and society:GetSocietyInfo().organization_id
    local only, count = nil, 0
    for _, assignment in pairs(own) do
        count, only = count + 1, assignment
        if organizationId and assignment.employerId == tostring(organizationId):lower() then return assignment end
    end
    if not society and count == 1 then return only end
    return nil
end

local function Command(name, handler)
    RegisterCommand(name, function(source, args)
        if source ~= 0 then return end
        CreateThread(function()
            local ok, problem = pcall(handler, args)
            if not ok then out(name, 'failed:', tostring(problem)) end
        end)
    end, true)
end

Command('SocietyDevChars', function()
    out('online players:')
    for _, playerId in ipairs(GetPlayers()) do
        local character = SocietyCharacters.Get(playerId)
        if character then out('  id', playerId, character.charIdentifier, character.firstname, character.lastname) end
    end
    out('society members:')
    for _, row in ipairs(DB.query([[
        SELECT s.business_id, s.business_name, s.owner_id AS character_id, 'owner' AS role, 'active' AS status
        FROM bcc_society s WHERE s.status = 'active'
        UNION ALL
        SELECT e.business_id, s.business_name, e.employee_id, e.employee_rank, e.status
        FROM bcc_society_employees e JOIN bcc_society s ON s.business_id = e.business_id
        WHERE s.status = 'active' ORDER BY business_id]]) or {}) do
        out('  society', row.business_id, row.business_name, '|', row.character_id,
            SocietyCharacters.GetFullName(row.character_id), '|', row.role, row.status)
    end
end)

Command('SocietyDevStatus', function(args)
    local characterId = Resolve(args[1])
    if not characterId then return out('usage: SocietyDevStatus <server id|character uuid>') end
    local snapshot = SocietyJobs.GetSnapshot(characterId)
    if not snapshot.ok then return out('Jobs unavailable:', Describe(snapshot)) end
    out(SocietyCharacters.GetFullName(characterId), characterId, 'revision', tostring(snapshot.value.revision))
    if #snapshot.value.assignments == 0 then out('  no open assignments') end
    for _, a in ipairs(snapshot.value.assignments) do
        out('  ' .. (a.assignmentId == snapshot.value.activeAssignmentId and '*' or ' '), a.jobKey, 'grade',
            tostring(a.gradeKey) .. '(' .. tostring(a.gradeOrdinal) .. ')', a.dutyState, 'rev', tostring(a.revision),
            'owner', tostring(a.ownerResource), a.assignmentId)
    end
    out('  (* = active job)')
end)

Command('SocietyDevHire', function(args)
    local society, characterId = ActiveSociety(args[1]), Resolve(args[2])
    if not society or not characterId then
        return out('usage: SocietyDevHire <active society id> <server id|character uuid> [rank]')
    end
    local info = society:GetSocietyInfo()
    if info.owner_id == characterId or society:GetEmployeeData(characterId) then
        return out('character already belongs to society', info.business_id)
    end
    local rank = args[3] and society:GetRankInfo(args[3]) or EntryRank(society)
    if not rank then return out('no such rank / society has no ranks') end
    DB.exec([[INSERT INTO bcc_society_employees (employee_id, business_id, employee_name, employee_rank, status)
        VALUES (?, ?, ?, ?, 'pending_assignment')]],
        characterId, info.business_id, SocietyCharacters.GetFullName(characterId), rank.rank_name)
    SocietyJobs.Enqueue(info.business_id, characterId, 'hire', rank.job_grade, nil)
    out('hire queued:', SocietyCharacters.GetFullName(characterId), 'rank', rank.rank_name,
        '- check with SocietyReconcile / SocietyDevStatus')
end)

Command('SocietyDevRank', function(args)
    local society, characterId = ActiveSociety(args[1]), Resolve(args[2])
    if not society or not characterId or not args[3] then
        return out('usage: SocietyDevRank <society id> <server id|character uuid> <rank name>')
    end
    local employee = society:GetEmployeeData(characterId)
    if not employee or employee.status == 'pending_removal' then return out('not an employee of this society') end
    local rank = society:GetRankInfo(args[3])
    if not rank then return out('rank not found:', args[3]) end
    DB.exec("UPDATE bcc_society_employees SET employee_rank = ? WHERE business_id = ? AND employee_id = ?",
        rank.rank_name, society:GetSocietyInfo().business_id, characterId)
    SocietyJobs.Enqueue(society:GetSocietyInfo().business_id, characterId, 'promote', rank.job_grade, nil)
    out('rank change queued:', rank.rank_name, '(grade', tostring(rank.job_grade) .. ')')
end)

Command('SocietyDevFire', function(args)
    local society, characterId = ActiveSociety(args[1]), Resolve(args[2])
    if not society or not characterId then return out('usage: SocietyDevFire <society id> <server id|character uuid>') end
    local info = society:GetSocietyInfo()
    if info.owner_id == characterId then return out('the owner cannot be fired (dissolve the society instead)') end
    if not society:GetEmployeeData(characterId) then return out('not an employee of this society') end
    DB.exec("UPDATE bcc_society_employees SET status = 'pending_removal' WHERE employee_id = ? AND business_id = ?",
        characterId, info.business_id)
    SocietyJobs.Enqueue(info.business_id, characterId, 'fire', nil, nil)
    out('fire queued:', SocietyCharacters.GetFullName(characterId))
end)

Command('SocietyDevDuty', function(args)
    local characterId, state = Resolve(args[1]), args[2]
    if not characterId or (state ~= 'on' and state ~= 'off') then
        return out('usage: SocietyDevDuty <server id|character uuid> <on|off> [society id]')
    end
    local society = args[3] and ActiveSociety(args[3]) or nil
    local target = AssignmentFor(characterId, society)
    if not target then return out('no matching bcc-society assignment (give the society id when there are several)') end
    local result
    if state == 'on' then
        SocietyJobs.OffDutyAll(characterId, target.assignmentId)
        result = SocietyJobs.SetActive(characterId, target.assignmentId, nil)
        if result.ok then result = SocietyJobs.SetDuty(target.assignmentId, 'on_duty', nil) end
    else
        result = SocietyJobs.SetDuty(target.assignmentId, 'off_duty', nil)
    end
    out('duty', state, '->', Describe(result))
end)

Command('SocietyDevSwitch', function(args)
    local characterId, society = Resolve(args[1]), ActiveSociety(args[2])
    if not characterId or not society then return out('usage: SocietyDevSwitch <server id|character uuid> <society id>') end
    local target = AssignmentFor(characterId, society)
    if not target then return out('character has no job in that society') end
    SocietyJobs.OffDutyAll(characterId)
    out('switch ->', Describe(SocietyJobs.SetActive(characterId, target.assignmentId, nil)))
end)

Command('SocietyDevLeave', function(args)
    local characterId = Resolve(args[1])
    if not characterId then return out('usage: SocietyDevLeave <server id|character uuid>') end
    SocietyJobs.OffDutyAll(characterId)
    out('everything off duty for', SocietyCharacters.GetFullName(characterId), '(as on disconnect)')
end)

out('development commands registered: SocietyDevChars, SocietyDevStatus, SocietyDevHire, SocietyDevRank,',
    'SocietyDevFire, SocietyDevDuty, SocietyDevSwitch, SocietyDevLeave')
