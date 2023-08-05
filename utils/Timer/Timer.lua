-- Original Author: aquietone
-- Modified by: judged

local PackageMan = require('mq/PackageMan')
local Debug = require("utils.Debug.Debug")

---@class Timer
local Timer = {
    authors = "aquietone, judged",
    key = "Timer"
}

local function DebugLog(str)
    Debug.Log(Timer.key, str)
end

---Initialize a new timer instance
---@param millisUntilExpiration number The number of milliseconds after the start time which the timer will be expired
---@return Timer timer
function Timer:new(millisUntilExpiration)
    local t = {}
    setmetatable(t, self)
    self.__index = self
    self.start_time = 0
    self.millisUntilExpiration = millisUntilExpiration
    DebugLog("Timer created with expiration: " .. tostring(millisUntilExpiration))
    self:reset()
    return t
end

local function getSocket()
    if Timer.socket == nil then
        Timer.socket = PackageMan.Require('luasocket', 'socket')
    end
    return Timer.socket
end

---Return the current time in seconds
---@return number @Returns a number representing the current unix time in seconds
function Timer.current_time()
    return getSocket().gettime()
end

---Reset the start time value to the current time
---@param millisUntilExpiration number @The number of seconds after the start time which the timer will be expired
function Timer:set(millisUntilExpiration)
    DebugLog("Set timer to expiration: " .. tostring(millisUntilExpiration))
    self:reset()
    self.millisUntilExpiration = millisUntilExpiration
end

---Reset the start time value to the current time
function Timer:reset()
    DebugLog("Resetting timer")
    self.start_time = Timer.current_time()
end

---@return boolean isExpired Returns true if the timer has expired, otherwise false
function Timer:timer_expired()
    local result = self.current_time() >= self.start_time + (self.millisUntilExpiration / 1000)
    DebugLog("Timer is expired? " .. tostring(result))
    return result
end

---@return number millisecondsRemaining Returns the number of milliseconds remaining until the timer expires
function Timer:time_remaining()
    local result = math.max(self.start_time + (self.millisUntilExpiration / 1000) - self.current_time(), 0)
    DebugLog("Time remaining: " .. tostring(result))
    return result
end

return Timer
