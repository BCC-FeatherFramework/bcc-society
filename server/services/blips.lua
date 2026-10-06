local onCooldownBlips = {}
RegisterServerEvent("bcc-society:ServerSyncBlips", function(blipSocietyId, delete)
    local _source = source
    local now = os.time()
    local shouldDelete = delete == true
    local desiredState = shouldDelete and "false" or "true"

    -- Name, sprite and position come from the database, never from the client.
    local society = DB.one("SELECT business_name, blip_hash, coords, show_blip, status FROM bcc_society WHERE business_id = ?", blipSocietyId)
    if not society or society.status ~= 'active' or society.blip_hash == 'none' then return end
    local coords = json.decode(society.coords)
    local blipVector3 = vector3(coords.x, coords.y, coords.z)

    -- Silent resync: the state already matches, so only the asking client needs it.
    if society.show_blip == desiredState then
        TriggerClientEvent('bcc-society:ClientSyncBlips', _source, society.business_name, society.blip_hash, blipVector3, blipSocietyId, shouldDelete)
        return
    end

    if not HasSocietyPermission(_source, blipSocietyId, "rank_can_toggle_blip") then
        return NotifyClient(_source, _U("noPermission"), "error", 4000)
    end

    local lastToggle = onCooldownBlips[blipSocietyId]
    if not lastToggle or os.difftime(now, lastToggle) >= Config.toggleBlipCooldown then
        onCooldownBlips[blipSocietyId] = now
        TriggerClientEvent('bcc-society:ClientSyncBlips', -1, society.business_name, society.blip_hash, blipVector3, blipSocietyId, shouldDelete)
        DB.exec("UPDATE bcc_society SET show_blip = ? WHERE business_id = ?", desiredState, blipSocietyId)
    else
        NotifyClient(_source, _U("blipCooldown"), "error", 4000)
    end
end)
