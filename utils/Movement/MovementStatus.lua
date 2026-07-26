---Result of a single movement pulse.
---
---`arrived` and `failed` are terminal: the task is finished and the movement service
---drops it. `holding` means the task is still active and satisfied (in stick range, close
---enough to the follow target) with the movement keys released.
---@class MovementStatus
local MovementStatus = {
    idle = "idle",
    moving = "moving",
    holding = "holding",
    blocked = "blocked",
    arrived = "arrived",
    failed = "failed"
}

---@param status string
---@return boolean isTerminal true when the task is done and will be dropped
function MovementStatus.IsTerminal(status)
    return status == MovementStatus.arrived or status == MovementStatus.failed
end

return MovementStatus
