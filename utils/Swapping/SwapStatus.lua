---Result of a single swapping pulse.
---
---`succeeded` and `failed` are terminal: the plan is finished and the swapping service drops the
---task. What separates the two before that is whether anything of the player's has been moved
---yet, which is the only thing that matters to whoever is cleaning up after an abandoned swap:
---in `preparing` nothing has left its slot and dropping the task costs nothing, while in
---`swapping` a slot has already been emptied or filled and walking away would leave gear in a bag
---the player did not put it in.
---@class SwapStatus
local SwapStatus = {
    idle = "idle",
    ---reading the world and getting the first item onto the cursor. Nothing has moved.
    preparing = "preparing",
    ---at least one slot has been changed, so there is something to put back.
    swapping = "swapping",
    succeeded = "succeeded",
    failed = "failed"
}

---@param status string
---@return boolean isTerminal true when the swap is over and will be dropped
function SwapStatus.IsTerminal(status)
    return status == SwapStatus.succeeded or status == SwapStatus.failed
end

---Whether the client is holding gear somewhere the player did not put it, so abandoning this has
---something to undo.
---@param status string
---@return boolean isCommitted
function SwapStatus.IsCommitted(status)
    return status == SwapStatus.swapping
end

return SwapStatus
