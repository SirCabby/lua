local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Locomotion = require("utils.Movement.Locomotion")
local Time = require("utils.Time.Time")

---"Have we stopped moving long enough to cast?"
---
---A cast is lost the moment the character moves, and a character that has *just* stopped is
---still moving as far as the server is concerned -- the client has released the key, the server
---has not caught up. So being still is not one check but two: the client says we are stopped,
---and we have been stopped for a settle window on top of that. MQ2Cast waits half a second
---after speed reaches zero for the same reason.
---
---This module only answers the question. Cancelling whatever *asked* the character to move
---belongs to the caller, which is the only thing that knows whether it is allowed to
---(`CastTask` weighs the cast's priority against the movement task's owner). The one exception
---is the back-tap below, which cancels a movement nothing in this script owns.
---@class Immobilizer
local Immobilizer = {
    author = "judged",
    key = "Immobilizer",
    results = {
        settled = "settled",
        waiting = "waiting",
        timedOut = "timedOut"
    }
}
Immobilizer.__index = Immobilizer

setmetatable(Immobilizer, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

local standRetryMs = 1000

---@param str string
local function DebugLog(str)
    Debug.Log(Immobilizer.key, str)
end

---@param options? table settleMs: how long stopped is stopped (default 250), timeoutMs: give up
---after this long (default 4000)
---@return Immobilizer
function Immobilizer.new(options)
    options = options or {}
    local self = setmetatable({}, Immobilizer)

---@diagnostic disable-next-line: inject-field
    self._ = {
        settleMs = options.settleMs or 250,
        timeoutMs = options.timeoutMs or 4000,
        startedMs = Time.current_time(),
        -- nil means "has not been seen moving", so a character already standing still settles
        -- on the first pulse instead of paying the window for nothing
        lastMovingMs = nil,
        lastStandMs = 0,
        tappedBack = false,
        reason = nil
    }

    return self
end

---Stand up out of anything that cannot cast. Throttled: the state does not change until the
---server answers, and spamming /stand every frame in the meantime does nothing but spam.
---@return boolean isStanding
local function standIfNeeded(self)
    local state = tostring(mq.TLO.Me.State() or "")

    -- HOVER is dead-but-not-released, which cannot cast either, but /stand will not fix it;
    -- MOUNT can cast, so it counts as standing
    if state == "STAND" or state == "MOUNT" then return true end
    if state ~= "SIT" and state ~= "DUCK" and state ~= "FEIGN" then return false end

    local now = Time.current_time()
    if now - self._.lastStandMs >= standRetryMs then
        self._.lastStandMs = now
        DebugLog("Standing up out of [" .. state .. "] to cast")
        mq.cmd("/stand")
    end
    return false
end

---One frame of waiting to be still. **Main loop only** -- it stands the character up and may
---tap a movement key.
---@return string result one of Immobilizer.results
function Immobilizer:Pulse()
    local now = Time.current_time()
    local isStanding = standIfNeeded(self)

    if mq.TLO.Me.Moving() then
        self._.lastMovingMs = now

        -- Something is moving us that this script is not holding a key for: autorun, or EQ's
        -- own /follow. One tap of a movement key cancels both, and it is the same trick
        -- MQ2Cast uses before a cast. Once per attempt -- if a tap did not stop it, tapping
        -- again every frame will not either, and the timeout below is the honest answer.
        if not Locomotion.IsMoving() and not self._.tappedBack then
            self._.tappedBack = true
            DebugLog("Moving with no key of ours held; tapping back to cancel autorun")
            mq.cmd("/keypress back")
        end
    end

    if not isStanding then
        self._.reason = "standing up"
    elseif self._.lastMovingMs ~= nil and now - self._.lastMovingMs < self._.settleMs then
        self._.reason = "settling"
    elseif mq.TLO.Me.Moving() then
        self._.reason = "moving"
    else
        self._.reason = nil
        return Immobilizer.results.settled
    end

    if now - self._.startedMs >= self._.timeoutMs then
        return Immobilizer.results.timedOut
    end

    return Immobilizer.results.waiting
end

---@return string|nil reason what we are still waiting on, nil once settled
function Immobilizer:Reason()
    return self._.reason
end

return Immobilizer
