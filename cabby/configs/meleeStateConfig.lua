local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local Actions = require("cabby.actions.actions")
local Character = require("cabby.character")
local EditAction = require("cabby.ui.actions.editAction")
local Skills = require("cabby.actions.skills")

---@class MeleeStateConfig : BaseConfig
local MeleeStateConfig = {
    key = "MeleeState",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[MeleeStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("MeleeStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[MeleeStateConfig.key] = {}
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

    if configRoot.primary_combat_ability == nil then
        configRoot.primary_combat_ability = Skills.none:Name()
        taint = true
    end

    if configRoot.secondary_combat_ability == nil then
        configRoot.secondary_combat_ability = Skills.none:Name()
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    for i = #configRoot.actions, 1, -1 do
        local action = configRoot.actions[i]
        if action.actionType == nil or action.actionType == EditAction.actionType then
            table.remove(configRoot.actions, i)
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

local function IsValidActiontype(actions, actionName)
    local actionNames = {}
    for _, action in ipairs(actions) do
        actionNames[#actionNames+1] = action:Name()
    end
    return TableUtils.ArrayContains(actionNames, actionName)
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function MeleeStateConfig.Init()
    if not MeleeStateConfig._.isInit then
        local ftkey = Global.tracing.open("MeleeStateConfig Setup")

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
    Global.configStore:SaveConfig()
    print("MeleeState is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean isEnabled
function MeleeStateConfig.GetAutoEngage()
    return getConfigSection().auto_engage
end

---@param enable boolean
function MeleeStateConfig.SetAutoEngage(enable)
    getConfigSection().auto_engage = enable == true
    Global.configStore:SaveConfig()
    print("MeleeState Auto-Engage is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean enable
function MeleeStateConfig.GetStick()
    return getConfigSection().stick
end

---@param enable boolean
function MeleeStateConfig.SetStick(enable)
    getConfigSection().stick = enable == true
    Global.configStore:SaveConfig()
    print("MeleeState stick: [" .. tostring(enable) .. "]")
end

---@return number engageDistance
function MeleeStateConfig.GetEngageDistance()
    return getConfigSection().engage_distance
end

---@param distance number
function MeleeStateConfig.SetEngageDistance(distance)
    getConfigSection().engage_distance = math.max(math.min(distance, 500), 0)
    Global.configStore:SaveConfig()
end

---@return Action primary_combat_ability
function MeleeStateConfig.GetPrimaryCombatAbility()
    local currentAbilityName = getConfigSection().primary_combat_ability
    ---@type Action
    local result = Skills.none
    if not IsValidActiontype(Character.primaryMeleeAbilities, currentAbilityName) then
        currentAbilityName = result:Name()
        getConfigSection().primary_combat_ability = currentAbilityName
        Global.configStore:SaveConfig()
    end
    result = Actions.Get(Actions.ability, currentAbilityName) or result
    return result
end

---@param primary_combat_ability Action
function MeleeStateConfig.SetPrimaryCombatAbility(primary_combat_ability)
    if IsValidActiontype(Character.primaryMeleeAbilities, primary_combat_ability:Name()) then
        getConfigSection().primary_combat_ability = primary_combat_ability:Name()
        Global.configStore:SaveConfig()
    end
end

---@return Action secondary_combat_ability
function MeleeStateConfig.GetSecondaryCombatAbility()
    local currentAbilityName = getConfigSection().secondary_combat_ability
    ---@type Action
    local result = Skills.none
    if not IsValidActiontype(Character.secondaryMeleeAbilities, currentAbilityName) then
        currentAbilityName = result:Name()
        getConfigSection().secondary_combat_ability = currentAbilityName
        Global.configStore:SaveConfig()
    end
    result = Actions.Get(Actions.ability, currentAbilityName) or result
    return result
end

---@param secondary_combat_ability Action
function MeleeStateConfig.SetSecondaryCombatAbility(secondary_combat_ability)
    if IsValidActiontype(Character.secondaryMeleeAbilities, secondary_combat_ability:Name()) then
        getConfigSection().secondary_combat_ability = secondary_combat_ability:Name()
        Global.configStore:SaveConfig()
    end
end

---@return array actions
function MeleeStateConfig.GetActions()
    return getConfigSection().actions
end

return MeleeStateConfig
