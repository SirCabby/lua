local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---One switch and nothing else: whether this character will loot its own corpse when told to.
---
---On by default, because the state does nothing at all until somebody says `lootcorpse` -- there
---is no habit here to opt into, only whether an order given to the group is one this character
---answers. Off is for a character somebody is playing by hand and would rather loot themselves.
---@class CorpseStateConfig : BaseConfig
local CorpseStateConfig = {
    key = "CorpseState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CorpseStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[CorpseStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("CorpseStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[CorpseStateConfig.key] = {}
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
function CorpseStateConfig.Init()
    if not CorpseStateConfig._.isInit then
        local ftkey = Global.tracing.open("CorpseStateConfig Setup")

        initAndValidate()

        CorpseStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function CorpseStateConfig.IsEnabled()
    return getConfigSection().enabled == true
end

---@param enable boolean
function CorpseStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("CorpseState is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function CorpseStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CorpseStateConfig
