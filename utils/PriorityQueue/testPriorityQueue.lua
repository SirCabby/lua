---@diagnostic disable: undefined-field, need-check-nil
local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local Debug = require("utils.Debug.Debug")
---@type PriorityQueue
local PriorityQueue = require("utils.PriorityQueue.PriorityQueue")
---@type PriorityQueueJob
local PriorityQueueJob = require("utils.PriorityQueue.PriorityQueueJob")



mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

-- TESTS
test.PriorityQueueJob.new_withTimerAndUnique = function()
    local job = PriorityQueueJob:new("iddqd", 3, function() end, 5, true)

    test.equal(job:GetIdentity(), "iddqd")
    test.equal(job:GetPriority(), 3)
    test.is_false(job:IsVisible())
    test.is_true(job:IsUnique())
    test.is_false(job:IsComplete())
end

test.PriorityQueueJob.new_withoutTimerNotUnique = function()
    local job = PriorityQueueJob:new("iddqd", 3, function() end)

    test.equal(job:GetIdentity(), "iddqd")
    test.equal(job:GetPriority(), 3)
    test.is_true(job:IsVisible())
    test.is_false(job:IsUnique())
    test.is_false(job:IsComplete())
end

test.PriorityQueueJob.Execute_noTimer = function()
    local job = PriorityQueueJob:new("iddqd", 3, function() end)

    test.equal(job:GetIdentity(), "iddqd")
    test.equal(job:GetPriority(), 3)
    test.is_true(job:IsVisible())
    test.is_false(job:IsUnique())
    test.is_false(job:IsComplete())

    job:Execute()

    test.is_true(job:IsComplete())
end

test.PriorityQueueJob.Execute_resetTimer = function()
    local job = PriorityQueueJob:new("iddqd", 3, function() return true end, 5)

    test.equal(job:GetIdentity(), "iddqd")
    test.equal(job:GetPriority(), 3)
    test.is_false(job:IsVisible())
    test.is_false(job:IsUnique())
    test.is_false(job:IsComplete())

    job:Execute()

    test.is_false(job:IsComplete())
    test.is_false(job:IsVisible())
end

test.PriorityQueue.InsertJob_isUnique = function()
    local pq1 = PriorityQueue:new(10)
    local pq2 = PriorityQueue:new(10)
    local job1 = PriorityQueueJob:new("iddqd1", 3, function() end, 5, true)
    local job2 = PriorityQueueJob:new("iddqd2", 3, function() end, 5, true)

    pq1:InsertJob(job1)
    pq1:InsertJob(job1)
    test.equal(#pq1._jobs, 1)

    pq1:InsertJob(job2)
    test.equal(#pq1._jobs, 2)
    test.equal(#pq2._jobs, 0)

    pq2:InsertJob(job1)
    test.equal(#pq1._jobs, 2)
    test.equal(#pq2._jobs, 1)
end

test.PriorityQueue.InsertJob_notUnique = function()
    local pq1 = PriorityQueue:new(10)
    local job1 = PriorityQueueJob:new("iddqd1", 3, function() end)
    local job2 = PriorityQueueJob:new("iddqd2", 3, function() end)

    pq1:InsertJob(job1)
    pq1:InsertJob(job1)
    test.equal(#pq1._jobs, 2)

    pq1:InsertJob(job2)
    test.equal(#pq1._jobs, 3)
end

test.PriorityQueue.GetNextJob_ordering = function()
    local pq1 = PriorityQueue:new(10)
    local job1 = PriorityQueueJob:new("iddqd1", 3, function() end)
    local job2 = PriorityQueueJob:new("iddqd2", 2, function() end)
    local job3 = PriorityQueueJob:new("iddqd3", 3, function() end)
    local job4 = PriorityQueueJob:new("iddqd4", 3, function() end)

    pq1:InsertJob(job1)
    pq1:InsertJob(job2)
    pq1:InsertJob(job3)
    pq1:InsertJob(job4)


    local nextJob = pq1:GetNextJob()
    nextJob:Execute()
    test.is_not_nil(nextJob)
    test.equal(nextJob:GetIdentity(), job2:GetIdentity())

    nextJob = pq1:GetNextJob()
    nextJob:Execute()
    test.is_not_nil(nextJob)
    test.equal(nextJob:GetIdentity(), job1:GetIdentity())

    nextJob = pq1:GetNextJob()
    nextJob:Execute()
    test.is_not_nil(nextJob)
    test.equal(nextJob:GetIdentity(), job3:GetIdentity())

    nextJob = pq1:GetNextJob()
    nextJob:Execute()
    test.is_not_nil(nextJob)
    test.equal(nextJob:GetIdentity(), job4:GetIdentity())

    test.equal(pq1:GetNextJob(), nil)
end

-- RUN TESTS
test.summary()
