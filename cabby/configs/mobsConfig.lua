local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---How far the mob roster's own eyes reach.
---
---Three of the four angles `cabby.mobs` builds the roster from cost nothing and are never
---configured -- the engagement, the extended target window and the group's `defend` reports are
---facts the client is handed. The fourth is the zone sweep, and it is the only one with a dial,
---because it is the only one that has to be told *where to stop looking*: the other three are
---bounded by what has actually happened to somebody, and a sweep is bounded by nothing but a
---number.
---@class MobsConfig : BaseConfig
local MobsConfig = {
    key = "Mobs",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MobsConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[MobsConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("MobsConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[MobsConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.sweep == nil then
        configRoot.sweep = true
        taint = true
    end

    if configRoot.radius == nil then
        -- Comfortably past a mez's own reach (a single-target mez is around 200) but well short of
        -- the zone: the roster is what is in *this* fight, and a mob that is a hundred units away
        -- and swinging at somebody is either in it or about to be. Every mez macro since the
        -- originals has landed between 50 and 100 for the same reason.
        configRoot.radius = 100
        taint = true
    end

    if configRoot.zradius == nil then
        -- The floor above and the floor below are not this fight. Without it a sweep in a tower or
        -- a dungeon stairwell collects mobs nobody can see, let alone reach.
        configRoot.zradius = 50
        taint = true
    end

    if configRoot.hold_radius == nil then
        -- What "near enough to still be this fight" means for a mob nothing is fighting -- see
        -- `Mobs.Hold`. Sat in the middle of this server's own aggro radii (the common values in
        -- `npc_types.aggroradius` are 35, 40, 45, 55, 70 and 100), because what is really being
        -- asked is whether anybody will be inside the mob's reach when it comes back to its
        -- senses. The mob's own radius is server-side data the client is never sent, so this is a
        -- stand-in for it and not a reading of it.
        configRoot.hold_radius = 50
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function MobsConfig.Init()
    if not MobsConfig._.isInit then
        local ftkey = Global.tracing.open("MobsConfig Setup")

        initAndValidate()

        MobsConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---Whether the roster sweeps the zone for mobs in combat stance, on top of the three angles it is
---handed for free.
---
---On by default, and the reason is what the sweep alone can see: an add pathing in that has not
---picked anybody yet, a mob chewing on somebody's pet (which is on no extended target window and
---in nobody's report), and the whole fight of a group that is not running cabby. Off leaves the
---roster to the three certain angles, which is the right answer for a character that must never
---act on a mob nobody has confirmed.
---@return boolean sweep
function MobsConfig.GetSweep()
    return getConfigSection().sweep == true
end

---@param sweep boolean
function MobsConfig.SetSweep(sweep)
    getConfigSection().sweep = sweep == true
    Global.configStore:SaveConfig()
    print("Mob sweep is Enabled: [" .. tostring(sweep == true) .. "]")
end

---@return number radius how far out the sweep looks
function MobsConfig.GetRadius()
    return getConfigSection().radius
end

---@param radius number
function MobsConfig.SetRadius(radius)
    getConfigSection().radius = math.max(math.min(math.floor(radius), 500), 10)
    Global.configStore:SaveConfig()
end

---@return number zradius how far above and below the sweep looks
function MobsConfig.GetZRadius()
    return getConfigSection().zradius
end

---@param zradius number
function MobsConfig.SetZRadius(zradius)
    getConfigSection().zradius = math.max(math.min(math.floor(zradius), 500), 5)
    Global.configStore:SaveConfig()
end

---How close a player has to be to a mob nothing is fighting for it to still count as in the fight.
---
---Only ever asked of a mob some state says it is holding (`Mobs.Hold`); it widens nothing on its
---own. A held mob further out than this is one that will wake up somewhere nobody is standing,
---which is the outcome a memory blur is *for* -- so it is let go rather than chased.
---@return number radius
function MobsConfig.GetHoldRadius()
    return getConfigSection().hold_radius
end

---@param radius number
function MobsConfig.SetHoldRadius(radius)
    getConfigSection().hold_radius = math.max(math.min(math.floor(radius), 500), 10)
    Global.configStore:SaveConfig()
end

---@diagnostic disable-next-line: duplicate-set-field
function MobsConfig.Print()
    TableUtils.Print(getConfigSection())
end

return MobsConfig
