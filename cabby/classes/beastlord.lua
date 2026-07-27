local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local MeleeState = require("cabby.states.meleeState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A beastlord fights with its pet, slows what the group is on, and carries enough healing and
---buffing to stand in for a priest. Only the melee half exists; the pet fights on its own once
---sent, and nothing sends it yet.
---@type BaseClass
local Beastlord = BaseClass.new({
    key = "Beastlord",
    shortName = "BST",
    states = {
        { state = HealState, priority = Priorities.heal + 5 },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = MeleeState, priority = Priorities.dps },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "the pet: summon it, and send it in and call it off with the attack orders",
        "slow, as the group's second slower",
        "paragon: a group mana buff cast because somebody is low, which the buff state does not judge"
    }
})

return Beastlord
