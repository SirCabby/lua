local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local Time = require("utils.Time.Time")
local Timer = require("utils.Time.Timer")
local StopWatch = require("utils.Time.StopWatch")

mq.cmd("/mqclear")

test.Timer = function()
    local timer = Timer:new(400)

    test.is_false(timer:timer_expired())
    mq.delay(50)
    test.is_false(timer:timer_expired())
    mq.delay(400)
    test.is_true(timer:timer_expired())
end

test.StopWatch.new = function()
    local stopWatch = StopWatch:new()
    mq.delay(10)
    test.equal(stopWatch:get_time(), 0)
end

test.StopWatch.new_started = function()
    local stopWatch = StopWatch:new(true)
    mq.delay(10)
    test.not_equal(stopWatch:get_time(), 0)
end

test.StopWatch.pause = function()
    local stopWatch = StopWatch:new(true)
    mq.delay(10)
    test.not_equal(stopWatch:get_time(), 0)

    stopWatch:pause()
    local time1 = stopWatch:get_time()
    mq.delay(10)
    local time2 = stopWatch:get_time()
    test.equal(time1, time2)
end

test.StopWatch.resume = function()
    local stopWatch = StopWatch:new()
    stopWatch:resume()
    local time1 = stopWatch:get_time()
    mq.delay(10)
    local time2 = stopWatch:get_time()
    test.not_equal(time1, time2)
end

test.StopWatch.reset = function()
    local stopWatch = StopWatch:new(true)
    local time1 = stopWatch:get_time()
    mq.delay(10)
    local time2 = stopWatch:get_time()
    test.not_equal(time1, time2)

    stopWatch:reset()
    mq.delay(10)
    test.equal(stopWatch:get_time(), 0)
end