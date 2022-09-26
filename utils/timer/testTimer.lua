local mq = require('mq')
local Timer = require "utils.timer.timer"

local my_timer = Timer:new(10)
-- by default, timer begins expired because initial start time is 0, so this loop ends immediately
while true do
    if my_timer:timer_expired() then
        print('timer expired')
        break
    else
        print('not yet')
    end
    mq.delay(1000)
end
-- reset sets start time to current time, so it will take full expiration time after that
my_timer:reset()
while true do
    if my_timer:timer_expired() then
        print('timer expired')
        break
    else
        print(my_timer:time_remaining())
    end
    mq.delay(1000)
end
