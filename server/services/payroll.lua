-- Server-side payroll. Replaces the old client timer, which sent its own pay
-- amount. Every minute the server checks each online employee's bcc-society
-- assignments in feather-jobs; while one is on duty, minutes accrue, and every
-- rank_pay_increment minutes rank_pay is owed (employee_payment). Collecting
-- pays the owed amount from the society treasury into the employee's wallet.

local onDutyMinutes = {}         -- "business:character" -> minutes since the last accrual
local playerPaymentCooldowns = {} -- character -> last collection time

local function AccrueFor(character)
    local own = SocietyJobs.OwnAssignments(character.charIdentifier)
    if not own then return end
    for assignmentId, assignment in pairs(own) do
        if assignment.dutyState == 'on_duty' then
            local employee = DB.one([[SELECT e.business_id, e.employee_rank, r.rank_pay, r.rank_pay_increment
                FROM bcc_society_employees e
                JOIN bcc_society_ranks r ON r.business_id = e.business_id AND r.rank_name = e.employee_rank
                WHERE e.assignment_id = ? AND e.status = 'active']], assignmentId)
            if employee then
                local key = employee.business_id .. ':' .. character.charIdentifier
                local minutes = (onDutyMinutes[key] or 0) + 1
                local interval = math.max(1, tonumber(employee.rank_pay_increment) or 1)
                if minutes >= interval then
                    minutes = 0
                    DB.exec([[UPDATE bcc_society_employees SET employee_payment = employee_payment + ?
                        WHERE business_id = ? AND employee_id = ?]],
                        math.max(0, tonumber(employee.rank_pay) or 0), employee.business_id, character.charIdentifier)
                end
                onDutyMinutes[key] = minutes
            end
        end
    end
end

CreateThread(function()
    while not DBUpdated do Wait(500) end
    while true do
        Wait(60000)
        if SocietyJobs.ready then
            for _, playerId in ipairs(GetPlayers()) do
                local character = SocietyCharacters.Get(playerId)
                if character then
                    local called, problem = pcall(AccrueFor, character)
                    if not called then print('[bcc-society] payroll accrual failed: ' .. tostring(problem)) end
                end
            end
        end
    end
end)

FeatherRPC:Register("bcc-society:GetPaymentAmount", function(params, cb, recSource)
    local char = SocietyCharacters.Get(recSource)
    if not char then return cb(false) end

    local employeeData = DB.one("SELECT employee_payment FROM bcc_society_employees WHERE employee_id = ? AND business_id = ? AND status = 'active'",
        char.charIdentifier, params.socId)
    local paymentAmount = employeeData and tonumber(employeeData.employee_payment)
    if paymentAmount and paymentAmount > 0 then
        cb(paymentAmount)
    else
        cb(false)
    end
end)

RegisterServerEvent("bcc-society:CollectPayment", function(businessId)
    local _source = source
    local char = SocietyCharacters.Get(_source)
    if not char then return end

    local currentTime = os.time()
    local cooldownTime = 120
    local last = playerPaymentCooldowns[char.charIdentifier]
    if last and currentTime - last < cooldownTime then
        return NotifyClient(_source, _U('cooldownActive'), "error", 4000)
    end

    local society = DB.one("SELECT * FROM bcc_society WHERE business_id = ? AND status = 'active'", businessId)
    local employeeData = DB.one("SELECT employee_payment FROM bcc_society_employees WHERE employee_id = ? AND business_id = ? AND status = 'active'",
        char.charIdentifier, businessId)
    if not society or not employeeData then
        return NotifyClient(_source, _U('youCannotCollect'), "error", 4000)
    end
    local payAmount = tonumber(employeeData.employee_payment)
    if not payAmount or payAmount <= 0 then
        return NotifyClient(_source, _U('youCannotCollect'), "error", 4000)
    end

    local treasury = SocietyEconomy.EnsureTreasury(society)
    local wallet = SocietyEconomy.GetWallet(char.charIdentifier)
    if not treasury.ok or not wallet.ok then
        return NotifyClient(_source, _U("moneyUnavailable"), "error", 4000)
    end

    -- Reserve the owed amount first so two collections can't both pay it.
    local reserved = DB.exec([[UPDATE bcc_society_employees SET employee_payment = employee_payment - ?
        WHERE employee_id = ? AND business_id = ? AND employee_payment >= ?]], payAmount, char.charIdentifier, businessId, payAmount)
    if tonumber(reserved) ~= 1 then
        return NotifyClient(_source, _U('youCannotCollect'), "error", 4000)
    end

    local paid = SocietyEconomy.Transfer(treasury.value, wallet.value, payAmount, 'society.payroll',
        { type = 'bcc_society', id = businessId }, ('society:payroll:%s:%s'):format(businessId, Society.NewId()), char)
    if not paid.ok then
        DB.exec([[UPDATE bcc_society_employees SET employee_payment = employee_payment + ?
            WHERE employee_id = ? AND business_id = ?]], payAmount, char.charIdentifier, businessId)
        return NotifyClient(_source, SocietyEconomy.Message(paid, "insufficientFunds"), "error", 4000)
    end

    playerPaymentCooldowns[char.charIdentifier] = currentTime
    NotifyClient(_source, _U('youHaveCollected') .. tostring(payAmount), "success", 4000)
end)
