--- Author judged
---@type Mq
local mq = require("mq")
local FileSystem = require("utils.FileSystem")
local PriorityQueue = require("utils.PriorityQueue.PriorityQueue")

-- Debug toggles
local Setup = require("cabby.setup")
Setup.debug = true
local Config = require("utils.Config.Config")
Config.debug = true

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
Setup:Init(configFilePath)
local pq = PriorityQueue:new(200)
print("/chelp for help")
print("Cabby script is running...")

mq.exit()

-- Keep script running
while (true) do
    mq.doevents()
    DoNextJob(pq)
end
