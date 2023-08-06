local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

---@class StopWatch
local StopWatch = {
    author = "judged",
    key = "StopWatch"
}

StopWatch.__index = StopWatch
setmetatable(StopWatch, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

local function DebugLog(str)
    Debug.Log(StopWatch.key, str)
end

---@param startNow boolean? defaults to false
---@return StopWatch stopwatch 
function StopWatch.new(startNow)
    local self = setmetatable({}, StopWatch)

    if startNow == nil then
        startNow = false
    end
    self:reset()
    if startNow then
        self:resume()
    end

    return self
end

function StopWatch:reset()
    DebugLog("Resetting stopwatch")
    self.start_time = 0
    self.stored_time = 0
    self.paused = true
    self.splitName = ""
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

---@return number milliseconds
function StopWatch:get_time()
    if self.paused then
        return Time.round(self.stored_time)
    end

    local pause_time = Time.current_time()
    return Time.round(self.stored_time + pause_time - self.start_time)
end

---@param splitName string? if supplied, the -next- time calling this method will output the duration of that split with this text
---@return number milliseconds
function StopWatch:split(splitName)
    local result = 0

    if self.paused == false then
        local split_at_time = Time.current_time()
        local split_time = split_at_time - self.start_time
        self.stored_time = self.stored_time + split_time
        self.start_time = split_at_time

        result = Time.round(split_time)
    end

    if self.splitName ~= nil and self.splitName ~= "" then
        print("Finished [" .. self.splitName .. "] took: " .. tostring(result) .. "ms")
    end
    self.splitName = splitName

    return 0
end

return StopWatch
