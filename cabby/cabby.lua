--- Author judged
---@type Mq
local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem.FileSystem")
local PriorityQueue = require("utils.PriorityQueue.PriorityQueue")
local Setup = require("cabby.setup")

-- Debug toggles
Debug:new()
-- Debug.writeFile = true
-- Debug.all = true
-- Debug:SetToggle(Setup.key, true)
-- ---@type Config
-- local Config = require("utils.Config.Config")
-- Debug:SetToggle(Config.key, true)

---Manage and prioritize jobs
---@param priorityQueue PriorityQueue
local function DoNextJob(priorityQueue)
    local nextJob = priorityQueue:GetNextJob()
    if nextJob == nil then return end

    nextJob:Execute()
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
