---What the items spells ask for are called.
---
---A component is an item id in the spell data and nothing else, and **nothing in the client maps
---an id to a name on its own**: `FindItem` answers only for items we are carrying, `FindItemBank`
---only for ones in the bank, and an item we have never held has no name anywhere on this side of
---the connection. Which is exactly the case that matters -- the reason a cast is refused is that
---the component is *not* in the bags, so the one moment a caster needs the name is the one moment
---the client cannot supply it. "Elemental: Earth failed: missing item 10015" is a puzzle;
---"missing Malachite" is a trip to a vendor.
---
---So the names are shipped. This is a lookup of last resort: `CastSubject:MissingReagent` asks the
---client first, both for the name and for where the item is, and only falls back to this table.
---
---**Scope**: every item id that appears as a spell component -- expendable (`components1..4`) or
---focus (`NoexpendReagent1..4`) -- in the client's own `spells_us.txt`. That is the whole set of
---things a cast can be refused for, and nothing else belongs in here.
---
---**Regenerating it** (both halves are read-only):
---
---```
---awk -F'^' '{for(i=59;i<=62;i++){id=$i+0; if(id>0) ids[id]=1}
---            for(i=67;i<=70;i++){id=$i+0; if(id>0) ids[id]=1}}
---           END {for(k in ids) print k}' spells_us.txt | sort -n | paste -sd, -
---select id, name from items where id in (<that list>) order by id
---```
---
---Ids the server does not know are simply absent, and read back as nil -- an id is still what
---`MissingReagent` says when nothing can name one.
---@class ReagentNames
local ReagentNames = {
    ---item id -> name, generated; see above before editing by hand
    names = {
        [  2093] = "Small Portal Fragments",
        [  6360] = "Broom of Trilon",
        [  6361] = "Shovel of Ponz",
        [  6362] = "Torch of Alna",
        [  6363] = "Stein of Ulissa",
        [  8658] = "CLASS 3 Wood Silver Tip Arrow",
        [  9962] = "Tiny Jade Inlaid Coffin",
        [  9963] = "Essence Emerald",
        [ 10012] = "Black Pearl",
        [ 10015] = "Malachite",
        [ 10019] = "Bloodstone",
        [ 10020] = "Jasper",
        [ 10021] = "Star Rose Quartz",
        [ 10022] = "Amber",
        [ 10023] = "Jade",
        [ 10024] = "Pearl",
        [ 10025] = "Topaz",
        [ 10026] = "Cat's Eye Agate",
        [ 10028] = "Peridot",
        [ 10029] = "Emerald",
        [ 10030] = "Opal",
        [ 10031] = "Fire Opal",
        [ 10032] = "Star Ruby",
        [ 10033] = "Fire Emerald",
        [ 10034] = "Sapphire",
        [ 10035] = "Ruby",
        [ 10036] = "Black Sapphire",
        [ 10037] = "Diamond",
        [ 10092] = "Fuligan Soulstone of Innoruuk",
        [ 10094] = "Cloudy Stone of Veeshan",
        [ 10307] = "Fire Beetle Eye",
        [ 10469] = "Large Brick of High Quality Ore",
        [ 10474] = "Large Brick of Brellium",
        [ 10475] = "Large Brick of Adamantite",
        [ 10476] = "Large Brick of Mithril",
        [ 11566] = "Staff of Elemental Mastery: Fire",
        [ 11567] = "Staff of Elemental Mastery: Earth",
        [ 11568] = "Staff of Elemental Mastery: Air",
        [ 11569] = "Staff of Elemental Mastery: Water",
        [ 11571] = "Encyclopedia Necrotheurgia",
        [ 12003] = "Sheet Metal",
        [ 12832] = "Plains Pebble",
        [ 13000] = "Hand Drum",
        [ 13001] = "Wooden Flute",
        [ 13011] = "Lute",
        [ 13012] = "Horn",
        [ 13068] = "Bat Wing",
        [ 13070] = "Snake Scales",
        [ 13073] = "Bone Chips",
        [ 13076] = "Fish Scales",
        [ 13079] = "Summoned: Globe of Water",
        [ 13080] = "Tiny Dagger",
        [ 15981] = "Raw Diamond",
        [ 16500] = "Silver Bar",
        [ 16501] = "Electrum Bar",
        [ 16502] = "Gold Bar",
        [ 16503] = "Platinum Bar",
        [ 16902] = "Large Block of Clay",
        [ 16965] = "Poison Vial",
        [ 17355] = "Jade Inlaid Coffin",
        [ 20508] = "Symbol of Ancient Summoning",
        [ 21602] = "Deeppocket Rapier",
        [ 21603] = "Deeppocket Hollow Staff",
        [ 21607] = "Imbued Deeppocket Traveling Staff",
        [ 21954] = "Alkaline Etched Stone",
        [ 22098] = "Velium Bar",
        [ 22504] = "Ivory",
        [ 25759] = "Chocolate",
        [ 26635] = "Putrescent Blood",
        [ 28144] = "Gloves of Dark Summoning",
        [ 28880] = "Black Ceremonial Coffin",
        [ 29346] = "Bubonian Blood",
        [ 29356] = "Quintessence of Knowledge",
        [ 29419] = "War Wraith Blood",
        [ 29521] = "Fire Mephit Blood",
        [ 29522] = "Water Mephit Blood",
        [ 29523] = "Earth Mephit Blood",
        [ 29524] = "Air Mephit Blood",
        [ 29525] = "Nightmare Mephit Blood",
        [ 29526] = "Storm Rider Blood",
        [ 29956] = "Metallic Liquid",
        [ 37601] = "Dwerium Bar",
        [ 39722] = "Temporite Bar",
        [ 45892] = "Prismatic Palladium Bar",
        [ 45952] = "Cosgrite Bar",
        [ 51756] = "Mushroom Spores",
        [ 51757] = "Crystalline Water",
        [ 52621] = "Blank Canvas",
        [ 52660] = "Lifeshard",
        [ 52673] = "Axe of the Annihilator",
        [ 52708] = "Axe of the Decimator",
        [ 52816] = "Axe of the Eradicator",
        [ 57263] = "Axe of the Savage",
        [ 58153] = "Taelosian Tea Leaves",
        [ 59654] = "Lesser Scrying Stone",
        [ 59655] = "Scrying Stone",
        [ 59656] = "Greater Scrying Stone",
        [ 59740] = "Purified Crystal",
        [ 59933] = "Basic Axe Components",
        [ 59934] = "Axe Components",
        [ 59935] = "Balanced Axe Components",
        [ 59936] = "Crafted Axe Components",
        [ 59998] = "Axe of the Destroyer",
        [ 60294] = "Generic Coffee Beans",
        [ 64524] = "Alaran Metal Bar",
        [ 64658] = "Infused Leaves of Dragonwart",
        [ 64659] = "Infused Pollen of Dragonwart",
        [ 64663] = "Metallic Potion Vial",
        [ 64683] = "Gnomish Handcannon Ammunition",
        [ 64950] = "Axe of the Sunderer",
        [ 69011] = "Blunt Axe",
        [ 69016] = "Bonesplicer Axe",
        [ 69020] = "Rage Axe",
        [ 76299] = "Planar Alloy",
        [ 76336] = "Planar Goo",
        [ 76436] = "Goo Gun Ammunition",
        [ 76500] = "Axe of the Brute",
        [ 81120] = "Repeating Crossbow Bolts",
        [ 81138] = "Feymetal Bar",
        [ 84098] = "Halfling Brain",
        [ 87020] = "Alluring Flute of the Piper",
        [135322] = "Terror Crossbow Bolts",
    }
}

---@param itemId number
---@return string|nil name nil when this id is not one of the components a spell asks for, or the
---server did not know it when this was generated
function ReagentNames.Get(itemId)
    itemId = tonumber(itemId)
    if itemId == nil then return nil end
    return ReagentNames.names[itemId]
end

return ReagentNames
