local Debug = require("utils.Debug.Debug")

---@class CabbyConfig
local MeleeStateConfig = {
    key = "MeleeState",
    _ = {
        isInit = false,
        config = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeStateConfig.key, str)
end

local function getConfigSection()
    return MeleeStateConfig._.config:GetConfigRoot()[MeleeStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("MeleeStateConfig Section was not set, updating...")
        MeleeStateConfig._.config:GetConfigRoot()[MeleeStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.stick == nil then
        configRoot.stick = true
        taint = true
    end

    if configRoot.auto_engage == nil then
        configRoot.auto_engage = true
        taint = true
    end

    if configRoot.engage_distance == nil then
        configRoot.engage_distance = 50
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    if taint then
        MeleeStateConfig._.config:SaveConfig()
    end
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function MeleeStateConfig.Init()
    if not MeleeStateConfig._.isInit then
        local ftkey = Global.tracing.open("MeleeStateConfig Setup")
        MeleeStateConfig._.config = Global.configStore

        initAndValidate()

        MeleeStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function MeleeStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function MeleeStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    MeleeStateConfig._.config:SaveConfig()
    print("MeleeState is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean isEnabled
function MeleeStateConfig.GetAutoEngage()
    return getConfigSection().auto_engage
end

---@param enable boolean
function MeleeStateConfig.SetAutoEngage(enable)
    getConfigSection().auto_engage = enable == true
    MeleeStateConfig._.config:SaveConfig()
    print("MeleeState Auto-Engage is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean enable
function MeleeStateConfig.GetStick()
    return getConfigSection().stick
end

---@param enable boolean
function MeleeStateConfig.SetStick(enable)
    getConfigSection().stick = enable == true
    MeleeStateConfig._.config:SaveConfig()
    print("MeleeState stick: [" .. tostring(enable) .. "]")
end

---@return number engageDistance
function MeleeStateConfig.GetEngageDistance()
    return getConfigSection().engage_distance
end

---@param distance number
function MeleeStateConfig.SetEngageDistance(distance)
    getConfigSection().engage_distance = math.max(math.min(distance, 500), 0)
    MeleeStateConfig._.config:SaveConfig()
end

return MeleeStateConfig
