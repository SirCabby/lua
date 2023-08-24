local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Character
local Character = {
    key = "Character",
    _ = {
        isInit = false,
        config = {},
        character = {
            abilities = {}
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Character.key, str)
end

local function loadAbilities()
    for i = 0, 250 do
        local ability = mq.TLO.Me.Ability(i)
        if ability ~= nil then
            ability = ability()
            local skill = mq.TLO.Me.Skill(ability)()
            if ability ~= "" and skill ~= nil and skill > 0 then
                table.insert(Character._.character.abilities, ability)
            end
        end
    end
end

Character.Refresh = function()
    loadAbilities()
    -- spells (memmed vs book)
    -- aa
    -- combatabilities (discs?) auras?
    -- songs
end

---@param ability string
---@return boolean hasAbility
Character.HasAbility = function(ability)
    return TableUtils.ArrayContains(Character._.character.abilities, ability)
end

return Character
