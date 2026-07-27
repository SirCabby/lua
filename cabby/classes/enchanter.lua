local BaseClass = require("cabby.classes.baseClass")

---An enchanter is the mez band. It is also the class that most needs the priority chain to be
---right: a mez that waits its turn behind a damage rotation is a mez that lands after the add
---has already killed somebody.
---@type BaseClass
local Enchanter = BaseClass.new({
    key = "Enchanter",
    shortName = "ENC",
    unimplemented = {
        "mez at the mez band: pick the add, land it, notice the break, re-mez",
        "charm: a pet made out of a mob, and handling the break before it kills the group",
        "slow and tash",
        "haste, clarity and the group buffs",
        "stuns and nukes, once there is mana to spare"
    }
})

return Enchanter
