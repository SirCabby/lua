local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A beastlord fights with its pet, slows what the group is on, and carries enough healing and
---buffing to stand in for a priest. Only the melee half exists; the pet fights on its own once
---sent, and nothing sends it yet.
---@type BaseClass
local Beastlord = BaseClass.new({
    key = "Beastlord",
    shortName = "BST",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "the pet: summon it, keep it alive and buffed, send it in and call it off with the attack orders",
        "slow, as the group's second slower",
        "the small heals and the group buffs (haste, focus)",
        "paragon and the mana line, once buffs exist"
    }
})

return Beastlord
