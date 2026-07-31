local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local MeleeState = require("cabby.states.meleeState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A beastlord fights with its pet, slows what the group is on, and carries enough healing and
---buffing to stand in for a priest. The warder is summoned and kept by the shared pet setup state,
---healed by the heal state, and sent at what this character is fighting by the pet dps state --
---which is above the swing rather than below it, because a warder that goes in when the melee
---state runs out of things to do is a warder that goes in late.
---@type BaseClass
local Beastlord = BaseClass.new({
    key = "Beastlord",
    shortName = "BST",
    states = {
        { state = HealState, priority = Priorities.heal + 5 },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = MeleeState, priority = Priorities.dps },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "slow, as the group's second slower",
        "paragon: a group mana buff cast because somebody is low, which the buff state does not judge"
    }
})

return Beastlord
