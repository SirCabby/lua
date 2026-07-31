local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A magician is its pet and its nukes, plus everything it hands out. Both halves have a home now.
---
---The pet states are the shared ones -- magician, necromancer, beastlord, shadow knight, shaman
---and the enchanter's animation all keep a pet the same way -- and this is the class they were
---built around, because a magician's pet is the only one that also has to be armed. Keeping it is
---`PetSetupState`, a band above buffing, so that a pet is standing there and holding what it is
---owed before anything is spent on buffing one; a pet buff cast on a pet that is about to be
---replaced is a wasted gem timer. Using it is `PetDpsState` at `dps - 2`, above the rotation for
---the reason everything above the melee state is: the swing starves what sits under it, and an
---order to the pet that waits for the next nuke to finish is a pet arriving after the mob has
---picked somebody.
---
---Keeping the pet alive is healing, so it is the heal state that does it: a mage's pet heals
---(Renew Elements and the Renewal line) land on the pet whatever a slot says, because where a
---heal can be aimed is read off the spell. The band is the hybrid one for the usual reason --
---this is not the class the group's healing comes from -- and it is still above the nukes,
---because a pet lost mid-fight costs more than the nuke that would have been cast instead. The
---pet is only watched while `healpets` is on, and the Heal State page says so against any pet
---heal while it is off.
---@type BaseClass
local Magician = BaseClass.new({
    key = "Magician",
    shortName = "MAG",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "summoning on request: mod rods, food and drink for whoever asks"
    }
})

return Magician
