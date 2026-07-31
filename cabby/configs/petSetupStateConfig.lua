local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character's pet is made of: what summons it, and what it is handed once it is here.
---
---Two ordered lists, the same shape every other state's list has. The **pet list** is what
---summons a pet -- the first entry that is ready is the one cast, so its order is which pet this
---character would rather have, and switching an entry off (from the page, a hotbar button or
---`petaction`) is how a magician says "the water pet today". The **gear list** is what gets
---conjured and handed over once a pet is standing there, in the order it is handed over.
---
---Almost nothing about a slot is configured, because the spell already knows: whether it summons
---a pet at all, which item it conjures, and what that item is called are read off the spell's own
---effects. The one dial a gear slot carries is `pet_gear_count` -- how many of that item this pet
---should end up with, which is the difference between arming one hand and arming two, and is not
---something any spell can answer.
---@class PetSetupStateConfig : BaseConfig
local PetSetupStateConfig = {
    key = "PetSetupState",
    _ = {
        isInit = false
    }
}

---What this section was called before the pet state became two of them (2026-07-30). Carried over
---rather than defaulted: a magician's pet list and its gear counts are minutes of picking spells,
---and losing them silently to a rename is the worst way for an update to land.
local formerKey = "PetState"

---One of the item is the answer for nearly everything: a weapon for the main hand, a focus item,
---a bag of food. Two is the dual-wield case and the reason the dial exists at all.
local defaultGearCount = 1

---More than a pet can plausibly be given of one thing. The cap is here so a mistyped number
---cannot turn into a summoning loop that runs until the mana is gone.
local maxGearCount = 4

---@param str string
local function DebugLog(str)
    Debug.Log(PetSetupStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[PetSetupStateConfig.key]
end

local function initAndValidate()
    local taint = false
    local configStore = Global.configStore:GetConfigRoot()

    -- the rename, once: an old section is moved across whole, and only when there is nothing here
    -- yet, so a character that has since been set up under the new name is never overwritten
    if getConfigSection() == nil and configStore[formerKey] ~= nil then
        DebugLog("Moving the [" .. formerKey .. "] section over to [" .. PetSetupStateConfig.key .. "]")
        configStore[PetSetupStateConfig.key] = configStore[formerKey]
        configStore[formerKey] = nil
        taint = true
    end

    if getConfigSection() == nil then
        DebugLog("PetSetupStateConfig Section was not set, updating...")
        configStore[PetSetupStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.summoning == nil then
        configRoot.summoning = true
        taint = true
    end

    if configRoot.gearing == nil then
        configRoot.gearing = true
        taint = true
    end

    if configRoot.in_combat == nil then
        -- off, for the reasons buffing is: a pet summon is a long cast and a full bar of mana,
        -- and handing something over needs the pet standing next to us rather than off fighting
        configRoot.in_combat = false
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    if configRoot.gear_actions == nil then
        configRoot.gear_actions = {}
        taint = true
    end

    -- a slot that was never finished being filled in cannot be used
    for _, list in ipairs({ configRoot.actions, configRoot.gear_actions }) do
        for i = #list, 1, -1 do
            local action = list[i]
            if action.actionType == nil or action.actionType == ActionType.Edit then
                table.remove(list, i)
                taint = true
            end
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function PetSetupStateConfig.Init()
    if not PetSetupStateConfig._.isInit then
        local ftkey = Global.tracing.open("PetSetupStateConfig Setup")

        initAndValidate()

        PetSetupStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function PetSetupStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function PetSetupStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("PetSetupState is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean summoning whether a missing pet is replaced
function PetSetupStateConfig.GetSummoning()
    return getConfigSection().summoning
end

---@param enable boolean
function PetSetupStateConfig.SetSummoning(enable)
    getConfigSection().summoning = enable == true
    Global.configStore:SaveConfig()
    print("PetSetupState summons the pet: [" .. tostring(enable) .. "]")
end

---@return boolean gearing whether the pet is handed what the gear list holds
function PetSetupStateConfig.GetGearing()
    return getConfigSection().gearing
end

---@param enable boolean
function PetSetupStateConfig.SetGearing(enable)
    getConfigSection().gearing = enable == true
    Global.configStore:SaveConfig()
    print("PetSetupState gears the pet: [" .. tostring(enable) .. "]")
end

---@return boolean inCombat whether pet work carries on while this character is fighting
function PetSetupStateConfig.GetInCombat()
    return getConfigSection().in_combat
end

---@param enable boolean
function PetSetupStateConfig.SetInCombat(enable)
    getConfigSection().in_combat = enable == true
    Global.configStore:SaveConfig()
    print("PetSetupState works during combat: [" .. tostring(enable) .. "]")
end

---@return table actions the pet summons, in the order they are tried
function PetSetupStateConfig.GetActions()
    return getConfigSection().actions
end

---@return table actions the gear, in the order it is handed over
function PetSetupStateConfig.GetGearActions()
    return getConfigSection().gear_actions
end

---Every action list this state owns, in the shape the shared action command and the menu both
---read.
---@return table actionLists array of { label, actions }
function PetSetupStateConfig.GetActionLists()
    return {
        { label = "Pet", actions = PetSetupStateConfig.GetActions() },
        { label = "Pet gear", actions = PetSetupStateConfig.GetGearActions() }
    }
end

---------------- Gear slot fields --------------------

---Written straight to the live slot rather than staged behind a Save, for the same reason the
---Enabled switch is: how many daggers the pet should end up holding is a dial you reach for while
---looking at the pet, not part of describing which spell summons them.

---How many of this slot's item the pet should end up with.
---@param action Action
---@return number count
function PetSetupStateConfig.GetGearCount(action)
    local count = tonumber(action.pet_gear_count)
    if count == nil then return defaultGearCount end
    return math.max(math.min(math.floor(count), maxGearCount), 1)
end

---@param action Action
---@param count number
function PetSetupStateConfig.SetGearCount(action, count)
    action.pet_gear_count = math.max(math.min(math.floor(count), maxGearCount), 1)
    Global.configStore:SaveConfig()
end

---@diagnostic disable-next-line: duplicate-set-field
function PetSetupStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return PetSetupStateConfig
