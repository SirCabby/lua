local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local CanniState = require("cabby.states.canniState")
local HealState = require("cabby.states.healState")
local PetDpsState = require("cabby.states.petDpsState")
local PetSetupState = require("cabby.states.petSetupState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A shaman slows first and heals second, and the slow has to land before the tank has taken the
---damage that made it necessary -- which puts it above the damage rotations rather than at the
---buff band where the rest of its casting sits.
---
---A shaman does swing on emu servers, and now has the melee state to do it with -- from the
---common states at `dps + 5`, which is the band that says a spear is not worth walking away from
---a slow for. A character played as a melee shaman moves it up by declaring it in this profile
---the way the melee classes do: `{ state = MeleeState, priority = Priorities.dps }`.
---
---Canni is the shaman's own state at `Priorities.canni`, above the damage rotations: the mana it
---buys is what everything below that band is spent out of, and the health floor and mana ceiling on
---its page are what stop it. The whole line is one list -- the spells, the Cannibalization AA, and
---a manastone if this character carries one.
---
---The spirit pet is the shared pet states', like a beastlord's warder: a companion summoned out of
---a fight and kept, rather than something cast into one, and sent at what this character is
---fighting once there is a fight. Nothing is conjured for it -- pet gear is a magician's business
--- -- so a shaman's pet setup page is the summon list and nothing else.
---@type BaseClass
local Shaman = BaseClass.new({
    key = "Shaman",
    shortName = "SHM",
    states = {
        { state = CanniState, priority = Priorities.canni },
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = HealState, priority = Priorities.heal + 5 },
        { state = PetDpsState, priority = Priorities.dps - 2 },
        { state = PetSetupState, priority = Priorities.buff - 1 }
    },
    unimplemented = {
        "slow, ahead of the damage rotations"
    }
})

return Shaman
