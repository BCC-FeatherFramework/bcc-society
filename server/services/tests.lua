-- Development-only acceptance test. MUTATES DATA: it creates a throwaway
-- "Society Test <run>" society owned by the first player, walks the Feather
-- integrations, and dissolves it again. A second player (optional) is hired,
-- promoted and fired.
--   Usage (server console): SocietyLiveTest <ownerServerId> [employeeServerId]
if not Config.devMode then return end

local function WaitFor(check, timeoutMs)
    local deadline = GetGameTimer() + (timeoutMs or 20000)
    while GetGameTimer() < deadline do
        local value = check()
        if value then return value end
        Wait(250)
    end
    return nil
end

local function SocietyRow(id) return DB.one("SELECT * FROM bcc_society WHERE business_id = ?", id) end
local function Member(id, characterId)
    return DB.one("SELECT * FROM bcc_society_employees WHERE business_id = ? AND employee_id = ?", id, characterId)
end

RegisterCommand('SocietyLiveTest', function(source, args)
    if source ~= 0 then return end
    local called, reason = xpcall(function()
        local owner = SocietyCharacters.Get(args[1])
        local employee = args[2] and SocietyCharacters.Get(args[2]) or nil
        if not owner or (args[2] and not employee) then
            return print('[SocietyLiveTest] usage: SocietyLiveTest <ownerServerId> [employeeServerId] (players must be online)')
        end
        if not SocietyJobs.ready then return print('[SocietyLiveTest] FAIL feather-jobs setup is not ready') end

        local run = tostring(os.time())
        local tests = {}
        local function Check(name, value) tests[#tests + 1] = { name, value } end

        -- Create directly (the admin event adds only the staff check and input parsing).
        local ped = GetPlayerPed(owner.source)
        local position = GetEntityCoords(ped)
        local id = DB.insert([[INSERT INTO bcc_society (business_name, owner_id, tax_amount, inv_limit, coords, blip_hash,
            inventory_upgrade_stages, society_job) VALUES (?, ?, 0, 10, ?, 'blip_shop_store', 'none', 'general_store')]],
            'Society Test ' .. run, owner.charIdentifier, json.encode({ x = position.x, y = position.y, z = position.z }))
        local linked = SocietyOrganizations.Ensure(SocietyRow(id))
        Check('organization linked', linked.ok and SocietyRow(id).organization_id ~= nil)

        local ownerAssignment = WaitFor(function() return SocietyRow(id).owner_assignment_id end)
        Check('owner assignment', ownerAssignment ~= nil)
        local organizationId = SocietyRow(id).organization_id
        local ownerCheck = SocietyJobs.Check({ characterId = owner.charIdentifier, jobKey = 'general_store',
            employerType = 'organization', employerId = organizationId, gradeKey = 'owner' })
        Check('owner holds owner grade', ownerCheck.ok and ownerCheck.value.matched == true)

        if ownerAssignment then
            local active = SocietyJobs.SetActive(owner.charIdentifier, ownerAssignment, owner.source)
            local onDuty = active.ok and SocietyJobs.SetDuty(ownerAssignment, 'on_duty', owner.source) or active
            local dutyCheck = SocietyJobs.Check({ characterId = owner.charIdentifier, jobKey = 'general_store', dutyState = 'on_duty' })
            Check('duty on (facts from Jobs)', onDuty.ok and dutyCheck.ok and dutyCheck.value.matched == true)
            local offDuty = SocietyJobs.SetDuty(ownerAssignment, 'off_duty', owner.source)
            Check('duty off', offDuty.ok and offDuty.value.dutyState == 'off_duty')
        end

        local ledger = SocietyAPI:GetSociety(id):GetLedgerAmount()
        Check('treasury readable', type(ledger) == 'number')

        if employee then
            DB.exec([[INSERT INTO bcc_society_ranks (business_id, rank_name, rank_label, rank_pay, rank_pay_increment, job_grade)
                VALUES (?, 'clerk', 'Clerk', 1, 60, 'clerk'), (?, 'manager', 'Manager', 2, 60, 'manager')]], id, id)
            DB.exec([[INSERT INTO bcc_society_employees (employee_id, business_id, employee_name, employee_rank, status)
                VALUES (?, ?, ?, 'clerk', 'pending_assignment')]], employee.charIdentifier, id, employee.firstname)
            SocietyJobs.Enqueue(id, employee.charIdentifier, 'hire', 'clerk', owner.source)
            local hired = WaitFor(function()
                local row = Member(id, employee.charIdentifier)
                return row and row.status == 'active' and row.assignment_id or nil
            end)
            Check('hire workflow', hired ~= nil)

            DB.exec("UPDATE bcc_society_employees SET employee_rank = 'manager' WHERE business_id = ? AND employee_id = ?", id, employee.charIdentifier)
            SocietyJobs.Enqueue(id, employee.charIdentifier, 'promote', 'manager', owner.source)
            local promoted = hired and WaitFor(function()
                local current = SocietyJobs.GetAssignment(hired)
                return current.ok and current.value.gradeKey == 'manager' or nil
            end)
            Check('promote workflow', promoted == true)

            SocietyJobs.Enqueue(id, employee.charIdentifier, 'fire', nil, owner.source)
            local fired = WaitFor(function() return Member(id, employee.charIdentifier) == nil or nil end)
            local ended = hired and SocietyJobs.GetAssignment(hired)
            Check('fire workflow', fired == true and ended and ended.ok and ended.value.status == 'ended')
        end

        DissolveSociety(SocietyRow(id), owner.source)
        local cleared = WaitFor(function() return SocietyRow(id).owner_assignment_id == nil or nil end)
        local organization = Society.Call('feather-organizations', 'GetOrganization', { organizationId = organizationId })
        Check('dissolve ends owner job', cleared == true)
        Check('organization dissolved', organization.ok and organization.value.status == 'dissolved')
        Check('society marked dissolved', SocietyRow(id).status == 'dissolved')

        local passed = 0
        for _, test in ipairs(tests) do
            if test[2] then passed = passed + 1 end
            print(('[SocietyLiveTest] %-28s %s'):format(test[1], test[2] and 'PASS' or 'FAIL'))
        end
        print(('[SocietyLiveTest] done %d/%d passed (MUTATING: society %s, dissolved)'):format(passed, #tests, tostring(id)))
    end, debug.traceback)
    if not called then print('[SocietyLiveTest] FAIL ' .. tostring(reason)) end
end, true)
