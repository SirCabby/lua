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
---so we work our way around a corner instead of grinding into it.
---
---The response escalates with the evidence rather than opening with everything at once. One
---stall means very little -- a door frame, a torch post, somebody's pet stood in the way --
---and the strafe alone slides past nearly all of it without a visible twitch. A jump clears
---knee-high geometry, but a character hopping mid-run reads as a player pressing keys, so it
---waits until a strafe attempt against this same wedge has provably failed: attempts two and
---onward jump, the first only slides.
---
---An attempt also consumes the stall that justified it (see `Begin`), so consecutive attempts
---and the give-up decision above them run on evidence gathered after the last try -- never on
---a stale count an earlier attempt already fixed.
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

---@param detector StuckDetector the evidence this unsticker answers: beginning an attempt
---consumes its stall, and its clean-window count is how consecutive attempts against one
---wedge are told apart from attempts against different snags along the way
---@param options? table durationMs (default 600) of a single attempt
---@return Unsticker
function Unsticker.new(detector, options)
    local self = setmetatable({}, Unsticker)
    options = options or {}

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.detector = detector
    self._.durationMs = options.durationMs or 600
    self._.untilMs = 0
    self._.direction = Locomotion.keys.strafeRight
    self._.streak = 0
    self._.cleanSeen = nil

    return self
end

---@return boolean isActive true while an attempt is still running
function Unsticker:IsActive()
    return Time.current_time() < self._.untilMs
end

---How many attempts in a row have gone against the same wedge, judged by whether any clean
---window of travel closed since the last one. This is the caller's give-up evidence: each
---count is a distinct recovery that provably did not free us -- attempts, not clock.
---@return number streak
function Unsticker:Streak()
    return self._.streak
end

---Start an attempt, alternating which way we slide from the last one. Jumps only once a
---previous attempt against this same wedge has failed -- see the note on this module.
function Unsticker:Begin()
    local clean = self._.detector:CleanWindows()
    if self._.cleanSeen == clean then
        self._.streak = self._.streak + 1
    else
        self._.streak = 1
    end
    self._.cleanSeen = clean
    -- the attempt eats the evidence that called for it: whatever the stall looks like next
    -- time is measured from here, with this attempt's effect in it
    self._.detector:Reset()

    self._.untilMs = Time.current_time() + self._.durationMs
    if self._.direction == Locomotion.keys.strafeRight then
        self._.direction = Locomotion.keys.strafeLeft
    else
        self._.direction = Locomotion.keys.strafeRight
    end

    DebugLog("Unstick attempt " .. tostring(self._.streak) .. ", strafing [" .. self._.direction .. "]")
    if self._.streak >= 2 and Locomotion.CanJump() then
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
    self._.streak = 0
    self._.cleanSeen = nil
end

return Unsticker
