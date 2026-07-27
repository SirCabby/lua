---The priority chain, as data.
---
---The state machine walks registered states in registration order and the first enabled one
---whose `Go()` returns true owns the frame, so registration order *is* priority. Classes
---declare a band per state instead of ordering their `Register` calls by hand
---(`cabby.classes.baseClass` sorts by these before registering), which is what makes the
---ordering comparable across classes: a paladin's heal has to land below a cleric's, and that
---is only checkable if both name the same band.
---
---**A bigger number is weaker** -- it sits later in the chain and is starved by everything
---above it. The gaps of ten are room to say "the same job, but not as strongly":
---`Priorities.heal + 5` is a hybrid healing below the class that heals for a living, and
---`Priorities.dps - 1` is a state that must get its swing in before the rest of the rotation.
---
---@class Priorities
local Priorities = {
    -- orders given to this character, and anything the client itself is waiting on
    commands = 1,

    -- the global pause: everything below it is starved while it is on
    passive = 19,

    cure = 29,
    heal = 39,

    pull = 49,

    -- in combat --
    mez = 59,        -- add control, above dps so a new add is handled before the next swing
    tank = 69,       -- taunt / grab aggro
    dps = 79,        -- melee and spell rotations

    -- out of combat --
    loot = 89,

    anchor = 99,     -- hold a spot
    follow = 109,    -- stay with someone

    buff = 119,
    misc = 129
}

return Priorities
