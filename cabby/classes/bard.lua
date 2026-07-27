local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

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
        { state = MeleeState, priority = Priorities.dps }
    },
    unimplemented = {
        "twisting: keeping a rotation of songs up, which needs the caster foundation and a twist service",
        "mez, charm and snare songs (crowd control at the mez band)",
        "the group songs -- haste, regen, mana -- at the buff band",
        "pulling: a bard pulls with a song and outruns what it brings back"
    }
})

return Bard
