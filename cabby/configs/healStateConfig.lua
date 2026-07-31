local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character heals, and with what.
---
---The whole model is one ordered list of **heal slots**. A slot is an action (a spell, an AA or a
---clicky) plus the two things that decide when it is the right one: the health it is *for*
---(`hp_threshold` -- use it on someone at or below this), and who it is for (`heal_scope`).
---Walking the list in order and taking the first slot that fits is how every heal macro since
---AFCleric has chosen a heal, and it is what lets one mechanism cover what those macros spelled
---out one setting at a time: a slot at 85% scoped to the tank is TankHealPoint, a slot at 50%
---scoped to yourself is SelfHealPoint, and a group heal at 60% is DivArbPoint.
---
---Scope only ever narrows a heal that *could* go to more than one person. Where a spell can be
---aimed is the spell's own business and outranks it: a pet heal lands on the pet and a self heal
---lands on us whatever the slot says, which is why the page offers those slots the one scope they
---can have and does not let it be changed.
---"Anyone else" is the rest of the group and not the pet -- the pet has a scope of its own, and
---a heal meant for the people in the group should not be spent on a pet because nobody thought
---to say so.
---@class HealStateConfig : BaseConfig
local HealStateConfig = {
    key = "HealState",
    scopes = {
        Any = { value = "any", display = "Anyone" },
        Self = { value = "self", display = "Myself" },
        Tank = { value = "tank", display = "The tank" },
        Others = { value = "others", display = "Anyone else" },
        Pet = { value = "pet", display = "My pet" }
    },
    _ = {
        isInit = false
    }
}

local defaultThreshold = 70
local defaultGroupMin = 3

---@param str string
local function DebugLog(str)
    Debug.Log(HealStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[HealStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("HealStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[HealStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.heal_group == nil then
        configRoot.heal_group = true
        taint = true
    end

    if configRoot.heal_pets == nil then
        -- off by default: a pet is cheaper to re-summon than a heal is to cast, and a healer
        -- spending mana on one while the tank drops is the classic complaint about heal bots.
        -- A pet class that means to keep its pet up turns it on, and the Heal State page says so
        -- against any slot holding a pet heal, which would otherwise never fire for no visible
        -- reason
        configRoot.heal_pets = false
        taint = true
    end

    if configRoot.emergency_pct == nil then
        configRoot.emergency_pct = 35
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    -- a slot that was never finished being filled in cannot be healed with
    for i = #configRoot.actions, 1, -1 do
        local action = configRoot.actions[i]
        if action.actionType == nil or action.actionType == ActionType.Edit then
            table.remove(configRoot.actions, i)
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function HealStateConfig.Init()
    if not HealStateConfig._.isInit then
        local ftkey = Global.tracing.open("HealStateConfig Setup")

        initAndValidate()

        HealStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function HealStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function HealStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("HealState is Enabled: [" .. tostring(enable) .. "]")
end

---Whether the rest of the group is somebody this character heals at all -- which is to say
---whether they are *watched*, since a heal is only ever chosen for somebody being watched. Off
---leaves this character and its pet, and a group-mate at 10% to whoever else is healing.
---
---It says nothing about group heal *spells*. One of those is cast because enough of the people
---being watched are hurt, so switching this off shrinks the count it is judged against rather
---than taking the spell out of the list.
---@return boolean healGroup
function HealStateConfig.GetHealGroup()
    return getConfigSection().heal_group
end

---@param enable boolean
function HealStateConfig.SetHealGroup(enable)
    getConfigSection().heal_group = enable == true
    Global.configStore:SaveConfig()
    print("HealState heals group members: [" .. tostring(enable) .. "]")
end

---@return boolean healPets
function HealStateConfig.GetHealPets()
    return getConfigSection().heal_pets
end

---@param enable boolean
function HealStateConfig.SetHealPets(enable)
    getConfigSection().heal_pets = enable == true
    Global.configStore:SaveConfig()
    print("HealState heals pets: [" .. tostring(enable) .. "]")
end

---The health at which someone is in trouble rather than merely hurt. It does not decide which
---heal to use -- the slots do that -- it decides what is worth throwing away a heal in progress
---for.
---@return number pct
function HealStateConfig.GetEmergencyPct()
    return getConfigSection().emergency_pct
end

---@param pct number
function HealStateConfig.SetEmergencyPct(pct)
    getConfigSection().emergency_pct = math.max(math.min(math.floor(pct), 99), 1)
    Global.configStore:SaveConfig()
end

---@return table actions the heal slots, in the order they are tried
function HealStateConfig.GetActions()
    return getConfigSection().actions
end

---Every action list this state owns, in the shape the shared `action` command and the menu both
---read. There is only one here, unlike the melee state's three.
---@return table actionLists array of { label, actions }
function HealStateConfig.GetActionLists()
    return { { label = "Heal", actions = HealStateConfig.GetActions() } }
end

---------------- Heal slot fields --------------------

---These are written straight to the live slot rather than staged behind a Save, for the same
---reason the Enabled switch is: a threshold is not part of *describing* a heal, it is the dial
---you reach for while watching a fight go badly.

---@param action Action
---@return number pct use this heal on someone at or below this health
function HealStateConfig.GetThreshold(action)
    return tonumber(action.hp_threshold) or defaultThreshold
end

---@param action Action
---@param pct number
function HealStateConfig.SetThreshold(action, pct)
    action.hp_threshold = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---@param action Action
---@return string scope one of HealStateConfig.scopes values
function HealStateConfig.GetScope(action)
    local scope = action.heal_scope
    for _, known in pairs(HealStateConfig.scopes) do
        if known.value == scope then return scope end
    end
    return HealStateConfig.scopes.Any.value
end

---@param action Action
---@param scope string
function HealStateConfig.SetScope(action, scope)
    action.heal_scope = scope
    Global.configStore:SaveConfig()
end

---How many people have to be hurt before a group heal is worth casting. Only means anything for
---a slot holding a spell that heals the group rather than a target.
---@param action Action
---@return number count
function HealStateConfig.GetGroupMin(action)
    return tonumber(action.group_min) or defaultGroupMin
end

---@param action Action
---@param count number
function HealStateConfig.SetGroupMin(action, count)
    action.group_min = math.max(math.min(math.floor(count), 6), 1)
    Global.configStore:SaveConfig()
end

---@param scope string
---@return string display
function HealStateConfig.GetScopeDisplay(scope)
    for _, known in pairs(HealStateConfig.scopes) do
        if known.value == scope then return known.display end
    end
    return HealStateConfig.scopes.Any.display
end

---@diagnostic disable-next-line: duplicate-set-field
function HealStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return HealStateConfig
