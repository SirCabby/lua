local BaseClass = require("cabby.classes.baseClass")

---A wizard nukes, and the hard part is not nuking so hard it pulls the mob off the tank. Until
---the caster foundation exists a wizard can follow the group and nothing else -- it is the
---emptiest shell of the sixteen, and deliberately does not register the melee state.
---@type BaseClass
local Wizard = BaseClass.new({
    key = "Wizard",
    shortName = "WIZ",
    unimplemented = {
        "the nuke rotation, held back so it does not out-aggro the tank",
        "evacuating a group that is losing",
        "ports on request"
    }
})

return Wizard
