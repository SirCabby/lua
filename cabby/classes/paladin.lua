local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A paladin tanks and heals, and is the reason both of those need bands rather than a fixed
---order: its heal belongs below a cleric's, and its tanking belongs below a warrior's when a
---warrior is holding the mob.
---
---Tanking rides inside the melee state today -- the taunt and hate action lists on the Melee
---State page -- which is why there is no separate entry at the tank band.
---@type BaseClass
local Paladin = BaseClass.new({
    key = "Paladin",
    shortName = "PAL",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "tanking as its own state: aggro-loss detection driving the taunt and hate lists",
        "healing, weaker than a cleric's, and curing",
        "stuns, and the undead nukes",
        "buff maintenance, and rez once the caster foundation exists"
    }
})

return Paladin
