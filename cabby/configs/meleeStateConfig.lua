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

    if configRoot.stick_distance == nil then
        configRoot.stick_distance = 12
        taint = true
    end

    if configRoot.engage_range == nil then
        configRoot.engage_range = 50
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

function MeleeStateConfig.SetEnabled(isEnabled)
    getConfigSection().enabled = isEnabled
    MeleeStateConfig._.config:SaveConfig()
    print("MeleeState is Enabled: [" .. tostring(isEnabled) .. "]")
end

return MeleeStateConfig
