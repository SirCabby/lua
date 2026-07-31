local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character throws at whatever it is fighting, and when it holds back.
---
---The list is the same shape as the melee state's: actions in the order they are tried, first one
---ready wins. What is different is the three numbers around it, and they are all about restraint
---rather than damage -- a caster with no restraint pulls the mob off the tank, runs itself out of
---mana, and spends a four second cast on something that dies in two.
---
---A slot holding something cast on a *friend* -- a damage shield, which is damage that happens to
---live on somebody's buff bar -- carries one more field: `dps_scope`, who it is for. It reads the
---same way the heal list's does and only ever narrows a spell that could go to more than one
---person: where a spell can be aimed is the spell's own business and outranks it.
---
---A slot aimed at the mob carries `dps_timing` instead, which is *when* in a fight it is worth
---casting. A nuke has nothing to say about that and keeps the default; a debuff that leaves
---something behind often does -- a root is a different order given at the top of a fight, at the
---bottom of one, and to something that has turned and run.
---
---It may also carry `dps_spread`, which is *how many* rather than when: a debuff that belongs on
---everything in the fight rather than only on the one being killed.
---@class SpellDpsStateConfig : BaseConfig
local SpellDpsStateConfig = {
    key = "SpellDpsState",
    scopes = {
        Any = { value = "any", display = "Anyone" },
        Self = { value = "self", display = "Myself" },
        Tank = { value = "tank", display = "The tank" },
        Others = { value = "others", display = "Anyone else" },
        Pet = { value = "pet", display = "My pet" }
    },
    ---When a slot aimed at what we are fighting has its moment. It only ever *narrows*: a slot
    ---still has to come up in the order, get past the three numbers above, and have something to
    ---do -- which is what covers "and reapply it if it fades" without a setting, since a spell
    ---that leaves something behind is not cast again while that something is still there.
    timings = {
        Always = { value = "always", display = "Right away" },
        Hurt = { value = "hurt", display = "Once it is hurt" },
        Fleeing = { value = "fleeing", display = "Once it runs" }
    },
    _ = {
        isInit = false
    }
}

---What "once it is hurt" means when nobody has said. Where a mob that is going to run turns and
---runs, near enough, which is what the answer is usually being set for.
local defaultTimingPct = 20

---@param str string
local function DebugLog(str)
    Debug.Log(SpellDpsStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[SpellDpsStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("SpellDpsStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[SpellDpsStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.mana_floor == nil then
        configRoot.mana_floor = 20
        taint = true
    end

    if configRoot.start_pct == nil then
        -- 95 rather than 100: a moment for the tank to land something before we start, which is
        -- the cheapest aggro management there is
        configRoot.start_pct = 95
        taint = true
    end

    if configRoot.stop_pct == nil then
        configRoot.stop_pct = 5
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    for i = #configRoot.actions, 1, -1 do
        local action = configRoot.actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.actions, i)
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsStateConfig.Init()
    if not SpellDpsStateConfig._.isInit then
        local ftkey = Global.tracing.open("SpellDpsStateConfig Setup")

        initAndValidate()

        SpellDpsStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function SpellDpsStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function SpellDpsStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("SpellDpsState is Enabled: [" .. tostring(enable) .. "]")
end

---Mana to keep back. Nothing is cast below it, which is what leaves a healer's mana for healing
---and a nuker's for the fight after this one.
---@return number pct
function SpellDpsStateConfig.GetManaFloor()
    return getConfigSection().mana_floor
end

---@param pct number
function SpellDpsStateConfig.SetManaFloor(pct)
    getConfigSection().mana_floor = math.max(math.min(math.floor(pct), 100), 0)
    Global.configStore:SaveConfig()
end

---@return number pct don't start until the target is at or below this health
function SpellDpsStateConfig.GetStartPct()
    return getConfigSection().start_pct
end

---@param pct number
function SpellDpsStateConfig.SetStartPct(pct)
    getConfigSection().start_pct = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---@return number pct don't start anything new once the target is below this health
function SpellDpsStateConfig.GetStopPct()
    return getConfigSection().stop_pct
end

---@param pct number
function SpellDpsStateConfig.SetStopPct(pct)
    getConfigSection().stop_pct = math.max(math.min(math.floor(pct), 99), 0)
    Global.configStore:SaveConfig()
end

---@return table actions the rotation, in the order it is tried
function SpellDpsStateConfig.GetActions()
    return getConfigSection().actions
end

---@return table actionLists in the shape the shared `action` command and the menu both read
function SpellDpsStateConfig.GetActionLists()
    return { { label = "Spell DPS", actions = SpellDpsStateConfig.GetActions() } }
end

---------------- Rotation slot fields --------------------

---Written straight to the live slot rather than staged behind a Save, for the same reason the
---heal list's threshold is: who a shield is for is a dial you reach for while the group is
---forming up, not part of describing which spell it is.

---Who a slot cast on a friend is for. Means nothing to a slot cast at what we are fighting, which
---has nobody to choose between.
---@param action Action
---@return string scope one of SpellDpsStateConfig.scopes values
function SpellDpsStateConfig.GetScope(action)
    local scope = action.dps_scope
    for _, known in pairs(SpellDpsStateConfig.scopes) do
        if known.value == scope then return scope end
    end
    return SpellDpsStateConfig.scopes.Any.value
end

---@param action Action
---@param scope string
function SpellDpsStateConfig.SetScope(action, scope)
    action.dps_scope = scope
    Global.configStore:SaveConfig()
end

---When a slot aimed at what we are fighting is worth casting. Means nothing to a slot cast on a
---friend, whose moment is "when they are short of it".
---@param action Action
---@return string timing one of SpellDpsStateConfig.timings values
function SpellDpsStateConfig.GetTiming(action)
    local timing = action.dps_timing
    for _, known in pairs(SpellDpsStateConfig.timings) do
        if known.value == timing then return timing end
    end
    return SpellDpsStateConfig.timings.Always.value
end

---@param action Action
---@param timing string
function SpellDpsStateConfig.SetTiming(action, timing)
    action.dps_timing = timing
    Global.configStore:SaveConfig()
end

---Whether this slot is spread across the whole fight rather than aimed only at what we are
---killing. Off by default, which is every nuke and most debuffs: one mob is being killed and the
---rest of the rotation is for it.
---
---On, the slot is not finished while anything else in the fight still lacks its effect, so the
---rotation does not move past it to the next action until they all have it -- which is the whole
---point of the setting: a slow, a tash or a snare is worth more on three mobs than a second nuke
---is worth on one. Means nothing to a slot cast on a friend (`dps_scope` already says who those
---are for), and nothing to a spell that leaves no effect behind, which has no way of being
---finished with anybody.
---@param action Action
---@return boolean spread
function SpellDpsStateConfig.GetSpread(action)
    return action.dps_spread == true
end

---@param action Action
---@param spread boolean
function SpellDpsStateConfig.SetSpread(action, spread)
    action.dps_spread = spread == true
    Global.configStore:SaveConfig()
end

---@param timing string
---@return string display
function SpellDpsStateConfig.GetTimingDisplay(timing)
    for _, known in pairs(SpellDpsStateConfig.timings) do
        if known.value == timing then return known.display end
    end
    return SpellDpsStateConfig.timings.Always.display
end

---The health that "once it is hurt" waits for. Only means anything to a slot carrying that
---timing.
---@param action Action
---@return number pct cast it once the target is at or below this health
function SpellDpsStateConfig.GetTimingPct(action)
    return tonumber(action.dps_timing_pct) or defaultTimingPct
end

---@param action Action
---@param pct number
function SpellDpsStateConfig.SetTimingPct(action, pct)
    action.dps_timing_pct = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---@param scope string
---@return string display
function SpellDpsStateConfig.GetScopeDisplay(scope)
    for _, known in pairs(SpellDpsStateConfig.scopes) do
        if known.value == scope then return known.display end
    end
    return SpellDpsStateConfig.scopes.Any.display
end

---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return SpellDpsStateConfig
