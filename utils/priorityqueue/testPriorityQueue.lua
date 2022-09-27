---@type Mq
local mq = require("mq")
local PriorityQueue = require "utils.priorityqueue.priorityqueue"

mq.cmd("/mqclear")

---@type PriorityQueue
local pq = PriorityQueue:new(200)

pq:Print()
print("should have been empty...")
print()

pq:InsertNewJob(3, "foo", 0, false)
pq:Print()
print("added foo")
print()

pq:InsertNewJob(4, "bar", 0, false)
pq:Print()
print("added bar")
print()

pq:InsertNewJob(5, "zoo", 0, false)
pq:Print()
print("added zoo")
print()

pq:InsertNewJob(3, "bazzar", 3, false)
pq:Print()
print("added bazzar after foo with small timer")
print()

pq:InsertNewJob(1, "skip", 0, false)
pq:Print()
print("skip to front")
print()

pq:InsertNewJob(3, "foo", 0, true)
pq:Print()
print("tried to add duplicate foo, but was set to unique only")
print()

pq:InsertNewJob(3, "foo", 0, false)
pq:Print()
print("added duplicate foo")
print()

pq:SetNextJob()
pq:CompleteCurrentJob()
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

pq:InsertNewJob(3, "foo", 0, false)
pq:Print()
print("added foo")
print()