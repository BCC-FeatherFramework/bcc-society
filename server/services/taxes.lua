-- Tax handling. Each active society pays tax_amount once per month from its
-- treasury to the Economy system sink (society.tax). The idempotency key is per
-- society per month, so a restart or a mode change never charges twice. A
-- society that cannot pay is reported to its owner (once a day) and the
-- console; it is not deleted.
--
-- Config.taxOnCreationDay = true: a society pays on the day of the month it was
-- created (the last day of shorter months), starting the month after creation.
-- If the server was down on that day it pays at the next check of the month.
-- taxes_paid then holds the last paid month as YYYYMM.
--
-- Config.taxOnCreationDay = false: every society pays on Config.taxDay;
-- Config.taxResetDay marks them all unpaid ('false') for the next month.

SocietyTaxes = {}

local ownerNotified = {} -- business_id -> date the owner was last told payment failed

local function DaysInMonth(year, month)
    return tonumber(os.date("%d", os.time({ year = year, month = month + 1, day = 0, hour = 12 })))
end

-- created_at as { year, month, day }; MySQL drivers return a string or epoch milliseconds.
local function CreatedDate(society)
    local value = society.created_at
    if type(value) == "number" then
        local t = os.date("*t", math.floor(value / 1000))
        return t.year, t.month, t.day
    end
    local year, month, day = tostring(value or ""):match("^(%d+)%-(%d+)%-(%d+)")
    return tonumber(year), tonumber(month), tonumber(day)
end

-- Is this society's tax due now in creation-day mode?
local function DueByCreationDay(society, today)
    local year, month, day = CreatedDate(society)
    if not year then
        DBG:Warning("[Taxes] society", society.business_id, "has no readable created_at:", society.created_at)
        return false
    end
    if year * 12 + month >= today.year * 12 + today.month then
        DBG:Info("[Taxes] society", society.business_id, "created this month; first tax next month")
        return false
    end
    local dueDay = math.min(day, DaysInMonth(today.year, today.month))
    if today.day < dueDay then
        DBG:Info("[Taxes] society", society.business_id, "due on day", dueDay)
        return false
    end
    return true
end

local function MarkPaid(society, paidValue)
    DB.exec("UPDATE bcc_society SET taxes_paid = ? WHERE business_id = ?", paidValue, society.business_id)
end

local function Charge(society, sink, month, paidValue)
    local amount = tonumber(society.tax_amount) or 0
    DBG:Info("[Taxes] society", society.business_id, society.business_name, "owes", amount, "for", month)
    if amount <= 0 then
        MarkPaid(society, paidValue)
        return DBG:Info("[Taxes] society", society.business_id, "has no tax; marked paid")
    end
    local treasury = SocietyEconomy.EnsureTreasury(society)
    local paid = treasury.ok and SocietyEconomy.Transfer(treasury.value, sink, amount, 'society.tax',
        { type = 'bcc_society', id = society.business_id },
        ('society:tax:%s:%s'):format(society.business_id, month), nil) or treasury
    if paid.ok then
        MarkPaid(society, paidValue)
        ownerNotified[society.business_id] = nil
        return print(('[bcc-society] taxes: %s paid %d for %s'):format(society.business_name, amount, month))
    end
    print(('[bcc-society] taxes: %s could not pay %d: %s'):format(society.business_name, amount, tostring(paid.code)))
    local date = os.date("%Y-%m-%d") -- real date, so a simulated run still notifies
    local owner = SocietyCharacters.FindSource(society.owner_id)
    if owner and ownerNotified[society.business_id] ~= date then
        ownerNotified[society.business_id] = date
        NotifyClient(owner, _U("taxesFailed") .. " " .. society.business_name, "error", 6000)
    end
end

-- `now` (epoch seconds) defaults to the current time; SocietyDevTaxes passes another date.
local function CollectTaxes(now)
    now = now or os.time()
    local today = os.date("*t", now)
    local month = os.date("%Y-%m", now)

    if Config.taxOnCreationDay then
        local paidValue = os.date("%Y%m", now)
        DBG:Info("[Taxes] check (creation-day mode): today", today.day, "month", month)
        local societies = DB.query("SELECT * FROM bcc_society WHERE status = 'active' AND taxes_paid <> ?", paidValue) or {}
        local sink
        for _, society in ipairs(societies) do
            if DueByCreationDay(society, today) then
                if not sink then
                    local result = SocietyEconomy.GetSystemSink()
                    if not result.ok then
                        return print('[bcc-society] taxes: Economy unavailable: ' .. tostring(result.code))
                    end
                    sink = result.value
                end
                Charge(society, sink, month, paidValue)
            end
        end
        return
    end

    DBG:Info("[Taxes] check: day", today.day, "taxDay", Config.taxDay, "taxResetDay", Config.taxResetDay)
    if today.day == tonumber(Config.taxResetDay) then
        DB.exec("UPDATE bcc_society SET taxes_paid = 'false' WHERE status = 'active'")
        DBG:Info("[Taxes] reset day: every active society marked unpaid")
        return
    end
    if today.day ~= tonumber(Config.taxDay) then return end

    local sink = SocietyEconomy.GetSystemSink()
    if not sink.ok then
        return print('[bcc-society] taxes: Economy unavailable: ' .. tostring(sink.code))
    end
    for _, society in ipairs(DB.query("SELECT * FROM bcc_society WHERE status = 'active' AND taxes_paid = 'false'") or {}) do
        Charge(society, sink.value, month, 'true')
    end
end

SocietyTaxes.Collect = CollectTaxes

CreateThread(function()
    if not Config.taxesEnabled then return end
    while not DBUpdated do Wait(1000) end
    while true do
        if SocietyJobs.ready then
            local called, problem = pcall(CollectTaxes)
            if not called then print('[bcc-society] taxes failed: ' .. tostring(problem)) end
        end
        Wait(60 * 60 * 1000) -- hourly; each society pays at most once per month
    end
end)
