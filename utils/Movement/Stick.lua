local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Locomotion = require("utils.Movement.Locomotion")
local MovementStatus = require("utils.Movement.MovementStatus")
local StuckDetector = require("utils.Movement.StuckDetector")
local Unsticker = require("utils.Movement.Unsticker")

---Hold position on a spawn, the `/stick` replacement.
---
---Two modes are supported. `loose` is `/stick <dist> loose`: stay faced at the spawn and
---hold the requested distance, which is all a melee attacker needs. `behind` adds the
---strafing arc work of `/stick behind`: while inside three times the stick distance, slide
---around the spawn until our heading is close to its heading, which is where you end up
---when you are behind something you are facing.
---
---The single-target break conditions from MQ2MoveUtils that still matter are here (target
---gone, target dead, target is us, target warped); the settings sprawl around them is not.
---@class Stick : MovementTask
local Stick = { author = "judged", key = "Stick" }

Stick.__index = Stick
setmetatable(Stick, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

Stick.modes = {
    loose = "loose",
    behind = "behind"
}

-- how much closer than the stick distance we tolerate before backing up
local moveBackSlack = 5

---@param str string
local function DebugLog(str)
    Debug.Log(Stick.key, str)
end

---@param spawnId number
---@param options? table
--- - distance: distance to hold, default 10
--- - mode: Stick.modes.loose (default) or Stick.modes.behind
--- - moveBack: back up when the spawn crowds us, default true
--- - arcBehind: half-arc for behind mode, in degrees, default 45
--- - warpDistance: a jump in distance larger than this is treated as a warp, default 75
--- - nudgeAfter / failAfter: stalled windows before unsticking / giving up, default 2 / 20
--- - owner: key of whoever asked for the stick
---@return Stick
function Stick.new(spawnId, options)
    local self = setmetatable({}, Stick)
    options = options or {}

    self.key = Stick.key
    self.owner = options.owner

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.spawnId = spawnId
    -- resolved once: Describe() is read by UI panels every rendered frame, and a spawn
    -- search does not belong in the render path
    self._.name = mq.TLO.Spawn("id " .. tostring(spawnId)).CleanName() or tostring(spawnId)
    self._.distance = options.distance or 10
    self._.mode = options.mode or Stick.modes.loose
    self._.moveBack = options.moveBack ~= false
    self._.arcBehind = options.arcBehind or 45
    self._.warpDistance = options.warpDistance or 75
    self._.nudgeAfter = options.nudgeAfter or 2
    self._.failAfter = options.failAfter or 20
    self._.lastDistance = nil
    self._.failReason = nil
    self._.stuck = StuckDetector.new()
    self._.unsticker = Unsticker.new()

    return self
end

---@param spawnId number
---@return number distance the usual melee hold distance for a spawn
function Stick.MeleeDistance(spawnId)
    local maxRangeTo = mq.TLO.Spawn("id " .. tostring(spawnId)).MaxRangeTo()
    if maxRangeTo == nil then return 14 end
    return math.min(14, maxRangeTo - 3)
end

---@param reason string
---@return string status
function Stick:Fail(reason)
    self._.failReason = reason
    DebugLog("Stick failed: " .. reason)
    Locomotion.ReleaseAll()
    return MovementStatus.failed
end

---Slide around the spawn until we are inside its rear arc
---@param spawn spawn
---@param distance number
function Stick:HoldArc(spawn, distance)
    if self._.mode ~= Stick.modes.behind or distance > self._.distance * 3 then
        Locomotion.ReleaseStrafe()
        return
    end

    local spawnHeading = spawn.Heading.DegreesCCW()
    if spawnHeading == nil then
        Locomotion.ReleaseStrafe()
        return
    end

    -- while we face the spawn, the gap between our heading and its heading is how far
    -- around it we still have to travel; zero means we are directly behind it
    local arc = Geometry.HeadingDiff(Locomotion.GetHeading(), spawnHeading)
    if math.abs(arc) <= self._.arcBehind then
        Locomotion.ReleaseStrafe()
    elseif arc < 0 then
        Locomotion.Hold(Locomotion.keys.strafeLeft)
    else
        Locomotion.Hold(Locomotion.keys.strafeRight)
    end
end

---@return string status
function Stick:Pulse()
    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if (spawn.ID() or 0) < 1 then
        return self:Fail("stick target is gone")
    end
    if spawn.Dead() or spawn.Type() == "Corpse" then
        return self:Fail("stick target is dead")
    end
    if self._.spawnId == mq.TLO.Me.ID() then
        return self:Fail("cannot stick to self")
    end

    local distance = spawn.Distance()
    local y = spawn.Y()
    local x = spawn.X()
    if distance == nil or y == nil or x == nil then
        Locomotion.ReleaseAll()
        return MovementStatus.blocked
    end

    -- a spawn that jumped across the zone is a warp, not something to chase down
    if self._.lastDistance ~= nil and distance - self._.lastDistance > self._.warpDistance then
        DebugLog("Stick target warped " .. tostring(distance - self._.lastDistance) .. ", holding")
        self._.lastDistance = distance
        self:OnBlocked()
        Locomotion.ReleaseAll()
        return MovementStatus.blocked
    end
    self._.lastDistance = distance

    Locomotion.FaceLoc(y, x)
    self:HoldArc(spawn, distance)

    if distance > self._.distance then
        if self._.stuck:StalledWindows() >= self._.failAfter then
            return self:Fail("could not reach the stick target")
        end

        if self._.unsticker:IsActive() then
            self._.unsticker:Drive()
        elseif self._.stuck:StalledWindows() >= self._.nudgeAfter then
            self._.unsticker:Begin()
            self._.unsticker:Drive()
        else
            Locomotion.Hold(Locomotion.keys.forward)
        end

        self._.stuck:Update(not Locomotion.IsRooted())
        return MovementStatus.moving
    end

    self._.stuck:Reset()
    self._.unsticker:Reset()

    if self._.moveBack and distance < self._.distance - moveBackSlack then
        Locomotion.Hold(Locomotion.keys.backward)
        return MovementStatus.moving
    end

    Locomotion.ReleaseForwardBack()
    if Locomotion.IsMoving() then
        return MovementStatus.moving
    end
    return MovementStatus.holding
end

---Called when the movement service will not let us move this frame
function Stick:OnBlocked()
    self._.stuck:Reset()
    self._.unsticker:Reset()
end

function Stick:Stop()
    Locomotion.ReleaseAll()
end

---@return number spawnId
function Stick:GetSpawnId()
    return self._.spawnId
end

---@return string|nil failReason
function Stick:FailReason()
    return self._.failReason
end

---@return string description
function Stick:Describe()
    return "sticking " .. self._.mode .. " to " .. self._.name .. " at " .. tostring(self._.distance)
end

return Stick
