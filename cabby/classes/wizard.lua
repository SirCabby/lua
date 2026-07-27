local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local BuffState = require("cabby.states.buffState")
local SpellDpsState = require("cabby.states.spellDpsState")

---A wizard nukes, and the hard part is not nuking so hard it pulls the mob off the tank -- which
---is what the spell dps state's "start below %" is for.
---
---Melee comes from the common states at `dps + 5` and stays off until it is switched on, because
---a wizard in melee range is still a dead wizard. It is there for the character who is out of
---mana with a mob already on them, which is the only time swinging beats standing still.
---@type BaseClass
local Wizard = BaseClass.new({
    key = "Wizard",
    shortName = "WIZ",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 },
        { state = BuffState, priority = Priorities.buff }
    },
    unimplemented = {
        "evacuating a group that is losing",
        "ports on request"
    }
})

return Wizard
