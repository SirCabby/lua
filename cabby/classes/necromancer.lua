local BaseClass = require("cabby.classes.baseClass")

---A necromancer is dots, a pet, and never dying. All of it needs the caster foundation, and the
---dot rotation in particular needs recast tracking that nothing in `actions/` models yet -- a
---dot re-landed early is mana thrown away.
---@type BaseClass
local Necromancer = BaseClass.new({
    key = "Necromancer",
    shortName = "NEC",
    unimplemented = {
        "the pet: summon it, keep it up, send it in and call it off",
        "the dot rotation, with recast tracking so dots are not stepped on",
        "lifetaps, and feigning death when they are not enough",
        "twitching mana to whoever is out",
        "fear kiting"
    }
})

return Necromancer
