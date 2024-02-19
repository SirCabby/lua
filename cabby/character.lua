local mq = require("mq")

local Skills = require("cabby.actions.skills")

---@class Character
local Character = {
    primaryMeleeAbilities = {},
    secondaryMeleeAbilities = {},
    meleeAbilities = {},
}

local function loadAbilities()
    -- Primary Melee Abilities
    Character.primaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.primary) do
        if skill:HasAction() then
            Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = skill
        end
    end
    Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = Skills.none

    -- Secondary Melee Abilities (Monk)
    Character.secondaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.secondary) do
        if skill:HasAction() then
            Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = skill
        end
    end
    Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = Skills.none

    -- Melee Abilities
    Character.meleeAbilities = {}
    for _, skill in ipairs(Skills.melee) do
        if skill:HasAction() then
            Character.meleeAbilities[#Character.meleeAbilities+1] = skill
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

return Character
