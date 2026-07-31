---Result of a single giving pulse.
---
---`succeeded` and `failed` are terminal: the hand-off is finished and the giving service drops
---it. The two before that are the halves that matter to anyone cleaning up after an abandoned
---give -- see `preparing`, where the item is still ours (on the cursor or in a bag) and dropping
---the task costs nothing, and `giving`, where it is sitting in the give window and walking away
---would leave that window open with our item in it.
---@class GiveStatus
local GiveStatus = {
    idle = "idle",
    ---picking the item up and getting on target. Nothing has left our hands.
    preparing = "preparing",
    ---the give window is open with the item in it, waiting on the Give button.
    giving = "giving",
    succeeded = "succeeded",
    failed = "failed"
}

---@param status string
---@return boolean isTerminal true when the hand-off is over and will be dropped
function GiveStatus.IsTerminal(status)
    return status == GiveStatus.succeeded or status == GiveStatus.failed
end

---Whether the client is holding something of ours that has to be put back if this is abandoned.
---@param status string
---@return boolean isCommitted
function GiveStatus.IsCommitted(status)
    return status == GiveStatus.giving
end

return GiveStatus
