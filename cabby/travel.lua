---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")
local Timer = require("utils.Time.Timer")

local Commands = require("cabby.commands.commands")

---The traveling core: the movement orders, and the procedures that carry them out.
---
---This used to live inside the follow state, which was fine for exactly as long as following was
---one state's job. Travel mode (flee) is "follow, and nothing else" -- the same order, the same
---trail-walking and the same click-through-the-zone-line, run from the passive band instead of the
---follow band -- and the moment two states needed the machinery, keeping it on either one meant
---the other reading a state, which no state may do. So the order and the procedures moved out,
---exactly the way the engagement moved out of the melee state into `combat.lua` when a wizard
---needed it too.
---
---**Exactly one state drives this per pass, and the chain is what serializes them.** FollowState
---drives it at the follow band in normal operation; FleeState drives it at the passive band while
---travel mode is on -- and since flee sits above follow and returns busy for as long as it is
---enabled, there is never a pass in which both run. Neither state knows the other exists; the
---ordering is the whole of the coordination, which is the design working as intended.
---
---**It holds the orders, because they cannot be re-derived**: who to follow, where to stand, and
---progress through clicking a zone line (a clicked door looks exactly like an unclicked one).
---Everything else is read from the world on every drive. Follow and anchor are contradictory, so
---taking either order clears the other -- with only one ever standing, "which am I doing" stays
---something to read.
---@class Travel
local Travel = {
    key = "Travel",
    _ = {
        -- who we were told to follow
        followTarget = "",
        -- 0 while we are holding the target by name (see followTargetSpawn), the spawn id we
        -- are holding them by otherwise
        followTargetId = 0,
        -- which command put us on this target, so that what the follow says about it later
        -- (waiting, stuck) is said wherever that command is configured to speak
        followCommand = "followme",
        -- the spawn the movement service is following, re-resolved whenever it is not following
        followSpawnId = 0,
        -- where we were told to stand
        anchor = { set = false, x = 0, y = 0 },
        -- Progress through clicking a zone line: the door has been clicked and the zone is
        -- coming, which is not something a fresh look at the world can reconstruct. The one
        -- piece of held state here that is not an order.
        clickZone = { step = nil, timer = nil, lastFailedMs = 0 },
        -- stuck detection, which is a measurement rather than a decision
        stuck = { checking = false, timer = nil, lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 } },
        waitingReported = false
    }
}

-- How close the movement service closes us to the follow target. Tight spacing by preference
-- (2026-07): about melee range, close enough to feel like a group -- but not so near that a
-- parked follower is stood on whoever it is following.
local followDistance = 13
-- and how far they get before we close on them again, which is the buffer zone that keeps a
-- follow from being a shadow: inside it they can turn around, back up and step past us without
-- anything of ours moving. Scaled alongside followDistance rather than left where it was, since
-- what matters is the room between the two -- a thin buffer is barely a buffer.
-- Nothing here re-measures it -- the follow task owns it (Follow.WithinHold)
local followResumeDistance = 23
-- how close we have to be before there is no point starting a follow at all
local keepCloseDistance = 15
-- how close to an anchor still counts as being parked on it
local anchorRadius = 15
-- how long to leave a failed attempt at clicking through a zone line alone. Without it, a door
-- that will not take us anywhere is clicked again on the pass after each failure, forever.
local clickZoneRetryMs = 15000

-- The command id the click-zone procedure speaks on. The command itself is registered by the
-- follow state (it owns the order surface); this is the same id, so what the procedure says lands
-- wherever that command is configured to speak.
local clickZoneSpeakId = "clickzone"

---Steps of the click-zone procedure, in order.
local clickZoneSteps = {
    findingSwitch = "findingSwitch",
    clickingSwitch = "clickingSwitch",
    waitingToZone = "waitingToZone"
}

---@param str string
local function DebugLog(str)
    Debug.Log(Travel.key, str)
end

local function UpdateLastLoc()
    local lastLoc = Travel._.stuck.lastLoc
    lastLoc.x = mq.TLO.Me.X()
    lastLoc.y = mq.TLO.Me.Y()
    lastLoc.z = mq.TLO.Me.Z()
    lastLoc.zoneId = mq.TLO.Zone.ID()
end

local function CloseToLastLoc()
    local lastLoc = Travel._.stuck.lastLoc
    return mq.TLO.Math.Distance(tostring(lastLoc.y) .. "," .. tostring(lastLoc.x) .. "," .. tostring(lastLoc.z))() < 30
end

---Whoever we are following, whether or not they are currently around: an invalid spawn
---(`Name()` of nil) means they are not in the zone with us.
---
---A player is held by name, which is what lets us pick them back up after they zone or die --
---their spawn id does not survive either. Anything else is held as the one spawn it is: a name
---is shared by every copy of an npc in the zone and outlives none of them.
local function followTargetSpawn()
    if Travel._.followTargetId > 0 then
        return mq.TLO.Spawn("id " .. Travel._.followTargetId)
    end
    return mq.TLO.Spawn("pc " .. Travel._.followTarget)
end

---The follow target's spawn id, but only while they are close enough and in sight to go and
---pick up. Held by name or by id the same way followTargetSpawn does.
local function followTargetInReachId()
    if Travel._.followTargetId > 0 then
        return mq.TLO.Spawn("id " .. Travel._.followTargetId .. " radius 200 los").ID()
    end
    return mq.TLO.Spawn("pc radius 200 los " .. Travel._.followTarget).ID()
end

---Say, once, that we are waiting on the follow target rather than every pass.
---@param message string
local function ReportWaiting(message)
    if Travel._.waitingReported then return end
    Travel._.waitingReported = true
    Commands.GetCommandSpeak(Travel._.followCommand):speak(message)
end

---Are we stuck trying to get to the follow target?
---
---A measurement, not a decision: it compares where we are against where we were, and the only
---thing it decides is whether to give up on this attempt and go back to looking.
---@return boolean isStuck
local function CheckStuck()
    -- we have escaped the bubble of lastloc, so things are going fine
    if not CloseToLastLoc() then
        UpdateLastLoc()
        Travel._.stuck.checking = false
        return false
    end

    -- first pass in one place: start the clock and remember where "here" was
    if not Travel._.stuck.checking then
        Travel._.stuck.timer = Timer.new(5000)
        UpdateLastLoc()
        Travel._.stuck.checking = true
        return false
    end

    if Travel._.stuck.timer:timer_expired() and CloseToLastLoc() then
        return true
    end

    return false
end

---Whether clicking through a zone line is worth trying: not while we have just failed at it.
---@return boolean
local function MayClickZone()
    return Time.current_time() - Travel._.clickZone.lastFailedMs >= clickZoneRetryMs
end

---@param failed boolean whether the procedure gave up rather than finishing
local function EndClickZone(failed)
    Travel._.clickZone.step = nil
    Travel._.clickZone.timer = nil
    Travel._.clickZone.lastFailedMs = failed and Time.current_time() or 0
end

---------------- Orders --------------------

---Start clicking through a zone line. Progress from here is held, because the world cannot tell
---us that the door has been clicked and the zone is on its way.
function Travel.BeginClickZone()
    Travel._.clickZone.step = clickZoneSteps.findingSwitch
    Travel._.clickZone.timer = Timer.new(10000)
end

---Take a follow order. Being told to follow somebody cancels being told to stand somewhere.
---@param name string who to follow
---@param spawnId number 0 to hold them by name (a player), their spawn id otherwise
---@param command string the command id this order arrived on, for routing what gets said about it
function Travel.SetFollowOrder(name, spawnId, command)
    DebugLog("Follow order: [" .. name .. "] via (" .. command .. ")")
    Travel._.followTarget = name
    Travel._.followTargetId = spawnId or 0
    Travel._.followCommand = command
    Travel._.followSpawnId = 0
    Travel._.waitingReported = false
    Travel.ClearAnchor()
end

---Stop following, and forget everything measured about doing it.
function Travel.ClearFollowOrder()
    Travel._.followTarget = ""
    Travel._.followTargetId = 0
    Travel._.followSpawnId = 0
    Travel._.stuck.checking = false
    Travel._.waitingReported = false
    Movement.StopFor(Travel.key)
end

---Take an anchor order. Being told to stand somewhere cancels being told to follow somebody.
---@param y number
---@param x number
function Travel.SetAnchor(y, x)
    Travel.ClearFollowOrder()
    Travel._.anchor = { set = true, x = x, y = y }
end

---Stop holding a spot.
function Travel.ClearAnchor()
    Travel._.anchor = { set = false, x = 0, y = 0 }
    Movement.StopFor(Travel.key)
end

---Forget every order and everything measured about carrying one out.
function Travel.Reset()
    Travel._.followTarget = ""
    Travel._.followTargetId = 0
    Travel._.followCommand = "followme"
    Travel._.followSpawnId = 0
    Travel._.anchor = { set = false, x = 0, y = 0 }
    Travel._.clickZone = { step = nil, timer = nil, lastFailedMs = 0 }
    Travel._.stuck = { checking = false, timer = nil, lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 } }
    Travel._.waitingReported = false
end

---Whoever this character was told to follow, whether or not they are in the zone right now.
---
---The order, not a conclusion drawn from it: "am I following them at this moment" is
---`Movement.IsFollowing`, and this stays set across a zone line and a death because the order does.
---@return string name "" when no follow order is standing
function Travel.GetFollowTarget()
    return Travel._.followTarget
end

---@return table anchor { set, x, y } -- read-only
function Travel.GetAnchor()
    return Travel._.anchor
end

---------------- Driving --------------------

---One pass of following whoever we were told to follow.
---
---Everything it decides is decided here, from the world: whether they are in the zone, whether we
---are close enough, whether a follow is running, and whether it is getting anywhere. What it
---keeps is what it cannot ask for again -- who we were told to follow.
---@return boolean isBusy
local function FollowPass()
    local targetSpawn = followTargetSpawn()

    if targetSpawn.Name() == nil then
        -- Their breadcrumb trail outlives them leaving; walk it out first, which puts us at the
        -- zone line (or their corpse) before we decide what to do about it.
        if Movement.IsFollowing(Travel._.followSpawnId) then
            return true
        end

        -- A target held by spawn id is not coming back once that id stops resolving -- it died,
        -- despawned, or we left the zone it was in -- so there is nothing here to wait for.
        if Travel._.followTargetId > 0 then
            Commands.GetCommandSpeak(Travel._.followCommand):speak(
                "Follow target [" .. Travel._.followTarget .. "] is gone, stopping follow")
            Travel.ClearFollowOrder()
            return false
        end

        -- Only a player walks out through a zone line. If they are not lying dead next to us,
        -- assume they zoned and go through after them.
        local corpse = mq.TLO.Spawn("corpse " .. Travel._.followTarget)
        if corpse.Name() == nil or corpse.Distance() > 100 then
            local switchDistance = mq.TLO.Switch("nearest").Distance()
            if switchDistance ~= nil and switchDistance < 100 and MayClickZone() then
                Travel.BeginClickZone()
                return true
            end
        end

        Movement.StopFor(Travel.key)
        ReportWaiting("Follow target [" .. Travel._.followTarget .. "] is not here, waiting...")
        -- nothing to do but wait, so let lower tier actions have the frame
        return false
    end

    -- Close enough: the follow task parks itself, and so do we.
    --
    -- Once a follow is running that reading is the task's to make rather than ours, because the
    -- buffer zone is hysteresis: whether 15 away is close enough depends on whether we were
    -- holding or closing a moment ago, and the task is what remembers which. Measuring the
    -- distance ourselves here would answer with the wrong threshold half the time and go back to
    -- following to the inch.
    local closeEnough
    if Movement.IsFollowing(Travel._.followSpawnId) then
        closeEnough = Movement.IsParked()
    else
        local targetDistance = targetSpawn.Distance3D()
        closeEnough = targetDistance ~= nil and targetDistance < keepCloseDistance
    end

    if closeEnough then
        UpdateLastLoc()
        Travel._.stuck.checking = false
        Travel._.waitingReported = false
        return false
    end

    -- Not close enough, so a follow should be running. It will not be on the first pass, after a
    -- zone, or when something with higher priority took movement over.
    if not Movement.IsFollowing(Travel._.followSpawnId) then
        local followSpawnId = followTargetInReachId()
        if followSpawnId == nil or followSpawnId <= 0 then
            Movement.StopFor(Travel.key)
            ReportWaiting("Follow target [" .. Travel._.followTarget .. "] out of range, waiting...")
            return false
        end

        Travel._.waitingReported = false
        Travel._.followSpawnId = followSpawnId
        Travel._.stuck.checking = false
        Movement.Follow(followSpawnId, {
            distance = followDistance,
            resumeDistance = followResumeDistance,
            owner = Travel.key
        })
        return true
    end

    if CheckStuck() then
        Commands.GetCommandSpeak(Travel._.followCommand):speak(
            "I got stuck while following [" .. Travel._.followTarget .. "], waiting...")
        Movement.StopFor(Travel.key)
        Travel._.followSpawnId = 0
        Travel._.stuck.checking = false
        return true
    end

    -- mid-run: nothing weaker should start moving us somewhere else
    return true
end

---One pass of standing where we were told to stand.
---@return boolean isBusy
local function AnchorPass()
    if not Travel._.anchor.set then return false end

    -- already walking back to it, let that finish
    if Movement.IsMovingTo() and Movement.IsOwnedBy(Travel.key) then
        return true
    end

    local myY = mq.TLO.Me.Y()
    local myX = mq.TLO.Me.X()
    if myY == nil or myX == nil then return false end

    if Geometry.Distance2D(myY, myX, Travel._.anchor.y, Travel._.anchor.x) > anchorRadius then
        Movement.StopFor(Travel.key)
        Movement.MoveToLoc(Travel._.anchor.y, Travel._.anchor.x, { owner = Travel.key })
        return true
    end

    return false
end

---One pass of the click-zone procedure: find the door, walk to it, click it, wait for the zone.
---
---This is the one place in this core that holds a mode, because it is the one thing the world
---cannot describe: a door that has been clicked looks exactly like one that has not.
---@return boolean isBusy
local function ClickZonePass()
    local step = Travel._.clickZone.step

    if step == clickZoneSteps.waitingToZone then
        if Travel._.stuck.lastLoc.zoneId ~= mq.TLO.Zone.ID() then
            EndClickZone(false)
            return true
        end

        if Travel._.clickZone.timer:timer_expired() then
            Commands.GetCommandSpeak(clickZoneSpeakId):speak("I failed to click into the zone. Waiting...")
            EndClickZone(true)
        end
        return true
    end

    local switchDistance = mq.TLO.Switch("nearest").Distance()

    if step == clickZoneSteps.clickingSwitch then
        if switchDistance ~= nil and switchDistance < 25 then
            UpdateLastLoc()
            mq.cmd("/invoke ${Switch[nearest].Target}")
            mq.cmd("/click left switch")
            Travel._.clickZone.step = clickZoneSteps.waitingToZone
            Travel._.clickZone.timer = Timer.new(10000)
            return true
        end

        if Travel._.clickZone.timer:timer_expired() then
            Commands.GetCommandSpeak(clickZoneSpeakId):speak("I failed to navigate to click zone. Waiting...")
            EndClickZone(true)
        end
        return true
    end

    -- findingSwitch
    Movement.StopFor(Travel.key)

    if switchDistance == nil or switchDistance >= 100 then
        Commands.GetCommandSpeak(clickZoneSpeakId):speak("Failed to click zone, could not find nearby switch")
        EndClickZone(true)
        return true
    end

    if switchDistance > 25 then
        local switchY = mq.TLO.Switch("nearest").Y()
        local switchX = mq.TLO.Switch("nearest").X()
        if switchY ~= nil and switchX ~= nil then
            Movement.MoveToLoc(switchY, switchX, { distance = 20, timeoutMs = 10000, owner = Travel.key })
        end
        Travel._.clickZone.step = clickZoneSteps.clickingSwitch
    else
        UpdateLastLoc()
        mq.cmd("/invoke ${Switch[nearest].Target}")
        mq.cmd("/click left switch")
        Travel._.clickZone.step = clickZoneSteps.waitingToZone
    end
    Travel._.clickZone.timer = Timer.new(10000)
    return true
end

---One pass of carrying out whatever is standing: a procedure in progress first, then whichever
---order is standing. Called by exactly one state per pass -- see the notes on this module.
---@return boolean isBusy
function Travel.Drive()
    -- Clicking through a zone line is the one thing here that is genuinely part-way done rather
    -- than a decision to re-make, so it comes first and finishes before anything else is asked.
    if Travel._.clickZone.step ~= nil then
        return ClickZonePass()
    end

    -- Following and anchoring are contradictory orders, so only one of them is ever standing:
    -- whichever was asked for last cancelled the other when it arrived.
    if Travel._.followTarget ~= "" then return FollowPass() end
    if Travel._.anchor.set then return AnchorPass() end

    return false
end

---@return string description of what the standing order is, for the pages and /state
function Travel.Describe()
    if Travel._.clickZone.step ~= nil then return "Clicking to Zone" end
    if Travel._.followTarget ~= "" then return "Following" end
    if Travel._.anchor.set then return "Anchoring" end
    return "Standby"
end

return Travel
