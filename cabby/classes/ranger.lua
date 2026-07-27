local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A ranger fights in melee or at range, and the range half is missing: archery is not an
---action type, so a ranger told to attack walks in and swings like a warrior would.
---@type BaseClass
local Ranger = BaseClass.new({
    key = "Ranger",
    shortName = "RNG",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "archery: a ranged action type, and a dps rotation that stays at range instead of sticking",
        "snare, and pulling with a bow",
        "tracking: finding a named, or reporting what is around",
        "the self and group buffs, and the small heals"
    }
})

return Ranger
