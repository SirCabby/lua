local mq = require("mq")
---@type PriorityQueue
local PriorityQueue = require("utils.PriorityQueue.PriorityQueue")
---@type FunctionContent
local pqFunctionContent = require("utils.PriorityQueue.PriorityQueueFunctionContent")

mq.cmd("/mqclear")
PriorityQueue.debug = true

local pq = PriorityQueue:new(200)
local pqToTestMultipleQueues = PriorityQueue:new(10)
assert(pq.maxSize == 200, "secondary queue reset maxsize of first queue")

pq:Print()
print("should have been empty...")
print()
assert(#pq.jobs == 0, "Queue should have been empty")

pq:InsertNewJob(3, "foo")
pq:Print()
print("added foo")
print()
local newJob = pq:GetCurrentJob()
assert(#pq.jobs == 1, "Queue size should be 1")
assert(newJob == nil, "currentJob should still be nil")
---@type Job
newJob = pq.jobs[1]
newJob:IsVisible()
assert(newJob.content == "foo", "new job should be foo")
assert(newJob.IsVisible(newJob), "new job should be visible")
assert(newJob.priority == 3, "new job priority should be 3")
pqToTestMultipleQueues:Print()
assert(#pqToTestMultipleQueues.jobs == 0, "Secondary queue should not be altered")

pq:InsertNewJob(4, "bar")
pq:Print()
print("added bar")
print()

pq:InsertNewJob(5, "zoo")
pq:Print()
print("added zoo")
print()

pq:InsertNewJob(3, "bazzar", 3)
pq:Print()
print("added bazzar after foo with small timer")
print()

pq:InsertNewJob(1, "skip")
pq:Print()
print("skip to front")
print()

pq:InsertNewJob(3, "foo", nil, true)
pq:Print()
print("tried to add duplicate foo, but was set to unique only")
print()

pq:InsertNewJob(3, "foo")
pq:Print()
print("added duplicate foo")
print()

pq:SetNextJob()
assert(pqToTestMultipleQueues.currentJobKey == -1, "Secondary Queue should not be updating keys")
pqToTestMultipleQueues:InsertNewJob(1, "alt")
pq:CompleteCurrentJob()
assert(#pqToTestMultipleQueues.jobs == 1, "completing job shouldn't impact alternate queue")
pq:Print()
print("completed current job")
print()

local key = pq.jobs[3].key
pq:CompleteJobByKey(key)
pq:Print()
print("completed job at index 3")
print()

pq:CompleteJobByKey(10)
pq:Print()
print("tried to complete job at index 10")
print()

pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job")
print()

pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job")
print()

mq.delay(1000)
pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job, delayed 1s")
print()

mq.delay(1000)
pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job, delayed 1s")
print()

mq.delay(1000)
pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job, delayed 1s")
print()

mq.delay(1000)
pq:SetNextJob()
pq:CompleteCurrentJob()
pq:Print()
print("completed next job, delayed 1s")
print()

pq:InsertNewJob(3, "foo")
pq:Print()
print("added foo")
print()


local wasCalled = false
local TestFunction = function(someInt, someString)
    wasCalled = true
    print("called test function")
    return someInt == someString
end
pqToTestMultipleQueues:InsertNewJob(3, function() TestFunction(3, "3") end)
pqToTestMultipleQueues:Print()
print("Test to add a function to a queue and print it")
print()
pqToTestMultipleQueues.jobs[2].content()
assert(wasCalled, "Did not call the test function")

local testContent = pqFunctionContent:new("This job will say Hello", function() return print("Hello") end)
pqToTestMultipleQueues:InsertNewJob(4, testContent)
pqToTestMultipleQueues:Print()
print("Testing FunctionContent")
print()
pqToTestMultipleQueues.jobs[3].content.Call()

print()
print("Attempting to add duplicate function with not allowing unique...")
pqToTestMultipleQueues:InsertNewJob(5, testContent, 3, true)
pqToTestMultipleQueues:Print()


pqToTestMultipleQueues:InsertNewJob(4, 2)
pqToTestMultipleQueues:Print()
print("Testing non string")
