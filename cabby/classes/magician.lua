local BaseClass = require("cabby.classes.baseClass")

---A magician is its pet and its nukes, plus everything it hands out. None of it exists yet:
---the pet is the first half of a shared pet state (magician, necromancer, beastlord, shadow
---knight, and an enchanter's charmed pet all want the same "keep it alive, send it in, call it
---off" behaviour).
---@type BaseClass
local Magician = BaseClass.new({
    key = "Magician",
    shortName = "MAG",
    unimplemented = {
        "the pet: summon the right elemental, gear it, send it in and call it off",
        "the nuke rotation",
        "summoning on request: mod rods, pet weapons, food and drink"
    }
})

return Magician
