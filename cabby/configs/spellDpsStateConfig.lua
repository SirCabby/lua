local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character throws at whatever it is fighting, and when it holds back.
---
---The list is the same shape as the melee state's: actions in the order they are tried, first one
---ready wins. What is different is the three numbers around it, and they are all about restraint
---rather than damage -- a caster with no restraint pulls the mob off the tank, runs itself out of
---mana, and spends a four second cast on something that dies in two.
---@class SpellDpsStateConfig : BaseConfig
local SpellDpsStateConfig = {
    key = "SpellDpsState",
    _ = {
        isInit = false
    }
}

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

---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return SpellDpsStateConfig
