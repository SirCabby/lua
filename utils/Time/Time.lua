local PackageMan = require('mq/PackageMan')

---@class Time
local Time = {
    author = "judged",
    key = "Time"
}

local function getSocket()
    if Time.socket == nil then
        Time.socket = PackageMan.Require('luasocket', 'socket')
    end
    return Time.socket
end

---@return number milliseconds current time in unix milliseconds
function Time.current_time()
    return Time.round(getSocket().gettime() * 1000)
end

---@param milliseconds number
---@return number rounded to nearest millisecond
function Time.round(milliseconds)
    return math.floor((math.floor(tonumber(milliseconds)*2) + 1)/2)
end

return Time
