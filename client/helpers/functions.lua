-- feather-menu-v2 through the compatibility layer in client/feather/menu_v2.lua,
-- so the existing v1-style menu code keeps working unchanged.
FeatherMenu = FeatherMenuV2Compat

--Global Vars
BCCSocietyMenu = FeatherMenu:RegisterMenu('BCC-Society:Menu', {
    top = '3%',
    left = '3%',
    ['720width'] = '400px',
    ['1080width'] = '500px',
    ['2kwidth'] = '600px',
    ['4kwidth'] = '800px',
    style = {
        --['background-image'] = 'url("nui://bcc-society/background.png")',
        --['background-image'] = 'url("https://i.imgur.com/7c2xBaG.png")',
        --[[['background-size'] = 'cover',
        ['background-repeat'] = 'no-repeat',
            ['background-position'] = 'center',
            ['padding'] = '50px',
            ['font-family'] = 'Courier New, monospace',
            ['color'] =  '#3e2e1e',
            ['width'] = '100%',
            ['margin'] =  '0 auto',
            ['box-shadow'] = '0 0 10px rgba(0,0,0,0.4)',]]--
    },
    contentslot = {
        style = {
            ['height'] = '450px',
            ['min-height'] = '300px'
        }
    },
    draggable = true,
    canclose = true
}, {
    opened = function()
        DisplayRadar(false)
    end,
    closed = function()
        DisplayRadar(true)
    end
})

-- Helper function for debugging in DevMode
if Config.devMode then
    function devPrint(...)
        local args = { ... }
        for i = 1, select('#', ...) do args[i] = tostring(args[i]) end
        -- One print per line, each ending with ^0 so the color never carries over.
        for line in (table.concat(args, " ") .. "\n"):gmatch("(.-)\n") do
            print("^1[DEV MODE] ^4" .. line .. "^0")
        end
    end
else
    function devPrint(...) end
end

-- Notify(message, type, duration) lives in client/feather/init.lua (feather-notify).

-- Function to create and display the player list menu
function GetPlayerListMenuPage(exclusionList, playerChosenCbFunct, backButtonCbFunct)
    local allPlayers = FeatherRPC:CallAsync("BCC-Society:GetPlayers")
    --print("All Players Data:", json.encode(allPlayers))  -- Confirm player data

    if not allPlayers or next(allPlayers) == nil then
        --print("No players received from RPC call")
        return nil
    end

    local playerListMenupage = BCCSocietyMenu:RegisterPage("bcc-society:playerListMenupage")
    playerListMenupage:RegisterElement("header", {
        value = _U("playerList"),
        slot = "header",
        style = {}
    })

    for k, v in pairs(allPlayers) do
        local exclude = false
        if exclusionList then
            for _, l in pairs(exclusionList) do
                if tonumber(v.staticid) == tonumber(l.charId) or tonumber(v.serverId) == tonumber(l.source) then
                    exclude = true
                    --print("Excluding player:", v.PlayerName, "ID:", v.staticid)  -- Debug exclusion
                    break
                end
            end
        end

        if not exclude then
            --print("Adding player to menu:", v.PlayerName, "ID:", v.staticid)  -- Confirm player addition
            playerListMenupage:RegisterElement("button", {
                label = v.PlayerName,
                style = {}
            }, function()
                --print("Player chosen:", v.PlayerName, "Char ID:", v.staticid, "Source:", v.serverId) -- Confirm selected data
                playerChosenCbFunct({
                    charId = v.staticid,
                    source = v.serverId
                })
            end)
        end
    end
    playerListMenupage:RegisterElement("line", {
        slot = "footer",
        style = {}
    })

    playerListMenupage:RegisterElement("button", {
        label = _U("back"),
        slot = 'footer',
        style = {}
    }, function()
        backButtonCbFunct()
    end)

    playerListMenupage:RegisterElement("bottomline", {
        slot = "footer",
        style = {}
    })
    return playerListMenupage
end

-- Dropdown of the grades a rank may map to (the society job type's grades,
-- owner grade excluded). Calls onSelect(gradeKey); preselects `current`.
function AddGradePicker(page, businessId, current, onSelect)
    local grades = FeatherRPC:CallAsync("bcc-society:GetRankGrades", { socId = businessId })
    if type(grades) ~= "table" or #grades == 0 then
        page:RegisterElement("textdisplay", { value = _U("noGrades"), style = {} })
        return
    end
    local options, start = {}, 1
    for index, grade in ipairs(grades) do
        options[index] = { label = grade.label, key = grade.key }
        if grade.key == current then start = index end
    end
    onSelect(options[start].key)
    page:RegisterElement("dropdown", {
        label = _U("rankJobGrade"),
        options = options,
        start = start,
        style = {}
    }, function(data)
        if data.value and data.value.key then onSelect(data.value.key) end
    end)
end

-- Asks the server each time (a staff role can be granted or revoked while the
-- player is online) and tells the player when they are not allowed.
function IsPlayerAdmin()
    AdminAllowed = FeatherRPC:CallAsync("BCC-Society:AdminCheck") == true
    if not AdminAllowed then
        Notify(_U("noPermission"), "error", 4000)
    end
    return AdminAllowed
end