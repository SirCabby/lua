local Debug = require("utils.Debug.Debug")
local Job = require("utils.PriorityQueue.PriorityQueueJob")

---@class PriorityQueue
---@field jobs table
---@field maxSize number
---@field currentJobKey number
local PriorityQueue = { author = "judged", key = "PriorityQueue" }

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
    Debug:new()

    ---@param str string
    local function DebugLog(str)
        Debug:Log(PriorityQueue.key, str)
    end

    ---@param content any
    ---@return string
    local function GetDisplayableJobContent(content)
        local result = ""
        if type(content) == "function" then
            result = "function"
        elseif type(content) == "table" and content["identity"] ~= nil then
            ---@type FunctionContent
            local functionContent = content
            result = functionContent.identity
        else
            result = tostring(content)
        end
        return result
    end

    ---Determines if the content is unique to the queue. If one already exists, no new job is added.
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@param content any The content to check for
    ---@return boolean - true if this is a unique job to add, false to abort
    local function IsUnique(priorityQueue, content)
        DebugLog("Checking for uniqueness in priorityqueue: " .. GetDisplayableJobContent(content))
        for _, job in ipairs(priorityQueue.jobs) do
            if type(content) == table and content.identity ~= nil and type(job) == table and job.identity ~= nil and job.identity == content.identity then
                DebugLog("Found matching FunctionContent")
                return true
            elseif job.content == content then
                DebugLog("Found matching content")
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
        DebugLog("Searching for job with key: " .. tostring(key))
        for index, job in ipairs(priorityQueue.jobs) do
            if job.key == key then
                DebugLog("Found key at index: " .. tostring(index))
                result = index
                break
            end
        end
        return result
    end

    ---Removes Job from queue by index
    ---@param priorityQueue PriorityQueue - queue containing metadata to leverage
    ---@param index integer job's place in the queue
    local function RemoveJobByIndex(priorityQueue, index)
        DebugLog("Removing job at index: " .. index)
        if index <= #priorityQueue.jobs then
            table.remove(priorityQueue.jobs, index)
        end
    end

    ---Sets next job to pull from the queue
    ---@return Job?
    function PriorityQueue:SetNextJob()
        DebugLog("Setting next job...")
        self.currentJobKey = -1
        if #self.jobs > 0 then
            for _, job in ipairs(self.jobs) do
                if job:IsVisible() then
                    -- wrap some debugs with an if check so we don't evaluate expensive reads while debug is off
                    DebugLog("Found next job key: " .. job.key .. ", content: " .. GetDisplayableJobContent(job.content))
                    self.currentJobKey = job.key
                    return self:GetCurrentJob()
                end
            end
        end
        DebugLog("No jobs visible")
        return nil
    end

    ---Returns the current job
    ---@return Job?
    function PriorityQueue:GetCurrentJob()
        local currentJobIndex = GetJobIndex(self, self.currentJobKey)
        if currentJobIndex < 0 then return nil end

        return self.jobs[currentJobIndex]
    end

    ---Creates and queues a new job based on priority
    ---@param priority number Priority of request to put into the queue, lower number is higher priority
    ---@param content any The content to queue
    ---@param time number? (Optional) Seconds the job goes invisible for once read
    ---@param onlyUnique boolean? (Optional) If true, will not add the job if it already exists in the queue
    function PriorityQueue:InsertNewJob(priority, content, time, onlyUnique)
        onlyUnique = onlyUnique or false
        time = time or 0
        DebugLog("Inserting a new job")

        -- If required unique but not unique, abort
        if onlyUnique and not IsUnique(self, content) then
            DebugLog("Job was not unique, not inserting.  Content: " .. GetDisplayableJobContent(content))
            return
        end

        local newJob = Job:new(self, priority, content, time)

        -- Determine where to insert
        for i = 1, self.maxSize, 1 do
            if i > #self.jobs or self.jobs[i].priority > priority then
                DebugLog("Inserting job at index: " .. tostring(i))
                table.insert(self.jobs, i, newJob)
                return
            end
        end
    end

    ---Removes a job by key from the queue
    ---@param key integer - Job's unique key
    function PriorityQueue:CompleteJobByKey(key)
        DebugLog("Completing job key: " .. tostring(key))
        local jobIndex = GetJobIndex(self, key)
        if (jobIndex > 0) then
            RemoveJobByIndex(self, jobIndex)
        end
    end

    ---Completes and removes the current job in the queue
    function PriorityQueue:CompleteCurrentJob()
        DebugLog("Completing current job")
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
            local content = GetDisplayableJobContent(job.content)
            print("Index("..idx..") Priority("..job.priority..") Key("..job.key..") Timer("..job.timer:time_remaining()..") Content: "..content)
        end
        print("===============")
    end

    return priorityQueue
end

return PriorityQueue
