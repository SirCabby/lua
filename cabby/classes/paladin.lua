local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local MeleeState = require("cabby.states.meleeState")
local SpellDpsState = require("cabby.states.spellDpsState")

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
        { state = HealState, priority = Priorities.heal + 5 },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = MeleeState, priority = Priorities.dps },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "tanking as its own state: aggro-loss detection driving the taunt and hate lists",
        "rez"
    }
})

return Paladin
