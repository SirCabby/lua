---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local CastAction = require("cabby.actions.castAction")

---The alternate advancement abilities this character has bought and can actually fire.
---
---There is no way to ask the client "list my AAs": `Me.AltAbility[#]` answers for one *group
---id* at a time and returns nothing for a group this character does not own, so finding them
---means walking the id space. That is what the scan below is, and it is why this is refreshed
---on demand rather than watched — an AA appears when one is purchased, and nothing else.
---
---Passive AAs are left out. They are not something a character *does*, so they have no place
---in a list of actions, and offering them would bury the twenty that matter under two hundred
---that cannot be activated at all.
---@class AAs
local AAs = {
    key = "AAs",
    all = {},       -- every activated AA this character owns
    hate = {},      -- increases the target's hate for us
    taunt = {}      -- moves us to the top of the hatelist
}

---How far up the group id space to look.
---
---Every id in the range is asked about, so this is the one genuinely expensive thing discovery
---does — which is why it happens at load, on an AA purchase, and on `/crefresh`, and never on a
---timer. The bound is generous rather than tuned: an AA above it is silently missing, and one
---line here is the fix, whereas a bound that costs a few tens of milliseconds once is not worth
---being clever about.
local maxGroupId = 5000

---@param str string
local function DebugLog(str)
    Debug.Log(AAs.key, str)
end

---@param name string
---@return CastAction? aa
function AAs.Get(name)
    if name == nil then return nil end
    name = tostring(name):lower()

    for _, aa in ipairs(AAs.all) do
        ---@type CastAction
        aa = aa
        if aa:Name():lower() == name then
            return aa
        end
    end

    return nil
end

---Walk the AA group ids and keep the activated ones we own.
function AAs.Refresh()
    AAs.all = {}
    AAs.hate = {}
    AAs.taunt = {}

    for groupId = 1, maxGroupId do
        local aa = mq.TLO.Me.AltAbility(groupId)
        local name = aa.Name()

        if name ~= nil and not aa.Passive() then
            local action = CastAction.AA(name)
            AAs.all[#AAs.all+1] = action

            -- Bucketed by what the AA's spell does, the same way disciplines are: SPA 199 is
            -- taunt, 92 and 192 are hate. Some activated AAs carry no spell at all, hence the
            -- guard rather than a bare HasSPA call.
            local spell = aa.Spell
            if spell ~= nil and spell.ID() ~= nil then
                if spell.HasSPA(199)() then
                    AAs.taunt[#AAs.taunt+1] = action
                elseif spell.HasSPA(92)() or spell.HasSPA(192)() then
                    AAs.hate[#AAs.hate+1] = action
                end
            end
        end
    end

    local byName = function(a, b) return a:Name() < b:Name() end
    table.sort(AAs.all, byName)
    table.sort(AAs.hate, byName)
    table.sort(AAs.taunt, byName)

    DebugLog("Found " .. tostring(#AAs.all) .. " activated AAs")
end

return AAs
