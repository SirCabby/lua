local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local HealState = require("cabby.states.healState")
local SpellDpsState = require("cabby.states.spellDpsState")

---The class the heal band was drawn for: a cleric heals at full priority and everything else
---it does yields to that.
---
---It deliberately does not register the melee state -- a cleric that walks into melee instead of
---healing is worse than one that stands still.
---@type BaseClass
local Cleric = BaseClass.new({
    key = "Cleric",
    shortName = "CLR",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal }
    },
    unimplemented = {
        "cure at the cure band",
        "buff maintenance (symbol, aegis) with stacking checks and rebuff timers",
        "rez, in and out of combat",
        "the hammer pet, and knowing undead from everything else when picking a nuke"
    }
})

return Cleric
