---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local CastSubject = require("utils.Casting.CastSubject")
local Debug = require("utils.Debug.Debug")
local Timer = require("utils.Time.Timer")

local ActionType = require("cabby.actions.actionType")

---A spell, an item click or an AA, as something a configured action slot can hold.
---
---One module for all three because the difference between them already lives in `CastSubject`
---(which TLO says it is ready, which command fires it, whether it has to be memorized first).
---What is left over is the same for each: is it worth firing right now, and how a caller asks
---for it — which is not by casting it, but by handing a request to the casting service and
---getting on with the frame.
---
---`DoAction` therefore returns immediately, having *asked*. The action's own 500 ms cooldown and
---the "not while anything else is casting" check in `IsReady` are what stop a rotation from
---asking again on the very next frame while the first cast is still standing the character up.
---@class CastAction : ActionType
local CastAction = {}
CastAction.__index = CastAction

setmetatable(CastAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---How long after asking for a cast this action stays quiet, whether or not the request was
---taken. Matches the melee actions' own cooldown.
local requestCooldownMs = 500

local actionTypesByKind = {
    [CastSubject.kinds.spell] = ActionType.Spell,
    [CastSubject.kinds.item] = ActionType.Item,
    [CastSubject.kinds.alt] = ActionType.AA
}

---@param str string
local function DebugLog(str)
    Debug.Log("CastAction", str)
end

---@param kind string one of CastSubject.kinds
---@param name string
---@return CastAction
function CastAction.new(kind, name)
    local self = setmetatable({}, CastAction)

---@diagnostic disable-next-line: inject-field
    self._ = {
        name = name,
        kind = kind,
        subject = CastSubject.new(kind, name),
        timer = Timer.new(requestCooldownMs)
    }

    return self
end

---@param name string spell name, as it appears in the spellbook
---@return CastAction
function CastAction.Spell(name)
    return CastAction.new(CastSubject.kinds.spell, name)
end

---@param name string item name, not the name of the spell on it
---@return CastAction
function CastAction.Item(name)
    return CastAction.new(CastSubject.kinds.item, name)
end

---@param name string alternate advancement ability name
---@return CastAction
function CastAction.AA(name)
    return CastAction.new(CastSubject.kinds.alt, name)
end

---@return string name
function CastAction:Name()
    return self._.name
end

---@return string actionType one of ActionType's values
function CastAction:ActionType()
    return actionTypesByKind[self._.kind]
end

---@return boolean hasAction whether this character has it at all
function CastAction:HasAction()
    return self._.subject:IsAvailable()
end

---Casts cost mana, not endurance, so this is always zero.
---
---The endurance threshold the action editor offers is built on this, and offering a mana
---threshold in its place would be offering a setting nothing reads: `end_threshold` is stored
---and never enforced anywhere. Mana is checked where it matters instead — in `IsReady` below,
---and again by the cast itself.
---@return number
function CastAction:EndCost()
    return 0
end

---@return number manaCost 0 for items and AAs
function CastAction:ManaCost()
    return self._.subject:ManaCost()
end

---@return boolean isMemorized always true for items and AAs, which need no gem
function CastAction:IsMemorized()
    return self._.subject:IsMemorized()
end

---@return CastSubject subject
function CastAction:Subject()
    return self._.subject
end

---Is this worth asking for right now?
---
---Deliberately stricter than the cast's own checks. Everything here is a reason the cast would
---be refused a moment later, and a rotation walks its whole list every frame — so the cheap
---answer is "not now" rather than a request that raises the priority floor, starves the states
---below it, and then fails.
---
---A spell that is not memorized is *not* one of those reasons. It is a memorize away, and the
---casting service does that itself -- into an empty gem where there is one, so the usual case
---costs nothing but the seconds it takes. A slot configured with a spell that happens not to be
---on the bar is a slot the user meant, and idling it instead was a silent puzzle: correctly
---configured, marked ready by the page, and never firing.
---
---What it does cost is those seconds, spent standing still with this state's priority floor up.
---That is the trade, and it is the right way round: everything stronger than the rotation --
---heals, mez, orders -- preempts it anyway, and the memorize happens once per spell rather than
---once per cast.
---@param request? table who this would be for. `targetId` matters: a heal is chosen for a group
---member who is not targeted yet, so range and line of sight have to be judged against *them*
---rather than against whatever the character happens to be looking at.
---@return boolean isReady
function CastAction:IsReady(request)
    local subject = self._.subject
    local targetId = (request or {}).targetId

    if not self._.timer:timer_expired() then return false end

    -- One cast at a time. A cast in flight normally means "not now" -- asking would be refused,
    -- or would preempt our own cast -- but a caller that outranks whoever is casting is exactly
    -- who *should* take it over, and telling them they have nothing to do would put the priority
    -- chain's whole point out of reach: a heal could never interrupt a nuke.
    if Casting.IsActive() and not Casting.CanPreempt((request or {}).priority) then return false end

    if not subject:IsAvailable() then return false end

    -- Feared, a spell has nowhere to go: the character is running where the server points them
    -- and the cast bar cannot survive it. The cast itself refuses this too -- that is where the
    -- fact lives, and a fear that lands mid-preparation has to be caught there -- but saying it
    -- here as well is what keeps a rotation from asking every frame through the whole fear and
    -- raising its priority floor over a cast that ends the moment it is looked at. Items and AAs
    -- are not gated, exactly as they are not for a silence.
    if subject:IsSpell() and mq.TLO.Me.Feared() ~= nil then return false end

    -- the gem timer, asked only of a spell that has a gem. `IsReady` reads false for an
    -- unmemorized spell as well, and reading that as "not now" is what would put a slot holding
    -- one back where it started -- never ready, so never memorized, so never ready
    if subject:IsMemorized() and not subject:IsReady() then return false end

    local manaCost = subject:ManaCost()
    if manaCost > 0 and (tonumber(mq.TLO.Me.CurrentMana()) or 0) < manaCost then return false end

    if subject:NeedsTarget() then
        -- whoever this is for: the spawn the caller named, or what is targeted now
        local spawn = mq.TLO.Target
        if targetId ~= nil then
            spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        end

        local spawnId = tonumber(spawn.ID())
        if spawnId == nil or spawnId < 1 then return false end

        local range = subject:Range()
        local distance = tonumber(spawn.Distance())
        if range > 0 and distance ~= nil and distance > range then return false end

        if spawn.LineOfSight() == false then return false end
    end

    return true
end

---Ask the casting service for this cast. Returns as soon as it has asked -- the cast itself
---takes seconds, and the caller has a frame to finish.
---@param request? table owner, priority and targetId of whoever is asking. A caller that leaves
---the priority out cannot preempt anything and will be refused if something else is casting.
function CastAction:DoAction(request)
    request = request or {}
    self._.timer:reset()

    local id, refused = Casting.Cast(self._.subject, {
        owner = request.owner,
        priority = request.priority,
        targetId = request.targetId
    })

    if id == nil then
        DebugLog("Cast of [" .. self._.name .. "] was refused: " .. tostring(refused))
    end
end

return CastAction
