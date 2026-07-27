local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local HealState = require("cabby.states.healState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A shaman slows first and heals second, and the slow has to land before the tank has taken the
---damage that made it necessary -- which puts it above the damage rotations rather than at the
---buff band where the rest of its casting sits.
---
---No melee state: a shaman does swing on emu servers, but a spear is not worth walking away
---from a slow for. A character being played that way adds the state to its own profile the way
---the melee classes do -- `{ state = MeleeState, priority = Priorities.dps }`.
---@type BaseClass
local Shaman = BaseClass.new({
    key = "Shaman",
    shortName = "SHM",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 }
    },
    unimplemented = {
        "slow, ahead of the damage rotations",
        "curing poison and disease",
        "buff maintenance (the str/sta lines, haste) with stacking checks",
        "canni: trading health for mana when there is a moment for it"
    }
})

return Shaman
