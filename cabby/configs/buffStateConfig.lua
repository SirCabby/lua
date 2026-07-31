local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")
local Classes = require("cabby.classes.classes")

---What this character keeps up, and on whom.
---
---One ordered list of **buff slots**, the same shape the heal list has. A slot is an action (a
---spell, an AA or a clicky) plus the two things that decide who it is for: `buff_scope` (myself,
---anyone else, anyone) and `buff_classes` (the classes it is worth casting on, empty meaning all
---of them). That second one is what buffing needs and healing did not -- clarity is for casters
---and strength is for melee, and a buff bot that cannot say so either wastes half its casts or
---needs a separate setting per buff line, which is what the macros it replaces did.
---
---Everything else about a slot is read off the spell rather than configured, because the spell
---already knows: whether it is a group buff, whether it is a pet buff, how long it lasts, and
---whether it would land at all. The only timing dial is the slot's own `buff_rebuff_secs` --
---how little has to be left on that buff before recasting it is worth a gem timer -- per slot,
---because a two-hour buff and a ten-minute one have nothing in common about "nearly gone".
---@class BuffStateConfig : BaseConfig
local BuffStateConfig = {
    key = "BuffState",
    scopes = {
        Any = { value = "any", display = "Anyone" },
        Self = { value = "self", display = "Myself" },
        Others = { value = "others", display = "Anyone else" }
    },
    _ = {
        isInit = false
    }
}

---Three minutes of headroom keeps a buff from ever actually fading between looks: long enough
---to ride out a fight owning the frames right as the timer runs down, short enough that no
---meaningful duration is thrown away. Far too long for a short buff -- the state clamps the
---effective value against half of what the buff actually lasts, so a song is not recast the
---moment it lands.
local defaultRebuffSecs = 180

---@param str string
local function DebugLog(str)
    Debug.Log(BuffStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[BuffStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("BuffStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[BuffStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.buff_group == nil then
        configRoot.buff_group = true
        taint = true
    end

    if configRoot.buff_pets == nil then
        -- on, unlike healing pets: a buff is cast once and lasts the session, so the mana that
        -- argument was about is not being spent over and over
        configRoot.buff_pets = true
        taint = true
    end

    if configRoot.in_combat == nil then
        -- off: buffing mid-fight targets away from what is being fought, spends the mana the
        -- healer needs, and lands a thirty minute buff two seconds before the mob dies
        configRoot.in_combat = false
        taint = true
    end

    if configRoot.rebuff_secs ~= nil then
        -- the dial moved onto each slot (buff_rebuff_secs); the page-wide value is retired
        configRoot.rebuff_secs = nil
        taint = true
    end

    if configRoot.actions == nil then
        configRoot.actions = {}
        taint = true
    end

    -- a slot that was never finished being filled in cannot be buffed with
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
function BuffStateConfig.Init()
    if not BuffStateConfig._.isInit then
        local ftkey = Global.tracing.open("BuffStateConfig Setup")

        initAndValidate()

        BuffStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function BuffStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function BuffStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("BuffState is Enabled: [" .. tostring(enable) .. "]")
end

---@return boolean buffGroup
function BuffStateConfig.GetBuffGroup()
    return getConfigSection().buff_group
end

---@param enable boolean
function BuffStateConfig.SetBuffGroup(enable)
    getConfigSection().buff_group = enable == true
    Global.configStore:SaveConfig()
    print("BuffState buffs the group: [" .. tostring(enable) .. "]")
end

---@return boolean buffPets
function BuffStateConfig.GetBuffPets()
    return getConfigSection().buff_pets
end

---@param enable boolean
function BuffStateConfig.SetBuffPets(enable)
    getConfigSection().buff_pets = enable == true
    Global.configStore:SaveConfig()
    print("BuffState buffs pets: [" .. tostring(enable) .. "]")
end

---@return boolean inCombat whether buffing carries on while this character is fighting
function BuffStateConfig.GetInCombat()
    return getConfigSection().in_combat
end

---@param enable boolean
function BuffStateConfig.SetInCombat(enable)
    getConfigSection().in_combat = enable == true
    Global.configStore:SaveConfig()
    print("BuffState buffs during combat: [" .. tostring(enable) .. "]")
end

---@return table actions the buff slots, in the order they are tried
function BuffStateConfig.GetActions()
    return getConfigSection().actions
end

---Every action list this state owns, in the shape the shared `action` command and the menu both
---read.
---@return table actionLists array of { label, actions }
function BuffStateConfig.GetActionLists()
    return { { label = "Buff", actions = BuffStateConfig.GetActions() } }
end

---------------- Buff slot fields --------------------

---Written straight to the live slot rather than staged behind a Save, for the same reason the
---Enabled switch is: who a buff is for is a dial you reach for while the group is standing
---around, not part of describing which buff it is.

---@param action Action
---@return string scope one of BuffStateConfig.scopes values
function BuffStateConfig.GetScope(action)
    local scope = action.buff_scope
    for _, known in pairs(BuffStateConfig.scopes) do
        if known.value == scope then return scope end
    end
    return BuffStateConfig.scopes.Any.value
end

---@param action Action
---@param scope string
function BuffStateConfig.SetScope(action, scope)
    action.buff_scope = scope
    Global.configStore:SaveConfig()
end

---How little has to be left on this slot's buff before it is worth recasting. A buff is not
---recast because it is old, it is recast because it is nearly gone -- and "nearly" belongs to
---the slot, so the headroom on a two-hour buff does not chew through a ten-minute one.
---@param action Action
---@return number secs
function BuffStateConfig.GetRebuffSecs(action)
    local secs = tonumber(action.buff_rebuff_secs)
    if secs == nil then return defaultRebuffSecs end
    return secs
end

---@param action Action
---@param secs number
function BuffStateConfig.SetRebuffSecs(action, secs)
    action.buff_rebuff_secs = math.max(math.min(math.floor(secs), 3600), 0)
    Global.configStore:SaveConfig()
end

---@param action Action
---@return number ms the same, in milliseconds, which is what every duration reads as
function BuffStateConfig.GetRebuffMs(action)
    return BuffStateConfig.GetRebuffSecs(action) * 1000
end

---@param scope string
---@return string display
function BuffStateConfig.GetScopeDisplay(scope)
    for _, known in pairs(BuffStateConfig.scopes) do
        if known.value == scope then return known.display end
    end
    return BuffStateConfig.scopes.Any.display
end

---The classes this buff is worth casting on. An empty list means everybody, which is both the
---default and the right answer for most buffs -- naming classes is for the ones where casting it
---on the wrong half of the group is a wasted gem timer.
---@param action Action
---@return string[] shortNames
function BuffStateConfig.GetClasses(action)
    local classes = action.buff_classes
    if type(classes) ~= "table" then return {} end
    return classes
end

---@param action Action
---@param shortName string as `Class.ShortName()` reports it
---@return boolean isAllowed
function BuffStateConfig.IsClassAllowed(action, shortName)
    local classes = BuffStateConfig.GetClasses(action)
    if #classes < 1 then return true end

    shortName = tostring(shortName):upper()
    for _, allowed in ipairs(classes) do
        if tostring(allowed):upper() == shortName then return true end
    end
    return false
end

---Add or remove one class from a slot's list. A list that ends up holding every class is emptied
---rather than left full: "all sixteen" and "no filter" are the same rule, and only one of them
---keeps meaning the same thing after a class is added to the game.
---@param action Action
---@param shortName string
function BuffStateConfig.ToggleClass(action, shortName)
    shortName = tostring(shortName):upper()

    local classes = {}
    local removed = false
    for _, allowed in ipairs(BuffStateConfig.GetClasses(action)) do
        if tostring(allowed):upper() == shortName then
            removed = true
        else
            classes[#classes+1] = tostring(allowed):upper()
        end
    end

    if not removed then
        classes[#classes+1] = shortName
    end

    if #classes >= #Classes.shortNames then
        classes = {}
    end

    action.buff_classes = classes
    Global.configStore:SaveConfig()
end

---Back to everybody, which is what an empty list means.
---@param action Action
function BuffStateConfig.ClearClasses(action)
    action.buff_classes = {}
    Global.configStore:SaveConfig()
end

---@param action Action
---@return string description of the class filter, for the menu and /chelp
function BuffStateConfig.DescribeClasses(action)
    local classes = BuffStateConfig.GetClasses(action)
    if #classes < 1 then return "Any class" end

    -- listed in the order the class list is offered in rather than the order they were clicked
    local ordered = {}
    for _, shortName in ipairs(Classes.shortNames) do
        if BuffStateConfig.IsClassAllowed(action, shortName) then
            ordered[#ordered+1] = shortName
        end
    end
    return table.concat(ordered, " ")
end

---@diagnostic disable-next-line: duplicate-set-field
function BuffStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return BuffStateConfig
