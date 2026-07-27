local BaseClass = require("cabby.classes.baseClass")

---A shaman slows first and heals second, and the slow has to land before the tank has taken the
---damage that made it necessary -- which puts it above the damage rotations rather than at the
---buff band where the rest of its casting sits.
---
---No melee state: a shaman does swing on emu servers, but a spear is not worth walking away
---from a slow for. A character being played that way adds the state to its own profile the way
---the melee classes do -- `{ state = MeleeState, priority = Priorities.dps }`.
---@type BaseClass
local Shaman = BaseClass.new({
    key = "Shaman",
    shortName = "SHM",
    unimplemented = {
        "slow, ahead of the damage rotations",
        "healing, weaker than a cleric's, tightening when no cleric is in the group",
        "curing poison and disease",
        "buff maintenance (the str/sta lines, haste) with stacking checks",
        "dots, and canni for mana"
    }
})

return Shaman
