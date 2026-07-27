local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local SpellDpsState = require("cabby.states.spellDpsState")

---An enchanter is the mez band. It is also the class that most needs the priority chain to be
---right: a mez that waits its turn behind a damage rotation is a mez that lands after the add
---has already killed somebody.
---@type BaseClass
local Enchanter = BaseClass.new({
    key = "Enchanter",
    shortName = "ENC",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 }
    },
    unimplemented = {
        "mez at the mez band: pick the add, land it, notice the break, re-mez",
        "charm: a pet made out of a mob, and handling the break before it kills the group",
        "slow and tash",
        "haste, clarity and the group buffs",
        "stunning a caster mid-cast: the rotation will cast a stun, but not because something is casting"
    }
})

return Enchanter
