local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

---@class StopWatch
local StopWatch = {
    author = "judged",
    key = "StopWatch"
}

local function DebugLog(str)
    Debug.Log(StopWatch.key, str)
end

---@param startNow boolean? defaults to false
---@return StopWatch stopwatch 
function StopWatch:new(startNow)
    local sw = {}
    setmetatable(sw, self)
    self.__index = self

    if startNow == nil then
        startNow = false
    end
    self:reset()
    if startNow then
        self:resume()
    end

    return sw
end

function StopWatch:reset()
    DebugLog("Resetting stopwatch")
    self.start_time = 0
    self.stored_time = 0
    self.paused = true
end

function StopWatch:resume()
    DebugLog("Starting stopwatch")
    if self.paused then
        self.start_time = Time.current_time()
        self.paused = false
    end
end

function StopWatch:pause()
    if self.paused == false then
        local pause_time = Time.current_time()
        self.stored_time = self.stored_time + pause_time - self.start_time
        self.paused = true
    end
end

function StopWatch:get_time()
    if self.paused then
        return self.stored_time
    end

    local pause_time = Time.current_time()
    return self.stored_time + pause_time - self.start_time
end

return StopWatch
