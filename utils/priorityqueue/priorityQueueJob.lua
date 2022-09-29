local Timer = require("utils.timer.timer")

---@class Job
---@field key integer
---@field priority number
---@field command string
---@field timer Timer
local Job = { author = "judged" }

---Creates a new job for queueing
---@param priorityQueue PriorityQueue - queue containing metadata to leverage
---@param priority number Priority of request to put into the queue, lower number is higher priority
---@param command string The command to execute
---@param time number Seconds the job goes invisible for once created
---@return Job - The created job
function Job:new(priorityQueue, priority, command, time)
    local newJob = {}
    setmetatable(newJob, self)
    self.__index = self
    newJob.priority = priority
    newJob.command = command
    newJob.timer = Timer:new(time)

    ---Generates a unique key for a job
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@return integer - new unique key, or -1 if unable to generate a key (queue is full)
    function Job.GenerateJobKey(priorityQueue)
        if #priorityQueue.jobs < 1 then return 1 end

        for newKey = 1, priorityQueue.maxSize, 1 do
            local found = false
            for _,job in ipairs(priorityQueue.jobs) do
                if job.key == newKey then
                    found = true
                    break
                end
            end
            if not found then
                return newKey
            end
        end

        print("Unable to find a unique key! Priority Queue might be full")
        return -1
    end

    ---Is this job visible
    ---@return boolean - true if visible
    function Job:IsVisible()
        return self.timer:timer_expired()
    end

    newJob.key = Job.GenerateJobKey(priorityQueue)
    return newJob
end

return Job