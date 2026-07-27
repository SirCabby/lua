local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A druid heals, but below a cleric -- and above one when there is no cleric, which is exactly
---the runtime priority adjustment by group makeup the class profiles are meant to carry
---(`Priorities.heal + 5` when a cleric is present, `Priorities.heal` when the group has none).
---That adjustment does not exist yet, so it sits at the hybrid band and a group with no cleric
---has a druid healing one step slower than it could.
---@type BaseClass
local Druid = BaseClass.new({
    key = "Druid",
    shortName = "DRU",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "curing poison and disease",
        "snare, for pulls and for runners",
        "ports, and evacuating a group that is losing"
    }
})

return Druid
