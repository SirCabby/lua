local Job = require("utils.PriorityQueue.PriorityQueueJob")

---@class PriorityQueue
---@field jobs table
---@field maxSize number
---@field currentJobKey number
local PriorityQueue = { author = "judged" }

---ctor
---@param maxSize number Maximum size of the queue
---@return PriorityQueue
function PriorityQueue:new(maxSize)
    local priorityQueue = {}
    setmetatable(priorityQueue, self)
    self.__index = self
    priorityQueue.maxSize = maxSize
    priorityQueue.jobs = {}
    priorityQueue.currentJobKey = -1

    ---Determines if the content is unique to the queue. If one already exists, no new job is added.
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@param content string The content to check for
    ---@return boolean - true if this is a unique job to add, false to abort
    local function IsUnique(priorityQueue, content)
        for _,job in ipairs(priorityQueue.jobs) do
            if job.content == content then
                return false
            end
        end
        return true
    end

    ---Get a job's index in the queue
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@param key integer - The job's unique key
    ---@return integer - job index in the queue
    local function GetJobIndex(priorityQueue, key)
        local result = -1
        for idx,job in ipairs(priorityQueue.jobs) do
            if job.key == key then
                result = idx
                break
            end
        end
        return result
    end

    ---Removes Job from queue by index
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@param index integer job's place in the queue
    local function RemoveJobByIndex(priorityQueue, index)
        if index <= #priorityQueue.jobs then
            table.remove(priorityQueue.jobs, index)
        end
    end

    ---Sets next job to pull from the queue
    ---@return Job|nil
    function PriorityQueue:SetNextJob()
        self.currentJobKey = -1
        if #self.jobs > 0 then
            for _,job in ipairs(self.jobs) do
                if job:IsVisible() then
                    self.currentJobKey = job.key
                    return self:GetCurrentJob()
                end
            end
        end
        return nil
    end

    ---Returns the current job
    ---@return Job|nil
    function PriorityQueue:GetCurrentJob()
        local currentJobIndex = GetJobIndex(self, self.currentJobKey)
        if currentJobIndex < 0 then return nil end

        return self.jobs[currentJobIndex]
    end

    ---Creates and queues a new job based on priority
    ---@param priority number Priority of request to put into the queue, lower number is higher priority
    ---@param content any The content to queue
    ---@param time number|nil (Optional) Seconds the job goes invisible for once read
    ---@param onlyUnique boolean|nil (Optional) If true, will not add the job if it already exists in the queue
    function PriorityQueue:InsertNewJob(priority, content, time, onlyUnique)
        onlyUnique = onlyUnique or false
        time = time or 0

        -- If required unique but not unique, abort
        if onlyUnique and not IsUnique(self, content) then
            return
        end

        local newJob = Job:new(self, priority, content, time)

        -- Determine where to insert
        for i = 1, self.maxSize, 1 do
            if i > #self.jobs or self.jobs[i].priority > priority then
                table.insert(self.jobs, i, newJob)
                return
            end
        end
    end

    ---Removes a job by key from the queue
    ---@param key integer - Job's unique key
    function PriorityQueue:CompleteJobByKey(key)
        local jobIndex = GetJobIndex(self, key)
        if (jobIndex > 0) then
            RemoveJobByIndex(self, jobIndex)
        end
    end

    ---Completes and removes the current job in the queue
    function PriorityQueue:CompleteCurrentJob()
        self:CompleteJobByKey(self.currentJobKey)
    end

    ---Prints the status of this PriorityQueue
    function PriorityQueue:Print()
        if (#self.jobs < 1) then
            print("Priority Queue is empty")
            return
        end
        print("Priority Queue:")
        print("===============")
        for idx,job in ipairs(self.jobs) do
            ---@type Job
            job = job
            local content = job.content
            if type(job.content) == "function" then
                content = "function"
            elseif type(job.content) == "table" and job.content["identity"] ~= nil then
                ---@type FunctionContent
                local jobContent = job.content
                content = jobContent.identity
            elseif type(job.content) ~= string then
                content = tostring(content)
            end
            print("Index("..idx..") Priority("..job.priority..") Key("..job.key..") Timer("..job.timer:time_remaining()..") Content: "..content)
        end
        print("===============")
    end

    return priorityQueue
end

return PriorityQueue
