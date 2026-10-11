-- bcc-society's boundary to feather-economy.
--
-- bcc-society keeps no balances. A society's ledger is its organization's
-- dollars treasury, bound to bcc-society with EnsureOperatedTreasury; Economy
-- only accepts society.* movements against a treasury bound to this resource.
-- bcc-society amounts are whole dollars; Economy amounts are cents.

SocietyEconomy = {}

local RESOURCE = 'feather-economy'
local CURRENCY = 'dollars'
local treasuries = {} -- business_id -> treasury account id

local function Economy(operation, request, context)
    if GetResourceState(RESOURCE) ~= 'started' then
        return Society.Err('economy_unavailable', 'Feather Economy is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[RESOURCE]
        return provider[operation](provider, request, context)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return Society.Err('economy_unavailable', ('Feather Economy %s failed.'):format(operation))
    end
    return result
end

function SocietyEconomy.ToMinor(dollars) return math.floor(dollars * 100 + 0.5) end
function SocietyEconomy.ToDollars(minor) return (tonumber(minor) or 0) / 100 end

-- Binds (once) and returns the society's dollars treasury account ID.
function SocietyEconomy.EnsureTreasury(society)
    if treasuries[society.business_id] then return Society.Ok(treasuries[society.business_id]) end
    if not society.organization_id then
        return Society.Err('not_ready', 'Society organization is not linked yet.')
    end
    local result = Economy('EnsureOperatedTreasury', { organizationId = society.organization_id })
    if not result.ok then
        DBG:Error("[Economy] treasury for society", society.business_id, "failed:", result.code, result.message)
        return result
    end
    for _, account in ipairs(result.value) do
        if account.accountType == 'treasury' and account.currency == CURRENCY then
            treasuries[society.business_id] = account.accountId
            DBG:Info("[Economy] society", society.business_id, "treasury bound:", account.accountId)
            return Society.Ok(account.accountId)
        end
    end
    DBG:Error("[Economy] society", society.business_id, "has no dollars treasury")
    return Society.Err('treasury_not_found', 'Economy returned no dollars treasury.')
end

function SocietyEconomy.GetLedgerAmount(society)
    if not society then return false end
    local treasury = SocietyEconomy.EnsureTreasury(society)
    if not treasury.ok then return false end
    local account = Economy('GetAccount', { accountId = treasury.value })
    if not account.ok then
        DBG:Error("[Economy] ledger read for society", society.business_id, "failed:", account.code)
        return false
    end
    DBG:Info("[Economy] society", society.business_id, "ledger balance:", SocietyEconomy.ToDollars(account.value.balance))
    return SocietyEconomy.ToDollars(account.value.balance)
end

function SocietyEconomy.GetWallet(characterId)
    local result = Economy('EnsureCharacterWallets', { characterId = characterId })
    if not result.ok then
        DBG:Error("[Economy] wallet for", characterId, "failed:", result.code, result.message)
        return result
    end
    for _, account in ipairs(result.value) do
        if account.accountType == 'wallet' and account.currency == CURRENCY then
            return Society.Ok(account.accountId)
        end
    end
    DBG:Error("[Economy] character", characterId, "has no dollars wallet")
    return Society.Err('wallet_not_found', 'Economy returned no dollars wallet.')
end

function SocietyEconomy.GetSystemSink()
    local result = Economy('GetSystemAccount', { currency = CURRENCY, accountType = 'system_sink' })
    if not result.ok then
        DBG:Error("[Economy] system sink unavailable:", result.code, result.message)
        return result
    end
    return Society.Ok(result.value.accountId)
end

-- Moves whole dollars between two Economy accounts. `actor` is the character
-- object of the player acting (from their session), or nil for server jobs.
function SocietyEconomy.Transfer(fromAccountId, toAccountId, dollars, reasonCode, reference, idempotencyKey, actor)
    DBG:Info("[Economy] transfer", reasonCode, dollars, "from", fromAccountId, "to", toAccountId,
        "by", actor and actor.charIdentifier or "server", "key", idempotencyKey)
    local result = Economy('Transfer', {
        fromAccountId = fromAccountId,
        toAccountId = toAccountId,
        currency = CURRENCY,
        amount = SocietyEconomy.ToMinor(dollars),
        reasonCode = reasonCode,
        referenceType = reference and reference.type or nil,
        referenceId = reference and tostring(reference.id) or nil,
        idempotencyKey = idempotencyKey
    }, {
        actorCharacterId = actor and actor.charIdentifier or nil,
        actorAccountId = actor and actor.accountId or nil,
        correlationId = idempotencyKey
    })
    if result.ok then
        local value = type(result.value) == 'table' and result.value or {}
        DBG:Success("[Economy] transfer", reasonCode, dollars, "done: tx", value.transactionId,
            "replayed", value.replayed)
    else
        DBG:Error("[Economy] transfer", reasonCode, dollars, "failed:", result.code, result.message)
    end
    return result
end

-- Readable player message for common Economy refusals.
function SocietyEconomy.Message(result, insufficientKey)
    local code = type(result) == 'table' and result.code or nil
    if code == 'insufficient_funds' then return _U(insufficientKey or "notEnoughCash") end
    if code == 'economy_unavailable' or code == 'not_ready' or code == 'dependency_unavailable' then
        return _U("moneyUnavailable")
    end
    return _U("transactionFailed")
end

AddEventHandler('onResourceStart', function(resource)
    if resource == RESOURCE then treasuries = {} end
end)
