local BaseClass = require("cabby.classes.baseClass")
local Priorities = require("cabby.classes.priorities")

local SpellDpsState = require("cabby.states.spellDpsState")

---A wizard nukes, and the hard part is not nuking so hard it pulls the mob off the tank -- which
---is what the spell dps state's "start below %" is for. It deliberately does not register the
---melee state: a wizard in melee range is a dead wizard.
---@type BaseClass
local Wizard = BaseClass.new({
    key = "Wizard",
    shortName = "WIZ",
    states = {
        { state = SpellDpsState, priority = Priorities.dps - 1 }
    },
    unimplemented = {
        "evacuating a group that is losing",
        "ports on request"
    }
})

return Wizard
