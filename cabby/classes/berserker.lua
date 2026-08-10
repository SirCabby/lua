local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local MeleeState = require("cabby.states.meleeState")

---A berserker is melee damage and nothing else, which makes it the class the existing melee
---state comes closest to covering: frenzy and the rage discs are ordinary discipline slots on
---the Melee State page, and the action list runs them.
---
---What it keeps on itself between fights is the buff state's, from the common states: clickies
---and AAs, which a buff slot holds the same way it holds a spell. A discipline is not one of
---those -- it is fired for a fight and has no cast to watch -- so the rage line stays where it
---is, on the melee page.
---@type BaseClass
local Berserker = BaseClass.new({
    key = "Berserker",
    shortName = "BER",
    states = {
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "throwing axes: ranged attack is not an action type yet",
        "reacting to a berserk proc rather than firing discs off a timer"
    }
})

return Berserker
