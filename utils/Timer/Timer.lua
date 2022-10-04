-- Original Author: aquietone
-- Modified by: judged

---@class Timer
local Timer = {
    authors = "aquietone, judged",
    expiration = 0,
    start_time = 0,
    debug = false
}

local function Debug(str)
    if Timer.debug then print(str) end
end

---Initialize a new timer instance
---@param expiration number @The number of seconds after the start time which the timer will be expired
---@return Timer @The timer instance
function Timer:new(expiration)
    local t = {}
    setmetatable(t, self)
    self.__index = self
    t.start_time = 0
    t.expiration = expiration
    Debug("Timer created with expiration: " .. tostring(expiration))
    t:reset()
    return t
end

---Return the current time in seconds
---@return number @Returns a number representing the current time in seconds
function Timer.current_time()
    return os.time()
end

---Reset the start time value to the current time
---@param expiration number @The number of seconds after the start time which the timer will be expired
function Timer:set(expiration)
    Debug("Set timer to expiration: " .. tostring(expiration))
    Timer:reset()
    self.expiration = expiration
end

---Reset the start time value to the current time
function Timer:reset()
    Debug("Resetting timer")
    self.start_time = Timer.current_time()
end

---Check whether the specified timer has passed its expiration
---@return boolean @Returns true if the timer has expired, otherwise false
function Timer:timer_expired()
    local result = os.difftime(Timer.current_time(), self.start_time) >= self.expiration
    Debug("Timer is expired? " .. tostring(result))
    return result
end

---Get the time remaining before the timer expires
---@return number @Returns the number of seconds remaining until the timer expires
function Timer:time_remaining()
    local result = math.max(self.expiration - os.difftime(Timer.current_time(), self.start_time), 0)
    Debug("Time remaining: " .. tostring(result))
    return result
end

return Timer
