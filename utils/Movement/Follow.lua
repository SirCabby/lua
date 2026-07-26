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
---Trail bookkeeping worth knowing about:
--- - waypoints are only recorded once the spawn has moved `sampleDistance` from the last one
--- - reaching a waypoint drops it, and a short lookahead drops any earlier ones we have
---   already wandered past, which collapses the backtracking a laggy trail collects
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
--- - distance: how close we hold to the spawn, default 10
--- - sampleDistance: how far the spawn moves before a new waypoint, default 5
--- - waypointGap: how close counts as reaching a waypoint, default 5
--- - maxWaypoints: trail cap, oldest dropped first, default 250
--- - warpDistance: a jump in the spawn's position larger than this restarts the trail, default 100
--- - openDoors: click closed doors we run into, default true
--- - nudgeAfter / failAfter: stalled windows before unsticking / giving up, default 2 / 20
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
    self._.sampleDistance = options.sampleDistance or 5
    self._.waypointGap = options.waypointGap or 5
    self._.maxWaypoints = options.maxWaypoints or 250
    self._.warpDistance = options.warpDistance or 100
    self._.openDoors = options.openDoors ~= false
    self._.nudgeAfter = options.nudgeAfter or 2
    self._.failAfter = options.failAfter or 20
    self._.zoneId = mq.TLO.Zone.ID()
    self._.failReason = nil
    self._.lastSelf = nil
    self._.lastDoorMs = 0
    self._.trail = {}
    self._.first = 1
    self._.last = 0
    self._.stuck = StuckDetector.new()
    self._.unsticker = Unsticker.new()

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
    end
    self._.lastSelf = { y = myY, x = myX, z = myZ }

    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    local spawnExists = (spawn.ID() or 0) > 0
    if spawnExists then
        self:Record(spawn)

        local distance = spawn.Distance3D()
        if distance ~= nil and distance <= self._.distance then
            -- close enough; keep recording so the trail stays warm for the next move
            Locomotion.ReleaseAll()
            self._.stuck:Reset()
            self._.unsticker:Reset()
            return MovementStatus.holding
        end
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

    if self._.stuck:StalledWindows() >= self._.failAfter then
        return self:Fail("stuck while following")
    end

    Locomotion.FaceLoc(waypoint.y, waypoint.x)
    self:OpenDoorAhead()

    if self._.unsticker:IsActive() then
        self._.unsticker:Drive()
    elseif self._.stuck:StalledWindows() >= self._.nudgeAfter then
        self._.unsticker:Begin()
        self._.unsticker:Drive()
    else
        Locomotion.ReleaseStrafe()
        Locomotion.Hold(Locomotion.keys.forward)
    end

    self._.stuck:Update(not Locomotion.IsRooted())
    return MovementStatus.moving
end

---Called when the movement service will not let us move this frame
function Follow:OnBlocked()
    self._.stuck:Reset()
    self._.unsticker:Reset()
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
    return "following " .. self._.name .. " (" .. tostring(self:TrailSize()) .. " waypoints)"
end

return Follow
