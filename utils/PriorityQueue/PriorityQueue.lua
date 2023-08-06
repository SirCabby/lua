---@diagnostic disable: undefined-field
local Debug = require("utils.Debug.Debug")

---@class PriorityQueue
local PriorityQueue = { author = "judged", key = "PriorityQueue" }

PriorityQueue.__index = PriorityQueue
setmetatable(PriorityQueue, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---ctor
---@param maxSize number Maximum size of the queue
---@return PriorityQueue
function PriorityQueue.new(maxSize)
    local self = setmetatable({}, PriorityQueue)

    self._ = {}
    self._.jobs = {}
    self._.maxSize = maxSize

    return self
end

---@param str string
local function DebugLog(str)
    Debug.Log(PriorityQueue.key, str)
end

---Determines if the job is unique to the queue. If one already exists, no new job is added.
---@param job PriorityQueueJob
---@param jobs array 
---@return boolean isUnique true if this is a unique job to add, false to abort
local function IsUnique(job, jobs)
    DebugLog("Checking for uniqueness in priorityqueue: " .. job:GetIdentity())
    for _, j in ipairs(jobs) do
        if j:GetIdentity() == job:GetIdentity() then 
            DebugLog("Found matching Job")
            return false
        end
    end
    return true
end

---Removes Job from queue by index
---@param index number job's place in the queue
---@param jobs array 
local function RemoveJobByIndex(index, jobs)
    DebugLog("Removing job at index: " .. index)
    if index <= #jobs then
        table.remove(jobs, index)
    end
end

---Removes all completed jobs from queue
---@param jobs array 
local function CleanupCompletedJobs(jobs)
    for i = #jobs, 1, -1 do
        if jobs[i]:IsComplete() then
            RemoveJobByIndex(i, jobs)
        end
    end
end

function PriorityQueue:GetNextJob()
    DebugLog("Setting next job...")
    CleanupCompletedJobs(self._.jobs)

    if #self._.jobs > 0 then
        for _, job in ipairs(self._.jobs) do
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

function PriorityQueue:InsertJob(job)
    DebugLog("Inserting a new job")
    ---@type PriorityQueueJob
    job = job

    -- If required unique but not unique, abort
    if job:IsUnique() and not IsUnique(job, self._.jobs) then
        DebugLog("Job was not unique, not inserting.  Job Id: " .. job:GetIdentity())
        return
    end

    -- Determine where to insert
    for i = 1, self._.maxSize, 1 do
        if i > #self._.jobs or self._.jobs[i]:GetPriority() > job:GetPriority() then
            DebugLog("Inserting job at index: " .. tostring(i))
            table.insert(self._.jobs, i, job)
            return
        end
    end

    error("Failed to insert job [" .. job:GetIdentity() .. "]")
end

function PriorityQueue:Print()
    if (#self._.jobs < 1) then
        print("Priority Queue is empty")
        return
    end
    print("Priority Queue:")
    print("===============")
    for idx, job in ipairs(self._.jobs) do
        ---@type PriorityQueueJob
        job = job
---@diagnostic disable-next-line: undefined-field
        print("Index("..idx..") Identity("..job:GetIdentity()..") Priority("..job:GetPriority()..") Timer("..job._timer:time_remaining()..")")
    end
    print("===============")
end

return PriorityQueue
