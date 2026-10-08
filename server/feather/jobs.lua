-- bcc-society as a feather-jobs consumer.
--
-- Jobs owns job definitions, grades, assignments, duty and the active job.
-- bcc-society owns societies, ranks, memberships and the rank -> grade mapping,
-- and stores the returned assignment ID on its own membership row.
--
-- Hire, promote, fire and owner changes are durable workflows
-- (bcc_society_workflows): the row is written first, then a worker calls Jobs
-- with the row's stable request ID and retries after timeouts or restarts.

SocietyJobs = { ready = false }

local RESOURCE = 'feather-jobs'
local EMPLOYER_TYPE = 'organization'

-- Codes that mean "try again later"; anything else fails the workflow.
local RETRYABLE = {
    transaction_failed = true, dependency_unavailable = true, not_ready = true,
    policy_unavailable = true, character_provider_unavailable = true,
    employer_provider_unavailable = true, internal_error = true, actor_unavailable = true
}

local function Jobs(operation, request)
    return Society.Call(RESOURCE, operation, request)
end

local function Describe(result)
    return ('%s %s'):format(tostring(result and result.code), tostring(result and result.message or ''))
end

-- Definitions ----------------------------------------------------------------

function SocietyJobs.JobConfig(jobKey)
    return type(jobKey) == 'string' and Config.Jobs[jobKey] or nil
end

function SocietyJobs.HasGrade(jobKey, gradeKey)
    local job = SocietyJobs.JobConfig(jobKey)
    if not job then return false end
    for _, grade in ipairs(job.grades) do
        if grade.key == gradeKey then return true end
    end
    return false
end

-- Registers every Config.Jobs entry and keeps its grades in step with config.
-- Idempotent: stable request IDs replay, and changed grades are updated with
-- the revision Jobs reports.
local function EnsureDefinition(jobKey, job)
    local registered = Jobs('RegisterJobDefinition', {
        requestId = 'bcc-society:definition:' .. jobKey,
        jobKey = jobKey,
        label = job.label,
        reasonCode = 'society.setup'
    })
    if not registered.ok and registered.code ~= 'job_key_conflict' and registered.code ~= 'idempotency_conflict' then
        return registered
    end

    local definition = Jobs('GetJobDefinition', { jobKey = jobKey })
    if not definition.ok then return definition end
    if definition.value.ownerResource ~= GetCurrentResourceName() then
        return Society.Err('job_owner_conflict', ('Job %s belongs to %s.'):format(jobKey, definition.value.ownerResource))
    end
    local jobId = definition.value.jobId

    if definition.value.status ~= 'active' or definition.value.label ~= job.label then
        local updated = Jobs('UpdateJobDefinition', {
            requestId = ('bcc-society:definition:%s:r%d'):format(jobKey, definition.value.revision),
            jobId = jobId,
            expectedRevision = definition.value.revision,
            label = job.label,
            status = 'active',
            reasonCode = 'society.setup'
        })
        if not updated.ok and updated.code ~= 'no_change' then return updated end
    end

    local existing = {}
    for _, grade in ipairs(definition.value.grades) do existing[grade.gradeKey] = grade end
    for _, grade in ipairs(job.grades) do
        local current = existing[grade.key]
        local request = {
            jobId = jobId,
            gradeKey = grade.key,
            label = grade.label,
            ordinal = grade.ordinal,
            status = 'active',
            reasonCode = 'society.setup'
        }
        local result
        if not current then
            request.requestId = ('bcc-society:grade:%s:%s:create'):format(jobKey, grade.key)
            result = Jobs('DefineGrade', request)
        elseif current.label ~= grade.label or current.ordinal ~= grade.ordinal or current.status ~= 'active' then
            request.requestId = ('bcc-society:grade:%s:%s:r%d'):format(jobKey, grade.key, current.revision)
            request.expectedRevision = current.revision
            result = Jobs('DefineGrade', request)
        end
        if result and not result.ok then return result end
    end
    return Society.Ok(jobId)
end

function SocietyJobs.Provision()
    SocietyJobs.ready = false
    local ready = Jobs('AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-society] jobs: feather-jobs is not ready: ' .. Describe(ready))
    end
    local count = 0
    for jobKey, job in pairs(Config.Jobs) do
        local ensured = EnsureDefinition(jobKey, job)
        if not ensured.ok then
            return print(('[bcc-society] jobs: job %s setup failed: %s'):format(jobKey, Describe(ensured)))
        end
        count = count + 1
    end
    SocietyJobs.ready = true
    print(('[bcc-society] jobs: ready (%d job types)'):format(count))
end

-- Reads ----------------------------------------------------------------------

function SocietyJobs.GetAssignment(assignmentId)
    return Jobs('GetAssignment', { assignmentId = assignmentId })
end

function SocietyJobs.GetSnapshot(characterId)
    return Jobs('GetEffectiveJobSnapshot', { characterId = characterId })
end

-- The character's open assignments that bcc-society created, keyed by assignment ID.
function SocietyJobs.OwnAssignments(characterId)
    local snapshot = SocietyJobs.GetSnapshot(characterId)
    if not snapshot.ok then return nil, snapshot end
    local own = {}
    for _, assignment in ipairs(snapshot.value.assignments) do
        if assignment.ownerResource == GetCurrentResourceName() then own[assignment.assignmentId] = assignment end
    end
    return own, snapshot
end

-- Facts only; the caller decides what they permit.
function SocietyJobs.Check(request)
    return Jobs('CheckAssignment', request)
end

-- Duty and active job --------------------------------------------------------

function SocietyJobs.SetDuty(assignmentId, dutyState, actorSource)
    local current = SocietyJobs.GetAssignment(assignmentId)
    if not current.ok then return current end
    if current.value.dutyState == dutyState then return Society.Ok(current.value) end
    local result = Jobs('SetDutyState', {
        requestId = ('bcc-society:duty:%s:r%d:%s'):format(assignmentId, current.value.revision, dutyState),
        assignmentId = assignmentId,
        expectedRevision = current.value.revision,
        dutyState = dutyState,
        reasonCode = 'society.duty',
        actorSource = actorSource
    })
    if not result.ok and result.code == 'no_change' then return Society.Ok(current.value) end
    return result
end

function SocietyJobs.SetActive(characterId, assignmentId, actorSource)
    local snapshot = SocietyJobs.GetSnapshot(characterId)
    if not snapshot.ok then return snapshot end
    if snapshot.value.activeAssignmentId == assignmentId then return Society.Ok(snapshot.value) end
    local result = Jobs('SetActiveAssignment', {
        requestId = ('bcc-society:active:%s:r%d:%s'):format(characterId, snapshot.value.revision, assignmentId),
        characterId = characterId,
        assignmentId = assignmentId,
        expectedRevision = snapshot.value.revision,
        reasonCode = 'society.switch_job',
        actorSource = actorSource
    })
    if not result.ok and result.code == 'no_change' then return Society.Ok(snapshot.value) end
    return result
end

-- Takes every bcc-society assignment of the character off duty (disconnect,
-- shutdown, switching societies). Never touches other resources' assignments.
function SocietyJobs.OffDutyAll(characterId, exceptAssignmentId)
    local own = SocietyJobs.OwnAssignments(characterId)
    if not own then return end
    for assignmentId, assignment in pairs(own) do
        if assignment.dutyState == 'on_duty' and assignmentId ~= exceptAssignmentId then
            local result = SocietyJobs.SetDuty(assignmentId, 'off_duty')
            if not result.ok then
                DBG:Error('[OffDutyAll] failed', assignmentId, Describe(result))
            end
        end
    end
end

-- Workflows --------------------------------------------------------------------

local processing = {}

local function Finish(workflow, status, code)
    DB.exec([[UPDATE `bcc_society_workflows` SET `status`=?, `last_code`=?, `attempts`=`attempts`+1
        WHERE `workflow_id`=?]], status, code, workflow.workflow_id)
end

local function Retry(workflow, code)
    local delay = math.min(300, 5 * (2 ^ math.min(6, tonumber(workflow.attempts) or 0)))
    DB.exec([[UPDATE `bcc_society_workflows` SET `attempts`=`attempts`+1, `last_code`=?,
        `next_attempt_at`=DATE_ADD(CURRENT_TIMESTAMP, INTERVAL ? SECOND) WHERE `workflow_id`=?]],
        code, math.floor(delay), workflow.workflow_id)
end

local function NotifyBoth(workflow, actorMessage, characterMessage)
    if actorMessage and workflow.actor_source then NotifyClient(workflow.actor_source, actorMessage, "info", 4000) end
    local target = characterMessage and SocietyCharacters.FindSource(workflow.character_id)
    if target then NotifyClient(target, characterMessage, "info", 4000) end
end

-- An existing open assignment for the same character/job/employer that
-- bcc-society created is adopted instead of failing the hire.
local function Adopt(result, society)
    local details = type(result.details) == 'table' and result.details or {}
    if result.code ~= 'assignment_exists' or not details.assignmentId then return nil end
    local existing = SocietyJobs.GetAssignment(details.assignmentId)
    if existing.ok and existing.value.ownerResource == GetCurrentResourceName()
        and existing.value.employerId == society.organization_id then
        return existing
    end
    return nil
end

local function ProcessAssign(workflow, society)
    local request = {
        requestId = workflow.request_id,
        characterId = workflow.character_id,
        jobKey = society.society_job,
        gradeKey = workflow.grade_key,
        employerType = EMPLOYER_TYPE,
        employerId = society.organization_id,
        provenanceType = workflow.operation == 'owner' and 'society_owner' or 'society_membership',
        provenanceId = ('%s:%s'):format(society.business_id, workflow.character_id),
        dutyState = 'off_duty',
        reasonCode = workflow.operation == 'owner' and 'society.owner' or 'society.hire',
        actorSource = workflow.actor_source and SocietyCharacters.Get(workflow.actor_source) and workflow.actor_source or nil
    }
    local result = Jobs('CreateAssignment', request)
    if not result.ok then result = Adopt(result, society) or result end
    if not result.ok then return result end

    if workflow.operation == 'owner' then
        DB.exec('UPDATE `bcc_society` SET `owner_assignment_id`=? WHERE `business_id`=?',
            result.value.assignmentId, society.business_id)
    else
        DB.exec([[UPDATE `bcc_society_employees` SET `assignment_id`=?, `status`='active'
            WHERE `business_id`=? AND `employee_id`=?]], result.value.assignmentId, society.business_id, workflow.character_id)
        NotifyBoth(workflow, _U("employeeHired"), _U("youWereHired") .. society.business_name)
        local target = SocietyCharacters.FindSource(workflow.character_id)
        if target then TriggerClientEvent("bcc-society:SocietyStart", target, false, society) end
    end
    return result
end

local function ProcessPromote(workflow, society)
    local employee = DB.one([[SELECT `assignment_id` FROM `bcc_society_employees`
        WHERE `business_id`=? AND `employee_id`=?]], society.business_id, workflow.character_id)
    if not employee or not employee.assignment_id then
        return Society.Err('assignment_missing', 'Membership has no assignment yet.')
    end
    local current = SocietyJobs.GetAssignment(employee.assignment_id)
    if not current.ok then return current end
    if current.value.gradeKey == workflow.grade_key then return current end
    local result = Jobs('ChangeAssignmentGrade', {
        requestId = ('%s:r%d'):format(workflow.request_id, current.value.revision),
        assignmentId = employee.assignment_id,
        expectedRevision = current.value.revision,
        gradeKey = workflow.grade_key,
        reasonCode = 'society.promote',
        actorSource = workflow.actor_source and SocietyCharacters.Get(workflow.actor_source) and workflow.actor_source or nil
    })
    if not result.ok and result.code == 'no_change' then return current end
    return result
end

local function ProcessFire(workflow, society)
    local employee = DB.one([[SELECT `assignment_id` FROM `bcc_society_employees`
        WHERE `business_id`=? AND `employee_id`=?]], society.business_id, workflow.character_id)
    -- Owners have no employee row; their assignment lives on the society.
    local isOwner = not employee and society.owner_id == workflow.character_id
    local assignmentId = employee and employee.assignment_id or (isOwner and society.owner_assignment_id) or nil
    if not employee and not isOwner then return Society.Ok(true) end
    if assignmentId then
        local current = SocietyJobs.GetAssignment(assignmentId)
        if current.ok and current.value.status == 'active' then
            local result = Jobs('EndAssignment', {
                requestId = ('%s:r%d'):format(workflow.request_id, current.value.revision),
                assignmentId = assignmentId,
                expectedRevision = current.value.revision,
                reasonCode = 'society.fire',
                actorSource = workflow.actor_source and SocietyCharacters.Get(workflow.actor_source) and workflow.actor_source or nil
            })
            if not result.ok and result.code ~= 'assignment_ended' then return result end
        elseif not current.ok and current.code ~= 'assignment_not_found' then
            return current
        end
    end
    if isOwner then
        DB.exec('UPDATE `bcc_society` SET `owner_assignment_id`=NULL WHERE `business_id`=?', society.business_id)
    else
        DB.exec('DELETE FROM `bcc_society_employees` WHERE `business_id`=? AND `employee_id`=?',
            society.business_id, workflow.character_id)
    end
    return Society.Ok(true)
end

function SocietyJobs.Process(workflow)
    if processing[workflow.workflow_id] then return end
    processing[workflow.workflow_id] = true
    local called, result = xpcall(function()
        local society = DB.one('SELECT * FROM `bcc_society` WHERE `business_id`=?', workflow.business_id)
        if not society then return Society.Err('society_not_found', 'Society no longer exists.') end
        if not SocietyJobs.ready then return Society.Err('not_ready', 'Jobs setup is not complete.') end
        if workflow.operation ~= 'fire' and not society.organization_id then
            return Society.Err('not_ready', 'Society organization is not linked yet.')
        end
        if workflow.operation == 'hire' or workflow.operation == 'owner' then return ProcessAssign(workflow, society) end
        if workflow.operation == 'promote' then return ProcessPromote(workflow, society) end
        return ProcessFire(workflow, society)
    end, debug.traceback)
    processing[workflow.workflow_id] = nil

    if not called then
        print('[bcc-society] workflow error: ' .. tostring(result))
        return Retry(workflow, 'internal_error')
    end
    if result.ok then return Finish(workflow, 'done', nil) end
    if RETRYABLE[result.code] then return Retry(workflow, result.code) end

    print(('[bcc-society] workflow %s %s failed: %s'):format(workflow.operation, workflow.request_id, Describe(result)))
    Finish(workflow, 'failed', result.code)
    if workflow.operation == 'hire' then
        DB.exec([[UPDATE `bcc_society_employees` SET `status`='failed'
            WHERE `business_id`=? AND `employee_id`=? AND `status`='pending_assignment']],
            workflow.business_id, workflow.character_id)
    end
    NotifyBoth(workflow, _U("workflowFailed") .. tostring(result.code), nil)
end

-- Queues an operation and starts it right away. Returns the workflow ID.
function SocietyJobs.Enqueue(businessId, characterId, operation, gradeKey, actorSource)
    local workflowId = Society.NewId()
    local requestId = ('bcc-society:%s:%s:%s:%s'):format(operation, businessId, characterId, workflowId)
    DB.exec([[INSERT INTO `bcc_society_workflows`
        (`workflow_id`,`business_id`,`character_id`,`operation`,`request_id`,`grade_key`,`actor_source`)
        VALUES (?,?,?,?,?,?,?)]], workflowId, businessId, characterId, operation, requestId, gradeKey, actorSource)
    local workflow = DB.one('SELECT * FROM `bcc_society_workflows` WHERE `workflow_id`=?', workflowId)
    CreateThread(function() SocietyJobs.Process(workflow) end)
    return workflowId
end

-- Worker: resumes pending workflows, including ones left by a restart.
CreateThread(function()
    while not DBUpdated do Wait(500) end
    while true do
        if SocietyJobs.ready then
            local due = DB.query([[SELECT * FROM `bcc_society_workflows`
                WHERE `status`='pending' AND `next_attempt_at`<=CURRENT_TIMESTAMP
                ORDER BY `created_at` LIMIT 20]]) or {}
            for _, workflow in ipairs(due) do SocietyJobs.Process(workflow) end
        end
        Wait(Config.WorkflowPollMs or 5000)
    end
end)

-- Console: lists workflows that are still pending or have failed.
RegisterCommand('SocietyReconcile', function(source)
    if source ~= 0 then return end
    local rows = DB.query([[SELECT `operation`,`business_id`,`character_id`,`status`,`attempts`,`last_code`,`request_id`
        FROM `bcc_society_workflows` WHERE `status`<>'done' ORDER BY `created_at`]]) or {}
    print(('[bcc-society] %d open workflow(s)'):format(#rows))
    for _, row in ipairs(rows) do
        print(('  %-8s society=%s character=%s status=%s attempts=%s last=%s'):format(row.operation,
            tostring(row.business_id), row.character_id, row.status, tostring(row.attempts), tostring(row.last_code)))
    end
end, true)

CreateThread(function()
    while not DBUpdated do Wait(500) end
    SocietyJobs.Provision()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then CreateThread(SocietyJobs.Provision) end
end)
