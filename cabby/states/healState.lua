---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Curing = require("cabby.curing")
local HealStateConfig = require("cabby.configs.healStateConfig")
local HealStateMenu = require("cabby.ui.states.healStateMenu")
local Menu = require("cabby.ui.menu")
local Roles = require("cabby.roles")
local SlashCmd = require("cabby.commands.slashcmd")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How often the group's health is read. Every frame would be affordable, but nothing here
---changes meaningfully inside a tenth of a second and a healer that is starving the states below
---it should be cheap while it watches.
local scanIntervalMs = 100

---After a heal lands, the client can take a moment to report the new health. Without this the
---next pulse sees the old number and casts the same heal again. Someone in real trouble is
---exempt -- chain healing a tank at 20% is the point of a healer.
local healSettleMs = 1000

---How far above the threshold that triggered a heal the target has to climb before the heal is
---no longer worth finishing. Some margin, because a heal landing from elsewhere at exactly the
---trigger point should not make us throw ours away.
local abortMarginPct = 10

---How long an ordered heal waits for its turn before it is forgotten. An order is about right
---now; one that could not be acted on for ten seconds is stale, and acting on it late is worse
---than not acting on it.
local orderTimeoutMs = 10000

---How long a target is left alone after a heal on them did not land.
---
---A refusal costs nothing to make, which is exactly the problem: without this, a target the
---client will not take a heal on is asked again on the very next pass, and every pass after that,
---at whatever rate the loop runs. What that looks like from the outside is a cast and a
---cancellation per frame and nothing ever leaving the ground.
---
---Deliberately *not* waived for someone below the emergency mark, which is the one thing that
---separates it from the settle window above: chain healing a tank at 20% is the point of a healer,
---but a cast that would not go out is not a heal that needs repeating faster. It is a debounce
---rather than a give-up -- the target is reconsidered the moment it runs out.
local retryAfterFailureMs = 3000

---Where a slot's heal can be aimed, read off the spell rather than configured -- the same model
---the buff state uses, and for the same reason: what a spell can land on is what it is, and
---asking the user to say so is one more thing to get wrong.
local aims = {
    self = "self",     -- only ever lands on the caster
    pet = "pet",       -- only ever lands on this character's pet
    group = "group",   -- one cast covers the whole group and needs no target
    single = "single"  -- one person at a time
}

local petTargetTypes = { ["pet"] = true, ["pet2"] = true }

---Keeping a group alive.
---
---One ordered list of heal slots decides everything (see `HealStateConfig`): who a slot is for,
---and how hurt they have to be for it to be the right one. This state's job is the choosing --
---who is worst off, which slot fits them, and whether the heal already in the air is still the
---right heal -- because the casting service does the casting and the priority chain does the
---holding-everything-else-back.
---
---What a slot can be aimed at is not part of that configuration: the group heal, the self heal
---and the pet heal are read off the spell (`aims` below), which is what lets one list serve a
---cleric keeping six people up and a magician keeping one pet up.
---
---**Curing rides here too**, and it is the one job in this state that is not chosen from the
---slot list. A cure is not configured at all: somebody says what is on them, and the best cure of
---that kind this character owns answers it -- which is the only shape that works, since the person
---afflicted is the only one who can see it and has no idea what anybody hearing them can cast.
---`cabby.curing` owns that whole conversation (the reading, the asking, the queue); this state is
---the hands, because casting a cure is choosing not to cast a heal and that choice belongs where
---the healing is arbitrated. Where it sits in the pass is the whole of the arbitration: after
---anybody in real trouble and before everything else -- see `Go`.
---
---What it deliberately leaves out: heal-over-time management, rezzes, and any awareness of what
---other healers in the group are doing. Those need a band of their own, a debuff model, or the
---group coordination that does not exist yet.
---@class HealState : BaseState
local HealState = {
    key = "HealState",
    eventIds = {
        -- `healnow` rather than `heal`: a registered phrase also matches every longer line that
        -- starts with it, so a plain `heal` would fire on `healme`, `healing off` and the rest of
        -- the switches below, complaining about spawn ids nobody typed
        heal = "healnow",
        healMe = "healme",
        healing = "healing",
        healGroup = "healgroup",
        healPets = "healpets",
        healAction = "healaction",
        curing = "curing"
    },
    _ = {
        isInit = false,
        candidates = {},
        lastScanMs = 0,
        castId = nil,
        healTarget = nil,   -- { id, name, pct } as it was when the heal started
        healSlot = nil,     -- the configured slot chosen for it
        healThreshold = nil,
        -- the CureRequest the cast in flight is answering, nil while it is an ordinary heal. The
        -- one thing that says which of the two jobs this state is in the middle of
        cureRequest = nil,
        lastCureResult = nil,
        order = nil,        -- { id, name, expiresMs } from a `heal <id>` or `healme`
        settleUntil = {},   -- { [spawn id] = time we may consider healing them again }
        -- { [spawn id] = when a heal that did not land is worth trying on them again }. Kept apart
        -- from settleUntil because the two are waived under different conditions: see isHeldOff
        tryAgainAt = {},
        calledOff = false,
        lastResult = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(HealState.key, str)
end

---------------- Who needs healing --------------------

---@class HealCandidate
---@field id number
---@field name string
---@field pct number current health, as a percentage
---@field isSelf boolean
---@field isTank boolean the group's main tank, by the role assigned in the group window
---@field isPet boolean

---@param candidates table
---@param id number|nil
---@param name string|nil
---@param pct number|nil
---@param flags table
local function addCandidate(candidates, id, name, pct, flags)
    id = tonumber(id)
    pct = tonumber(pct)
    if id == nil or id < 1 or pct == nil then return end

    -- Nobody at nothing is healable, and `Dead()` is not enough to catch them: a player on the way
    -- to a corpse reads as a live spawn at zero or *below* zero health for as long as the server
    -- takes to make the corpse. Sorted worst-first, one of those outranks every real target in the
    -- group -- so it is not merely a wasted cast, it is the only cast this state will consider.
    if pct <= 0 then return end

    candidates[#candidates+1] = {
        id = id,
        name = name or tostring(id),
        pct = pct,
        isSelf = flags.isSelf == true,
        isTank = flags.isTank == true,
        isPet = flags.isPet == true
    }
end

---Everyone worth watching, and how they are doing.
---
---Group members who are out of the zone or offline are skipped rather than counted as healthy:
---they have no spawn to heal, and treating a missing member as a full one would be a quiet way
---to get the count for a group heal wrong.
---@return table candidates
local function scanCandidates()
    local candidates = {}

    -- Through Roles rather than off `Group.Member[#].MainTank`, so that "the tank" is one answer
    -- for the whole script -- and so it is answered for *this* character too. A paladin holding
    -- the role is who a tank-scoped slot is for, and reading the flag per group member could never
    -- say so, since we are not one of our own group members.
    local mainTank = Roles.GetMainTank()

    addCandidate(candidates, mq.TLO.Me.ID(), mq.TLO.Me.CleanName(), mq.TLO.Me.PctHPs(),
        { isSelf = true, isTank = Roles.IsMainTank() })

    if HealStateConfig.GetHealGroup() then
        for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
            local member = mq.TLO.Group.Member(index)
            if not member.OtherZone() and not member.Offline() then
                local spawn = member.Spawn
                if not spawn.Dead() then
                    addCandidate(candidates, spawn.ID(), spawn.CleanName(), Status.HealthPct(spawn),
                        { isTank = Roles.Matches(mainTank, spawn.ID(), spawn.CleanName()) })
                end
            end
        end
    end

    if HealStateConfig.GetHealPets() then
        local pet = mq.TLO.Me.Pet
        if pet.ID() ~= nil and not pet.Dead() then
            addCandidate(candidates, pet.ID(), pet.CleanName(), Status.HealthPct(pet), { isPet = true })
        end
    end

    -- worst off first: the order every decision below is made in
    table.sort(candidates, function(a, b) return a.pct < b.pct end)
    return candidates
end

---@return table candidates cached between scans
local function getCandidates()
    local now = Time.current_time()
    if now - HealState._.lastScanMs >= scanIntervalMs then
        HealState._.lastScanMs = now
        HealState._.candidates = scanCandidates()
    end
    return HealState._.candidates
end

---@param id number
---@return table? candidate
local function findCandidate(id)
    for _, candidate in ipairs(getCandidates()) do
        if candidate.id == id then return candidate end
    end
    return nil
end

---@param pct number
---@return number count how many of the people we watch are at or below this health
local function countAtOrBelow(pct)
    local count = 0
    for _, candidate in ipairs(getCandidates()) do
        if candidate.pct <= pct then count = count + 1 end
    end
    return count
end

---------------- Choosing a heal --------------------

---What a heal can land on, read off the spell.
---
---A pet heal is the reason this is not simply "does it need a target": EQ aims one at the pet
---with nothing targeted, exactly as it aims a group heal at the group, so the two are
---indistinguishable by `NeedsTarget` alone -- and a pet class's only heal would have been chosen
---for the group and cast because three people were scuffed.
---@param subject CastSubject
---@return string aim one of `aims`
local function aimOf(subject)
    local targetType = subject:TargetType()
    if petTargetTypes[targetType] then return aims.pet end
    if targetType == "self" then return aims.self end
    -- everything else that aims itself covers the group: Group v1/v2, and the point-blank and
    -- targeted AE heals that land on whoever is standing with us
    if not subject:NeedsTarget() then return aims.group end
    return aims.single
end

---@param action ActionType|nil
---@return string? aim nil for an action this state cannot heal with at all
local function aimOfAction(action)
    -- casts only: this state polls the cast it started, which a skill or a discipline has no
    -- equivalent of. Only casts are offered on the page; this is for a config edited by hand.
    if action == nil or action.Subject == nil then return nil end
    return aimOf(action:Subject())
end

---Is this slot meant for this person?
---
---Where the heal can be aimed comes first and scope cannot argue with it: a pet heal is for the
---pet whatever the slot says, and a self heal is for us. Scope narrows what is left over, which
---is the heals that could go to more than one person.
---@param slot Action
---@param aim string one of `aims`
---@param candidate HealCandidate
---@return boolean applies
local function appliesTo(slot, aim, candidate)
    if aim == aims.self then return candidate.isSelf end
    if aim == aims.pet then return candidate.isPet end

    local scope = HealStateConfig.GetScope(slot)
    if scope == HealStateConfig.scopes.Self.value then return candidate.isSelf end
    if scope == HealStateConfig.scopes.Pet.value then return candidate.isPet end
    if scope == HealStateConfig.scopes.Tank.value then return candidate.isTank end
    -- a pet is not one of the others: "anyone else" is the rest of the group, and a pet has a
    -- scope of its own to be picked out with
    if scope == HealStateConfig.scopes.Others.value then
        return not candidate.isSelf and not candidate.isPet
    end
    return true
end

---@param candidate HealCandidate
---@return boolean isSettling true while we are waiting for a heal we already cast to show up
local function isSettling(candidate)
    if candidate.pct <= HealStateConfig.GetEmergencyPct() then return false end
    local until_ = HealState._.settleUntil[candidate.id]
    return until_ ~= nil and Time.current_time() < until_
end

---@param candidate HealCandidate
---@return boolean isHeldOff true while a heal that would not go out is being left alone
local function isHeldOff(candidate)
    local at = HealState._.tryAgainAt[candidate.id]
    return at ~= nil and Time.current_time() < at
end

---Would this pass pick this person, if it were picking?
---
---The question `reasonToAbandon` has to ask before it throws a heal away for somebody. Cancelling
---a heal in the air is only ever right when there is a better one to cast instead, and "somebody
---is worse off" is not the same claim: they may be settling, they may be held off after a refusal,
---or no configured slot may be scoped to them at all. Abandoning for someone this state has
---already decided not to heal ends the cast and then re-picks the same target on the next pass,
---which is a cast and a cancellation per frame for as long as they stay in that condition -- and
---below the emergency mark is exactly where people *stay*, because that is where a rez leaves
---them.
---
---Readiness is deliberately left out. A gem still recovering is a reason to wait a moment, not a
---reason to keep casting the wrong heal at the wrong person, and asking about it here would mean
---a real emergency could not preempt anything in the second after a cast.
---@param candidate HealCandidate
---@return boolean wouldChoose
local function wouldChoose(candidate)
    if isHeldOff(candidate) or isSettling(candidate) then return false end

    for _, slot in ipairs(HealStateConfig.GetActions()) do
        if candidate.pct <= HealStateConfig.GetThreshold(slot) then
            local aim = aimOfAction(Action.GetActionType(slot))
            -- a group heal is chosen for the group, so it is not a reason to drop somebody's heal
            if aim ~= nil and aim ~= aims.group and appliesTo(slot, aim, candidate)
                and Action.IsEnabled(slot) and Action.GetLuaResult(slot) then
                return true
            end
        end
    end

    return false
end

---Drop the windows above once they have run out, so a long session does not collect an entry per
---person this character has ever tried to heal.
local function prune()
    local now = Time.current_time()
    for id, at in pairs(HealState._.settleUntil) do
        if now >= at then HealState._.settleUntil[id] = nil end
    end
    for id, at in pairs(HealState._.tryAgainAt) do
        if now >= at then HealState._.tryAgainAt[id] = nil end
    end
end

---@class HealPick
---@field action ActionType
---@field slot Action
---@field targetId number|nil what the cast should target; nil for a heal that aims itself
---@field forId number|nil who the heal is for, which a heal that aims itself still has; nil only
---for a group heal, which is for everybody
---@field name string what is being healed, for status output
---@field threshold number the health the slot was chosen for

---Who this state is when it asks the casting service for something. The band matters to
---`IsReady` as much as to the cast itself: a heal that outranks the rotation in flight has to be
---told it *can* take it over, or it stands down and nobody heals.
---@param targetId number|nil
---@return table request
function HealState.CastRequest(targetId)
    return {
        owner = HealState.key,
        priority = HealState.priority,
        targetId = targetId
    }
end

---@param slot Action
---@param request table
---@return ActionType? action the slot's action, when it is usable right now
local function readySlotAction(slot, request)
    if not Action.IsEnabled(slot) then return nil end

    local action = Action.GetActionType(slot)
    if action == nil then return nil end
    -- a heal slot has to be something castable: the state polls the cast it started, which a
    -- skill or a discipline has no equivalent of. Only casts are offered on the page; this is
    -- for a config that was edited by hand.
    if action.Subject == nil then return nil end
    if not action:IsReady(request) then return nil end
    if not Action.GetLuaResult(slot) then return nil end

    return action
end

---A heal that covers the whole group, when enough of it is hurt.
---
---Checked before individual heals, but only while nobody is in real trouble: three people at 60%
---is what a group heal is for, and one person at 15% is not, however many others are scuffed.
---@return HealPick? pick
local function chooseGroupHeal()
    for _, slot in ipairs(HealStateConfig.GetActions()) do
        local action = Action.GetActionType(slot)
        if aimOfAction(action) == aims.group then
            local threshold = HealStateConfig.GetThreshold(slot)
            if countAtOrBelow(threshold) >= HealStateConfig.GetGroupMin(slot) then
                if readySlotAction(slot, HealState.CastRequest()) ~= nil then
                    return {
                        action = action, slot = slot, targetId = nil, forId = nil,
                        name = "the group", threshold = threshold
                    }
                end
            end
        end
    end
    return nil
end

---The first slot that suits this person, in the order they are configured.
---@param candidate HealCandidate
---@param ignoreThreshold? boolean for an ordered heal, which is about doing as it is told
---@return HealPick? pick
local function chooseFor(candidate, ignoreThreshold)
    for _, slot in ipairs(HealStateConfig.GetActions()) do
        local threshold = HealStateConfig.GetThreshold(slot)
        local covers = ignoreThreshold or candidate.pct <= threshold

        -- the health first, and the action only for a slot that passes it: resolving one is a walk
        -- through the spellbook, and this runs per slot per person every pass
        if covers then
            local action = Action.GetActionType(slot)
            local aim = aimOfAction(action)

            -- a group heal is chosen for the group, never for one person
            if aim ~= nil and aim ~= aims.group and appliesTo(slot, aim, candidate) then
                -- a heal that aims itself is cast at nobody: EQ puts a self heal on us and a pet
                -- heal on our pet with nothing targeted, and targeting for one of those would drop
                -- whatever we were looking at to no purpose
                local targetId = aim == aims.single and candidate.id or nil

                if readySlotAction(slot, HealState.CastRequest(targetId)) ~= nil then
                    return {
                        action = action,
                        slot = slot,
                        targetId = targetId,
                        forId = candidate.id,
                        name = candidate.name,
                        -- what "they no longer need this" means for this heal. Normally the health
                        -- the slot was written for; for an order, the health they were at when it
                        -- was given, since the slot's threshold was not what chose it and would
                        -- call the heal off before it left the ground.
                        threshold = ignoreThreshold and math.max(threshold, candidate.pct) or threshold
                    }
                end
            end
        end
    end
    return nil
end

---What to heal, and with what, right now.
---@param candidates table this pass's reading of who needs what
---@return HealPick? pick
local function choosePick(candidates)
    if #candidates < 1 then return nil end

    -- An order outranks the state's own judgment, which is the point of being able to give one:
    -- the tank knows they are about to pull, and we do not.
    local order = HealState._.order
    if order ~= nil then
        if Time.current_time() > order.expiresMs then
            print("(healnow) Too late to heal " .. order.name .. "; dropping the request")
            HealState._.order = nil
        else
            local candidate = findCandidate(order.id)
            if candidate == nil then
                -- not someone we watch (out of the group, or out of the zone): heal them anyway
                -- if they are here, since we were asked to
                local spawn = mq.TLO.Spawn("id " .. tostring(order.id))
                if spawn.ID() ~= nil and not spawn.Dead() then
                    candidate = {
                        id = order.id,
                        name = spawn.CleanName() or order.name,
                        pct = Status.HealthPct(spawn) or 100,
                        isSelf = false, isTank = false, isPet = false
                    }
                end
            end

            if candidate ~= nil then
                if candidate.pct <= 0 then
                    -- the same reading `addCandidate` refuses: a spawn at nothing is on its way to
                    -- being a corpse whatever `Dead()` says, and an order is not a reason to spend
                    -- the group's healer casting at one
                    print("(healnow) " .. candidate.name .. " is past healing")
                    HealState._.order = nil
                elseif candidate.pct >= 100 then
                    print("(healnow) " .. candidate.name .. " is already at full health")
                    HealState._.order = nil
                else
                    -- thresholds are how this state decides *for itself* who needs healing. An
                    -- order has already decided that, so the slots are read only for which heal
                    -- suits them -- scope still applies, the health it was written for does not.
                    local pick = chooseFor(candidate, true)
                    if pick ~= nil then
                        HealState._.order = nil
                        return pick
                    end
                    -- nothing ready yet: keep the order until it times out
                end
            else
                print("(healnow) Nothing here with id " .. tostring(order.id))
                HealState._.order = nil
            end
        end
    end

    local worst = candidates[1]
    if worst.pct > HealStateConfig.GetEmergencyPct() then
        local groupPick = chooseGroupHeal()
        if groupPick ~= nil then return groupPick end
    end

    for _, candidate in ipairs(candidates) do
        if not isHeldOff(candidate) and not isSettling(candidate) then
            local pick = chooseFor(candidate)
            if pick ~= nil then return pick end
        end
    end

    return nil
end

---------------- Curing --------------------

---Why answering cure requests is not something this character should be doing right now, if it is
---not.
---
---Read from the world every pass rather than latched, like everything else here: a fight starting
---is what switches curing off for a character set to stay out of them, and it has to switch off on
---the pass the fight starts rather than the next time somebody asks.
---
---A reason rather than a boolean because **this is the gate that looks like a broken healer**. The
---shipped default is out of combat only, and a DoT worth curing almost always lands *in* a fight --
---so the ordinary first experience of curing is a cleric that hears every request, queues every
---one, and casts nothing, saying nothing about why. `/cheal` and the state's own status line both
---quote this now.
---@return string|nil reason nil when cures are being answered
local function reasonNotCuring()
    if not HealStateConfig.IsCuring() then return "switched off on the Heal State page" end
    if Combat.IsEngaged() and not HealStateConfig.GetCureInCombat() then
        return "in a fight, and this is set to cure out of combat only"
    end
    return nil
end

---@return boolean isCuring
local function isCuring()
    return reasonNotCuring() == nil
end

---Is somebody in real trouble that this state would actually heal?
---
---The guard that curing is held to, and it deliberately asks the second half of that question as
---well. "Somebody is below the emergency mark" on its own is not a reason to leave an affliction
---alone: they may be settling, held off after a refusal, or scoped to no configured slot at all --
---and below the emergency mark is exactly where people *stay*, because that is where a rez leaves
---them. Curing would then be blocked forever by somebody nothing was ever going to be cast at.
---@param candidates table this pass's reading of who needs what, worst off first
---@return boolean isPending
local function emergencyPending(candidates)
    local emergency = HealStateConfig.GetEmergencyPct()

    for _, candidate in ipairs(candidates) do
        -- sorted worst-first, so the first one above the mark ends the walk
        if candidate.pct > emergency then return false end
        if wouldChoose(candidate) then return true end
    end

    return false
end

---@class CurePick
---@field request CureRequest
---@field targetId number|nil what the cast should target; nil for a cure that aims itself
---@field name string who is being cured, for status output

---The first queued cure this character can actually cast right now.
---
---The whole queue is walked rather than only its head, which is where this differs from how the
---buff state answers its requests. A cure is aimed at a person: the one at the front may be out of
---range or behind a wall while the one behind them is standing right here, and holding everybody
---up for a name that cannot be reached would be a healer doing nothing while somebody it *can*
---reach asks again every twenty seconds. Order is still the rule -- it is the first that can be
---cast, not the best -- so a reachable queue is answered oldest first.
---@return CurePick? pick
local function chooseCure()
    if not isCuring() then return nil end

    for _, request in ipairs(Curing.GetRequests()) do
        if Curing.IsActionable(request) then
            -- a cure that aims itself is cast at nobody: EQ puts a group cure on the group and a
            -- self cure on us with nothing targeted, and targeting for one of those would drop
            -- whatever we were looking at to no purpose
            local targetId = request.needsTarget and request.id or nil
            if request.action:IsReady(HealState.CastRequest(targetId)) then
                return { request = request, targetId = targetId, name = request.name }
            end
        end
    end

    return nil
end

---Start the cure this pass decided on.
---@param pick CurePick
---@return boolean isBusy
local function startCure(pick)
    local request = pick.request
    local castId, refused = Casting.Cast(request.action:Subject(), HealState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Cure of [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Curing " .. request.typeKey .. " on [" .. pick.name .. "] with [" ..
        request.action:Name() .. "]")
    HealState._.castId = castId
    -- the one field that says which of this state's two jobs the cast in flight belongs to
    HealState._.cureRequest = request
    return true
end

---Is the cure in the air still worth finishing?
---@param candidates table
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandonCure(candidates)
    local request = HealState._.cureRequest
    if request == nil then return nil end

    if not isCuring() then return "curing is off now" end

    if not request.isSelf then
        local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
        if spawn.ID() == nil then return "they are gone" end
        if spawn.Dead() then return "they died" end
    end

    -- the guard again, now that the cast is committed: somebody who has dropped into real trouble
    -- since it started is worth throwing a cure away for, exactly as they are worth throwing away
    -- a heal aimed at the wrong person
    if emergencyPending(candidates) then return "somebody needs healing" end

    return nil
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordCureFinished(status, outcome, reason)
    local request = HealState._.cureRequest or {}
    local spell = request.action ~= nil and request.action:Name() or "a cure"

    if status == Casting.status.succeeded then
        HealState._.lastCureResult = spell .. " on " .. tostring(request.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        -- **the request stays queued.** A cure strips a fixed number of counters and an affliction
        -- can carry more than one cast's worth, so a cure that went off is not a job that is done
        -- -- what finishes it is the counters actually being gone, which `cabby.curing` reads back
        -- off them once the client has caught up. Nothing here writes down that we cured somebody,
        -- because the world says it better.
        Curing.NoteCast(request)
    else
        if not HealState._.calledOff then
            HealState._.lastCureResult = spell .. " on " .. tostring(request.name) ..
                " failed: " .. tostring(reason)
        end
        -- a cure we called off ourselves costs nothing but its place in the queue for a moment: it
        -- was dropped because somebody was dying, and coming back to it afterwards is right
        Curing.NoteFailure(request, HealState._.calledOff and "called off" or reason)
    end

    HealState._.calledOff = false

    DebugLog("Cure finished: " .. tostring(HealState._.lastCureResult))
    HealState.Reset()
end

---------------- The state itself --------------------

function HealState.Reset()
    HealState._.castId = nil
    HealState._.healTarget = nil
    HealState._.healSlot = nil
    HealState._.healThreshold = nil
    HealState._.cureRequest = nil
end

---@return string description of what this state is doing, for /cheal and the menu
function HealState.Describe()
    if HealState._.castId ~= nil then
        local request = HealState._.cureRequest
        if request ~= nil then
            return "curing " .. request.typeKey .. " on " .. request.name ..
                " with " .. request.action:Name()
        end
        if HealState._.healTarget ~= nil then
            return "healing " .. HealState._.healTarget.name .. " with " .. tostring(HealState._.healTarget.spell)
        end
    end

    local waiting = #Curing.GetRequests()
    if waiting > 0 then
        -- said even when curing is off, which is the whole point: a queue that is filling up while
        -- nothing is cast is exactly the state somebody is staring at wondering why their healer
        -- has stopped answering them
        local notCuring = reasonNotCuring()
        return "watching, with " .. tostring(waiting) ..
            (waiting == 1 and " cure" or " cures") .. " waiting" ..
            (notCuring ~= nil and (" -- not curing: " .. notCuring) or "")
    end

    return "watching"
end

---@return string|nil result how the last heal went
function HealState.GetLastResult()
    return HealState._.lastResult
end

---@return string|nil result how the last cure went
function HealState.GetLastCureResult()
    return HealState._.lastCureResult
end

---@return table requests the cure requests outstanding, oldest first
function HealState.GetCureRequests()
    return Curing.GetRequests()
end

---@return table candidates last read health of everyone this state watches
function HealState.GetCandidates()
    return HealState._.candidates
end

---Which scopes a slot holding this may be given.
---
---A spell that can only land on one kind of person has already answered the question scope asks,
---so there is exactly one answer to offer -- and offering the others would be offering settings
---that do nothing, which is how a pet heal comes to be scoped "the tank" and its owner to be
---waiting for a heal that was never going to be chosen for one.
---@param aim string one of `aims`
---@return table scopes set of scope values, empty when there is nothing to scope at all
local function scopesFor(aim)
    if aim == aims.self then return { [HealStateConfig.scopes.Self.value] = true } end
    if aim == aims.pet then return { [HealStateConfig.scopes.Pet.value] = true } end
    -- a group heal lands on whoever is standing there; there is no choosing to be done
    if aim == aims.group then return {} end

    local all = {}
    for _, known in pairs(HealStateConfig.scopes) do all[known.value] = true end
    return all
end

---@class HealSlotFacts
---@field aim string one of `aims`
---@field aimText string what that means, in words
---@field scopes table set of scope values this slot may be given; one entry means it is decided
---@field isGroup boolean whether this slot is the one cast that covers everybody
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user. Everything here is
---read off the spell rather than configured, so it is also the answer to "why is this one not
---firing" -- which is otherwise a silent puzzle.
---@param slot Action
---@return HealSlotFacts facts
function HealState.DescribeSlot(slot)
    local facts = {
        aim = aims.single,
        aimText = "one at a time",
        scopes = scopesFor(aims.single),
        isGroup = false,
        problem = nil
    }

    -- a row being filled in has nothing to report yet, and "this character does not have it" is a
    -- strange thing to say about a spell nobody has picked
    if slot.name == nil or slot.name == "" then return facts end

    local action = Action.GetActionType(slot)
    if action == nil then
        facts.problem = "this character does not have it"
        return facts
    end
    if action.Subject == nil then
        facts.problem = "only spells, clickies and AAs can heal"
        return facts
    end

    facts.aim = aimOf(action:Subject())
    facts.aimText = ({
        [aims.self] = "on me",
        [aims.pet] = "on my pet",
        [aims.group] = "on the group, in one cast",
        [aims.single] = "one at a time"
    })[facts.aim]
    facts.scopes = scopesFor(facts.aim)
    facts.isGroup = facts.aim == aims.group

    if facts.aim == aims.pet and not HealStateConfig.GetHealPets() then
        facts.problem = "'Heal my pet' is off, so this never fires"
    end

    return facts
end

---Start the heal this pass decided on.
---@param pick HealPick
---@return boolean isBusy
local function startHeal(pick)
    local castId, refused = Casting.Cast(pick.action:Subject(), HealState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Heal of [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Healing [" .. pick.name .. "] with [" .. pick.action:Name() .. "]")
    HealState._.castId = castId
    -- who it is for, not what the cast targets: a pet heal aims itself, and the settle window and
    -- the abandon check are both about the person whose health this was chosen for
    HealState._.healTarget = { id = pick.forId, name = pick.name, spell = pick.action:Name() }
    HealState._.healSlot = pick.slot
    HealState._.healThreshold = pick.threshold
    return true
end

---Is the heal already in the air still the right heal?
---
---Read against the same reading of the group the rest of the pass uses, and deliberately not
---"would I choose this again": a heal that is merely no longer the *best* one is still a good
---one, and dropping it every time somebody else takes a scratch would mean never landing
---anything. What ends a heal is it being *wrong* -- the target does not need it, or somebody
---else needs one more than they do.
---@param candidates table
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandon(candidates)
    local target = HealState._.healTarget
    if target == nil or target.id == nil then return nil end

    local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
    if spawn.ID() == nil then return "they are gone" end
    if spawn.Dead() then return "they died" end

    local pct = Status.HealthPct(spawn)
    if pct == nil then return nil end

    -- somebody else healed them, or the mob switched targets
    if pct > (HealState._.healThreshold or 100) + abortMarginPct then
        return "they are back up to " .. tostring(math.floor(pct)) .. "%"
    end

    -- Someone else is in real trouble, this heal is not for them, and -- the part that has to be
    -- asked -- we would actually heal them if we dropped this. Without that last clause the cast
    -- is thrown away for somebody nothing is going to be cast at, and the next pass starts the
    -- same heal on the same target to be thrown away again.
    local emergency = HealStateConfig.GetEmergencyPct()
    if pct > emergency then
        for _, candidate in ipairs(candidates) do
            if candidate.id ~= target.id and candidate.pct <= emergency and wouldChoose(candidate) then
                return candidate.name .. " needs it more"
            end
        end
    end

    return nil
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordFinished(status, outcome, reason)
    local target = HealState._.healTarget or {}

    if status == Casting.status.succeeded then
        HealState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        if target.id ~= nil then
            HealState._.settleUntil[target.id] = Time.current_time() + healSettleMs
            HealState._.tryAgainAt[target.id] = nil
        end
    elseif not HealState._.calledOff then
        -- a heal we called off already said why; anything else is the client refusing it
        HealState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            " failed: " .. tostring(reason)
        -- and a refusal is worth remembering for a moment. Without this the same target is chosen
        -- again on the very next pass, refused again, and the whole thing runs at loop speed --
        -- which is what a log full of a cast and a cancellation per frame actually is. A heal we
        -- called off ourselves is left out on purpose: that one was dropped because somebody else
        -- needed it more, and coming straight back to them is the right thing to do.
        if target.id ~= nil then
            HealState._.tryAgainAt[target.id] = Time.current_time() + retryAfterFailureMs
        end
    end
    HealState._.calledOff = false

    DebugLog("Heal finished: " .. tostring(HealState._.lastResult))
    HealState.Reset()
end

---------------- Orders --------------------

---@param id number
---@param name string
local function orderHeal(id, name)
    HealState._.order = { id = id, name = name, expiresMs = Time.current_time() + orderTimeoutMs }
    DebugLog("Heal ordered for [" .. name .. "] (" .. tostring(id) .. ")")
end

---Call off whatever is being healed right now, and forget any order waiting for a turn.
function HealState.CallOff()
    HealState._.order = nil
    if HealState._.castId ~= nil then
        Casting.StopFor(HealState.key)
    end
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function HealState.Init()
    if HealState._.isInit then return end

    -- our own config, so a class that does not register this state has no heal slots written
    HealStateConfig.Init()

    Menu.RegisterState(HealState)

    local healDocs = ChelpDocs.new(function() return {
        "(healnow <id>) Tells listener(s) to heal the spawn with <id> now",
        " -- Usage: healnow <spawn id>",
        " -- Usage (call off the heal in progress): healnow off",
        " -- The heal used is the first configured slot that suits them; if they are already",
        "    healthy enough that none of them applies, nothing is cast.",
        " -- An order that cannot be acted on within ten seconds is dropped rather than",
        "    landing long after it mattered."
    } end )
    local function event_Heal(_, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.heal):HasPermission(speaker) then
            DebugLog("Ignoring heal speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(healnow) No one given. Usage: healnow <spawn id>, or `healnow off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            HealState.CallOff()
            return
        end

        local targetId = tonumber(args[1])
        if targetId == nil then
            print("(healnow) [" .. args[1] .. "] is not a spawn id. Usage: healnow <spawn id>")
            return
        end

        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        if spawn.ID() == nil then
            print("(healnow) Nothing here with id [" .. tostring(targetId) .. "]")
            return
        end

        orderHeal(targetId, spawn.CleanName() or tostring(targetId))
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.heal, event_Heal, healDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                { label = "Myself", args = "${Me.ID}", name = "Heal me" },
                { label = "Call off the heal", args = "off", name = "Stop healing" }
            } end
        }))

    local healMeDocs = ChelpDocs.new(function() return {
        "(healme) Tells listener(s) to heal whoever said it, now",
        " -- The button a tank binds: it needs no spawn id, since the healer works out who",
        "    spoke. Nothing to say to yourself, so the local channel will not take it."
    } end )
    local function event_HealMe(_, speaker)
        if not Commands.GetCommandOwners(HealState.eventIds.healMe):HasPermission(speaker) then
            DebugLog("Ignoring healme speaker [" .. speaker .. "]")
            return
        end

        local spawn = mq.TLO.Spawn("pc radius 300 " .. speaker)
        if spawn.ID() == nil then
            Commands.GetCommandSpeak(HealState.eventIds.healMe):speak("Cannot see [" .. speaker .. "] to heal them")
            return
        end

        orderHeal(spawn.ID(), speaker)
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.healMe, event_HealMe, healMeDocs)
        :ActsOnSpeaker())

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healing,
        summary = "Turns healing on or off for listener(s)",
        about = { "Off calls off a heal in progress as well as stopping new ones." },
        get = HealStateConfig.IsEnabled,
        set = HealState.SetEnabled
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healGroup,
        summary = "Turns healing the rest of the group on or off",
        about = {
            "Whether group members are somebody this character heals at all.",
            "Off watches nobody but this character (and its pet, if that is on), so a",
            "group-mate at 10% is left to somebody else.",
            "Not about group heal spells: one of those is cast because enough of the people",
            "being watched are hurt, so this changes what is counted, not whether it is used."
        },
        get = HealStateConfig.GetHealGroup,
        set = HealStateConfig.SetHealGroup
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healPets,
        summary = "Turns healing this character's pet on or off",
        about = { "Off by default: a pet is cheaper to summon than the mana spent keeping it up." },
        get = HealStateConfig.GetHealPets,
        set = HealStateConfig.SetHealPets
    })

    ---What a person might type for each setting. Three answers to one question, so a switch will
    ---not do -- but the words people reach for are still on/off words, and `curing on` meaning
    ---"cure, out of fights" is the reading that matches how every other switch in cabby behaves
    ---about combat: off until told otherwise.
    local cureWords = {
        ["off"] = HealStateConfig.cureModes.Off.value,
        ["no"] = HealStateConfig.cureModes.Off.value,
        ["none"] = HealStateConfig.cureModes.Off.value,
        ["disabled"] = HealStateConfig.cureModes.Off.value,
        ["on"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["yes"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["out"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["outofcombat"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["combat"] = HealStateConfig.cureModes.Always.value,
        ["incombat"] = HealStateConfig.cureModes.Always.value,
        ["battle"] = HealStateConfig.cureModes.Always.value,
        ["always"] = HealStateConfig.cureModes.Always.value
    }

    local curingDocs = ChelpDocs.new(function() return {
        "(curing <off | on | combat>) Sets whether listener(s) answer cure requests, and when",
        " -- Usage: curing off      -- ignore them",
        " -- Usage: curing on       -- cure, but not while fighting",
        " -- Usage: curing combat   -- cure, fights included",
        " -- Usage: curing          -- report what it is set to now",
        " -- Nothing about a cure is configured: whoever needs one names the kind (`cure poison`)",
        "    and the best cure of that kind this character owns answers it. There is no slot list",
        "    to fill in, because the person afflicted is the only one who can see it and has no",
        "    idea what anybody hearing them can cast.",
        " -- Cures are cast ahead of ordinary heals and behind anybody below the emergency point.",
        " -- Asking for a cure is the other half of this and every class does it, whether or not",
        "    it can cure anything: see /chelp callcure",
        " -- Currently: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode())
    } end )
    local function event_Curing(_, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.curing):HasPermission(speaker) then
            DebugLog("Ignoring curing speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("Curing: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode()))
            return
        end

        local mode = cureWords[args[1]:lower()]
        if mode == nil then
            print("(curing) [" .. args[1] .. "] is not a curing setting. Usage: curing <off | on | combat>")
            return
        end

        HealStateConfig.SetCureMode(mode)
        if not HealStateConfig.IsCuring() and HealState._.cureRequest ~= nil then
            -- switched off with one in the air: it is the casting service's now, and it would go
            -- on holding the chain back for a job we were just told to stop
            Casting.StopFor(HealState.key)
        end
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.curing, event_Curing, curingDocs)
        :WithArgs({
            required = true,
            hint = "off, on, or combat",
            default = "on",
            choices = function() return {
                { label = "Do not cure", args = "off", name = "Curing off" },
                { label = "Cure, but not while fighting", args = "on", name = "Curing on" },
                { label = "Cure, fights included", args = "combat", name = "Curing in battle" }
            } end
        }))

    ActionCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healAction,
        summary = "Switches one of the configured heals on or off",
        where = "Heal State page",
        getActionLists = HealStateConfig.GetActionLists
    })

    local chealDocs = ChelpDocs.new(function() return {
        "(/cheal) Report what the heal state is doing, and who it is watching",
        " -- Usage: /cheal",
        " -- Usage (call off the heal in progress): /cheal off"
    } end )
    local function Bind_CHeal(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            chealDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            HealState.CallOff()
            print("Heal called off")
            return
        end

        print("Heal: " .. HealState.Describe() .. (HealState.IsEnabled() and "" or " (disabled)"))
        local result = HealState.GetLastResult()
        if result ~= nil then
            print(" -- last: " .. result)
        end
        local notCuring = reasonNotCuring()
        print(" -- curing: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode()) ..
            (notCuring ~= nil and (" -- not answering right now: " .. notCuring) or ""))
        local cureResult = HealState.GetLastCureResult()
        if cureResult ~= nil then
            print(" -- last cure: " .. cureResult)
        end
        for _, request in ipairs(HealState.GetCureRequests()) do
            print(" -- asked for: " .. request.typeKey .. " for " .. request.name ..
                " with " .. request.action:Name())
        end
        for _, candidate in ipairs(getCandidates()) do
            print(" -- " .. candidate.name .. ": " .. tostring(math.floor(candidate.pct)) .. "%" ..
                (candidate.isTank and " (tank)" or "") .. (candidate.isPet and " (pet)" or ""))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cheal", Bind_CHeal, chealDocs))

    HealState.Reset()
    HealState._.isInit = true
end

---Read the group, decide what should be happening, act on it, and release.
---
---There is no "I am healing" mode to be stuck in. Every pass reads everyone's health afresh and
---asks the same question -- is a heal in the air still the right heal, and if there is none,
---which one should there be -- so nothing a cast does or fails to do can stop this state
---deciding. A heal that cannot get started is reconsidered on the next pass like everything else,
---and dropped the moment it stops being the right thing to do.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function HealState.Go()
    local candidates = getCandidates()

    local castId = HealState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)
        local isCure = HealState._.cureRequest ~= nil

        if status == nil then
            local abandon = isCure and reasonToAbandonCure(candidates) or reasonToAbandon(candidates)
            if abandon ~= nil then
                DebugLog("Calling off the " .. (isCure and "cure" or "heal") .. ": " .. abandon)
                if isCure then
                    HealState._.lastCureResult = "called off: " .. abandon
                else
                    HealState._.lastResult = "called off: " .. abandon
                end
                HealState._.calledOff = true
                Casting.StopFor(HealState.key)
            end
            return true
        end

        if isCure then
            recordCureFinished(status, outcome, reason)
        else
            recordFinished(status, outcome, reason)
        end
        return true
    end

    prune()

    -- **A cure comes after anybody in real trouble and before everything else.**
    --
    -- Above an ordinary heal because the two are not the same kind of cost. A heal gives back what
    -- has already been taken; a cure stops the taking. An affliction with two minutes left will
    -- spend more health than the heal being weighed against it and go on spending it every tick,
    -- and it is *finite* -- once it is off, the healing that would have been owed to it never has
    -- to happen at all. Above an ordered heal for the same reason, and because a cure request is
    -- itself somebody's explicit order: both are people saying what they need, and the one that
    -- ends a recurring cost in a single cast is the one to answer first.
    --
    -- Below somebody dying, because nothing outranks that. It is the same guard a group heal is
    -- held to a few lines down, and asked the same careful way (see `emergencyPending`): whether
    -- there is somebody in trouble this state would actually cast at, rather than merely somebody
    -- with a low number, so a rezzed group-mate parked at 15% cannot block curing forever.
    if not emergencyPending(candidates) then
        local curePick = chooseCure()
        if curePick ~= nil then return startCure(curePick) end
    end

    local pick = choosePick(candidates)
    if pick == nil then return false end

    return startHeal(pick)
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
HealState.IsEnabled = function()
    return HealStateConfig.IsEnabled()
end

---Switching healing off has to call off the heal in the air as well: it is the casting service's
---now, and it would go on holding the whole chain back for a job we were just told to stop.
---@diagnostic disable-next-line: duplicate-set-field
HealState.SetEnabled = function(isEnabled)
    HealStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        HealState.CallOff()
        HealState.Reset()
    end
end

function HealState.BuildMenu()
    HealStateMenu.BuildMenu(HealState)
end

return HealState
