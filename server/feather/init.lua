-- bcc-society's boundary to the Feather Framework (server side).
--
-- Keeps the call shapes the existing services were written against
-- (DBG, NotifyClient, an RPC object, character objects with
-- charIdentifier/firstname/lastname) while every value now comes from
-- feather-core sessions and the Character provider. Character IDs are UUIDs.

Society = Society or {}

function Society.Ok(value) return { ok = true, value = value } end
function Society.Err(code, message, details)
    return { ok = false, code = code, message = message, details = details }
end

-- Debug output in dev mode: DBG:Info / DBG:Success / DBG:Warning / DBG:Error(...)
-- (DBG.Info(...) works too). Tables are JSON-encoded. Every line gets a colored
-- label and ends with ^0, so a color never carries over to the next line.
local function debugPrinter(color, label)
    return function(first, ...)
        if not Config.devMode then return end
        local values = first == DBG and table.pack(...) or table.pack(first, ...)
        local parts = {}
        for i = 1, values.n do
            local value = values[i]
            if type(value) == "table" then
                local ok, encoded = pcall(json.encode, value)
                parts[i] = ok and encoded or tostring(value)
            else
                parts[i] = tostring(value)
            end
        end
        for line in (table.concat(parts, " ") .. "\n"):gmatch("(.-)\n") do
            print(("^%d[bcc-society %s]^0 %s^0"):format(color, label, line))
        end
    end
end

DBG = {
    Info = debugPrinter(4, "info"),
    Success = debugPrinter(2, "ok"),
    Warning = debugPrinter(3, "warn"),
    Error = debugPrinter(1, "error")
}

-- RPC ------------------------------------------------------------------------
-- Same handler shape as before: function(params, cb, source).

FeatherRPC = {}

function FeatherRPC:Register(name, handler, options)
    local registered = exports['feather-core']:RegisterRPC(name, function(params, respond, src)
        local called, problem = xpcall(handler, debug.traceback, params or {}, respond, src)
        if not called then
            print(('[bcc-society] rpc %s failed: %s'):format(name, tostring(problem)))
            respond(false)
        end
    end, options or { windowMs = 1000, maxCalls = 10, maxPayloadBytes = 8192, requireCharacter = true })
    if registered ~= true then
        print(('[bcc-society] rpc registration failed: %s'):format(name))
    end
end

function FeatherRPC:Notify(name, params, target)
    return exports['feather-core']:NotifyRPC(name, params or {}, target)
end

-- Notifications ----------------------------------------------------------------

function NotifyClient(src, message, notifyType, duration)
    if not src or tonumber(src) == 0 then return end
    local result = exports['feather-core']:SendNotification({
        source = tonumber(src),
        style = Config.NotifyStyle or 'right',
        message = tostring(message),
        duration = tonumber(duration) or 4000
    })
    if type(result) ~= 'table' or result.ok ~= true then
        DBG:Error('[NotifyClient] failed', type(result) == 'table' and result.code or 'invalid_result')
    end
end

-- Characters -----------------------------------------------------------------

SocietyCharacters = {}
local names = {} -- characterId -> { firstname, lastname }

local function IsCallable(value)
    return type(value) == 'function' or (type(value) == 'table'
        and type(rawget(value, '__cfx_functionReference')) == 'string')
end

local function ProfileProvider()
    local provider = exports['feather-core']:GetProvider('character-profile', nil, 1)
    local implementation = type(provider) == 'table' and provider.ok and provider.value.implementation or nil
    if type(implementation) ~= 'table' then return nil end
    return implementation
end

-- First and last name of any character, online or offline.
function SocietyCharacters.GetName(characterId)
    if type(characterId) ~= 'string' then return 'Unknown', 'Unknown' end
    local cached = names[characterId]
    if cached then return cached.firstname, cached.lastname end
    local provider = ProfileProvider()
    if provider and IsCallable(provider.GetProfile) then
        local profile = provider.GetProfile(characterId)
        if type(profile) == 'table' and profile.ok and type(profile.value) == 'table' then
            names[characterId] = {
                firstname = profile.value.firstName or 'Unknown',
                lastname = profile.value.lastName or 'Unknown'
            }
            return names[characterId].firstname, names[characterId].lastname
        end
    end
    return 'Unknown', 'Unknown'
end

function SocietyCharacters.GetFullName(characterId)
    local firstname, lastname = SocietyCharacters.GetName(characterId)
    return firstname .. " " .. lastname
end

-- The active character of a connected player, or nil. The identity comes from
-- the Core session; nothing the client sends is trusted.
function SocietyCharacters.Get(src)
    src = tonumber(src)
    if not src or src <= 0 then return nil end
    local session = exports['feather-core']:GetSessionContext(src)
    if type(session) ~= 'table' or not session.ok or type(session.value) ~= 'table'
        or type(session.value.characterId) ~= 'string' then
        return nil
    end
    local characterId = session.value.characterId
    local firstname, lastname = SocietyCharacters.GetName(characterId)
    return {
        source = src,
        charIdentifier = characterId,
        identifier = characterId,
        accountId = session.value.accountId,
        firstname = firstname,
        lastname = lastname
    }
end

-- Server ID of a character if they are online, else nil.
function SocietyCharacters.FindSource(characterId)
    for _, playerId in ipairs(GetPlayers()) do
        local character = SocietyCharacters.Get(playerId)
        if character and character.charIdentifier == characterId then return tonumber(playerId) end
    end
    return nil
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'feather-character' then names = {} end
end)

-- Domain calls ---------------------------------------------------------------
-- Calls a Feather domain export so the invoking resource is bcc-society, and
-- turns exceptions or malformed replies into error envelopes.

function Society.Call(resource, operation, request)
    if GetResourceState(resource) ~= 'started' then
        return Society.Err('dependency_unavailable', resource .. ' is not started.')
    end
    local called, result = pcall(function()
        local provider = exports[resource]
        return provider[operation](provider, request)
    end)
    if not called or type(result) ~= 'table' or type(result.ok) ~= 'boolean' then
        return Society.Err('dependency_unavailable', ('%s %s failed.'):format(resource, operation))
    end
    return result
end

-- A stable request ID for operations that are retried.
function Society.NewId()
    return DB.value('SELECT UUID()')
end
