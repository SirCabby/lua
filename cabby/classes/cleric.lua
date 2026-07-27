local BaseClass = require("cabby.classes.baseClass")

---The class the heal band was drawn for: a cleric heals at full priority and everything else
---it does yields to that.
---
---Nothing here casts, so a cleric currently follows the group and watches. It deliberately does
---not register the melee state -- a cleric that walks into melee instead of healing is worse
---than one that stands still.
---@type BaseClass
local Cleric = BaseClass.new({
    key = "Cleric",
    shortName = "CLR",
    unimplemented = {
        "healing at the heal band: self, group and role targets, thresholds, emergency vs topping off",
        "cure at the cure band",
        "buff maintenance (symbol, aegis) with stacking checks and rebuff timers",
        "rez, in and out of combat",
        "hammering things and nuking undead when nothing needs a heal"
    }
})

return Cleric
