local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local FlowTracer = require("utils.Debug.FlowTracer")

-- TESTS

test.FlowTracer.new = function()
    FlowTracer.new()
end

test.FlowTracer.open = function()
    local ft = FlowTracer.new()
    ft:open("test1")
    ft:open("test2")
    ft:open("test3")
    ft:open("test4")
end

test.FlowTracer.split = function()
    local ft = FlowTracer.new()
    ft:open("test1")
    ft:split("hi1")
    ft:open("test2")
    ft:split("hi2")
    ft:open("test3")
    ft:split("hi3")
    ft:open("test4")
    ft:split("hi4")
end

test.FlowTracer.split_withoutOpen = function()
    local ft = FlowTracer.new()
    ft:split("test")
end

test.FlowTracer.close = function()
    local ft = FlowTracer.new()
    local key1 = ft:open("test1")
    ft:split("hi1")
    local key2 = ft:open("test2")
    ft:split("hi2")
    local key3 = ft:open("test3")
    ft:split("hi3")
    ft:close(key3)
    ft:split("hi2-2")
    local key4 = ft:open("test4")
    ft:split("hi4")
    ft:close(key4)
    ft:close(key2)
    ft:close(key1)
end

test.FlowTracer.close_skippedLevels = function()
    local ft = FlowTracer.new()
    local key1 = ft:open("test1")
    ft:open("test2")
    ft:open("test3")
    ft:open("test4")
    ft:close(key1)
end

test.FlowTracer.close_orphanedKey = function()
    local ft = FlowTracer.new()
    ft:open("test1")
    ft:close(5)
end

test.FlowTracer.close_empty = function()
    local ft = FlowTracer.new()
    ft:close(5)
end

-- RUN TESTS
test.summary()
