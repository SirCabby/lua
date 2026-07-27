local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---What "we are fighting that" means, for every state that fights.
---
---Small on purpose. It exists because the engagement target stopped belonging to the melee state
---the moment a wizard needed one too, and the settings that decide *when* we pick one up came
---with it.
---@class CombatConfig : BaseConfig
local CombatConfig = {
    key = "Combat",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CombatConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[CombatConfig.key]
end

---`auto_engage` used to live in the melee state's section, which is where every character that
---has run cabby before still has it. Take it across rather than making them set it again, and
---take it out of the old section so there is one answer to the question.
---@return boolean? inherited
local function inheritFromMelee()
    local melee = Global.configStore:GetConfigRoot()["MeleeState"]
    if melee == nil or melee.auto_engage == nil then return nil end

    local inherited = melee.auto_engage == true
    melee.auto_engage = nil
    DebugLog("Took auto_engage across from the MeleeState config: " .. tostring(inherited))
    return inherited
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("CombatConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[CombatConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    local inherited = inheritFromMelee()
    if inherited ~= nil then
        taint = true
        if configRoot.auto_engage == nil then
            configRoot.auto_engage = inherited
        end
    end

    if configRoot.auto_engage == nil then
        configRoot.auto_engage = true
        taint = true
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CombatConfig.Init()
    if not CombatConfig._.isInit then
        local ftkey = Global.tracing.open("CombatConfig Setup")

        initAndValidate()

        CombatConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean autoEngage whether anything attacking us is picked up without being told
function CombatConfig.GetAutoEngage()
    return getConfigSection().auto_engage
end

---@param enable boolean
function CombatConfig.SetAutoEngage(enable)
    getConfigSection().auto_engage = enable == true
    Global.configStore:SaveConfig()
    print("Auto-Engage is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function CombatConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CombatConfig
