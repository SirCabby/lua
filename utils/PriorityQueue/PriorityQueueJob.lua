---@diagnostic disable: undefined-field
local Timer = require("utils.Time.Timer")

---@class PriorityQueueJob
local PriorityQueueJob = { author = "judged" }

PriorityQueueJob.__index = PriorityQueueJob
setmetatable(PriorityQueueJob, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---Creates a new job for queueing
---@param identity string Text displayable unique ID
---@param priority number Priority of request to put into the queue, lower number is higher priority
---@param content function The function to be queued for execution, have function return true if it should reset timer and stay queued
---@param timeMs? number Milliseconds the job goes invisible for once created / read
---@param isUnique? boolean Intended to be a unique job in a queue
---@return PriorityQueueJob newJob The created job
function PriorityQueueJob.new(identity, priority, content, timeMs, isUnique)
    local self = setmetatable({}, PriorityQueueJob)

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.identity = identity
    self._.priority = priority
    self._.content = content
    self._.timer = Timer.new(timeMs or 0)
    self._.isUnique = isUnique or false
    self._.isComplete = false

    return self
end

---@return string identity
function PriorityQueueJob:GetIdentity()
    return self._.identity
end

---@return number priority
function PriorityQueueJob:GetPriority()
    return self._.priority
end

---@return boolean isUnique
function PriorityQueueJob:IsUnique()
    return self._.isUnique
end

---@return boolean isVisible
function PriorityQueueJob:IsVisible()
    return self._.timer:timer_expired()
end

function PriorityQueueJob:ResetTimer()
    self._.timer:reset()
end

---@return boolean isComplete
function PriorityQueueJob:IsComplete()
    return self._.isComplete
end

function PriorityQueueJob:Execute()
    if not self._.isComplete then
        if self._.content() == true then
            self:ResetTimer()
        else
            self._.isComplete = true
        end
    end
end

return PriorityQueueJob