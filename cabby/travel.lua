---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")
local Timer = require("utils.Time.Timer")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Status = require("cabby.status")
local TravelConfig = require("cabby.configs.travelConfig")

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
---**It holds the orders, because they cannot be re-derived**: who to follow, where to stand and in
---which zone, and progress through a zone line -- clicking one's switch, or walking through after
---somebody where there is no switch to click (a clicked door looks exactly like an unclicked one,
---and a walk aimed at an invisible trigger looks exactly like walking). The one measurement kept
---alongside them -- where the follow target was last seen, which way they were going and whether
---they were still moving -- exists for the same reason: it is the fact their vanishing is judged
---by, and there is nobody left to ask once they are gone. Everything else is read from the world
---on every drive. Follow and anchor are contradictory, so taking either order clears the other --
---with only one ever standing, "which am I doing" stays something to read.
---@class Travel
local Travel = {
    key = "Travel",
    _ = {
        isInit = false,
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
        -- where we were told to stand, and the zone those numbers are a place in: a coordinate
        -- pair only names a spot inside one zone, so the zone is half of the order
        anchor = { set = false, x = 0, y = 0, zoneId = 0 },
        -- where the follow target was last seen, and in which zone: the spot their vanishing is
        -- judged from. Gone within click range of a switch reads as clicked-through; gone on
        -- the move anywhere else reads as a walk-through zone line taking them, with heading
        -- saying which way through it and seenMs/movedMs saying whether they were still moving;
        -- gone from a standstill reads as nothing to chase. A measurement, not an order -- and
        -- one vanishing spends it.
        lastSeen = { zoneId = 0, y = 0, x = 0, heading = 0, seenMs = 0, movedMs = 0 },
        -- Progress through clicking a zone line: the door has been clicked and the zone is
        -- coming, which is not something a fresh look at the world can reconstruct. Held state
        -- that is not an order, like walkZone below.
        clickZone = { step = nil, timer = nil, lastFailedMs = 0 },
        -- Progress through walking a walk-through zone line: the vanish spot is being walked
        -- past and the zone should be coming, which a fresh look at the world cannot
        -- reconstruct once the sighting that justified it is spent.
        walkZone = { active = false, taskId = 0, destY = 0, destX = 0, fromZoneId = 0, lastFailedMs = 0 },
        -- stuck detection, which is a measurement rather than a decision
        stuck = { checking = false, timer = nil, lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 } },
        waitingReported = false
    }
}

-- How far past the distance we close to the target may get before we close on them again, as a
-- fraction of that distance: the buffer zone that keeps a follow from being a shadow, since inside
-- it they can turn around, back up and step past us without anything of ours moving. A fraction
-- rather than a fixed margin because what matters is the room between the two -- a thin buffer is
-- barely a buffer, and a buffer that stayed at ten units while the distance went to forty would be
-- exactly that. Nothing here re-measures it: the follow task owns it (Follow.WithinHold).
local holdBufferScale = 0.75
-- How much further than the distance we hold at still counts as close enough not to bother
-- starting a follow. Only ever asked with no follow running, which is the one moment there is no
-- hysteresis to read (see closeEnough below); the buffer above is what answers it after that.
local keepCloseSlack = 2
-- how close to an anchor still counts as being parked on it
local anchorRadius = 15
-- how long to leave a failed attempt at clicking through a zone line alone. Without it, a door
-- that will not take us anywhere is clicked again on the pass after each failure, forever.
local clickZoneRetryMs = 15000
-- how near a switch the follow target must have vanished for that vanishing to read as "they
-- clicked through it": their click reach, plus a breath of movement between our looks at them
local zoneSwitchDistance = 30
-- how near their corpse must be for a vanishing to read as "they died here"
local corpseDistance = 100
-- Walking through a walk-through zone line, for a target vanishing on the move where there is no
-- switch: how far past the spot they vanished from to aim. The trigger plane is a step past where
-- their client last reported them, so the walk has to overshoot -- it is the zone line that ends
-- it, not arriving.
local zoneWalkDistance = 40
-- how lately the target must still have been moving, as of our last sighting of them, for their
-- vanishing to read as walking through a zone line. A gate is cast and a camp is sat out, both
-- from a standstill measured in whole seconds; a zone line takes somebody mid-stride.
local zoneWalkRecentMoveMs = 2500
-- how near the vanish spot we must be for walking through after them to be honest: the trail
-- walked out is what brings us here, and a beeline from further away has no known-walkable route
local zoneWalkNearDistance = 60
-- how long to leave a failed walk-through alone, for the same reason as clickZoneRetryMs
local zoneWalkRetryMs = 15000

-- The command ids the procedures here speak on. The commands themselves are registered by the
-- follow state (it owns the order surface); these are the same ids, so what gets said lands
-- wherever those commands are configured to speak.
local clickZoneSpeakId = "clickzone"
local anchorSpeakId = "anchor"

---Steps of the click-zone procedure, in order.
local clickZoneSteps = {
    findingSwitch = "findingSwitch",
    clickingSwitch = "clickingSwitch",
    waitingToZone = "waitingToZone"
}

---Ids of the game-text listeners this core registers (see Travel.Init).
local eventIds = {
    followTargetSlain = "followtargetslain",
    followTargetDied = "followtargetdied"
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

---A fresh, empty last-sighting: nothing measured yet, nothing to judge a vanishing by.
local function EmptyLastSeen()
    return { zoneId = 0, y = 0, x = 0, heading = 0, seenMs = 0, movedMs = 0 }
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

---How close we hold station on the follow target right now, and how far they get before we close
---on them again.
---
---Re-derived from the world every time it is asked rather than fixed when the follow started,
---because the answer changes underneath a running follow: a fight breaks out around a character
---that has no business being at melee range, and the follow it already has going is the one that
---has to hear about it (see `Movement.SetFollowHold`).
---
---The fight is `Combat.IsGroupFighting` rather than our own engagement, because the character this
---setting is for is precisely the one *not* fighting: anything with a job in the fight is busy at a
---band above follow and never reaches this core at all. A run is not a fight -- `Status.IsFleeing`
---is the same order Combat reads, and a follower that spread out while the group ran for the zone
---line would be the one that did not make it.
---@return number distance
---@return number resumeDistance
local function holdDistances()
    local distance = TravelConfig.GetFollowDistance()

    if TravelConfig.GetCombatRelax() and not Status.IsFleeing() and Combat.IsGroupFighting() then
        distance = math.max(TravelConfig.GetCombatFollowDistance(), distance)
    end

    return distance, distance * (1 + holdBufferScale)
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

---Whether walking through a zone line is worth trying: not while we have just failed at it.
---@return boolean
local function MayWalkZone()
    return Time.current_time() - Travel._.walkZone.lastFailedMs >= zoneWalkRetryMs
end

---@param failed boolean whether the walk ended with the zone never taking us
local function EndWalkZone(failed)
    Travel._.walkZone.active = false
    Travel._.walkZone.taskId = 0
    Travel._.walkZone.lastFailedMs = failed and Time.current_time() or 0
end

---Start walking through a walk-through zone line: aim past the spot the follow target vanished
---from, along the way they were going, and let the zone line end the walk the way it ended
---theirs.
---@param lastSeen table the sighting being spent: where they vanished, and their heading through
local function BeginWalkZone(lastSeen)
    local rad = math.rad(lastSeen.heading)
    Travel._.walkZone.active = true
    Travel._.walkZone.taskId = 0
    Travel._.walkZone.destY = lastSeen.y + math.cos(rad) * zoneWalkDistance
    Travel._.walkZone.destX = lastSeen.x + math.sin(rad) * zoneWalkDistance
    Travel._.walkZone.fromZoneId = mq.TLO.Zone.ID()
    DebugLog(string.format("Walking through a zone line: last seen %.0f, %.0f heading %.0f, aiming %.0f, %.0f",
        lastSeen.y, lastSeen.x, lastSeen.heading, Travel._.walkZone.destY, Travel._.walkZone.destX))
end

---------------- Init --------------------

---The world announcing that whoever we follow died. A follow order does not outlive its target:
---a dead player is not somewhere to walk to -- they come back at a bind point, on their own
---clock -- and a follower left holding the order starts reading their absence as a zone line to
---click through. The message is the one death notice that arrives even when no corpse is left to
---find, and it arrives while a fight still owns the frames -- which is exactly when it happens.
---@param name string|nil who the death message named, cleaned to its last word by the listener
local function event_FollowTargetDied(_, name)
    if Travel._.followTarget == "" or name == nil then return end
    if name:lower() ~= Travel._.followTarget:lower() then return end

    Commands.GetCommandSpeak(Travel._.followCommand):speak(
        "Follow target [" .. Travel._.followTarget .. "] died, stopping follow")
    Travel.ClearFollowOrder()
end

---One-time wiring: the settings the following is carried out by, and the game-text listeners the
---orders depend on. Both death patterns hear every death in range, so the handler answers only to
---the name it is holding a follow order for.
function Travel.Init()
    if Travel._.isInit then return end
    Travel._.isInit = true

    TravelConfig.Init()

    local slainDocs = ChelpDocs.new(function() return {
        "(followtargetslain) Ends autofollow when the character being followed is slain"
    } end)
    Commands.RegisterEvent(Event.new(eventIds.followTargetSlain, "#1# has been slain by #2#!", event_FollowTargetDied, slainDocs))

    local diedDocs = ChelpDocs.new(function() return {
        "(followtargetdied) Ends autofollow when the character being followed dies without a slayer"
    } end)
    Commands.RegisterEvent(Event.new(eventIds.followTargetDied, "#1# died.", event_FollowTargetDied, diedDocs))
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
    Travel._.lastSeen = EmptyLastSeen()
    -- a walk-through in progress was justified by a sighting of whoever we *were* following
    EndWalkZone(false)
    Travel._.waitingReported = false
    Travel.ClearAnchor()
end

---Stop following, and forget everything measured about doing it.
function Travel.ClearFollowOrder()
    Travel._.followTarget = ""
    Travel._.followTargetId = 0
    Travel._.followSpawnId = 0
    Travel._.lastSeen = EmptyLastSeen()
    -- a walk-through in progress only exists in service of the order being dropped
    EndWalkZone(false)
    Travel._.stuck.checking = false
    Travel._.waitingReported = false
    Movement.StopFor(Travel.key)
end

---Take an anchor order. Being told to stand somewhere cancels being told to follow somebody.
---
---The zone we are standing in when the order arrives is taken down with it, because it is the
---rest of the order rather than decoration: "y 400, x -1200" is a place in Kaesora and a
---different place everywhere else, and the ways out of a zone that leave an anchor standing --
---a death and the bind point it wakes us at, a gate, a port -- all end with those numbers
---pointing at somewhere we were never told to be.
---@param y number
---@param x number
function Travel.SetAnchor(y, x)
    Travel.ClearFollowOrder()
    Travel._.anchor = { set = true, x = x, y = y, zoneId = tonumber(mq.TLO.Zone.ID()) or 0 }
end

---Stop holding a spot.
function Travel.ClearAnchor()
    Travel._.anchor = { set = false, x = 0, y = 0, zoneId = 0 }
    Movement.StopFor(Travel.key)
end

---Drop whatever standing order is in force -- following somebody, holding a spot, or neither.
---
---The two are one order to whoever gives them, since each cancels the other and only one is ever
---standing: "stop" means stop travelling, not a guess at which of the two is the one to forget.
---A character told to stop while parked on an anchor would otherwise walk straight back to it,
---which reads as the order having been ignored.
function Travel.ClearOrders()
    Travel.ClearFollowOrder()
    Travel.ClearAnchor()
end

---Forget every order and everything measured about carrying one out.
function Travel.Reset()
    Travel._.followTarget = ""
    Travel._.followTargetId = 0
    Travel._.followCommand = "followme"
    Travel._.followSpawnId = 0
    Travel._.anchor = { set = false, x = 0, y = 0, zoneId = 0 }
    Travel._.lastSeen = EmptyLastSeen()
    Travel._.clickZone = { step = nil, timer = nil, lastFailedMs = 0 }
    Travel._.walkZone = { active = false, taskId = 0, destY = 0, destX = 0, fromZoneId = 0, lastFailedMs = 0 }
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

---How close this character is holding station on whoever it follows, as of right now.
---
---For the Follow State page, and the reason it is worth a row there: the setting pair only ever
---shows what *would* be held, and this is the one that is. It is also how the relax is seen to be
---doing anything at all -- a caster that stayed at thirteen while the group fought would otherwise
---look exactly like one whose relax never fired.
---@return number distance
function Travel.GetHoldDistance()
    local distance = holdDistances()
    return distance
end

---------------- Driving --------------------

---One pass of following whoever we were told to follow.
---
---Everything it decides is decided here, from the world: whether they are in the zone, whether we
---are close enough, whether a follow is running, and whether it is getting anywhere. What it
---keeps is what it cannot ask for again -- who we were told to follow, and where we last saw them.
---@return boolean isBusy
local function FollowPass()
    local targetSpawn = followTargetSpawn()

    if targetSpawn.Name() == nil then
        -- Their breadcrumb trail outlives them leaving; walk it out first, which puts us at the
        -- spot where they vanished before we decide what to do about it.
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

        -- A death leaves proof behind: their corpse, near where we watched them go down. The
        -- order ends there -- see event_FollowTargetDied, which is this same conclusion heard
        -- rather than seen, and usually reaches it first.
        local targetCorpseDistance = mq.TLO.Spawn("corpse " .. Travel._.followTarget).Distance()
        if targetCorpseDistance ~= nil and targetCorpseDistance < corpseDistance then
            Commands.GetCommandSpeak(Travel._.followCommand):speak(
                "Follow target [" .. Travel._.followTarget .. "] died, stopping follow")
            Travel.ClearFollowOrder()
            return false
        end

        -- A vanishing at a spot we watched them reach is the world saying they went through a
        -- zone line there, and there are two ways through one. Inside click range of a switch,
        -- they clicked through it. On the move anywhere else, they walked through one -- the
        -- trigger is invisible, and somebody dropping out of the world mid-stride is its one
        -- announcement. Go after them either way. A vanish from a standstill is neither: a gate
        -- is cast and a camp is sat out, and both go somewhere no step past their spot can
        -- reach -- and a spot we never walked their route to has no known-walkable line to walk
        -- through, so those wait where they are, as does a death whose notice never reached us.
        -- One sighting pays for one follow-through: spent when the procedure begins, earned
        -- back only by seeing them again. In particular, a spot remembered from another zone --
        -- theirs before we zoned, or ours before we died -- pays for nothing.
        local lastSeen = Travel._.lastSeen
        if lastSeen.zoneId == mq.TLO.Zone.ID() then
            local switch = mq.TLO.Switch("nearest")
            local switchY = switch.Y()
            local switchX = switch.X()
            if switchY ~= nil and switchX ~= nil
                and Geometry.Distance2D(lastSeen.y, lastSeen.x, switchY, switchX) < zoneSwitchDistance then
                if MayClickZone() then
                    Travel._.lastSeen = EmptyLastSeen()
                    Travel.BeginClickZone()
                    return true
                end
            elseif MayWalkZone() and lastSeen.seenMs - lastSeen.movedMs <= zoneWalkRecentMoveMs then
                local myY = mq.TLO.Me.Y()
                local myX = mq.TLO.Me.X()
                if myY ~= nil and myX ~= nil
                    and Geometry.Distance2D(myY, myX, lastSeen.y, lastSeen.x) < zoneWalkNearDistance then
                    BeginWalkZone(lastSeen)
                    Travel._.lastSeen = EmptyLastSeen()
                    return true
                end
            end
        end

        Movement.StopFor(Travel.key)
        ReportWaiting("Follow target [" .. Travel._.followTarget .. "] is not here, waiting...")
        -- nothing to do but wait, so let lower tier actions have the frame
        return false
    end

    -- While they are here, keep fresh where "here" is: everything above judges their vanishing
    -- from the last spot we saw them at, which way they were going, and whether they were still
    -- moving. Moving is read off the spot itself -- a runner's reported position changes every
    -- look (the client walks them smoothly between the server's updates), a stander's is frozen
    -- exactly -- so the epsilon only has to clear float noise, not a stride.
    local seenY = targetSpawn.Y()
    local seenX = targetSpawn.X()
    if seenY ~= nil and seenX ~= nil then
        local lastSeen = Travel._.lastSeen
        local zoneId = mq.TLO.Zone.ID()
        if lastSeen.zoneId ~= zoneId or Geometry.Distance2D(lastSeen.y, lastSeen.x, seenY, seenX) > 0.1 then
            lastSeen.movedMs = Time.current_time()
        end
        lastSeen.y = seenY
        lastSeen.x = seenX
        lastSeen.zoneId = zoneId
        lastSeen.heading = targetSpawn.Heading.DegreesCCW() or lastSeen.heading
        lastSeen.seenMs = Time.current_time()
    end

    -- How much room we are keeping, as of this pass. A fight opening or closing around us is an
    -- answer that changes with a follow already running, so a follow that is running is told --
    -- before anything reads what it makes of it, since IsParked below is exactly that reading.
    local distance, resumeDistance = holdDistances()
    Movement.SetFollowHold(Travel.key, distance, resumeDistance)

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
        closeEnough = targetDistance ~= nil and targetDistance < distance + keepCloseSlack
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
            distance = distance,
            resumeDistance = resumeDistance,
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
---
---An anchor does not outlive the zone it was given in, the same way a follow order does not
---outlive its target. Dying is how that usually happens: we wake up at a bind point somewhere
---else, still holding a spot that no longer exists anywhere we can walk, and the distance to it
---is only a number -- a large one, since it is measured between two zones' coordinate systems --
---which is what a character running for the horizon after a wipe was doing. A gate and a port
---are the same story with no death in them. Nothing here waits to be sure: leaving is the
---answer, and it is read off the world every pass.
---@return boolean isBusy
local function AnchorPass()
    if not Travel._.anchor.set then return false end

    -- A zone id the client will not give us is a client mid-load, not a new zone -- and mid-load
    -- is exactly when this gets asked. Judge nothing until it answers, and judge nothing for an
    -- anchor that never got a zone written on it.
    local zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    if zoneId > 0 and Travel._.anchor.zoneId > 0 and zoneId ~= Travel._.anchor.zoneId then
        DebugLog("Anchor was set in zone " .. tostring(Travel._.anchor.zoneId) .. ", we are in "
            .. tostring(zoneId) .. " -- dropping it")
        Commands.GetCommandSpeak(anchorSpeakId):speak(
            "I left the zone I was anchored in, dropping the anchor")
        Travel.ClearAnchor()
        return false
    end

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

---One pass of walking through a walk-through zone line: keep the walk going until the zone
---takes us, the world says no, or whoever we walked after turns out to be back.
---
---The walk is one straight, short leg: from the end of their trail, through the spot they
---vanished from, to a little past it along the way they were going. The move's own end is the
---evidence window -- arriving, sticking or timing out still in this zone is the world saying
---there was no zone line where they vanished.
---@return boolean isBusy
local function WalkZonePass()
    local walkZone = Travel._.walkZone

    -- the zone took us: done here, and the next pass re-derives everything in the new zone
    if walkZone.fromZoneId ~= mq.TLO.Zone.ID() then
        DebugLog("Walked through the zone line")
        Movement.StopFor(Travel.key)
        EndWalkZone(false)
        return true
    end

    -- whoever we are walking after is back -- they zoned back over the line, or never left --
    -- and going to them is the ordinary follow's job, not this guess's
    if followTargetSpawn().Name() ~= nil then
        DebugLog("Follow target reappeared, calling off the walk-through")
        Movement.StopFor(Travel.key)
        EndWalkZone(false)
        return true
    end

    if walkZone.taskId == 0 then
        walkZone.taskId = Movement.MoveToLoc(walkZone.destY, walkZone.destX,
            { distance = 5, timeoutMs = 20000, owner = Travel.key })
        return true
    end

    -- the walk ended and we are still here: there was no zone line where they vanished
    if Movement.GetResult(walkZone.taskId) ~= nil then
        Commands.GetCommandSpeak(Travel._.followCommand):speak(
            "Follow target [" .. Travel._.followTarget .. "] vanished but I found no zone line, waiting...")
        Travel._.waitingReported = true
        EndWalkZone(true)
        return true
    end

    return true
end

---One pass of carrying out whatever is standing: a procedure in progress first, then whichever
---order is standing. Called by exactly one state per pass -- see the notes on this module.
---@return boolean isBusy
function Travel.Drive()
    -- Getting through a zone line is the one kind of thing here that is genuinely part-way done
    -- rather than a decision to re-make, so a procedure in progress comes first and finishes
    -- before anything else is asked.
    if Travel._.clickZone.step ~= nil then
        return ClickZonePass()
    end
    if Travel._.walkZone.active then
        return WalkZonePass()
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
    if Travel._.walkZone.active then return "Walking through a Zone Line" end
    if Travel._.followTarget ~= "" then return "Following" end
    if Travel._.anchor.set then return "Anchoring" end
    return "Standby"
end

return Travel
