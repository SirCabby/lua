local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local Pet = require("cabby.pet")

---How this character uses its pet in a fight: when to send it, and how it should be set up to
---fight while it is out there.
---
---There is no action list here, which is what makes this the shortest config of any state. A pet
---is not a rotation: what it does in a fight is decided by the pet, and everything this end has to
---say is said in one order (`/pet attack`) and four switches the client keeps for us. So the
---settings are a number and four dials, and the number is the only one that is about *this*
---fight.
---
---**The dials are three-way on purpose.** "Leave alone" is what a pet toggle is worth to a player
---who wants to keep flipping it by hand, and it is the default for all four: a script that arrives
---with opinions about taunt would be changing how somebody's pet has fought for years on the first
---frame after an update. On or off is a standing order, and it is enforced -- see the state for
---the courtesy paid to a toggle flipped by hand.
---
---**Taunt has a fourth position, because taunt is the one of the four whose right answer is not a
---setting.** Whether a pet should hold what it is on depends on whether anybody else is holding it,
---which changes between fights and inside them; a player who sets it by hand is setting it for the
---last pull. `Automatic` hands that dial to the state, which reads the group and answers it every
---pass -- see `states/petDpsState.lua`. It is offered only for the switches an automatic answer
---exists for (`autoSwitches` below), because a dial position that resolves to nothing is a dial
---position that lies.
---**The job is the one setting that changes what the pet is *for*.** Everything else here is about
---how it fights what the fight is on; `protect` says that a mob on us outranks that. It is a
---setting rather than a mode this state works out for itself because it is a trade nobody else can
---make: a pet peeling adds off its owner is a pet not adding damage to the mob the group is killing,
---and which of those a character wants depends on what it is -- a magician stood in the open wants
---the peel, a beastlord in melee next to a tank usually does not.
---@class PetDpsStateConfig : BaseConfig
local PetDpsStateConfig = {
    key = "PetDpsState",
    ---What the pet is for. Fighting is the job it ships with, and is what a pet has always done
    ---here; protecting is the same pet with one thing put above it.
    jobs = {
        Fight = { value = "fight", display = "Fight what we fight" },
        Protect = { value = "protect", display = "Protect me first" }
    },
    ---What a posture dial can be set to. `Leave` is not "off": it is this script having no opinion,
    ---which is a different thing from an opinion that the switch should be off. `Auto` is not
    ---"leave alone" either: it is an opinion that changes with the fight.
    postures = {
        Leave = { value = "leave", display = "Leave alone" },
        Auto = { value = "auto", display = "Automatic" },
        On = { value = "on", display = "On" },
        Off = { value = "off", display = "Off" }
    },
    ---The switches `Automatic` may be set on. The state is what actually answers them -- this is
    ---only the list of dials allowed to offer the position, kept here because the config is what
    ---has to refuse a stored value that means nothing.
    autoSwitches = {
        taunt = true
    },
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(PetDpsStateConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[PetDpsStateConfig.key]
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("PetDpsStateConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[PetDpsStateConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if configRoot.enabled == nil then
        configRoot.enabled = true
        taint = true
    end

    if configRoot.send_pct == nil then
        -- 100, unlike the nuke rotation's 95: a pet sent a moment late is a pet the tank has to
        -- pull the mob off anyway, and the classes that carry one expect it in from the start.
        -- The dial is here for the groups that would rather it waited
        configRoot.send_pct = 100
        taint = true
    end

    if configRoot.job == nil then
        -- what a pet has always done here, and what a config written before this setting existed
        -- was doing: a script that starts peeling adds off its owner on the first frame after an
        -- update is a script that changed the fight without being asked
        configRoot.job = PetDpsStateConfig.jobs.Fight.value
        taint = true
    end

    if configRoot.postures == nil then
        configRoot.postures = {}
        taint = true
    end

    for _, name in ipairs(Pet.toggleOrder) do
        if configRoot.postures[name] == nil then
            configRoot.postures[name] = PetDpsStateConfig.postures.Leave.value
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function PetDpsStateConfig.Init()
    if not PetDpsStateConfig._.isInit then
        local ftkey = Global.tracing.open("PetDpsStateConfig Setup")

        initAndValidate()

        PetDpsStateConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---@return boolean isEnabled
function PetDpsStateConfig.IsEnabled()
    return getConfigSection().enabled
end

---@param enable boolean
function PetDpsStateConfig.SetEnabled(enable)
    getConfigSection().enabled = enable == true
    Global.configStore:SaveConfig()
    print("PetDpsState is Enabled: [" .. tostring(enable) .. "]")
end

---Don't send the pet in until what we are fighting is at or below this health. 100 sends it the
---moment there is a fight, which is what a pet class usually wants; anything lower is aggro
---management -- a moment for the tank to get a hold of the mob before a pet starts hitting it.
---@return number pct
function PetDpsStateConfig.GetSendPct()
    return getConfigSection().send_pct
end

---@param pct number
function PetDpsStateConfig.SetSendPct(pct)
    getConfigSection().send_pct = math.max(math.min(math.floor(pct), 100), 1)
    Global.configStore:SaveConfig()
end

---What the pet is for: fighting what we are fighting, or taking off us whatever is on us first.
---@return string job one of PetDpsStateConfig.jobs values
function PetDpsStateConfig.GetJob()
    local value = getConfigSection().job
    for _, known in pairs(PetDpsStateConfig.jobs) do
        if known.value == value then return value end
    end
    return PetDpsStateConfig.jobs.Fight.value
end

---@param job string one of PetDpsStateConfig.jobs values
function PetDpsStateConfig.SetJob(job)
    getConfigSection().job = job
    Global.configStore:SaveConfig()
    print("PetDpsState job: [" .. PetDpsStateConfig.GetJobDisplay(job) .. "]")
end

---@param job string
---@return string display
function PetDpsStateConfig.GetJobDisplay(job)
    for _, known in pairs(PetDpsStateConfig.jobs) do
        if known.value == job then return known.display end
    end
    return PetDpsStateConfig.jobs.Fight.display
end

---@return boolean isProtecting whether the pet is allowed to leave the fight to defend its owner
function PetDpsStateConfig.IsProtecting()
    return PetDpsStateConfig.GetJob() == PetDpsStateConfig.jobs.Protect.value
end

---@param name string one of `Pet.toggles`
---@return boolean supportsAuto whether this switch has an automatic answer to offer
function PetDpsStateConfig.SupportsAuto(name)
    return PetDpsStateConfig.autoSwitches[name] == true
end

---Where one of the pet's four switches should stand.
---@param name string one of `Pet.toggles`
---@return string posture one of PetDpsStateConfig.postures values
function PetDpsStateConfig.GetPosture(name)
    local value = getConfigSection().postures[name]

    -- `auto` on a switch nothing answers automatically is read as no opinion rather than acted on:
    -- a hand-edited config, or a switch that had an automatic answer in some later version, must
    -- not resolve to this state flipping something for a reason it cannot name
    if value == PetDpsStateConfig.postures.Auto.value and not PetDpsStateConfig.SupportsAuto(name) then
        return PetDpsStateConfig.postures.Leave.value
    end

    for _, known in pairs(PetDpsStateConfig.postures) do
        if known.value == value then return value end
    end
    return PetDpsStateConfig.postures.Leave.value
end

---@param name string one of `Pet.toggles`
---@param posture string one of PetDpsStateConfig.postures values
function PetDpsStateConfig.SetPosture(name, posture)
    getConfigSection().postures[name] = posture
    Global.configStore:SaveConfig()

    local toggle = Pet.toggles[name]
    print("PetDpsState " .. (toggle ~= nil and toggle.display:lower() or name) ..
        ": [" .. tostring(PetDpsStateConfig.GetPostureDisplay(posture)) .. "]")
end

---@param posture string
---@return string display
function PetDpsStateConfig.GetPostureDisplay(posture)
    for _, known in pairs(PetDpsStateConfig.postures) do
        if known.value == posture then return known.display end
    end
    return PetDpsStateConfig.postures.Leave.display
end

---@return boolean isManaging whether any of the four switches has been given an opinion
function PetDpsStateConfig.HasPostures()
    for _, name in ipairs(Pet.toggleOrder) do
        if PetDpsStateConfig.GetPosture(name) ~= PetDpsStateConfig.postures.Leave.value then
            return true
        end
    end
    return false
end

---@diagnostic disable-next-line: duplicate-set-field
function PetDpsStateConfig.Print()
    TableUtils.Print(getConfigSection())
end

return PetDpsStateConfig
