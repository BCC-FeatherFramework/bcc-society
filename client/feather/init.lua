-- bcc-society's boundary to the Feather Framework (client side).
-- Keeps the call shapes the existing menus use (FeatherRPC:CallAsync/Call,
-- Notify(message, type, duration)) on top of feather-core and feather-notify.

FeatherRPC = {}

-- Returns the server handler's reply, or nil on transport failure.
function FeatherRPC:CallAsync(name, params)
    local result, transportError = exports['feather-core']:CallRPCAsync(name, params or {})
    if result == nil and type(transportError) == 'table' then
        print(('[bcc-society] rpc %s failed: %s'):format(name, tostring(transportError.code or transportError.message)))
    end
    return result, transportError
end

function FeatherRPC:Call(name, params, callback)
    CreateThread(function()
        local result, extra = self:CallAsync(name, params)
        if callback then callback(result, extra) end
    end)
end

-- Server-to-client procedures (e.g. opening a receipt).
function FeatherRPC:Register(name, handler)
    exports['feather-core']:RegisterRPC(name, function(params, respond)
        handler(params or {})
        if respond then respond(true) end
    end)
end

function Notify(message, typeOrDuration, maybeDuration)
    local duration = tonumber(maybeDuration) or (type(typeOrDuration) == 'number' and typeOrDuration) or 4000
    local result = exports['feather-notify']:ShowNotification({
        style = Config.NotifyStyle or 'right',
        message = tostring(message),
        duration = duration
    })
    if type(result) ~= 'table' or result.ok ~= true then
        print(('[bcc-society] notification failed: %s'):format(type(result) == 'table' and tostring(result.code) or 'invalid_result'))
    end
end
