-- The society ledger is its organization's feather-economy treasury. Deposits
-- and withdrawals are single Economy transfers between the acting player's own
-- wallet and that treasury; bcc-society only checks the rank permission.

FeatherRPC:Register("bcc-society:GetLedgerData", function(params, cb, recSource)
    if not IsSocietyMember(recSource, params.socId) then
        DBG:Warning("[GetLedgerData] source", recSource, "is not a member of society", params.socId)
        return cb(false)
    end
    local society = SocietyAPI:GetSociety(params.socId)
    local amount = society and society:GetLedgerAmount()
    DBG:Info("[GetLedgerData] society", params.socId, "ledger", amount)
    return cb(amount or 0)
end)

RegisterServerEvent("bcc-society:LedgerManagement", function(businessId, amount, type)
    local _source = source
    DBG:Info("[LedgerManagement] source", _source, type, amount, "society", businessId)
    local permission = type == "deposit" and "rank_can_deposit" or type == "withdraw" and "rank_can_withdraw" or nil
    if not permission then
        DBG:Warning("[LedgerManagement] invalid type", type)
        return NotifyClient(_source, _U("invalidTransactionType"), "error", 4000)
    end

    local allowed, character, society = HasSocietyPermission(_source, businessId, permission)
    if not allowed then
        DBG:Warning("[LedgerManagement] source", _source, "lacks", permission, "in society", businessId)
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    local amountToProcess = ParseAmount(amount)
    if not amountToProcess then
        DBG:Warning("[LedgerManagement] invalid amount", amount)
        return NotifyClient(_source, _U("invalidAmount"), "error", 4000)
    end

    local info = society:GetSocietyInfo()
    local treasury = SocietyEconomy.EnsureTreasury(info)
    local wallet = SocietyEconomy.GetWallet(character.charIdentifier)
    if not treasury.ok or not wallet.ok then
        DBG:Error("[LedgerManagement] money unavailable: treasury", treasury.code, "wallet", wallet.code)
        return NotifyClient(_source, _U("moneyUnavailable"), "error", 4000)
    end

    local idempotencyKey = ('society:%s:%s:%s'):format(type, businessId, Society.NewId())
    local reference = { type = 'bcc_society', id = businessId }
    local result
    if type == "deposit" then
        result = SocietyEconomy.Transfer(wallet.value, treasury.value, amountToProcess, 'society.deposit',
            reference, idempotencyKey, character)
    else
        result = SocietyEconomy.Transfer(treasury.value, wallet.value, amountToProcess, 'society.withdraw',
            reference, idempotencyKey, character)
    end

    if result.ok then
        DBG:Success("[LedgerManagement]", type, amountToProcess, "society", businessId, "by",
            character.charIdentifier, "ledger now", Config.devMode and society:GetLedgerAmount() or "")
        NotifyClient(_source, _U(type == "deposit" and "depositSuccess" or "withdrawSuccess"), "success", 4000)
    else
        DBG:Error("[LedgerManagement]", type, "failed", result.code)
        NotifyClient(_source, SocietyEconomy.Message(result, type == "deposit" and "notEnoughCash" or "notEnoughFundsInLedger"), "error", 4000)
    end
end)
