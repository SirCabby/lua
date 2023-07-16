local mq = require("mq")
local Debug = require("utils.Debug.Debug")
---@type Stack
local Stack = require("utils.Stack.Stack")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)
Debug:new()

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

test.Stack.push = function()
    for i = 1, 7 do
        s1:push(pushStuff1[i])
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

    s2:push(pushStuff2[1])
    test.assert(not TableUtils.ArrayContains(s1Stack, pushStuff2[1]))
    test.equal(s2Stack[1], pushStuff2[1])
    test.equal(#s1Stack, 7)
    test.equal(#s2Stack, 1)
end

test.Stack.pop = function()
    test.equal(s1:pop(), pushStuff1[7])
    test.equal(s1:pop(4), pushStuff1[4])
    test.equal(s1:pop(4), pushStuff1[5])
    test.equal(s1:pop(4), "nil")
    test.equal(#s1Stack, 3)
    test.equal(#s2Stack, 1)

    test.equal(s2:pop(), pushStuff2[1])
    test.equal(s2:pop(), nil)
    test.equal(s2:pop(), nil)
    test.equal(s2:pop(), nil)
end

test.Stack.peek = function()
    test.equal(s1:peek(), pushStuff1[3])
    s1:pop()
    test.equal(s1:peek(), pushStuff1[2])
    s1:pop()
    test.equal(s1:peek(), pushStuff1[1])
    s1:pop()
    test.equal(s1:peek(), nil)
end

-- RUN TESTS
test.summary()
