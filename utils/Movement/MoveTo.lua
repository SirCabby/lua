local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Locomotion = require("utils.Movement.Locomotion")
local MovementStatus = require("utils.Movement.MovementStatus")
local StuckDetector = require("utils.Movement.StuckDetector")
local Time = require("utils.Time.Time")
local Unsticker = require("utils.Movement.Unsticker")

---Straight line move to a location or a spawn, the `/moveto` replacement.
---
---There is no pathfinding here on purpose: this walks the straight line, notices when that
---is not working, and gives up with a reason so the caller can do something smarter.
---@class MoveTo : MovementTask
local MoveTo = { author = "judged", key = "MoveTo" }

MoveTo.__index = MoveTo
setmetatable(MoveTo, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

-- heading error beyond which running forward would take us somewhere unhelpful
local maxDriftDegrees = 90

---@param str string
local function DebugLog(str)
    Debug.Log(MoveTo.key, str)
end

---@param options table
--- - y, x: destination, when moving to a fixed location
--- - spawnId: chase this spawn's current location instead
--- - distance: how close counts as arrived, default 10
--- - timeoutMs: give up after this long, default 30000, false to disable
--- - nudgeAfter: stalled windows before trying to unstick, default 2
--- - failAfter: stalled windows before giving up, default 12
--- - owner: key of whoever asked for the move
---@return MoveTo
function MoveTo.new(options)
    local self = setmetatable({}, MoveTo)
    options = options or {}

    self.key = MoveTo.key
    self.owner = options.owner

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.y = options.y
    self._.x = options.x
    self._.spawnId = options.spawnId
    -- resolved once: Describe() is read by UI panels every rendered frame, and a spawn
    -- search does not belong in the render path
    if options.spawnId ~= nil then
        self._.name = mq.TLO.Spawn("id " .. tostring(options.spawnId)).CleanName() or tostring(options.spawnId)
    end
    self._.distance = options.distance or 10
    self._.nudgeAfter = options.nudgeAfter or 2
    self._.failAfter = options.failAfter or 12
    self._.failReason = nil
    self._.stuck = StuckDetector.new()
    self._.unsticker = Unsticker.new()

    if options.timeoutMs == false then
        self._.deadlineMs = nil
    else
        self._.deadlineMs = Time.current_time() + (options.timeoutMs or 30000)
    end

    return self
end

---@param reason string
---@return string status
function MoveTo:Fail(reason)
    self._.failReason = reason
    DebugLog("Move failed: " .. reason)
    Locomotion.ReleaseAll()
    return MovementStatus.failed
end

---@return number|nil y
---@return number|nil x
function MoveTo:Destination()
    if self._.spawnId == nil then
        return self._.y, self._.x
    end

    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if (spawn.ID() or 0) < 1 then return nil, nil end
    return spawn.Y(), spawn.X()
end

---@return string status
function MoveTo:Pulse()
    local y, x = self:Destination()
    if y == nil or x == nil then
        if self._.spawnId ~= nil then
            return self:Fail("target spawn is gone")
        end
        return self:Fail("no destination")
    end

    local myY = mq.TLO.Me.Y()
    local myX = mq.TLO.Me.X()
    if myY == nil or myX == nil then
        Locomotion.ReleaseAll()
        return MovementStatus.blocked
    end

    local distance = Geometry.Distance2D(myY, myX, y, x)
    if distance <= self._.distance then
        Locomotion.ReleaseAll()
        return MovementStatus.arrived
    end

    if self._.deadlineMs ~= nil and Time.current_time() > self._.deadlineMs then
        return self:Fail("timed out short of the destination")
    end

    if self._.stuck:StalledWindows() >= self._.failAfter then
        return self:Fail("stuck short of the destination")
    end

    Locomotion.FaceLoc(y, x)

    if self._.unsticker:IsActive() then
        self._.unsticker:Drive()
    elseif self._.stuck:StalledWindows() >= self._.nudgeAfter then
        self._.unsticker:Begin()
        self._.unsticker:Drive()
    else
        local drift = math.abs(Geometry.HeadingDiff(Locomotion.GetHeading(), Geometry.HeadingTo(myY, myX, y, x)))
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

---Called when the movement service will not let us move this frame
function MoveTo:OnBlocked()
    self._.stuck:Reset()
    self._.unsticker:Reset()
end

function MoveTo:Stop()
    Locomotion.ReleaseAll()
end

---@return number|nil spawnId
function MoveTo:GetSpawnId()
    return self._.spawnId
end

---@return string|nil failReason
function MoveTo:FailReason()
    return self._.failReason
end

---@return string description
function MoveTo:Describe()
    if self._.spawnId ~= nil then
        return "moving to " .. self._.name
    end
    return string.format("moving to loc %.0f, %.0f", self._.y or 0, self._.x or 0)
end

return MoveTo
