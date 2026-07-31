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

    -- On by default and harmless where it does not apply: only the character holding the group's
    -- main tank role ever says anything, so every other character carries the setting unused until
    -- the day it is handed the role.
    if configRoot.call_assist == nil then
        configRoot.call_assist = true
        taint = true
    end

    -- On by default for the same reason: it costs nothing where it does not apply. Only a
    -- character something is actually coming for says anything, only the main tank acts on what
    -- is said, and the reports stop by themselves once the tank takes the mob's hate.
    if configRoot.call_defend == nil then
        configRoot.call_defend = true
        taint = true
    end

    -- On by default, and on the same reasoning: it costs nothing where it does not apply. Only a
    -- character that is *not* the group's main tank, in a group that has named one, holding the
    -- top of the hate list of the very mob the tank should be holding, ever eases off anything --
    -- which is the moment it exists for. A group with no tank named never sees it.
    if configRoot.ease_off == nil then
        configRoot.ease_off = true
        taint = true
    end

    -- The four below are one driving style -- the player's own client running the group -- and
    -- all default off, unlike call_assist: engage_on_attack turns a keypress into an order to
    -- charge, assist_on_engage speaks with no role gate in front of it, and the two disengage
    -- switches let go of a fight the group may still be winning, so a group shipping with any
    -- of them on would be six characters charging, announcing and quitting at once.
    if configRoot.engage_on_attack == nil then
        configRoot.engage_on_attack = false
        taint = true
    end

    if configRoot.assist_on_engage == nil then
        configRoot.assist_on_engage = false
        taint = true
    end

    if configRoot.disengage_on_attack_off == nil then
        configRoot.disengage_on_attack_off = false
        taint = true
    end

    if configRoot.disengage_on_target_clear == nil then
        configRoot.disengage_on_target_clear = false
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

---@return boolean callAssist whether the main tank calls the assist out to the group
function CombatConfig.GetCallAssist()
    return getConfigSection().call_assist
end

---@param enable boolean
function CombatConfig.SetCallAssist(enable)
    getConfigSection().call_assist = enable == true
    Global.configStore:SaveConfig()
    print("Calling the assist is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean callDefend whether beatings this character cannot shed are called out for the tank
function CombatConfig.GetCallDefend()
    return getConfigSection().call_defend
end

---@param enable boolean
function CombatConfig.SetCallDefend(enable)
    getConfigSection().call_defend = enable == true
    Global.configStore:SaveConfig()
    print("Calling for defense is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean easeOff whether damage is held back while we hold the mob the tank should have
function CombatConfig.GetEaseOff()
    return getConfigSection().ease_off
end

---@param enable boolean
function CombatConfig.SetEaseOff(enable)
    getConfigSection().ease_off = enable == true
    Global.configStore:SaveConfig()
    print("Easing off what we pull off the main tank is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean engageOnAttack whether the attack toggle turning on engages the target as an order
function CombatConfig.GetEngageOnAttack()
    return getConfigSection().engage_on_attack
end

---@param enable boolean
function CombatConfig.SetEngageOnAttack(enable)
    getConfigSection().engage_on_attack = enable == true
    Global.configStore:SaveConfig()
    print("Engage on attack is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean assistOnEngage whether this character's own fights are called out, role or no role
function CombatConfig.GetAssistOnEngage()
    return getConfigSection().assist_on_engage
end

---@param enable boolean
function CombatConfig.SetAssistOnEngage(enable)
    getConfigSection().assist_on_engage = enable == true
    Global.configStore:SaveConfig()
    print("Assist on engage is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean disengageOnAttackOff whether the attack toggle switching off calls the fight off
function CombatConfig.GetDisengageOnAttackOff()
    return getConfigSection().disengage_on_attack_off
end

---@param enable boolean
function CombatConfig.SetDisengageOnAttackOff(enable)
    getConfigSection().disengage_on_attack_off = enable == true
    Global.configStore:SaveConfig()
    print("Disengage on attack off is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean disengageOnTargetClear whether clearing the fight's own target calls the fight off
function CombatConfig.GetDisengageOnTargetClear()
    return getConfigSection().disengage_on_target_clear
end

---@param enable boolean
function CombatConfig.SetDisengageOnTargetClear(enable)
    getConfigSection().disengage_on_target_clear = enable == true
    Global.configStore:SaveConfig()
    print("Disengage on target clear is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function CombatConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CombatConfig
