local TableUtils = require("utils.TableUtils.TableUtils")

local Skill = require("cabby.actions.skill")

---@class Skills
local Skills = {
    all = {},
    damage = {},        -- Inflict some amount of damage
    facing = {},        -- Must be facing the target to use
    fear = {},          -- Inflicts fear
    hate = {},          -- Increases aggro / hate against target
    melee = {},         -- Actions to perform while in melee combat (non-primary)
    primary = {},       -- Primary Melee actions
    push = {},          -- Pushes target
    secondary = {},     -- Secondary Melee actions
    stun = {},          -- Stuns target
    targeted = {}       -- Action requires target
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
