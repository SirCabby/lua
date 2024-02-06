local TableUtils = require("utils.TableUtils.TableUtils")

local Skill = require("cabby.actions.skill")

---@class Skills
---@field damage array -- Inflict some amount of damage
---@field facing array -- Must be facing the target to use
---@field fear array -- Inflicts fear
---@field hate array -- Increases aggro / hate against target
---@field melee array -- Actions to perform while in melee combat (non-primary)
---@field primary array -- Primary Melee actions
---@field push array -- Pushes target
---@field secondary array -- Secondary Melee actions
---@field stun array -- Stuns target
---@field targeted array -- Action requires target
local Skills = {
    all = {}
}

Skills.bash =           Skill.new("Bash")
Skills.backstab =       Skill.new("Backstab")
Skills.begging =        Skill.new("Begging")
Skills.disarm =         Skill.new("Disarm")
Skills.dragonpunch =    Skill.new("Dragon Punch")
Skills.eaglestrike =    Skill.new("Eagle Strike")
Skills.flyingkick =     Skill.new("Flying Kick")
Skills.intimidation =   Skill.new("Intimidation")
Skills.kick =           Skill.new("Kick")
Skills.roundkick =      Skill.new("Round Kick")
Skills.slam =           Skill.new("Slam")
Skills.tailrake =       Skill.new("Tail Rake")
Skills.taunt =          Skill.new("Taunt")
Skills.tigerclaw =      Skill.new("Tiger Claw")
Skills.none =           Skill.new("None")
-- Bind Wound, Feign Death, Fishing, Foraging, Hide, Mend, Sense Heading, Sneak

local setAttribute = function(attr, ...)
    for _, skill in ipairs({...}) do
        -- Enable this attribute on this skill
        skill._[attr] = true

        -- Categorize skill by attribute into Skills.attr array
        Skills[attr] = Skills[attr] or {}
        Skills[attr][#Skills[attr]+1] = skill

        -- Add all skills to Skills.all array
        if not TableUtils.ArrayContains(Skills.all, skill) then
            Skills.all[#Skills.all+1] = skill
        end
    end
end

setAttribute("damage",
Skills.backstab, Skills.bash, Skills.dragonpunch, Skills.eaglestrike, Skills.flyingkick, Skills.intimidation,
Skills.kick, Skills.roundkick, Skills.slam, Skills.tailrake, Skills.tigerclaw)

setAttribute("facing",
Skills.backstab, Skills.bash, Skills.begging, Skills.disarm, Skills.dragonpunch, Skills.eaglestrike,
Skills.flyingkick, Skills.intimidation, Skills.kick, Skills.roundkick, Skills.slam, Skills.taunt,
Skills.tailrake, Skills.tigerclaw)

setAttribute("fear",
Skills.intimidation)

setAttribute("hate",
Skills.taunt)

setAttribute("melee",
Skills.disarm, Skills.intimidation, Skills.taunt)

setAttribute("primary",
Skills.backstab, Skills.flyingkick, Skills.kick, Skills.roundkick, Skills.slam)

setAttribute("push",
Skills.dragonpunch, Skills.tailrake)

setAttribute("secondary",
Skills.dragonpunch, Skills.eaglestrike, Skills.tailrake, Skills.tigerclaw)

setAttribute("stun",
Skills.bash, Skills.slam)

setAttribute("targeted",
Skills.backstab, Skills.bash, Skills.begging, Skills.disarm, Skills.dragonpunch, Skills.eaglestrike,
Skills.flyingkick, Skills.intimidation, Skills.kick, Skills.roundkick, Skills.slam, Skills.taunt,
Skills.tailrake, Skills.tigerclaw)

return Skills
