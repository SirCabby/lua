local Skills = require("cabby.actions.skills")

---@class Character
local Character = {
    key = "Character",
    primaryMeleeAbilities = {},
    secondaryMeleeAbilities = {},
    meleeAbilities = {},
    _ = {
        primaryOrder = { Skills.slam, Skills.bash, Skills.backstab, Skills.flyingkick, Skills.roundkick, Skills.kick },
        secondaryOrder = { Skills.dragonpunch, Skills.tailrake, Skills.eaglestrike, Skills.tigerclaw },
    }
}

local function loadAbilities()
    -- Primary Melee Abilities
    Character.primaryMeleeAbilities = {}
    for _, skill in ipairs(Character._.primaryOrder) do
        if skill:HasSkill() then
            Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = skill
        end
    end
    Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = Skills.none

    -- Secondary Melee Abilities (Monk)
    Character.secondaryMeleeAbilities = {}
    for _, skill in ipairs(Character._.secondaryOrder) do
        if skill:HasSkill() then
            Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = skill
        end
    end
    Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = Skills.none

    -- Melee Abilities
    Character.meleeAbilities = {}
    for _, skill in ipairs(Skills.melee) do
        if skill:HasSkill() then
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
