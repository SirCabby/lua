local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A rogue's damage is behind the mob, and the melee state sticks to the front: it asks Movement
---for a plain `Stick` (`MeleeState.StickToCurrentTarget`). The rear-arc stick already exists --
---`utils/Movement/Stick.lua` has a `behind` mode that strafes into the back arc -- so this is a
---matter of the melee state knowing to ask for it, not of writing the movement.
---@type BaseClass
local Rogue = BaseClass.new({
    key = "Rogue",
    shortName = "ROG",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "backstabbing: sticking behind the target (Movement can already do it) and using the skill from there",
        "evade, to hand aggro back to the tank",
        "sneak and hide, and pulling with them",
        "applying and maintaining poisons"
    }
})

return Rogue
