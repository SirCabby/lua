local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")
local Actions = require("cabby.actions.actions")
local Character = require("cabby.character")
local Skills = require("cabby.actions.skills")

---@class MeleeStateConfig : BaseConfig
local MeleeStateConfig = {
    key = "MeleeState",
    usages = {
        Always = { value = "always", display = "Always" },
        AsNeeded = { value = "as_needed", display = "As Needed" },
        Off = { value = "off", display = "Off" }
    },
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

    if Character.HasSecondaryAbilities() and configRoot.primary_combat_ability == nil then
        configRoot.secondary_combat_ability = Skills.none:Name()
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

    if Character.HasTaunts() then
        if configRoot.taunt_actions == nil then
            configRoot.taunt_actions = {}
            taint = true
        end

        if configRoot.taunt_usage == nil then
            configRoot.taunt_usage = MeleeStateConfig.usages.AsNeeded.value
            taint = true
        end
    end

    for i = #configRoot.taunt_actions, 1, -1 do
        local action = configRoot.taunt_actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.taunt_actions, i)
            taint = true
        end
    end

    if Character.HasHates() then
        if configRoot.hate_actions == nil then
            configRoot.hate_actions = {}
            taint = true
        end

        if configRoot.hate_usage == nil then
            configRoot.hate_usage = MeleeStateConfig.usages.Always.value
            taint = true
        end
    end

    for i = #configRoot.hate_actions, 1, -1 do
        local action = configRoot.hate_actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.hate_actions, i)
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

---@return ActionType primary_combat_ability
function MeleeStateConfig.GetPrimaryCombatAbility()
    local currentAbilityName = getConfigSection().primary_combat_ability
    ---@type ActionType
    local result = Skills.none
    if not IsValidActiontype(Character.primaryMeleeAbilities, currentAbilityName) then
        currentAbilityName = result:Name()
        getConfigSection().primary_combat_ability = currentAbilityName
        Global.configStore:SaveConfig()
    end
    result = Actions.Get(ActionType.Ability, currentAbilityName) or result
    return result
end

---@param primary_combat_ability ActionType
function MeleeStateConfig.SetPrimaryCombatAbility(primary_combat_ability)
    if IsValidActiontype(Character.primaryMeleeAbilities, primary_combat_ability:Name()) then
        getConfigSection().primary_combat_ability = primary_combat_ability:Name()
        Global.configStore:SaveConfig()
    end
end

---@return ActionType secondary_combat_ability
function MeleeStateConfig.GetSecondaryCombatAbility()
    local currentAbilityName = getConfigSection().secondary_combat_ability
    ---@type ActionType
    local result = Skills.none
    if not IsValidActiontype(Character.secondaryMeleeAbilities, currentAbilityName) then
        currentAbilityName = result:Name()
        getConfigSection().secondary_combat_ability = currentAbilityName
        Global.configStore:SaveConfig()
    end
    result = Actions.Get(ActionType.Ability, currentAbilityName) or result
    return result
end

---@param secondary_combat_ability ActionType
function MeleeStateConfig.SetSecondaryCombatAbility(secondary_combat_ability)
    if IsValidActiontype(Character.secondaryMeleeAbilities, secondary_combat_ability:Name()) then
        getConfigSection().secondary_combat_ability = secondary_combat_ability:Name()
        Global.configStore:SaveConfig()
    end
end

---@return boolean enable
function MeleeStateConfig.GetBashOverride()
    return getConfigSection().bash_override
end

---@param enable boolean
function MeleeStateConfig.SetBashOverride(enable)
    getConfigSection().bash_override = enable == true
    Global.configStore:SaveConfig()
end

---@return boolean enable
function MeleeStateConfig.GetTanking()
    return getConfigSection().tanking
end

---@param enable boolean
function MeleeStateConfig.SetTanking(enable)
    getConfigSection().tanking = enable == true
    Global.configStore:SaveConfig()
end

---@return string usage
function MeleeStateConfig.GetTauntUsage()
    return getConfigSection().taunt_usage
end

---@param usage string
function MeleeStateConfig.SetTauntUsage(usage)
    for _, usageType in pairs(MeleeStateConfig.usages) do
        if usageType.value == usage then
            getConfigSection().taunt_usage = usage
            Global.configStore:SaveConfig()
            return
        end
    end
end

---@return string usage
function MeleeStateConfig.GetHateUsage()
    return getConfigSection().hate_usage
end

---@param usage string
function MeleeStateConfig.SetHateUsage(usage)
    for _, usageType in pairs(MeleeStateConfig.usages) do
        if usageType.value == usage then
            getConfigSection().hate_usage = usage
            Global.configStore:SaveConfig()
            return
        end
    end
end

---@return array actions
function MeleeStateConfig.GetActions()
    return getConfigSection().actions
end

---@return array actions
function MeleeStateConfig.GetTauntActions()
    return getConfigSection().taunt_actions
end

---@return array actions
function MeleeStateConfig.GetHateActions()
    return getConfigSection().hate_actions
end

return MeleeStateConfig
