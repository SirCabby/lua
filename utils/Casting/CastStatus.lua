---Result of a single casting pulse.
---
---`succeeded` and `failed` are terminal: the cast is finished and the casting service drops
---it. Everything before that is one long "hold everything" -- see `preparing`, which covers
---getting on target, standing still and memorizing, all of which can be interrupted for free,
---and `casting`, which cannot.
---@class CastStatus
local CastStatus = {
    idle = "idle",
    ---getting ready: target, stand still, memorize. Nothing has been committed yet.
    preparing = "preparing",
    ---the cast is in flight. Moving, ducking or taking a hit now loses it.
    casting = "casting",
    succeeded = "succeeded",
    failed = "failed"
}

---@param status string
---@return boolean isTerminal true when the cast is over and will be dropped
function CastStatus.IsTerminal(status)
    return status == CastStatus.succeeded or status == CastStatus.failed
end

---Whether the character is committed: a cast in this state is lost if anything moves us.
---@param status string
---@return boolean isCommitted
function CastStatus.IsCommitted(status)
    return status == CastStatus.casting
end

return CastStatus
