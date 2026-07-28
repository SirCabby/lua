local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Locomotion = require("utils.Movement.Locomotion")
local MovementStatus = require("utils.Movement.MovementStatus")
local StuckDetector = require("utils.Movement.StuckDetector")
local Time = require("utils.Time.Time")
local Unsticker = require("utils.Movement.Unsticker")

---Breadcrumb follow of a spawn, the `/afollow` replacement -- and like `/afollow`, it walks
---where the target actually walked, never at where the target happens to be.
---
---Line of sight is not walkability. A leader visible below a ledge, across a chasm railing or
---down a switchback is one confident straight line away over a drop, and a follower that runs
---that line is off the cliff -- seeing somebody says nothing about being able to walk to them.
---The route the leader walked is the one route known walkable, so we sample their position
---into a trail and replay it, corner for corner, whether or not they are in sight. (An earlier
---version dropped the trail whenever the target was visible and ran straight at them; the
---clipped corners and cliff dives that bought are why this works like `/afollow` now, 2026-07.)
---
---Arrival is still measured against the spawn, not the trail: reaching them ends the replay
---wherever the trail happens to be. How close we hold is two numbers rather than one -- we
---close to `distance` and then stand still until they are `resumeDistance` away, so they get
---a buffer to move around in instead of being shadowed step for step (see `WithinHold`).
---
---Trail bookkeeping worth knowing about:
--- - waypoints are recorded once the spawn has moved `sampleDistance` from the last one
--- - a jump in the spawn's position too big to be walking becomes a **warp seam** in the
---   trail: the leg into it is not walkable, so on reaching it we stand and wait rather than
---   walk a line the leader never walked (see `Pulse`)
--- - every pulse drops the trail through the furthest waypoint we are standing on, wherever
---   in the trail it is, and holding at the target retires the whole route that got us there
---   -- which is what keeps the trail draining instead of stockpiling the leader's camp
---   wander and replaying it drunk when they leave
--- - a backward jog the trail makes right where we stand (a laggy link records the target
---   rubber-banding) is skipped by arc rather than replayed -- see `TrimBacktrack`
--- - a big jump in our own position (summon, port, gate) invalidates the trail entirely
---@class Follow : MovementTask
local Follow = { author = "judged", key = "Follow" }

Follow.__index = Follow
setmetatable(Follow, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

-- heading error beyond which running forward would take us somewhere unhelpful
local maxDriftDegrees = 90
-- distance our own position can change in a frame before the trail is meaningless
local selfWarpDistance = 50
local doorRetryMs = 500
local doorDistance = 12
local doorArcDegrees = 50
-- how far from a warp seam we stand and wait, rather than walk a leg nobody walked
local warpWaitDistance = 50
-- cap on how much one pulse of our own travel can widen the reached radius: comfortably past
-- any honest pulse of running, small enough that one hitch cannot swallow a real corner
local reachTravelCap = 20
-- how far past a backtracking head the arc trim looks, how much of that is judged by the
-- looser arc, and the arcs themselves (degrees half-width; the far stretch must be squarely
-- ahead). These are MQ2AdvPath's ClearLag numbers with its 512-unit angles read as degrees.
local trimLookahead = 15
local trimNearCount = 10
local trimBehindArc = 70
local trimFrontArcNear = 70
local trimFrontArcFar = 35

---@param str string
local function DebugLog(str)
    Debug.Log(Follow.key, str)
end

---@param spawnId number
---@param options? table
--- - distance: how close we close to the spawn, default 10
--- - resumeDistance: how far the spawn gets before we close it again, default distance
--- - sampleDistance: how far the spawn moves before a new waypoint, default 5
--- - waypointGap: how close counts as reaching a waypoint, default 5
--- - maxWaypoints: trail cap, oldest dropped first, default 250
--- - warpDistance: a jump in the spawn's position larger than this is recorded as a warp
---   seam rather than a leg to walk, default 100
--- - openDoors: click closed doors we run into, default true
--- - nudgeAfter: stalled windows before an unstick attempt, default 2
--- - failAttempts: consecutive failed unstick attempts before giving up, default 9
--- - owner: key of whoever asked for the follow
---@return Follow
function Follow.new(spawnId, options)
    local self = setmetatable({}, Follow)
    options = options or {}

    self.key = Follow.key
    self.owner = options.owner

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.spawnId = spawnId
    -- resolved once: Describe() is read by UI panels every rendered frame, and a spawn
    -- search does not belong in the render path
    self._.name = mq.TLO.Spawn("id " .. tostring(spawnId)).CleanName() or tostring(spawnId)
    self._.distance = options.distance or 10
    -- never inside distance, or closing and holding would each undo the other
    self._.resumeDistance = math.max(options.resumeDistance or self._.distance, self._.distance)
    -- which of the two thresholds is in force right now (see WithinHold)
    self._.holding = false
    -- standing at a warp seam waiting for the world to change, cached for IsParked/Describe
    self._.warpWaiting = false
    -- the gap last pulse, and how fast it is closing, which is what we aim the stop with
    self._.lastDistance = nil
    self._.closing = 0
    self._.sampleDistance = options.sampleDistance or 5
    self._.waypointGap = options.waypointGap or 5
    self._.maxWaypoints = options.maxWaypoints or 250
    self._.warpDistance = options.warpDistance or 100
    self._.openDoors = options.openDoors ~= false
    self._.nudgeAfter = options.nudgeAfter or 2
    self._.failAttempts = options.failAttempts or 9
    self._.zoneId = mq.TLO.Zone.ID()
    self._.failReason = nil
    self._.lastSelf = nil
    self._.lastDoorMs = 0
    self._.trail = {}
    self._.first = 1
    self._.last = 0
    self._.stuck = StuckDetector.new()
    self._.unsticker = Unsticker.new(self._.stuck)

    return self
end

---@param reason string
---@return string status
function Follow:Fail(reason)
    self._.failReason = reason
    DebugLog("Follow failed: " .. reason)
    Locomotion.ReleaseAll()
    return MovementStatus.failed
end

---Whether we are close enough to stand still, which is not the same question as whether we were
---close enough to have stayed standing still.
---
---One threshold means we hold the spawn at exactly that range, so every step they take is a step
---we take: correct to the inch, and unpleasant to be followed by. So there are two -- we close to
---`distance` and then hold until they are `resumeDistance` away -- and the gap between them is the
---room they get to move around in before we come after them again.
---@param distance number how far away the spawn is now
---@return boolean withinHold
function Follow:WithinHold(distance)
    return distance <= (self._.holding and self._.resumeDistance or self._.distance)
end

---@return number count waypoints still on the trail
function Follow:TrailSize()
    return self._.last - self._.first + 1
end

function Follow:ClearTrail()
    self._.trail = {}
    self._.first = 1
    self._.last = 0
end

---@param y number
---@param x number
---@param z number
---@param warp? boolean whether the leg into this waypoint was a jump rather than a walk
function Follow:PushWaypoint(y, x, z, warp)
    self._.last = self._.last + 1
    self._.trail[self._.last] = { y = y, x = x, z = z, warp = warp == true }

    while self:TrailSize() > self._.maxWaypoints do
        -- evicting a warp seam moves it onto the next waypoint: everything after it is still
        -- on the far side of a jump nobody walked
        if self._.trail[self._.first].warp then
            self._.trail[self._.first + 1].warp = true
        end
        self._.trail[self._.first] = nil
        self._.first = self._.first + 1
    end
end

---Extend the trail when the spawn has moved far enough from the last breadcrumb
---@param spawn spawn
function Follow:Record(spawn)
    local y = spawn.Y()
    local x = spawn.X()
    local z = spawn.Z()
    if y == nil or x == nil or z == nil then return end

    local last = self._.trail[self._.last]
    if last == nil then
        self:PushWaypoint(y, x, z)
        return
    end

    local moved = Geometry.Distance3D(last.y, last.x, last.z, y, x, z)
    if moved > self._.warpDistance then
        DebugLog("Follow target warped " .. tostring(moved) .. ", marking a seam in the trail")
        self:PushWaypoint(y, x, z, true)
    elseif moved >= self._.sampleDistance then
        self:PushWaypoint(y, x, z)
    end
end

---Drop the trail through the furthest waypoint we are standing on.
---
---Standing on a waypoint -- any waypoint -- is proof that everything before it is history: the
---trail from there on is walkable from right here, however the rest of it got behind us. The
---scan is the whole trail rather than a window because staleness is not local -- a target who
---wanders around a parked follower, or ports away and later walks back past us, leaves the
---fresh part of the trail joined at our feet and the stale part somewhere else entirely, and
---skipping to the join is the only honest reading. The head waypoint alone is also tested
---against `reach`: at speed one pulse covers real ground, and a waypoint we will be past by
---the time the next decision lands has been reached (the same actuation lag
---`Locomotion.leadPulses` exists for -- a fixed radius orbits at background frame rates).
---
---Standing on a waypoint is a 3D fact. Measured flat, the breadcrumb three units away but
---thirty below -- the ledge hop, the bottom of the ramp we are at the top of -- reads as
---reached, and dropping it skips the one place the leader's route went *down*: the follower
---aims past the descent point and walks off whatever the leader climbed down. Cut corners in
---trail mode traced back to exactly this.
---@param myY number
---@param myX number
---@param myZ number
---@param reach number reached radius for the head waypoint; the rest use waypointGap
---@return number popped how many waypoints were dropped
function Follow:PopReached(myY, myX, myZ, reach)
    local reached = nil
    for i = self._.first, self._.last do
        local waypoint = self._.trail[i]
        local radius = i == self._.first and reach or self._.waypointGap
        if Geometry.Distance3D(myY, myX, myZ, waypoint.y, waypoint.x, waypoint.z) <= radius then
            reached = i
        end
    end
    if reached == nil then return 0 end

    local popped = reached - self._.first + 1
    for i = self._.first, reached do
        self._.trail[i] = nil
    end
    self._.first = reached + 1
    return popped
end

---Skip a backward jog the trail makes right where we stand.
---
---A laggy link records the target rubber-banding: a step backward, then onward. Replaying it
---is a follower that flips around mid-run for two steps, over and over. When the head waypoint
---is behind us and a waypoint shortly after it is ahead, the jog was lag rather than route,
---and the trail resumes at the ahead one. Only called on a pulse that reached a waypoint while
---already walking -- the one moment our heading is a fact about the trail (it faces along the
---leg just finished) rather than about wherever we happened to park. The scan stops at a warp
---seam, because "behind us and then ahead" says nothing about a stretch nobody walked. This is
---MQ2AdvPath's ClearLag.
---@param myY number
---@param myX number
function Follow:TrimBacktrack(myY, myX)
    local head = self._.trail[self._.first]
    if head == nil or head.warp then return end

    local heading = Locomotion.GetHeading()
    local behindHeading = Geometry.Normalize(heading + 180)
    if not Geometry.IsWithinArc(behindHeading, Geometry.HeadingTo(myY, myX, head.y, head.x), trimBehindArc) then
        return
    end

    for i = self._.first + 1, math.min(self._.last, self._.first + trimLookahead) do
        local waypoint = self._.trail[i]
        if waypoint.warp then return end
        local arc = (i - self._.first) <= trimNearCount and trimFrontArcNear or trimFrontArcFar
        if Geometry.IsWithinArc(heading, Geometry.HeadingTo(myY, myX, waypoint.y, waypoint.x), arc) then
            DebugLog("Follow trimmed a lag backtrack of " .. tostring(i - self._.first) .. " waypoints")
            for j = self._.first, i - 1 do
                self._.trail[j] = nil
            end
            self._.first = i
            return
        end
    end
end

---Click open a closed door we have run into. Callers gate this on being stalled: a switch
---within reach that is not blocking us must be left alone, because it may be a zone line.
function Follow:OpenDoorAhead()
    if not self._.openDoors then return end

    local now = Time.current_time()
    if now - self._.lastDoorMs < doorRetryMs then return end
    self._.lastDoorMs = now

    local door = mq.TLO.Switch("nearest")
    if (door.ID() or 0) < 1 or door.Open() then return end

    local distance = door.Distance3D()
    if distance == nil or distance > doorDistance then return end

    local headingTo = door.HeadingTo.DegreesCCW()
    if headingTo == nil or not Geometry.IsWithinArc(Locomotion.GetHeading(), headingTo, doorArcDegrees) then return end

    DebugLog("Opening door [" .. tostring(door.Name()) .. "]")
    door.Toggle()
end

---@return string status
function Follow:Pulse()
    if mq.TLO.Zone.ID() ~= self._.zoneId then
        return self:Fail("zoned away from the follow target")
    end

    local myY = mq.TLO.Me.Y()
    local myX = mq.TLO.Me.X()
    local myZ = mq.TLO.Me.Z()
    if myY == nil or myX == nil or myZ == nil then
        Locomotion.ReleaseAll()
        return MovementStatus.blocked
    end

    -- a trail we did not walk to the start of leads nowhere useful
    local travelled = 0
    local lastSelf = self._.lastSelf
    if lastSelf ~= nil then
        travelled = Geometry.Distance3D(lastSelf.y, lastSelf.x, lastSelf.z, myY, myX, myZ)
        if travelled > selfWarpDistance then
            DebugLog("We moved without walking, dropping the trail")
            self:ClearTrail()
            -- and a gap measured either side of a jump is not a speed
            self._.lastDistance = nil
            travelled = 0
        end
    end
    self._.lastSelf = { y = myY, x = myX, z = myZ }

    local reach = self._.waypointGap + math.min(reachTravelCap, travelled) * Locomotion.leadPulses
    local popped = self:PopReached(myY, myX, myZ, reach)

    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    local spawnExists = (spawn.ID() or 0) > 0
    if spawnExists then
        self:Record(spawn)
        local distance = spawn.Distance3D()

        -- Stopping is a decision we only get to make once a pulse, and the keys let go later
        -- still -- a full pulse and change behind the read, see Locomotion.leadPulses -- so the
        -- gap is tested where it will be when the release actually lands. Aiming half a pulse
        -- ahead was tried here first and still stopped long every time: it assumed the release
        -- was instant, and it never is. No hold distance setting can absorb the error either --
        -- it grows with speed and loop congestion, not with the threshold.
        --
        -- What matters is how fast the *gap* is closing, which is not how fast we are moving. A
        -- leader turning and running back through the group closes it at both our speeds at once,
        -- and that is exactly the moment a follower ends up stood on top of them -- our own speed
        -- would have said we needed half as much room as we did. The gap is the thing to measure,
        -- so measure the gap. Clamped because a zone or a port is not a speed -- but clamped well
        -- above any real sprint, because a clamp that bites on a fast runner eats exactly the
        -- lead that runner needs.
        local closing = 0
        if distance ~= nil and self._.lastDistance ~= nil then
            closing = math.max(-Locomotion.closingClamp, math.min(Locomotion.closingClamp, self._.lastDistance - distance))
        end
        self._.lastDistance = distance
        self._.closing = closing

        local holding = distance ~= nil and self:WithinHold(distance - closing * Locomotion.leadPulses)
        self._.holding = holding
        if holding then
            -- Being at the leader retires the route that got us here, seams and all: the trail
            -- restarts from the newest breadcrumb (theirs, where they stand), so what is
            -- replayed on unpark is only where they go next -- never the camp wander they did
            -- around us, and never a warp seam they have since walked back across. The hop
            -- this leaves for unpark -- our parked spot to theirs -- is bounded by the hold
            -- buffer, between two spots the group stood at together.
            if self:TrailSize() > 1 then
                for i = self._.first, self._.last - 1 do
                    self._.trail[i] = nil
                end
                self._.first = self._.last
            end
            self._.warpWaiting = false
            Locomotion.ReleaseAll()
            self._.stuck:Reset()
            self._.unsticker:Reset()
            return MovementStatus.holding
        end
    else
        -- walking a trail out to where they no longer are is not holding station on them, so the
        -- buffer is spent: whenever they turn up again we close on them properly
        self._.holding = false
        self._.lastDistance = nil
        self._.closing = 0
    end

    if popped > 0 and Locomotion.IsMoving() then
        self:TrimBacktrack(myY, myX)
    end

    local waypoint = self._.trail[self._.first]
    if waypoint == nil then
        if not spawnExists then
            -- out of breadcrumbs and out of spawn: we are wherever they last were
            return self:Fail("ran out of trail to follow")
        end
        waypoint = { y = spawn.Y(), x = spawn.X(), z = spawn.Z() }
        if waypoint.y == nil or waypoint.x == nil then
            Locomotion.ReleaseAll()
            return MovementStatus.blocked
        end
    end

    -- The leg into a warp seam is a jump nobody walked, so it is not ours to walk either.
    -- Stand at the seam with the follow alive: the trail keeps recording, and the moment the
    -- target's route brings them back over us -- or brings the seam within an honest walk --
    -- the pop scan reconnects us. A gone target is different: we are standing where they
    -- vanished, and there is nothing on the far side of the seam to wait for.
    if waypoint.warp and Geometry.Distance3D(myY, myX, myZ, waypoint.y, waypoint.x, waypoint.z) > warpWaitDistance then
        if not spawnExists then
            return self:Fail("the trail ends at a warp")
        end
        if not self._.warpWaiting then
            DebugLog("Follow target warped away, waiting at the seam")
        end
        self._.warpWaiting = true
        Locomotion.ReleaseAll()
        self._.stuck:Reset()
        self._.unsticker:Reset()
        return MovementStatus.moving
    end
    self._.warpWaiting = false

    Locomotion.FaceLoc(waypoint.y, waypoint.x, waypoint.z)

    -- Only a door the world has already refused us through -- we are stalled against it -- is
    -- worth clicking. The client offers no way to tell a door from a zone line's clickable, and
    -- clicking one of those is not opening a door, it is leaving the zone: a follower that
    -- clicks every switch it brushes past zones itself out from under a leader who is still
    -- here. Stalling first is the world saying this switch is what is actually in the way --
    -- and if it does turn out to be a zone line, it is one the leader's own route runs through.
    if self._.stuck:StalledWindows() >= 1 then
        self:OpenDoorAhead()
    end

    if self._.unsticker:IsActive() then
        self._.unsticker:Drive()
    elseif self._.stuck:StalledWindows() >= self._.nudgeAfter then
        if self._.unsticker:Streak() >= self._.failAttempts then
            return self:Fail("stuck while following")
        end
        self._.unsticker:Begin()
        self._.unsticker:Drive()
    else
        local drift = math.abs(Geometry.HeadingDiff(Locomotion.GetHeading(), Geometry.HeadingTo(myY, myX, waypoint.y, waypoint.x)))
        Locomotion.ReleaseStrafe()
        if drift > maxDriftDegrees then
            -- our facing has not caught up yet; do not sprint off in the wrong direction
            Locomotion.ReleaseForwardBack()
        else
            Locomotion.Hold(Locomotion.keys.forward)
        end
    end

    self._.stuck:Update(Locomotion.IsMoving() and not Locomotion.IsRooted())
    return MovementStatus.moving
end

---Whether this follow has anywhere to go right now.
---
---The same reading `Pulse` holds on -- `WithinHold`, buffer zone and all -- asked before the pulse
---rather than during it, because the service has to know whether the character is worth standing up
---before it stands them up. A target that is merely not in the zone is not "close enough": the
---trail still leads somewhere and we should be walking it.
---
---Waiting at a warp seam is parked too -- the task is alive with nothing to walk toward until the
---world changes -- but only while the target is still far on both counts. Everything here must be
---re-derived from the world on every ask, never remembered from the last pulse: parked means the
---service may let us sit, sitting means no more pulses, and a remembered "waiting" would sleep
---straight through the target walking back past us. A target within an honest walk of us has to be
---pulsed at -- recording the route they return by is the very thing that reconnects the trail.
---@return boolean isParked
function Follow:IsParked()
    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if (spawn.ID() or 0) < 1 then return false end

    local distance = spawn.Distance3D()
    if distance == nil then return false end
    if self:WithinHold(distance) then return true end

    if distance > warpWaitDistance then
        local head = self._.trail[self._.first]
        local myY = mq.TLO.Me.Y()
        local myX = mq.TLO.Me.X()
        local myZ = mq.TLO.Me.Z()
        if head ~= nil and head.warp and myY ~= nil and myX ~= nil and myZ ~= nil
            and Geometry.Distance3D(myY, myX, myZ, head.y, head.x, head.z) > warpWaitDistance then
            return true
        end
    end

    return false
end

---Called when the movement service will not let us move this frame
function Follow:OnBlocked()
    self._.stuck:Reset()
    self._.unsticker:Reset()
    -- a gap measured either side of the held stretch is not a speed
    self._.lastDistance = nil
    self._.closing = 0
end

function Follow:Stop()
    Locomotion.ReleaseAll()
end

---@return number spawnId
function Follow:GetSpawnId()
    return self._.spawnId
end

---@return string|nil failReason
function Follow:FailReason()
    return self._.failReason
end

---@return string description
function Follow:Describe()
    -- The gap and how fast it is closing, because how close we end up is a pulse of closing
    -- away from where we aimed -- a per-pulse figure that is large is the loop being too slow
    -- to stop on a mark, and no threshold will fix that. The waypoint count says how much of
    -- the target's route is still queued up to be replayed.
    local gap = string.format("%.0f away, %.1f/pulse", self._.lastDistance or 0, self._.closing or 0)

    if self._.warpWaiting then
        return "waiting out " .. self._.name .. "'s warp (" .. tostring(self:TrailSize()) .. " waypoints, " .. gap .. ")"
    end
    return "trailing " .. self._.name .. " (" .. tostring(self:TrailSize()) .. " waypoints, " .. gap .. ")"
end

return Follow
