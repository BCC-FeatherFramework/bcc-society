-- Each society is a Feather Organization (type business, key bcc_society_<id>).
-- The organization is the society's durable identity: feather-jobs uses it as
-- the employer of every assignment, and feather-economy holds its treasury.
SocietyOrganizations = {}

local RESOURCE = 'feather-organizations'
local REASON_CODE = 'society.lifecycle'

local function Organizations(operation, request)
    return Society.Call(RESOURCE, operation, request)
end

local function OrganizationKey(businessId)
    return 'bcc_society_' .. tostring(businessId)
end

-- Moves the organization through its lifecycle until it reaches `target`.
local function Transition(organization, target)
    local path = target == 'active' and { 'active' } or { 'dissolving', 'dissolved' }
    local current = organization
    for _, status in ipairs(path) do
        if current.status == status or (status == 'dissolving' and current.status == 'dissolved') then
            goto continue
        end
        do
            local changed = Organizations('ChangeOrganizationStatus', {
                organizationId = current.organizationId,
                expectedRevision = current.revision,
                status = status,
                requestId = ('bcc-society:organization:%s:%s:r%d'):format(current.organizationId, status, current.revision),
                reasonCode = REASON_CODE
            })
            if not changed.ok then return changed end
            local reloaded = Organizations('GetOrganization', { organizationId = current.organizationId })
            if not reloaded.ok then return reloaded end
            current = reloaded.value
        end
        ::continue::
    end
    return Society.Ok(current)
end

-- Finds or creates the society's organization, makes sure it is active and
-- links it. Safe to repeat.
function SocietyOrganizations.Ensure(society)
    local current
    if type(society.organization_id) == 'string' and society.organization_id ~= '' then
        current = Organizations('GetOrganization', { organizationId = society.organization_id })
    else
        current = Organizations('FindOrganizationByKey', { organizationKey = OrganizationKey(society.business_id) })
        if not current.ok and current.code == 'organization_not_found' then
            local name = tostring(society.business_name):sub(1, 100)
            local created = Organizations('CreateOrganization', {
                requestId = 'bcc-society:organization:' .. society.business_id,
                organizationType = 'business',
                organizationKey = OrganizationKey(society.business_id),
                legalName = name,
                displayName = name,
                reasonCode = REASON_CODE
            })
            if not created.ok then return created end
            current = Organizations('GetOrganization', { organizationId = created.value.organizationId })
        end
    end
    if not current.ok then return current end

    local active = Transition(current.value, 'active')
    if not active.ok then return active end
    local organizationId = active.value.organizationId

    DB.exec('UPDATE `bcc_society` SET `organization_id`=? WHERE `business_id`=? AND `organization_id` IS NULL',
        organizationId, society.business_id)
    society.organization_id = organizationId

    -- The society ledger is this organization's treasury, operated by bcc-society.
    local treasury = SocietyEconomy.EnsureTreasury(society)
    if not treasury.ok then
        print(('[bcc-society] society %s treasury not bound yet: %s'):format(tostring(society.business_id), tostring(treasury.code)))
    end

    -- The owner holds the job at the configured owner grade.
    if not society.owner_assignment_id then
        local pending = DB.value([[SELECT COUNT(*) FROM `bcc_society_workflows` WHERE `business_id`=?
            AND `character_id`=? AND `operation`='owner' AND `status`='pending']], society.business_id, society.owner_id)
        if (tonumber(pending) or 0) == 0 then
            local job = SocietyJobs.JobConfig(society.society_job)
            SocietyJobs.Enqueue(society.business_id, society.owner_id, 'owner', job and job.ownerGrade, nil)
        end
    end
    return Society.Ok(organizationId)
end

-- Dissolves the organization when a society is deleted. Its history stays in
-- feather-organizations; the society row is removed by the caller.
function SocietyOrganizations.Dissolve(society)
    if not society.organization_id then return Society.Ok(true) end
    local current = Organizations('GetOrganization', { organizationId = society.organization_id })
    if not current.ok then return current end
    return Transition(current.value, 'dissolved')
end

function SocietyOrganizations.Rename(society, name)
    if not society.organization_id then return Society.Ok(true) end
    local current = Organizations('GetOrganization', { organizationId = society.organization_id })
    if not current.ok then return current end
    if current.value.displayName == name then return current end
    return Organizations('UpdateOrganizationIdentity', {
        organizationId = society.organization_id,
        expectedRevision = current.value.revision,
        legalName = name,
        displayName = name,
        requestId = ('bcc-society:organization-name:%s:r%d'):format(society.organization_id, current.value.revision),
        reasonCode = REASON_CODE
    })
end

local function ProvisionAll()
    while not DBUpdated do Wait(250) end
    local ready = Organizations('AwaitReady', 30000)
    if not ready.ok then
        return print('[bcc-society] organizations: Feather Organizations is not ready: ' .. tostring(ready.code))
    end
    local deadline = GetGameTimer() + 60000
    while not SocietyJobs.ready and GetGameTimer() < deadline do Wait(250) end

    local linked, failed = 0, 0
    for _, society in ipairs(DB.query("SELECT * FROM `bcc_society` WHERE `status`='active'") or {}) do
        local result = SocietyOrganizations.Ensure(society)
        if result.ok then
            linked = linked + 1
        else
            failed = failed + 1
            print(('[bcc-society] organizations: society %s (%s) not linked: %s %s'):format(
                tostring(society.business_id), tostring(society.business_name), tostring(result.code), tostring(result.message)))
        end
    end
    print(('[bcc-society] organizations: %d society organization(s) ready, %d failed'):format(linked, failed))
end

CreateThread(ProvisionAll)

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE or resource == 'feather-economy' then CreateThread(ProvisionAll) end
end)
