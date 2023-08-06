local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local Debug = require("utils.Debug.Debug")
---@type Stack
local Stack = require("utils.Stack.Stack")
local TableUtils = require("utils.TableUtils.TableUtils")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

-- Arrange
---@type Stack
local s1
---@type Stack
local s2
---@type array
local s1Stack
---@type array
local s2Stack
local pushStuff1 = { "p1", { "p2" }, 3, true, false, nil, "p7" }
local pushStuff2 = { "2p" }

-- TESTS
test.Stack.new = function()
    s1 = Stack:new()
    s2 = Stack:new()
    s1Stack = s1._stack
    s2Stack = s2._stack
end

test.Stack.Push_oneStack = function()
    for i = 1, 7 do
        s1:Push(pushStuff1[i])
    end

    test.equal(#s1Stack, 7)
    test.equal(#s2Stack, 0)

    for i = 1, 7 do
        local compare = pushStuff1[i]
        if compare == nil then compare = "nil" end
        if type(compare) == "table" then
            test.assert(TableUtils.Compare(s1Stack[i], compare))
        else
            test.equal(s1Stack[i], compare)
        end
    end
end

test.Stack.Push_secondStack = function()
    s2:Push(pushStuff2[1])
    test.assert(not TableUtils.ArrayContains(s1Stack, pushStuff2[1]))
    test.equal(s2Stack[1], pushStuff2[1])
    test.equal(#s1Stack, 7)
    test.equal(#s2Stack, 1)
end

test.Stack.Pop_defaultEnd = function()
    test.equal(s1:Pop(), pushStuff1[7])
    test.equal(#s1Stack, 6)
    test.equal(#s2Stack, 1)
end

test.Stack.Pop_byIndex = function()
    test.equal(s1:Pop(4), pushStuff1[4])
    test.equal(s1:Pop(4), pushStuff1[5])
    test.equal(s1:Pop(4), "nil")
    test.equal(#s1Stack, 3)
    test.equal(#s2Stack, 1)
end

test.Stack.Pop_afterEmpty = function()
    test.equal(s2:Pop(), pushStuff2[1])
    test.equal(#s2Stack, 0)
    test.equal(s2:Pop(), nil)
    test.equal(s2:Pop(), nil)
    test.equal(s2:Pop(), nil)
    test.equal(#s2Stack, 0)
end

test.Stack.Peek_fromPopulatedStack = function()
    test.equal(s1:Peek(), pushStuff1[3])
end

test.Stack.Peek_fromEmptyStack = function()
    s1:Pop()
    test.equal(s1:Peek(), pushStuff1[2])
    s1:Pop()
    test.equal(s1:Peek(), pushStuff1[1])
    s1:Pop()
    test.equal(#s1Stack, 0)
    test.equal(s1:Peek(), nil)
end

-- RUN TESTS
test.summary()
