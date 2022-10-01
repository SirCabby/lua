---@type Mq
local mq = require('mq')
local Timer = require("utils.Timer.Timer")

mq.cmd("/mqclear")

local my_timer = Timer:new(10)

while true do
    if my_timer:timer_expired() then
        print('timer expired')
        break
    else
        print(my_timer:time_remaining())
    end
    mq.delay(1000)
end
