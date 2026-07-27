---Which module plays which class.
---
---Held as paths rather than modules so that only the class this character actually is gets
---required -- a wizard has no reason to load the melee state, and every class module pulls in
---the states it registers.
---@class Classes
local Classes = {
    key = "Classes",
    ---@type table<string, string> EQ short name -> module path
    modules = {
        BRD = "cabby.classes.bard",
        BER = "cabby.classes.berserker",
        BST = "cabby.classes.beastlord",
        CLR = "cabby.classes.cleric",
        DRU = "cabby.classes.druid",
        ENC = "cabby.classes.enchanter",
        MAG = "cabby.classes.magician",
        MNK = "cabby.classes.monk",
        NEC = "cabby.classes.necromancer",
        PAL = "cabby.classes.paladin",
        RNG = "cabby.classes.ranger",
        ROG = "cabby.classes.rogue",
        SHD = "cabby.classes.shadowknight",
        SHM = "cabby.classes.shaman",
        WAR = "cabby.classes.warrior",
        WIZ = "cabby.classes.wizard"
    }
}

---@param shortName string as `mq.TLO.Me.Class.ShortName()` reports it
---@return BaseClass? class nil when there is no module for that class
function Classes.Get(shortName)
    local path = Classes.modules[tostring(shortName):upper()]
    if path == nil then return nil end
    return require(path)
end

return Classes
