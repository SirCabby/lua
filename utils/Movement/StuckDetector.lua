local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Time = require("utils.Time.Time")

---Travelled-path stuck detection over fixed wall-clock windows.
---
---Stuck means wedged: asking the character to move and the character not moving. So the thing
---to measure is the path actually walked -- every sample's displacement, summed -- and not the
---net start-to-end displacement of a window. Net displacement cannot tell wedged from orbiting:
---a character that overshoots a mark, flips around and runs back crosses its own start point
---all window long, nets out to nothing, and reads as stalled while sprinting -- and the
---unsticker it arms then jumps and strafes a character that was never wedged. Summed travel
---keeps those apart: wedged is the only way it stays near zero.
---
---MQ2MoveUtils averaged movement across a pulse count, which ties the thresholds to how
---often the plugin happens to be pulsed. Sampling over a time window instead keeps the
---behavior the same whether the caller runs at 25ms or 100ms per frame.
---@class StuckDetector
local StuckDetector = { author = "judged", key = "StuckDetector" }

StuckDetector.__index = StuckDetector
setmetatable(StuckDetector, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param str string
local function DebugLog(str)
    Debug.Log(StuckDetector.key, str)
end

---@param options? table windowMs (default 500), minDistance (default 1.0)
---@return StuckDetector
function StuckDetector.new(options)
    local self = setmetatable({}, StuckDetector)
    options = options or {}

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.windowMs = options.windowMs or 500
    self._.minDistance = options.minDistance or 1.0
    self._.stalledWindows = 0
    self._.cleanWindows = 0
    self._.windowStartMs = 0
    self._.travelled = 0
    self._.y = 0
    self._.x = 0
    self._.z = 0

    self:Reset()

    return self
end

---Forget any accumulated stall and restart the window from where we are now
function StuckDetector:Reset()
    self._.stalledWindows = 0
    self._.windowStartMs = Time.current_time()
    self._.travelled = 0
    self._.y = mq.TLO.Me.Y() or 0
    self._.x = mq.TLO.Me.X() or 0
    self._.z = mq.TLO.Me.Z() or 0
end

---Sample progress for this frame
---@param isTryingToMove boolean false when we are not asking the character to move, which resets the window
---@return number stalledWindows consecutive windows without meaningful movement
function StuckDetector:Update(isTryingToMove)
    if not isTryingToMove then
        self:Reset()
        return 0
    end

    local y = mq.TLO.Me.Y() or 0
    local x = mq.TLO.Me.X() or 0
    local z = mq.TLO.Me.Z() or 0
    self._.travelled = self._.travelled + Geometry.Distance3D(self._.y, self._.x, self._.z, y, x, z)
    self._.y = y
    self._.x = x
    self._.z = z

    local now = Time.current_time()
    if now - self._.windowStartMs < self._.windowMs then
        return self._.stalledWindows
    end

    if self._.travelled < self._.minDistance then
        self._.stalledWindows = self._.stalledWindows + 1
        DebugLog("Stalled window " .. tostring(self._.stalledWindows) .. ", travelled " .. tostring(self._.travelled))
    else
        self._.stalledWindows = 0
        self._.cleanWindows = self._.cleanWindows + 1
    end

    self._.windowStartMs = now
    self._.travelled = 0

    return self._.stalledWindows
end

---@return number stalledWindows consecutive windows without meaningful movement
function StuckDetector:StalledWindows()
    return self._.stalledWindows
end

---Lifetime count of windows that closed with real travel in them. It only grows -- `Reset`
---deliberately leaves it alone -- so a caller can hold one value and later ask "have we moved
---cleanly since?", which is how the unsticker tells a wedge that survived its last attempt
---from a fresh snag somewhere further along.
---@return number cleanWindows
function StuckDetector:CleanWindows()
    return self._.cleanWindows
end

return StuckDetector
