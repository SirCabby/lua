local BaseClass = require("cabby.classes.baseClass")

---A druid heals, but below a cleric -- and above one when there is no cleric, which is exactly
---the runtime priority adjustment by group makeup the class profiles are meant to carry
---(`Priorities.heal + 5` when a cleric is present, `Priorities.heal` when the group has none).
---That adjustment does not exist yet; neither does the heal state.
---@type BaseClass
local Druid = BaseClass.new({
    key = "Druid",
    shortName = "DRU",
    unimplemented = {
        "healing, weaker than a cleric's, tightening when no cleric is in the group",
        "curing poison and disease",
        "nukes and dots",
        "snare, for pulls and for runners",
        "buff maintenance (skin, regen, SoW) with stacking checks",
        "ports, and evacuating a group that is losing"
    }
})

return Druid
