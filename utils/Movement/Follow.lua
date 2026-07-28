local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Locomotion = require("utils.Movement.Locomotion")
local MovementStatus = require("utils.Movement.MovementStatus")
local StuckDetector = require("utils.Movement.StuckDetector")
local Time = require("utils.Time.Time")
local Unsticker = require("utils.Movement.Unsticker")

---Breadcrumb follow of a spawn, the `/afollow` replacement.
---
---Running straight at someone only works while you can see them; the moment they round a
---corner the straight line goes through a wall. So we sample where the spawn has been into
---a trail and walk the trail instead, which reproduces their route around corners and, when
---they leave the zone or our sight, still walks us to the last place they were.
---
---How close we hold is two numbers rather than one: we close to `distance` and then stand still
---until they are `resumeDistance` away, so they get a buffer to move around in instead of being
---shadowed step for step (see `WithinHold`).
---
---Trail bookkeeping worth knowing about:
--- - waypoints are only recorded once the spawn has moved `sampleDistance` from the last one
--- - reaching a waypoint drops it, and a short lookahead drops any earlier ones we have
---   already wandered past, which collapses the backtracking a laggy trail collects
--- - the trail is dropped entirely on any frame the spawn is in line of sight, because with no
---   wall between us there is nothing it can tell us that we cannot see -- see `Pulse`
--- - a big jump in our own position (summon, port, gate) invalidates the trail entirely
---@class Follow : MovementTask
local Follow = { author = "judged", key = "Follow" }

Follow.__index = Follow
setmetatable(Follow, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

-- how many waypoints ahead we look for one we have already reached
local lookaheadWaypoints = 10
-- heading error beyond which running forward would take us somewhere unhelpful
local maxDriftDegrees = 90
-- distance our own position can change in a frame before the trail is meaningless
local selfWarpDistance = 50
local doorRetryMs = 500
local doorDistance = 12
local doorArcDegrees = 50

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
--- - warpDistance: a jump in the spawn's position larger than this restarts the trail, default 100
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
    -- whether we are running at them or walking a trail, cached for Describe (a render path)
    self._.inSight = false
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
function Follow:PushWaypoint(y, x, z)
    self._.last = self._.last + 1
    self._.trail[self._.last] = { y = y, x = x, z = z }

    while self:TrailSize() > self._.maxWaypoints do
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
        DebugLog("Follow target warped " .. tostring(moved) .. ", restarting the trail")
        self:ClearTrail()
        self:PushWaypoint(y, x, z)
    elseif moved >= self._.sampleDistance then
        self:PushWaypoint(y, x, z)
    end
end

---Drop every waypoint up to the furthest one we have already reached
---@param myY number
---@param myX number
---@return table|nil waypoint the next one to walk toward
function Follow:NextWaypoint(myY, myX)
    local lookahead = math.min(self._.last, self._.first + lookaheadWaypoints - 1)
    local reached = nil

    for i = self._.first, lookahead do
        local waypoint = self._.trail[i]
        if Geometry.Distance2D(myY, myX, waypoint.y, waypoint.x) <= self._.waypointGap then
            reached = i
        end
    end

    if reached ~= nil then
        for i = self._.first, reached do
            self._.trail[i] = nil
        end
        self._.first = reached + 1
    end

    return self._.trail[self._.first]
end

---Click open a closed door we are about to run into
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
    local lastSelf = self._.lastSelf
    if lastSelf ~= nil and Geometry.Distance3D(lastSelf.y, lastSelf.x, lastSelf.z, myY, myX, myZ) > selfWarpDistance then
        DebugLog("We moved without walking, dropping the trail")
        self:ClearTrail()
        -- and a gap measured either side of a jump is not a speed
        self._.lastDistance = nil
    end
    self._.lastSelf = { y = myY, x = myX, z = myZ }

    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    local spawnExists = (spawn.ID() or 0) > 0
    if spawnExists then
        local distance = spawn.Distance3D()

        -- **The trail is memory of where they went while we could not see them, and nothing else.**
        --
        -- Its whole reason for existing is the corner: the moment they round one, the straight line
        -- goes through a wall. While we *can* see them there is no wall, so there is nothing the
        -- breadcrumbs can tell us that we cannot see for ourselves -- and following them anyway is
        -- what makes a follow look drunk. They record the leader shuffling about camp and walking
        -- out to pull and back, and setting off along that means retracing every step of it before
        -- heading anywhere, and being carried clean past them on the way: arriving is measured
        -- against the spawn and not against the trail, so a trail that loops out and comes back
        -- walks us out and back too. The wandering and the overshoot are the same bug.
        --
        -- So while they are in sight we run at them and keep no trail at all. What `Record` leaves
        -- behind is a single breadcrumb on where they are standing right now -- which is exactly
        -- the corner they went round, on the frame they go out of sight.
        self._.inSight = spawn.LineOfSight() == true
        if self._.inSight then
            self:ClearTrail()
        end
        self:Record(spawn)

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
            -- close enough; keep recording so the trail stays warm for the next move
            Locomotion.ReleaseAll()
            self._.stuck:Reset()
            self._.unsticker:Reset()
            return MovementStatus.holding
        end
    else
        -- walking a trail out to where they no longer are is not holding station on them, so the
        -- buffer is spent: whenever they turn up again we close on them properly
        self._.holding = false
        self._.inSight = false
        self._.lastDistance = nil
        self._.closing = 0
    end

    local waypoint = self:NextWaypoint(myY, myX)
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

    Locomotion.FaceLoc(waypoint.y, waypoint.x)
    self:OpenDoorAhead()

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
---before it stands them up. A target that is not in the zone is not "close enough": the trail
---still leads somewhere and we should be walking it.
---@return boolean isParked
function Follow:IsParked()
    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if (spawn.ID() or 0) < 1 then return false end

    local distance = spawn.Distance3D()
    return distance ~= nil and self:WithinHold(distance)
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
    -- Which of the two things a follow can be doing, because from the outside they look the same
    -- and only one of them can wander: `/cmove` saying "trailing" with a pile of waypoints is the
    -- reading that says the route is being replayed rather than run.
    --
    -- The gap and how fast it is closing are here for the same reason -- how close we end up is a
    -- pulse of closing away from where we aimed, so a per-pulse figure that is large is the loop
    -- being too slow to stop on a mark, and no threshold will fix that.
    local gap = string.format("%.0f away, %.1f/pulse", self._.lastDistance or 0, self._.closing or 0)

    if self._.inSight then
        return "chasing " .. self._.name .. " (" .. gap .. ")"
    end
    return "trailing " .. self._.name .. " (" .. tostring(self:TrailSize()) .. " waypoints, " .. gap .. ")"
end

return Follow
