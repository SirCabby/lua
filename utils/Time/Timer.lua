-- Original Author: aquietone
-- Modified by: judged

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

---@class Timer
local Timer = {
    authors = "aquietone, judged",
    key = "Timer"
}

Timer.__index = Timer
setmetatable(Timer, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

local function DebugLog(str)
    Debug.Log(Timer.key, str)
end

---Initialize a new timer instance
---@param millisUntilExpiration number The number of milliseconds after the start time which the timer will be expired
---@return Timer timer
function Timer.new(millisUntilExpiration)
    local self = setmetatable({}, Timer)

    self.start_time = 0
    self.millisUntilExpiration = millisUntilExpiration
    DebugLog("Timer created with expiration: " .. tostring(millisUntilExpiration))
    self:reset()

    return self
end

---Reset the start time value to the current time
---@param millisUntilExpiration number The number of seconds after the start time which the timer will be expired
function Timer:set(millisUntilExpiration)
    DebugLog("Set timer to expiration: " .. tostring(millisUntilExpiration))
    self:reset()
    self.millisUntilExpiration = millisUntilExpiration
end

---Reset the start time value to the current time
function Timer:reset()
    DebugLog("Resetting timer")
    self.start_time = Time.current_time()
end

---@return boolean isExpired Returns true if the timer has expired, otherwise false
function Timer:timer_expired()
    local result = Time.current_time() >= self.start_time + self.millisUntilExpiration
    DebugLog("Timer is expired? " .. tostring(result))
    return result
end

---@return number millisecondsRemaining Returns the number of milliseconds remaining until the timer expires
function Timer:time_remaining()
    local result = Time.round(math.max(self.start_time + self.millisUntilExpiration - Time.current_time(), 0))
    DebugLog("Time remaining: " .. tostring(result))
    return result
end

return Timer
