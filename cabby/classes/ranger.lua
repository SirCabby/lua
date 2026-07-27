local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local MeleeState = require("cabby.states.meleeState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A ranger fights in melee or at range. Spells have a home now; archery does not -- it is not an
---action type, so a ranger told to attack still walks in and swings like a warrior would.
---@type BaseClass
local Ranger = BaseClass.new({
    key = "Ranger",
    shortName = "RNG",
    states = {
        { state = HealState, priority = Priorities.heal + 5 },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = MeleeState, priority = Priorities.dps },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "archery: a ranged action type, and a dps rotation that stays at range instead of sticking",
        "snare, and pulling with a bow",
        "tracking: finding a named, or reporting what is around"
    }
})

return Ranger
