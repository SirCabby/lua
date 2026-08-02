local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local SpellDpsState = require("cabby.states.spellDpsState")

---The class the heal band was drawn for: a cleric heals at full priority and everything else
---it does yields to that.
---
---Melee comes from the common states at `dps + 5`, below the nukes and far below the heals, and
---switched off until someone asks for it. A cleric that walks into melee instead of healing is
---still worse than one that stands still -- what the band buys is that it cannot happen by
---accident: healing, then nuking, then swinging, in that order, every pass.
---@type BaseClass
local Cleric = BaseClass.new({
    key = "Cleric",
    shortName = "CLR",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "rez, in and out of combat",
        "the hammer pet, and knowing undead from everything else when picking a nuke"
    }
})

return Cleric
