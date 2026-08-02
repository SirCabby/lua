local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---What this character says about its own afflictions.
---
---Small on purpose, and separate from the heal state's section for one reason: **every class
---carries this and only the healers carry that**. A warrior standing in a poison DoT is exactly
---who needs to say so, and it has no heal state, no heal config and nothing to cure with. So the
---asking half of curing lives with the service that does the asking (`cabby.curing`) and is
---configured here; the answering half is a setting on the Heal State page.
---@class CuringConfig : BaseConfig
local CuringConfig = {
    key = "Curing",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CuringConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[CuringConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("CuringConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[CuringConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    -- On by default, and load-bearing the way the assist call is: nothing else in the group can
    -- see what is ticking on this character -- another player's debuffs are not readable until
    -- they are targeted, and nobody targets a group-mate mid-fight to check. An unheard
    -- affliction is a DoT that runs its full two minutes with a cleric standing next to it. The
    -- line costs one message per affliction and is silent on a character nothing is on, which is
    -- almost always.
    if configRoot.call_cure == nil then
        configRoot.call_cure = true
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CuringConfig.Init()
    if not CuringConfig._.isInit then
        local ftkey = Global.tracing.open("CuringConfig Setup")

        initAndValidate()

        CuringConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean callCure whether this character asks the group for a cure when it is afflicted
function CuringConfig.GetCallCure()
    return getConfigSection().call_cure == true
end

---@param enable boolean
function CuringConfig.SetCallCure(enable)
    getConfigSection().call_cure = enable == true
    Global.configStore:SaveConfig()
    print("Asking the group for cures is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function CuringConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CuringConfig
