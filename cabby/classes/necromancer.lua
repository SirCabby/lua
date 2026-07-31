local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local HealState = require("cabby.states.healState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A necromancer is dots, a pet, and never dying. The rotation casts dots happily enough, but
---nothing tracks how long one has left to run, and a dot re-landed early is mana thrown away --
---so a dot in the rotation is the author's own risk until recast tracking exists.
---
---The pet is summoned and kept by the shared pet setup state, a band above buffing: bone chips are
---a reagent, so a summon that cannot be made says which reagent is missing rather than failing
---quietly. Sending it in and calling it off is the pet dps state, above the rotation -- a
---necromancer's pet is most of its damage while the dots tick, so it goes in first.
---
---It heals two things, which is why it gets the heal state at the hybrid band: the pet, with the
---pet heals that land on it whatever a slot says (Mend Companion, the Mending line), and a
---person, with the empathy line -- health handed over at the cost of its own, which is a real
---heal even if nobody would build a group around it. Both are above the dots for the same
---reason: what they are keeping up is worth more than the next tick. The pet is only watched
---while `healpets` is on.
---@type BaseClass
local Necromancer = BaseClass.new({
    key = "Necromancer",
    shortName = "NEC",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "dot recast tracking, so a rotation does not step on a dot that is still ticking",
        "lifetaps, and feigning death when they are not enough",
        "twitching mana to whoever is out",
        "fear kiting"
    }
})

return Necromancer
