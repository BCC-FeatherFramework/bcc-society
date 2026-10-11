-- Tax handling. On Config.taxDay each active society pays tax_amount from its
-- treasury to the Economy system sink (society.tax). The idempotency key is per
-- society per month, so a restart on tax day never charges twice. A society
-- that cannot pay is reported to its owner and the console; it is not deleted.
-- On Config.taxResetDay every society is marked unpaid for the next month.

local function CollectTaxes()
    local day = tonumber(os.date("%d"))
    local month = os.date("%Y-%m")
    DBG:Info("[Taxes] check: day", day, "taxDay", Config.taxDay, "taxResetDay", Config.taxResetDay)

    if day == tonumber(Config.taxResetDay) then
        DB.exec("UPDATE bcc_society SET taxes_paid = 'false' WHERE status = 'active'")
        DBG:Info("[Taxes] reset day: every active society marked unpaid")
        return
    end
    if day ~= tonumber(Config.taxDay) then return end

    local sink = SocietyEconomy.GetSystemSink()
    if not sink.ok then
        return print('[bcc-society] taxes: Economy unavailable: ' .. tostring(sink.code))
    end

    for _, society in ipairs(DB.query("SELECT * FROM bcc_society WHERE status = 'active' AND taxes_paid = 'false'") or {}) do
        local amount = tonumber(society.tax_amount) or 0
        DBG:Info("[Taxes] society", society.business_id, society.business_name, "owes", amount)
        if amount <= 0 then
            DB.exec("UPDATE bcc_society SET taxes_paid = 'true' WHERE business_id = ?", society.business_id)
            DBG:Info("[Taxes] society", society.business_id, "has no tax; marked paid")
        else
            local treasury = SocietyEconomy.EnsureTreasury(society)
            local paid = treasury.ok and SocietyEconomy.Transfer(treasury.value, sink.value, amount, 'society.tax',
                { type = 'bcc_society', id = society.business_id },
                ('society:tax:%s:%s'):format(society.business_id, month), nil) or treasury
            if paid.ok then
                DB.exec("UPDATE bcc_society SET taxes_paid = 'true' WHERE business_id = ?", society.business_id)
                print(('[bcc-society] taxes: %s paid %d'):format(society.business_name, amount))
            else
                print(('[bcc-society] taxes: %s could not pay %d: %s'):format(society.business_name, amount, tostring(paid.code)))
                local owner = SocietyCharacters.FindSource(society.owner_id)
                if owner then NotifyClient(owner, _U("taxesFailed") .. " " .. society.business_name, "error", 6000) end
            end
        end
    end
end

CreateThread(function()
    if not Config.taxesEnabled then return end
    while not DBUpdated do Wait(1000) end
    while true do
        if SocietyJobs.ready then
            local called, problem = pcall(CollectTaxes)
            if not called then print('[bcc-society] taxes failed: ' .. tostring(problem)) end
        end
        Wait(60 * 60 * 1000) -- hourly; collection itself happens once per tax day
    end
end)
