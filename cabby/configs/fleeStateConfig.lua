local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---Travel mode, as one persisted switch.
---
---There is only the one setting, and it is the mode itself: `enabled` here means "this character
---is fleeing", not "the flee state is available". That is deliberate -- a second switch over the
---top of it would only ever be a way to have the order refused without saying so.
---
---It is persisted like every other switch, which means a character that was fleeing when the
---script was reloaded comes back fleeing. That is the right answer far more often than the
---alternative (a long run is not over because a client restarted), but it is also the one setting
---that is easy to forget you left on, so `FleeState.Init` says so at startup.
---@class FleeStateConfig : BaseConfig
local FleeStateConfig = {
    key = "FleeState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(FleeStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[FleeStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("FleeStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[FleeStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        -- off: fleeing is something to be told to do, and a bot that starts up refusing to fight
        -- looks broken to everyone who did not set it
        configRoot.enabled = false
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function FleeStateConfig.Init()
    if not FleeStateConfig._.isInit then
        local ftkey = Global.tracing.open("FleeStateConfig Setup")

        initAndValidate()

        FleeStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isFleeing
function FleeStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---Written through `FleeState.SetEnabled`, which is what lets go of the fight, the cast and the
---stick that were standing when the order arrived. Nothing else should call this directly.
---@param enable boolean
function FleeStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("FleeState is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function FleeStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return FleeStateConfig
