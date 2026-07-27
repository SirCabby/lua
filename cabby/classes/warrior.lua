local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A warrior holds aggro and swings, and that is all it does, which is why it is the class the
---melee state was built against.
---
---Tanking rides inside the melee state today -- the taunt and hate action lists on the Melee
---State page, run by the `tanking` switch -- so there is no separate entry at the tank band.
---When tanking splits out into its own state, it lands here at `Priorities.tank` and the melee
---state stays where it is.
---@type BaseClass
local Warrior = BaseClass.new({
    key = "Warrior",
    shortName = "WAR",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "tanking as its own state: aggro-loss detection, so the 'as needed' taunt and hate lists fire "
            .. "when aggro is actually slipping instead of on a timer",
        "pulling"
    }
})

return Warrior
