local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A monk hits things and pulls them. The hitting works: the melee state's primary and secondary
---skill slots exist because of monks (`Character.HasSecondaryAbilities`), so a monk's rotation
---is already configurable on the Melee State page.
---@type BaseClass
local Monk = BaseClass.new({
    key = "Monk",
    shortName = "MNK",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "feign-death pulling at the pull band, which is the reason to bring a monk",
        "mend when hurt, and feigning out of a fight that has gone wrong",
        "sneaking a pull, and safefall drops"
    }
})

return Monk
