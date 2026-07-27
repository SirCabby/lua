local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local MeleeState = require("cabby.states.meleeState")

---A bard melees while it sings, and the singing is the class. Nothing here twists yet, so what
---is left is a melee character that happens to be able to run away faster than anything else.
---
---Movement already knows about bards: its pause gate holds every other class still while a cast
---is in the air and lets a bard keep running (`utils/Movement/Movement.lua`), which is the one
---piece of bard handling that is done.
---@type BaseClass
local Bard = BaseClass.new({
    key = "Bard",
    shortName = "BRD",
    states = {
        { state = MeleeState, priority = Priorities.dps },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "twisting: a rotation of songs kept up together. The buff state will keep one song going" ..
            " -- it knows bards sing on the move -- but it casts one thing at a time and waits for" ..
            " it, which is the opposite of a twist",
        "mez, charm and snare songs (crowd control at the mez band)",
        "pulling: a bard pulls with a song and outruns what it brings back"
    }
})

return Bard
