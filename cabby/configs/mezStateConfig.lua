local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ActionType = require("cabby.actions.actionType")

---What this character locks the fight down with.
---
---One ordered list, like every other action list in cabby -- but unlike the others, **what a slot
---is for is not configured at all**. A slot holding a spell that mesmerizes is a mez, one that
---stuns is a stun, and anything else in the list is a softener: the debuff cast at a mob so that
---the mez after it lands. All three are read off the spell's own effects (`Spells.Mesmerizes`,
---`Spells.Stuns`), because the alternative is a dropdown that lets somebody file a tash as a mez
---and then wonder why the adds are loose.
---
---The numbers around the list are the restraints, and each one is a way mezzing makes a fight
---worse rather than better:
---
---- **`stop_pct`** -- a mob this close to dead is not worth locking. It also is not worth the
---  *risk*: a mez that lands on something the group is three seconds from killing takes it out of
---  reach of the damage already in the air.
---- **`mana_floor`** -- the same floor the rotation keeps, and for the same reason. An enchanter
---  out of mana is a group with no crowd control at all in ten seconds' time.
---- **`ae_min`** -- how many loose mobs make an AE worth its aggro. One is never worth it: an AE
---  mez wakes what it does not land on, and a single-target mez was going to cover one mob anyway.
---
---A slot carries at most two dials of its own, and only where they mean anything -- a mez has
---nothing to say about either.
---@class MezStateConfig : BaseConfig
local MezStateConfig = {
    key = "MezState",
    ---When a softener (a tash, a resist debuff, a cripple) is worth a cast of its own.
    ---
    ---This is the setting that carries "sometimes we have to tash it first". *Once it resists* is
    ---the default because it is the honest one: most mobs take a mez without help, and a group
    ---that tashes everything first has spent a gem timer and three seconds per add finding that
    ---out. *Always* is for the zone where they all resist, and is a real answer rather than a
    ---worse one -- it is just not the one to ship.
    softenWhen = {
        Resisted = { value = "resisted", display = "Once it resists a mez" },
        Always = { value = "always", display = "Before every mez" }
    },
    ---What a stun slot is *for*, which the spell cannot say -- a stun is a stun whether it is
    ---being used to buy a cast or to hold a caster down.
    stunWhen = {
        OnMe = { value = "onme", display = "When it turns on me" },
        Casting = { value = "casting", display = "When it is casting" },
        Either = { value = "either", display = "Either" }
    },
    _ = {
        isInit = false
    }
}

---How long a mez has to have left before it is worth refreshing, over and above the time the cast
---itself takes. Under this, the mob is treated as loose.
---
---Not a give-up timer and not a guess: a mez that has four seconds left and takes three to cast is
---a mez that must be started *now* or it wears off mid-cast, which is the mob loose on a caster who
---is stood still and unable to do anything about it. So the answer is always `cast time + this`,
---and this is the margin for the server's round trip and for the pass we did not get.
local defaultRefreshLeadMs = 3000

---@param str string
local function DebugLog(str)
    Debug.Log(MezStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[MezStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("MezStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[MezStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.mana_floor == nil then
        -- lower than the rotation's floor on purpose: the last of the mana is better spent
        -- holding an add still than on one more nuke
        configRoot.mana_floor = 5
        taint = true
    end

    if configRoot.stop_pct == nil then
        -- 80 is where every mez macro has landed. A mob under it has taken real damage from
        -- somebody, which means it is either being killed or about to be, and a mez that lands on
        -- it takes it away from the damage already in the air
        configRoot.stop_pct = 80
        taint = true
    end

    if configRoot.ae_min == nil then
        configRoot.ae_min = 3
        taint = true
    end

    if configRoot.ae_confirmed == nil then
        configRoot.ae_confirmed = true
        taint = true
    end

    if configRoot.refresh_lead_ms == nil then
        configRoot.refresh_lead_ms = defaultRefreshLeadMs
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

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function MezStateConfig.Init()
    if not MezStateConfig._.isInit then
        local ftkey = Global.tracing.open("MezStateConfig Setup")

        initAndValidate()

        MezStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function MezStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function MezStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("MezState is Enabled: [" .. tostring(enable) .. "]")
end

---@return number pct mana to keep back
function MezStateConfig.GetManaFloor()
    return getConfigSection().mana_floor
end

---@param pct number
function MezStateConfig.SetManaFloor(pct)
    getConfigSection().mana_floor = math.max(math.min(math.floor(pct), 100), 0)
    Global.configStore:SaveConfig()
end

---@return number pct a mob at or below this health is left alone
function MezStateConfig.GetStopPct()
    return getConfigSection().stop_pct
end

---@param pct number
function MezStateConfig.SetStopPct(pct)
    getConfigSection().stop_pct = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---@return number count how many loose mobs an AE mez wants before it is worth casting
function MezStateConfig.GetAeMin()
    return getConfigSection().ae_min
end

---@param count number
function MezStateConfig.SetAeMin(count)
    getConfigSection().ae_min = math.max(math.min(math.floor(count), 20), 2)
    Global.configStore:SaveConfig()
end

---Whether an AE mez may only be centred where every mob it would catch is one the client has been
---*told* about, rather than one the roster's own sweep found.
---
---On by default, and it is the setting that stands in for the "AE mez safety check" every other
---script grew: the sweep can see a mob in combat stance without being able to say it is in combat
---with *us*, and an AE aimed into a group of those is how a camp pulls the room. Off is for a
---character that would rather blanket the area and deal with what wakes up.
---@return boolean confirmedOnly
function MezStateConfig.GetAeConfirmedOnly()
    return getConfigSection().ae_confirmed == true
end

---@param confirmedOnly boolean
function MezStateConfig.SetAeConfirmedOnly(confirmedOnly)
    getConfigSection().ae_confirmed = confirmedOnly == true
    Global.configStore:SaveConfig()
end

---How much of a mez has to be left, on top of the time the cast takes, before it counts as still
---holding. Under it, the mob is loose and is re-mezzed.
---@return number ms
function MezStateConfig.GetRefreshLeadMs()
    return tonumber(getConfigSection().refresh_lead_ms) or defaultRefreshLeadMs
end

---@param ms number
function MezStateConfig.SetRefreshLeadMs(ms)
    getConfigSection().refresh_lead_ms = math.max(math.min(math.floor(ms), 30000), 500)
    Global.configStore:SaveConfig()
end

---@return table actions the control list, in the order it is tried
function MezStateConfig.GetActions()
    return getConfigSection().actions
end

---@return table actionLists in the shape the shared action command and the menu both read
function MezStateConfig.GetActionLists()
    return { { label = "Crowd Control", actions = MezStateConfig.GetActions() } }
end

---------------- Control slot fields --------------------

---Written straight to the live slot rather than staged behind a Save, like the heal list's
---threshold and the rotation's scope: when a softener is worth casting is a dial you reach for
---when the zone turns out to resist, not part of describing which spell it is.

---When a softener slot is worth a cast. Means nothing to a mez or a stun slot.
---@param action Action
---@return string when one of MezStateConfig.softenWhen values
function MezStateConfig.GetSoftenWhen(action)
    local when = action.mez_soften_when
    for _, known in pairs(MezStateConfig.softenWhen) do
        if known.value == when then return when end
    end
    return MezStateConfig.softenWhen.Resisted.value
end

---@param action Action
---@param when string
function MezStateConfig.SetSoftenWhen(action, when)
    action.mez_soften_when = when
    Global.configStore:SaveConfig()
end

---@param when string
---@return string display
function MezStateConfig.GetSoftenWhenDisplay(when)
    for _, known in pairs(MezStateConfig.softenWhen) do
        if known.value == when then return known.display end
    end
    return MezStateConfig.softenWhen.Resisted.display
end

---What a stun slot is for. Means nothing to a mez or a softener slot.
---@param action Action
---@return string when one of MezStateConfig.stunWhen values
function MezStateConfig.GetStunWhen(action)
    local when = action.mez_stun_when
    for _, known in pairs(MezStateConfig.stunWhen) do
        if known.value == when then return when end
    end
    return MezStateConfig.stunWhen.OnMe.value
end

---@param action Action
---@param when string
function MezStateConfig.SetStunWhen(action, when)
    action.mez_stun_when = when
    Global.configStore:SaveConfig()
end

---@param when string
---@return string display
function MezStateConfig.GetStunWhenDisplay(when)
    for _, known in pairs(MezStateConfig.stunWhen) do
        if known.value == when then return known.display end
    end
    return MezStateConfig.stunWhen.OnMe.display
end

---@diagnostic disable-next-line: duplicate-set-field
function MezStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return MezStateConfig
