---@type Mq
local mq = require('mq')
local Timer = require("utils.Timer.Timer")

mq.cmd("/mqclear")

Timer.debug = true

local my_timer = Timer:new(10)

while true do
    if my_timer:timer_expired() then
        break
    else
        my_timer:time_remaining()
    end
    mq.delay(1000)
end
