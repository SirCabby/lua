local Timer = require("utils.Timer.Timer")

---@class PriorityQueueJob
local PriorityQueueJob = { author = "judged" }

---@meta PriorityQueueJob
function PriorityQueueJob:GetIdentity() end
function PriorityQueueJob:GetPriority() end
function PriorityQueueJob:IsUnique() end
---Is this job visible
---@return boolean - true if visible
function PriorityQueueJob:IsVisible() end
---Reset visibility timer of this job
function PriorityQueueJob:ResetTimer() end
---@return boolean isComplete
function PriorityQueueJob:IsComplete() end
function PriorityQueueJob:Execute() end

---Creates a new job for queueing
---@param identity string Text displayable unique ID
---@param priority number Priority of request to put into the queue, lower number is higher priority
---@param content function The function to be queued for execution, have function return true if it should reset timer and stay queued
---@param time? number Seconds the job goes invisible for once created / read
---@param isUnique? boolean Intended to be a unique job in a queue
---@return PriorityQueueJob newJob The created job
function PriorityQueueJob:new(identity, priority, content, time, isUnique)
    local newJob = {}

    newJob._identity = identity
    newJob._priority = priority
    newJob._timer = Timer:new(time or 0)
    newJob._isUnique = isUnique or false
    newJob._isComplete = false

    function newJob:GetIdentity()
        return newJob._identity
    end

    function newJob:GetPriority()
        return newJob._priority
    end

    function newJob:IsUnique()
        return newJob._isUnique
    end

    function newJob:IsVisible()
        return newJob._timer:timer_expired()
    end

    function newJob:ResetTimer()
        newJob._timer:reset()
    end

    function newJob:IsComplete()
        return newJob._isComplete
    end

    function newJob:Execute()
        if not newJob._isComplete then
            if content() == true then
                newJob:ResetTimer()
            else
                newJob._isComplete = true
            end
        end
    end

    return newJob
end

return PriorityQueueJob