local TableUtils = require("utils.TableUtils.TableUtils")

local Skill = require("cabby.actions.skill")

---@class Skills
local Skills = {
    all = {},
    damage = {},        -- Inflict some amount of damage
    facing = {},        -- Must be facing the target to use
    fear = {},          -- Inflicts fear
    hate = {},          -- Increases aggro / hate against target
    innate = {},        -- Granted by race, so an illusion of another race takes it away
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

-- setAttribute("damage",
-- Skills.backstab, Skills.bash, Skills.dragonpunch, Skills.eaglestrike, Skills.flyingkick, Skills.intimidation,
-- Skills.kick, Skills.roundkick, Skills.slam, Skills.tailrake, Skills.tigerclaw)

setAttribute("facing",
Skills.backstab, Skills.bash, Skills.begging, Skills.disarm, Skills.dragonpunch, Skills.eaglestrike,
Skills.flyingkick, Skills.intimidation, Skills.kick, Skills.roundkick, Skills.slam, Skills.taunt,
Skills.tailrake, Skills.tigerclaw)

-- setAttribute("fear",
-- Skills.intimidation)

-- setAttribute("hate",
-- Skills.taunt)

-- Race grants these, not a class or a level. The client rebuilds its innate abilities out of
-- whatever race it is showing, so one of these reads absent for as long as an illusion of another
-- race is worn -- which is not the same fact as the character not having it. `cabby.character`
-- is where the two are told apart.
setAttribute("innate",
Skills.slam)

setAttribute("melee",
Skills.disarm, Skills.intimidation)

setAttribute("primary",
Skills.slam, Skills.backstab, Skills.flyingkick, Skills.roundkick, Skills.kick) -- Ordered by priority

-- setAttribute("push",
-- Skills.dragonpunch, Skills.tailrake)

setAttribute("secondary",
Skills.dragonpunch, Skills.tailrake, Skills.eaglestrike, Skills.tigerclaw) -- Ordered by priority

-- setAttribute("stun",
-- Skills.bash, Skills.slam)

setAttribute("targeted",
Skills.backstab, Skills.bash, Skills.begging, Skills.disarm, Skills.dragonpunch, Skills.eaglestrike,
Skills.flyingkick, Skills.intimidation, Skills.kick, Skills.roundkick, Skills.slam, Skills.taunt,
Skills.tailrake, Skills.tigerclaw)

return Skills
