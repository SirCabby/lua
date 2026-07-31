local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local MezState = require("cabby.states.mezState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---An enchanter is the mez band. It is also the class that most needs the priority chain to be
---right: a mez that waits its turn behind a damage rotation is a mez that lands after the add
---has already killed somebody -- which is why `MezState` sits at `Priorities.mez`, above both
---dps states and above tanking, and why it is the first class to register one.
---
---What that state does with the band is one ordered list holding all three of the things an
---enchanter locks a fight down with: the mez, the tash cast at whatever resists one, and the stun
---that buys the seconds a mez needs to be cast at all. Which of the three a slot is comes off the
---spell rather than out of a dropdown -- see `states/mezState.lua`.
---
---The pet is the shared pet states' -- summoned and kept by one, sent in and called off by the
---other -- and this is the one pet class with no heal for its pet, which is why there is no heal
---state here.
---
---**Both of its pets are handled, and they are not the same animal.** An animation is summoned and
---kept like any other pet, but it takes no orders: `cabby.pet` reads that (and reads `Animation
---Empathy`, the alternate ability that is the only thing which changes it), so the dps state says
---nothing to one instead of sending orders nobody hears. A charmed pet is an ordinary pet as far as
---the commands go and is fought with in full -- but never geared, since what a charmed mob is handed
---leaves with it when the charm breaks. What is still missing is the *casting*: nothing here lands a
---charm, notices it break, or re-charms.
---@type BaseClass
local Enchanter = BaseClass.new({
    key = "Enchanter",
    shortName = "ENC",
    states = {
        { state = MezState, priority = Priorities.mez },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "casting charm: the pet states handle a charmed pet, but nothing lands one, notices the break, or re-charms",
        "slow: the mez list will cast one, but only at something it is about to mez -- a slow on the mob the group is killing is a rotation slot",
        "memory blur, and everything else that manages aggro rather than the fight"
    }
})

return Enchanter
