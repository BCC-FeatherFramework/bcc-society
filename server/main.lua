-- Society administration: feather-authority staff capability, or a feather-jobs
-- job listed in Config.AllowedJobs. Fails closed.
function IsSocietyAdmin(src)
    if tonumber(src) == 0 then return Config.Admin.allowConsole == true end
    local allowed = SocietyAuthority.IsAllowed(src)
    if allowed then return true end

    local character = SocietyCharacters.Get(src)
    if not character then return false end
    for _, jobKey in ipairs(Config.AllowedJobs or {}) do
        local checked = SocietyJobs.Check({ characterId = character.charIdentifier, jobKey = jobKey })
        if checked.ok and checked.value.matched then return true end
    end
    return false
end

FeatherRPC:Register("BCC-Society:AdminCheck", function(_, cb, src)
    local allowed = IsSocietyAdmin(src)
    devPrint("[AdminCheck] src " .. tostring(src) .. " allowed=" .. tostring(allowed))
    return cb(allowed)
end)

FeatherRPC:Register("BCC-Society:GetPlayers", function(params, cb, recSource)
    devPrint("[GetPlayers] RPC invoked by src", tostring(recSource))

    local data    = {}
    local players = GetPlayers()

    devPrint("[GetPlayers] Players table length:", players and tostring(#players) or "nil")

    if not players or #players == 0 then
        devPrint("[GetPlayers] No players found on server.")
        cb(data)
        return
    end

    local added = 0

    for _, playerId in ipairs(players) do
        local pidStr = tostring(playerId)
        devPrint("[GetPlayers] Inspecting playerId:", pidStr)

        local Character = SocietyCharacters.Get(playerId)
        if not Character then
            devPrint("[GetPlayers] no active character for", pidStr)
        else
            local playerName = Character.firstname .. " " .. Character.lastname
            local staticid   = Character.charIdentifier

            devPrint("[GetPlayers] Adding player to list:", pidStr,
                     "name:", playerName,
                     "charId:", tostring(staticid))

            data[pidStr] = {
                serverId   = playerId,
                PlayerName = playerName,
                staticid   = staticid,
            }
            added = added + 1
        end
    end

    devPrint("[GetPlayers] Completed. Added", tostring(added), "of", tostring(#players), "players.")
    cb(data)
end)

