--- Author judged
---@type Mq
local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem")
local PriorityQueue = require("utils.PriorityQueue.PriorityQueue")
local Setup = require("cabby.setup")

-- Debug toggles
Debug:new()
-- Debug.toggles[Setup.key] = true
-- local Config = require("utils.Config.Config")
-- Debug.toggles[Config.key] = true

---Manage and prioritize jobs
---@param priorityQueue PriorityQueue
local function DoNextJob(priorityQueue)
    local nextJob = priorityQueue:SetNextJob()
    if nextJob == nil then return end

    -- Assuming all queued jobs are FunctionContent
    ---@type FunctionContent
    local job = nextJob.content
    local isDone = job.Call()
    if (isDone) then
        priorityQueue:CompleteCurrentJob()
    else
        nextJob:ResetTimer()
    end
end

-- start
mq.cmd("/mqclear")

print("Loading Cabby script...")
local configFilePath = FileSystem.PathJoin(mq.configDir, "cabby", mq.TLO.Me.Name() .. "-Config.json")
local pq = PriorityQueue:new(200)
Setup:Init(configFilePath, pq)
print("/chelp for help")
print("Cabby script is running...")

-- Keep script running
while (true) do
    mq.doevents()
    DoNextJob(pq)
    mq.delay(1)
end
