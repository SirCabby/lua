local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local MeleeState = require("cabby.states.meleeState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A shadow knight tanks with spells as much as with taunts -- the lifetaps and dots are how it
---holds aggro -- so its tanking is not finished by the aggro-loss detection alone; it needs the
---caster foundation too.
---
---Tanking rides inside the melee state today (the taunt and hate action lists), which is why
---there is no separate entry at the tank band.
---
---The undead pet is the shared pet setup state's, a band above buffing. A shadow knight's is the
---plain case of that state: something to summon and nothing to arm, since the pet gear a magician
---conjures is a magician's. The pet dps state sends it in with everything else that fights.
---
---It gets the heal state for the one heal it has: the empathy line, health handed to somebody
---else at the cost of its own. Not the pet -- a shadow knight has no pet heal, unlike the other
---pet classes -- and not the lifetaps either, which are detrimental spells aimed at a mob and
---belong in the rotation where they already are. A heal list holding one spell and whatever
---clickies the character carries is thin, but it is a real heal, and the band puts it above the
---swinging for the same reason a paladin's is.
---@type BaseClass
local ShadowKnight = BaseClass.new({
    key = "Shadow Knight",
    shortName = "SHD",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 },
        { state = MeleeState, priority = Priorities.dps },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "tanking as its own state: aggro-loss detection driving the taunt and hate lists",
        "aggro from lifetaps and dots: the rotation casts them, but nothing casts them *because* aggro slipped",
        "fear, and fear kiting",
        "feign-death pulling"
    }
})

return ShadowKnight
