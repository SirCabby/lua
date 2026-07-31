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
---   in the trail it is
--- - standing on a waypoint means being inside `waypointGap` of it or having run past it;
---   being merely *near* one we are still running at is not reaching it (see `PopReached`)
--- - a route that comes back to itself has the loop cut out of it, which is what keeps the
---   leader's camp wander from stockpiling while we are parked (see `PruneLoop`)
--- - standing at the target clears a warp seam and nothing else; what is *between* us and them
---   is the part of their route that is not history yet, and it is what we walk when they
---   move off (see `ClearSeams` and the hold branch of `Pulse`)
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
-- cap on how much of one pulse of our own travel counts as having run past a waypoint:
-- comfortably past any honest pulse of running, small enough that one hitch cannot swallow a
-- whole corner leg
local passedTravelCap = 20
-- heading error at which a waypoint is back the way we came rather than ahead of us
local passedArcDegrees = 90
-- How much of one pulse of running counts as standing on a breadcrumb (see Pulse). Both edges of
-- this are failure modes, and a corridor harness swept over corner shapes, start offsets and
-- speeds (2026-07) puts the floor of the bowl at 0.75:
--  - too wide (1.0 and up) is a radius that reaches the far side of a corner apex, so corners are
--    clipped; by 1.5 it is the travel-widened reach that wedged followers on corners outright
--  - too narrow (0.5 and down) is a pop scan that cannot keep up with the ground we cover: the
--    breadcrumbs we walk over are missed instead of retired, the trail drains at the one a pulse
--    `PassedHead` can manage, and a follower steering at breadcrumbs it has long since passed
--    stops making sense of its own route
local gapTravelScale = 0.75
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
--- - sampleDistance: how far the spawn moves before a new waypoint, default 3
--- - waypointGap: how close counts as reaching a waypoint, default 3
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
    -- How finely the leader's route is recorded, and the closest we ever require to have walked
    -- it. A corner only exists in the trail if a breadcrumb landed near its apex, and the follower
    -- only walks the corner if it has to reach that breadcrumb rather than clip past it -- so
    -- these are one setting in two halves and neither is worth moving alone. Tightened from 5
    -- (2026-07, at the user's direction: followers were catching corners in dungeon halls).
    --
    -- `waypointGap` is the floor rather than the whole answer: the gap in force is scaled to how
    -- far we are actually travelling per pulse (see Pulse), because standing on a breadcrumb is
    -- not a distance a character moving 11 units a frame can hold to. The floor is what a
    -- standstill and a creep get, and it is never wider than the spacing -- a route recorded more
    -- finely than it is walked is a route not walked.
    self._.sampleDistance = options.sampleDistance or 3
    self._.waypointGap = math.min(options.waypointGap or 3, self._.sampleDistance)
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

---Cut the loop out of a route that has come back to itself.
---
---A target standing at a breadcrumb they already left has walked a loop, and nobody needs to walk
---a loop: the camp wander around a parked follower, the pacing sentry, the two-step rubber-band a
---laggy link records. So the excursion between the breadcrumb they are back on and the newest one
---is dropped, and the route resumes from the one they returned to.
---
---This is the only thing keeping the trail short while we are parked, now that arriving retires
---the route once instead of every pulse -- and unlike a retire it cannot invent a shortcut. The
---join it leaves is between two points a breadcrumb apart, so what is left is always a stretch of
---the route the target actually walked, never a line across the middle of one. That is the whole
---reason the test is "are they back *on* a breadcrumb" rather than anything about distance to us:
---the follower's position says nothing about which of the target's ground is walkable.
---
---A seam in the dropped stretch stops it. Everything after a warp is on the far side of a jump,
---and rejoining across one would claim a leg nobody walked -- the one thing this must never do.
---@param y number
---@param x number
---@param z number
function Follow:PruneLoop(y, x, z)
    -- oldest first: the earliest breadcrumb they are back on cuts the biggest loop
    for i = self._.first, self._.last - 1 do
        local waypoint = self._.trail[i]
        if Geometry.Distance3D(y, x, z, waypoint.y, waypoint.x, waypoint.z) <= self._.sampleDistance then
            for j = i + 1, self._.last do
                if self._.trail[j].warp then return end
            end

            DebugLog("Follow target came back to a breadcrumb, cutting " ..
                tostring(self._.last - i) .. " waypoints of loop")
            for j = i + 1, self._.last do
                self._.trail[j] = nil
            end
            self._.last = i
            return
        end
    end
end

---Drop the trail through the newest warp seam, for a follower standing at the target.
---
---A seam says the leg into it is a jump nobody walked, which is why the trail is walked *to* one
---and no further. Being at the target settles that question a different way: however they got
---there and however we got here, we are together, so every jump their route records is behind us.
---This is the one thing being parked genuinely proves, and the only thing it is allowed to retire.
function Follow:ClearSeams()
    local newest = nil
    for i = self._.first, self._.last do
        if self._.trail[i].warp then newest = i end
    end
    if newest == nil then return end

    DebugLog("Standing with the follow target, clearing " ..
        tostring(newest - self._.first + 1) .. " waypoints through their last warp")
    for i = self._.first, newest do
        self._.trail[i] = nil
    end
    self._.first = newest + 1
end

---Extend the trail when the spawn has moved far enough from the last breadcrumb
---@param spawn spawn
function Follow:Record(spawn)
    local y = spawn.Y()
    local x = spawn.X()
    local z = spawn.Z()
    if y == nil or x == nil or z == nil then return end

    -- before measuring against the newest breadcrumb, because a target back on an old one has no
    -- new route to record: the loop cut leaves them standing on the head of the trail again
    self:PruneLoop(y, x, z)

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
---skipping to the join is the only honest reading.
---
---Standing on a waypoint is a 3D fact. Measured flat, the breadcrumb three units away but
---thirty below -- the ledge hop, the bottom of the ramp we are at the top of -- reads as
---reached, and dropping it skips the one place the leader's route went *down*: the follower
---aims past the descent point and walks off whatever the leader climbed down. Cut corners in
---trail mode traced back to exactly this.
---
---One waypoint is reachable without being stood on: the head, when we have already run past it
---(`PassedHead`). Overshooting is what a background frame rate does to a fixed radius -- a pulse
---covers real ground, and a waypoint stepped over from five units short to five units long is
---never inside its radius, so it is faced again, run back to, and orbited.
---@param myY number
---@param myX number
---@param myZ number
---@param gap number how close counts as standing on a waypoint this pulse
---@param passedRadius number how far past the head waypoint one pulse could have carried us
---@return number popped how many waypoints were dropped
function Follow:PopReached(myY, myX, myZ, gap, passedRadius)
    local reached = nil
    for i = self._.first, self._.last do
        local waypoint = self._.trail[i]
        if Geometry.Distance3D(myY, myX, myZ, waypoint.y, waypoint.x, waypoint.z) <= gap then
            reached = i
        end
    end
    -- asked only when nothing was stood on, both because a later waypoint already covers the
    -- head and because this is the branch that reads our heading
    if reached == nil and self:PassedHead(myY, myX, myZ, passedRadius) then
        reached = self._.first
    end
    if reached == nil then return 0 end

    local popped = reached - self._.first + 1
    for i = self._.first, reached do
        self._.trail[i] = nil
    end
    self._.first = reached + 1
    return popped
end

---Whether the head waypoint is behind us: run past rather than run up to.
---
---Overshoot is the one thing a fixed reached-radius cannot see, and the first fix for it was to
---widen that radius by our own per-pulse travel. That is what a follower cutting corners looks
---like from the inside: at background frame rates the widened radius reached tens of units, so
---the breadcrumb sitting *on* the corner was retired while we were still a hallway short of it,
---the aim moved to the waypoint around the corner, and the follower drove into the wall between
---them -- the corner apex being exactly where a trail follow can least afford to steer early.
---Distance was never the question. A waypoint dead ahead has not been reached however close it
---is; one behind us has been, however we got there. So this asks direction, and asks it only
---within the ground one pulse could have covered -- a waypoint far behind us is not an overshoot,
---it is us being off the route, and the way back onto the route is to walk to it.
---
---Our heading is the reading it is because of when this is asked: at the top of a pulse we are
---still facing wherever last pulse aimed us, which was this waypoint (`Pulse` calls `FaceLoc`
---after this). So a head that now reads as behind us is one we ran through.
---@param myY number
---@param myX number
---@param myZ number
---@param radius number how far past it one pulse could have carried us
---@return boolean passed
function Follow:PassedHead(myY, myX, myZ, radius)
    if radius <= 0 then return false end

    local head = self._.trail[self._.first]
    if head == nil then return false end
    if Geometry.Distance3D(myY, myX, myZ, head.y, head.x, head.z) > radius then return false end

    local toHead = Geometry.HeadingTo(myY, myX, head.y, head.x)
    return math.abs(Geometry.HeadingDiff(Locomotion.GetHeading(), toHead)) > passedArcDegrees
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

    -- Both reached tests are measured in the ground this pulse of running actually covered,
    -- because that is the resolution the character has: a fixed radius means one thing to a
    -- walker and another to a sprinting Sow'd bard, and it is the pulse of travel -- not the run
    -- speed the client reports -- that says which. Travel is the honest number twice over: it is
    -- already the frame rate, the lag and the wall we are pressed against, all folded in.
    -- - `gap`: how close counts as standing on a breadcrumb, under a step so the trail is walked
    --   rather than clipped, and floored at waypointGap for a standstill.
    -- - `passedRadius`: how far past the head one pulse could already have carried us, the only
    --   distance an overshoot can be hiding in (see PassedHead), leaning past a full pulse for
    --   the actuation lag `Locomotion.leadPulses` exists for.
    local pulseTravel = math.min(passedTravelCap, travelled)
    local gap = math.max(self._.waypointGap, pulseTravel * gapTravelScale)
    local passedRadius = pulseTravel * Locomotion.leadPulses
    local popped = self:PopReached(myY, myX, myZ, gap, passedRadius)

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
            -- Standing with them retires a warp seam, and only a warp seam. Whatever jump their
            -- route records, we are past it: we are next to them. Nothing else in the task can
            -- clear one -- a seam is never walked over, so `PopReached` will not drop it -- and a
            -- follower that unparks onto a stale seam stands at it waiting for a world that has
            -- already changed.
            --
            -- What this used to do was retire the *whole* trail, every parked pulse, on the
            -- reasoning that arriving makes everything before it history. It does not: their
            -- route between us and them is exactly the part that is not history yet. Discarding
            -- it as fast as it is recorded leaves nothing to steer at on unpark but wherever they
            -- have already got to -- a blind straight line of up to `resumeDistance` through
            -- whatever is in between. A follower that keeps catching up (a leader on foot, boxes
            -- at the same speed or better) does that at every corner, and drives into the wall at
            -- every corner (2026-07: 11 of 14 wedged runs in the corridor harness, and the last
            -- two were this same retire firing while the leader was mid-corner). Parked is not a
            -- reason to stop banking where they went; it is a reason to stop walking. What keeps
            -- the trail short is what has always kept it short -- walking it (`PopReached`) --
            -- plus their own loops coming out of it (`PruneLoop`).
            self:ClearSeams()
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
