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

function Time.current_time()
    return getSocket().gettime()
end

return Time
