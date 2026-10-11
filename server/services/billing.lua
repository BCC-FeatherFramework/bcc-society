-- Billing (D6: the customer accepts first). The biller's rank must allow
-- billing; the bill is stored as PENDING and offered to the customer, and only
-- an accepted bill moves money: customer wallet -> society treasury
-- (society.bill), with the customer as the acting character.

local BILL_TTL_SECONDS = 120

FeatherRPC:Register("bcc-society:BillPlayer", function(params, cb, src)
    local allowed, biller, society = HasSocietyPermission(src, params.societyId, "rank_can_bill_players")
    DBG:Info("[BillPlayer] source", src, "bills", params.playerServerId, params.amount, "society", params.societyId)
    if not allowed then
        DBG:Warning("[BillPlayer] source", src, "lacks rank_can_bill_players in society", params.societyId)
        return cb(false, _U("noBillPerms"))
    end

    local billed = SocietyCharacters.Get(params.playerServerId)
    if not billed then
        DBG:Warning("[BillPlayer] target", params.playerServerId, "has no active character")
        return cb(false, _U("playerNotOnline"))
    end
    if billed.charIdentifier == biller.charIdentifier then
        DBG:Warning("[BillPlayer] refused: biller and customer are the same character")
        return cb(false, _U("cannotBillSelf"))
    end

    local cost = ParseAmount(params.amount)
    if not cost then
        DBG:Warning("Invalid cost entered: " .. tostring(params.amount))
        return cb(false, _U("invalidAmount"))
    end

    local description = type(params.description) == "string" and params.description:sub(1, 500) or ""
    local info = society:GetSocietyInfo()
    local billId = DB.insert(
        'INSERT INTO bcc_society_bills (billed_identifier, biller_identifier, billed_name, biller_name, amount, society_id, description, timestamp, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        billed.charIdentifier, biller.charIdentifier,
        billed.firstname .. " " .. billed.lastname, biller.firstname .. " " .. biller.lastname,
        cost, info.business_id, description, os.time(), "PENDING"
    )

    FeatherRPC:Notify("bcc-society:BillRequest", {
        id = billId,
        amount = cost,
        society = info.business_name,
        biller = biller.firstname .. " " .. biller.lastname,
        description = description
    }, billed.source)
    DBG:Success("[BillPlayer] bill", billId, "for", cost, "sent to", billed.charIdentifier, "(source " ..
        tostring(billed.source) .. ") society", info.business_id)
    return cb(true)
end)

-- The customer's answer. Only the billed character can answer, once.
FeatherRPC:Register("bcc-society:RespondBill", function(params, cb, src)
    local customer = SocietyCharacters.Get(src)
    DBG:Info("[RespondBill] source", src, "bill", params.billId, "accept", params.accept)
    if not customer then return cb(false) end
    local bill = DB.one("SELECT * FROM bcc_society_bills WHERE id = ? AND billed_identifier = ? AND status = 'PENDING'",
        tonumber(params.billId), customer.charIdentifier)
    if not bill then
        DBG:Warning("[RespondBill] bill", params.billId, "not pending for", customer.charIdentifier)
        NotifyClient(src, _U("receiptNotFound"), "error", 4000)
        return cb(false)
    end
    local billerSource = SocietyCharacters.FindSource(bill.biller_identifier)

    if params.accept ~= true or os.time() - tonumber(bill.timestamp) > BILL_TTL_SECONDS then
        local status = params.accept == true and "EXPIRED" or "DECLINED"
        DB.exec("UPDATE bcc_society_bills SET status = ? WHERE id = ? AND status = 'PENDING'", status, bill.id)
        DBG:Info("[RespondBill] bill", bill.id, status)
        if billerSource then NotifyClient(billerSource, _U("billDeclined"), "error", 4000) end
        if status == "EXPIRED" then NotifyClient(src, _U("billExpired"), "error", 4000) end
        return cb(false)
    end

    -- Claim the bill before paying so it can't be paid twice.
    if tonumber(DB.exec("UPDATE bcc_society_bills SET status = 'PAYING' WHERE id = ? AND status = 'PENDING'", bill.id)) ~= 1 then
        DBG:Warning("[RespondBill] bill", bill.id, "already being answered")
        return cb(false)
    end

    local society = DB.one("SELECT * FROM bcc_society WHERE business_id = ? AND status = 'active'", bill.society_id)
    local treasury = society and SocietyEconomy.EnsureTreasury(society)
    local wallet = SocietyEconomy.GetWallet(customer.charIdentifier)
    local paid = (treasury and treasury.ok and wallet.ok) and SocietyEconomy.Transfer(wallet.value, treasury.value,
        tonumber(bill.amount), 'society.bill', { type = 'bcc_society_bill', id = bill.id },
        ('society:bill:%s'):format(bill.id), customer) or Society.Err('economy_unavailable', 'Society money is unavailable.')

    if not paid.ok then
        DB.exec("UPDATE bcc_society_bills SET status = 'FAILED' WHERE id = ?", bill.id)
        DBG:Error("[RespondBill] bill", bill.id, "payment failed:", paid.code, paid.message)
        NotifyClient(src, SocietyEconomy.Message(paid, "notEnoughCash"), "error", 4000)
        if billerSource then NotifyClient(billerSource, _U("targetNoMoney"), "error", 4000) end
        return cb(false)
    end

    DB.exec("UPDATE bcc_society_bills SET status = 'PAID', transaction_id = ? WHERE id = ?", paid.value.transactionId, bill.id)
    DBG:Success("[RespondBill] bill", bill.id, "PAID", bill.amount, "to society", bill.society_id, "tx", paid.value.transactionId)
    NotifyClient(src, _U("youHaveBeenBilled") .. bill.amount, "success", 5000)
    if billerSource then NotifyClient(billerSource, _U("billSuccess"), "success", 4000) end

    FeatherRPC:Notify("bcc-society:OpenReceiptMenu", {
        id = bill.id,
        amount = bill.amount,
        paidFrom = bill.billed_name,
        paidTo = bill.biller_name,
        society = society.business_name,
        timestamp = os.date("%Y-%m-%d %H:%M:%S", tonumber(bill.timestamp)),
        description = bill.description,
        status = "PAID"
    }, src)
    return cb(true)
end)

-- A customer may delete their own paid receipt record.
FeatherRPC:Register("bcc-society:RevokeReceipt", function(params, cb, src)
    local character = SocietyCharacters.Get(src)
    if not character or not params.receiptId then return cb(false) end
    local deleted = DB.exec("DELETE FROM bcc_society_bills WHERE id = ? AND billed_identifier = ? AND status = 'PAID'",
        tonumber(params.receiptId), character.charIdentifier)
    DBG:Info("[RevokeReceipt] receipt", params.receiptId, "deleted", tonumber(deleted) == 1)
    return cb(tonumber(deleted) == 1)
end)

-- Lists the caller's own paid receipts (newest first).
FeatherRPC:Register("bcc-society:GetMyReceipts", function(_, cb, src)
    local character = SocietyCharacters.Get(src)
    if not character then return cb(false) end
    local rows = DB.query([[SELECT b.*, s.business_name FROM bcc_society_bills b
        LEFT JOIN bcc_society s ON s.business_id = b.society_id
        WHERE b.billed_identifier = ? AND b.status = 'PAID' ORDER BY b.id DESC LIMIT 25]], character.charIdentifier) or {}
    DBG:Info("[GetMyReceipts]", character.charIdentifier, "has", #rows, "paid receipts")
    local receipts = {}
    for _, bill in ipairs(rows) do
        receipts[#receipts + 1] = {
            id = bill.id,
            amount = bill.amount,
            paidFrom = bill.billed_name,
            paidTo = bill.biller_name,
            society = bill.business_name or "-",
            timestamp = os.date("%Y-%m-%d %H:%M:%S", tonumber(bill.timestamp)),
            description = bill.description,
            status = bill.status
        }
    end
    return cb(receipts)
end)
