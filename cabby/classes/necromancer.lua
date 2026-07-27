local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local SpellDpsState = require("cabby.states.spellDpsState")

---A necromancer is dots, a pet, and never dying. The rotation casts dots happily enough, but
---nothing tracks how long one has left to run, and a dot re-landed early is mana thrown away --
---so a dot in the rotation is the author's own risk until recast tracking exists.
---@type BaseClass
local Necromancer = BaseClass.new({
    key = "Necromancer",
    shortName = "NEC",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 }
    },
    unimplemented = {
        "the pet: summon it, keep it up, send it in and call it off",
        "dot recast tracking, so a rotation does not step on a dot that is still ticking",
        "lifetaps, and feigning death when they are not enough",
        "twitching mana to whoever is out",
        "fear kiting"
    }
})

return Necromancer
