-- Advertises bcc-society's player commands in feather-chat. Suggestions only
-- help players discover commands; every command still checks its own rules.
-- Staff commands are shown to society administrators, /bill to society owners.

local ADMIN_PROVIDER = 'bcc-society.admin-suggestions'
local OWNER_PROVIDER = 'bcc-society.owner-suggestions'
local registered = false

local function IsOwner(src)
    local character = SocietyCharacters.Get(src)
    if not character then
        return false
    end
    return DB.value("SELECT 1 FROM bcc_society WHERE owner_id = ? AND status = 'active' LIMIT 1",
        character.charIdentifier) ~= nil
end

local function Provider(name, check)
    local result = exports['feather-chat']:RegisterChannelAccessProvider(name, {
        CanView = function(request)
            local source = request.actor and tonumber(request.actor.source)
            return { ok = true, value = { allowed = source ~= nil and check(source) == true } }
        end
    })
    return result.ok or result.code == 'conflict'
end

local function Suggestion(command, key, provider)
    return {
        key = 'bcc-society.' .. command:lower(),
        trigger = '/' .. command,
        description = _U(key),
        descriptionKey = 'bcc-society.' .. key,
        accessProvider = provider
    }
end

local function Register()
    if registered or GetResourceState('feather-chat') ~= 'started' then
        return
    end
    local health = exports['feather-chat']:GetHealth()
    if type(health) ~= 'table' or not health.ok or health.value.state ~= 'ready' then
        return
    end
    if not Provider(ADMIN_PROVIDER, IsSocietyAdmin) or not Provider(OWNER_PROVIDER, IsOwner) then
        return
    end

    local definitions = {
        Suggestion(Config.createSocietyCommandName, 'chatSuggestionCreateSociety', ADMIN_PROVIDER),
        Suggestion(Config.adminMenuCommandName, 'chatSuggestionManageSocieties', ADMIN_PROVIDER),
        Suggestion(Config.openJobManagementMenuCommandName, 'chatSuggestionJobManagement'),
        Suggestion(Config.toggleOnDutyCommandName, 'chatSuggestionOnDuty'),
        Suggestion(Config.toggleOffDutyCommandName, 'chatSuggestionOffDuty'),
        Suggestion(Config.billCommandName, 'chatSuggestionBill', OWNER_PROVIDER),
        Suggestion(Config.receiptsCommandName, 'chatSuggestionReceipts')
    }
    if Config.switchJobCommandName and Config.switchJobCommandName ~= '' then
        definitions[#definitions + 1] = Suggestion(Config.switchJobCommandName, 'chatSuggestionSwitchJob')
    end

    for _, definition in ipairs(definitions) do
        local result = exports['feather-chat']:RegisterSuggestion(definition)
        if not result.ok and result.code ~= 'conflict' then
            print(('[bcc-society] chat suggestion %s failed: %s'):format(definition.trigger, tostring(result.code)))
            return
        end
    end
    registered = true
end

AddEventHandler('chat.ready.v1', Register)

AddEventHandler('onResourceStop', function(resource)
    if resource == 'feather-chat' then
        registered = false
    end
end)

CreateThread(Register)
