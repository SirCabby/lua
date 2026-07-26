local Debug = require("utils.Debug.Debug")
local Locomotion = require("utils.Movement.Locomotion")
local Time = require("utils.Time.Time")

---The "we are wedged on something" recovery used by every movement task.
---
---MQ2MoveUtils recovered by nudging the heading a few degrees at a time and flipping the
---direction once it had turned halfway around. That works when the plugin owns the heading;
---our tasks re-face their destination every frame, so a heading nudge would be undone
---immediately. Strafing is the equivalent that survives constant re-facing: keep pushing
---forward, slide sideways along whatever is in the way, and alternate sides on each attempt
---so we work our way around a corner instead of grinding into it. A jump is thrown in as
---well, which clears most knee-high geometry.
---@class Unsticker
local Unsticker = { author = "judged", key = "Unsticker" }

Unsticker.__index = Unsticker
setmetatable(Unsticker, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param str string
local function DebugLog(str)
    Debug.Log(Unsticker.key, str)
end

---@param options? table durationMs (default 600) of a single attempt
---@return Unsticker
function Unsticker.new(options)
    local self = setmetatable({}, Unsticker)
    options = options or {}

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.durationMs = options.durationMs or 600
    self._.untilMs = 0
    self._.direction = Locomotion.keys.strafeRight

    return self
end

---@return boolean isActive true while an attempt is still running
function Unsticker:IsActive()
    return Time.current_time() < self._.untilMs
end

---Start an attempt, alternating which way we slide from the last one
function Unsticker:Begin()
    self._.untilMs = Time.current_time() + self._.durationMs
    if self._.direction == Locomotion.keys.strafeRight then
        self._.direction = Locomotion.keys.strafeLeft
    else
        self._.direction = Locomotion.keys.strafeRight
    end

    DebugLog("Attempting to unstick by strafing [" .. self._.direction .. "]")
    if Locomotion.CanJump() then
        Locomotion.Jump()
    end
end

---Hold the keys for the current attempt. Safe to call every frame while active.
function Unsticker:Drive()
    Locomotion.Hold(Locomotion.keys.forward)
    Locomotion.Hold(self._.direction)
end

function Unsticker:Reset()
    self._.untilMs = 0
end

return Unsticker
