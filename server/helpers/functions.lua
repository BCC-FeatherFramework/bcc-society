-- Shared server helpers. Framework plumbing (RPC, notifications, characters)
-- lives in server/feather/init.lua.

-- Resolves the caller's active character, notifying them when there is none.
function RequireCharacter(src)
    local character = SocietyCharacters.Get(src)
    if not character then
        NotifyClient(src, _U("noCharacter"), "error", 4000)
    end
    return character
end

-- True when the caller owns the society, or is an active member whose rank has
-- the given permission column set ("rank_can_withdraw", ...). Owners always pass.
-- Every state-changing handler calls this before acting: the client is never trusted.
function HasSocietyPermission(src, businessId, permission)
    local character = SocietyCharacters.Get(src)
    if not character then return false, nil, nil end
    local society = SocietyAPI:GetSociety(businessId)
    if not society then return false, character, nil end
    local info = society:GetSocietyInfo()
    if not info or info.status ~= 'active' then return false, character, society end
    if info.owner_id == character.charIdentifier then return true, character, society end
    if not permission then return false, character, society end

    local employee = society:GetEmployeeData(character.charIdentifier)
    if not employee or employee.status ~= 'active' then return false, character, society end
    local rank = society:GetRankInfo(employee.employee_rank)
    return rank ~= false and rank[permission] == "true", character, society
end

-- True for the owner or any active member of the society (read access).
function IsSocietyMember(src, businessId)
    local character = SocietyCharacters.Get(src)
    if not character then return false end
    local society = SocietyAPI:GetSociety(businessId)
    local info = society and society:GetSocietyInfo()
    if not info or info.status ~= 'active' then return false end
    if info.owner_id == character.charIdentifier then return true end
    local employee = society:GetEmployeeData(character.charIdentifier)
    return employee ~= false and employee.status == 'active'
end

-- Positive whole-dollar amount from client input, or nil.
function ParseAmount(value)
    local amount = tonumber(value)
    if not amount or amount ~= amount or amount <= 0 or amount > 1000000000 or amount % 1 ~= 0 then
        return nil
    end
    return amount
end
