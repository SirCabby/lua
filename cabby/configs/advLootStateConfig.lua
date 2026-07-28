local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---One switch and nothing else: whether this character answers the loot window's rolls for itself.
---
---On by default, because the state already limits itself to the one situation the answer is
---obvious in -- somebody *else* controls the loot, and an unanswered roll is one the whole group
---waits on. Controlling the loot ourselves, or with nothing rolling, the state does nothing
---whatever this says, so the switch only ever matters to a character that wants to answer its
---own rolls by hand.
---@class AdvLootStateConfig : BaseConfig
local AdvLootStateConfig = {
    key = "AdvLootState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(AdvLootStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[AdvLootStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("AdvLootStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[AdvLootStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function AdvLootStateConfig.Init()
    if not AdvLootStateConfig._.isInit then
        local ftkey = Global.tracing.open("AdvLootStateConfig Setup")

        initAndValidate()

        AdvLootStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function AdvLootStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---@param enable boolean
function AdvLootStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("AdvLootState is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function AdvLootStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return AdvLootStateConfig
