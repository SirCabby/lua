local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local MeleeState = require("cabby.states.meleeState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A shadow knight tanks with spells as much as with taunts -- the lifetaps and dots are how it
---holds aggro -- so its tanking is not finished by the aggro-loss detection alone; it needs the
---caster foundation too.
---
---Tanking rides inside the melee state today (the taunt and hate action lists), which is why
---there is no separate entry at the tank band.
---@type BaseClass
local ShadowKnight = BaseClass.new({
    key = "Shadow Knight",
    shortName = "SHD",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = MeleeState, priority = Priorities.dps },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "tanking as its own state: aggro-loss detection driving the taunt and hate lists",
        "aggro from lifetaps and dots: the rotation casts them, but nothing casts them *because* aggro slipped",
        "fear, and fear kiting",
        "the pet: summon it and keep it",
        "feign-death pulling"
    }
})

return ShadowKnight
