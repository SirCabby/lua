local Debug = require("utils.Debug.Debug")

---@class PriorityQueue
---@field jobs table
---@field maxSize number
local PriorityQueue = { author = "judged", key = "PriorityQueue" }

---@meta PriorityQueue
---Gets next available job from the queue if one exists
---@return PriorityQueueJob?
function PriorityQueue:GetNextJob() end
---Creates and queues a new job based on priority
---@param job PriorityQueueJob
function PriorityQueue:InsertJob(job) end
function PriorityQueue:Print() end

---ctor
---@param maxSize number Maximum size of the queue
---@return PriorityQueue
function PriorityQueue:new(maxSize)
    local priorityQueue = {}

    priorityQueue._jobs = {}
    Debug:new()

    ---@param str string
    local function DebugLog(str)
        Debug:Log(PriorityQueue.key, str)
    end

    ---Determines if the job is unique to the queue. If one already exists, no new job is added.
    ---@param job PriorityQueueJob
    ---@return boolean isUnique true if this is a unique job to add, false to abort
    local function IsUnique(job)
        DebugLog("Checking for uniqueness in priorityqueue: " .. job:GetIdentity())
        for _, j in ipairs(priorityQueue._jobs) do
            if j:GetIdentity() == job:GetIdentity() then
                DebugLog("Found matching Job")
                return false
            end
        end
        return true
    end

    ---Removes Job from queue by index
    ---@param index number job's place in the queue
    local function RemoveJobByIndex(index)
        DebugLog("Removing job at index: " .. index)
        if index <= #priorityQueue._jobs then
            table.remove(priorityQueue._jobs, index)
        end
    end

    ---Removes all completed jobs from queue
    local function CleanupCompletedJobs()
        for index, job in ipairs(priorityQueue._jobs) do
            if job:IsComplete() then
                RemoveJobByIndex(index)
                return CleanupCompletedJobs()
            end
        end
    end

    function priorityQueue:GetNextJob()
        DebugLog("Setting next job...")
        CleanupCompletedJobs()

        if #priorityQueue._jobs > 0 then
            for _, job in ipairs(priorityQueue._jobs) do
                ---@type PriorityQueueJob
                job = job

                if job:IsVisible() then
                    DebugLog("Found next job id: " .. job:GetIdentity())
                    return job
                end
            end
        end
        DebugLog("No jobs visible")
        return nil
    end

    function priorityQueue:InsertJob(job)
        DebugLog("Inserting a new job")
        ---@type PriorityQueueJob
        job = job

        -- If required unique but not unique, abort
        if job:IsUnique() and not IsUnique(job) then
            DebugLog("Job was not unique, not inserting.  Job Id: " .. job:GetIdentity())
            return
        end

        -- Determine where to insert
        for i = 1, maxSize, 1 do
            if i > #priorityQueue._jobs or priorityQueue._jobs[i]:GetPriority() > job:GetPriority() then
                DebugLog("Inserting job at index: " .. tostring(i))
                table.insert(priorityQueue._jobs, i, job)
                return
            end
        end

        error("Failed to insert job [" .. job:GetIdentity() .. "]")
    end

    function priorityQueue:Print()
        if (#priorityQueue._jobs < 1) then
            print("Priority Queue is empty")
            return
        end
        print("Priority Queue:")
        print("===============")
        for idx,job in ipairs(priorityQueue._jobs) do
            ---@type PriorityQueueJob
            job = job
---@diagnostic disable-next-line: undefined-field
            print("Index("..idx..") Identity("..job:GetIdentity()..") Priority("..job:GetPriority()..") Timer("..job._timer:time_remaining()..")")
        end
        print("===============")
    end

    return priorityQueue
end

return PriorityQueue
