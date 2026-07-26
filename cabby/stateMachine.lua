---@diagnostic disable: undefined-field
local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")

local ErrorAlert = require("cabby.errorAlert")

---@class StateMachine
local StateMachine = { author = "judged", key = "StateMachine" }

StateMachine.__index = StateMachine
setmetatable(StateMachine, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

-- Consecutive failures before a state or service is paused; resume from its alert in the
-- Cabby Alerts window
local maxFailStreak = 3

function StateMachine.new()
    local self = setmetatable({}, StateMachine)

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.registeredStates = {}
    self._.registeredServices = {}
    self._.started = false
    self._.loopDelayMs = 25
    self._.paused = {}
    self._.failStreaks = {}

    return self
end

---Crash barrier bookkeeping shared by states and services
---@param subject table the state or service that failed
---@param sourceKey string alert source label
---@param traceback string
---@param onPause? function cleanup to run when the subject is paused
local function recordFailure(self, subject, sourceKey, traceback, onPause)
    local streak = (self._.failStreaks[subject] or 0) + 1
    self._.failStreaks[subject] = streak
    local alert = ErrorAlert.Record(sourceKey, traceback)
    if streak >= maxFailStreak then
        self._.paused[subject] = true
        alert.paused = true
        alert.onResume = function()
            self._.paused[subject] = nil
            self._.failStreaks[subject] = 0
        end
        if onPause ~= nil then
            pcall(onPause)
        end
    end
end

---@return boolean isBusy result of state:Go(), or false if the state errored
local function runState(self, state)
    local ok, result = xpcall(function()
        if state:IsEnabled() then
            return state.Go()
        end
        return false
    end, debug.traceback)

    if ok then
        self._.failStreaks[state] = 0
        return result
    end

    recordFailure(self, state, "state:" .. tostring(state.key), result)
    return false
end

---Services are pulsed every frame ahead of the states, whether or not a state is busy.
---Movement is one: the keys it holds have to be released on the frame its task ends, not
---on some later frame when the state that started it happens to get a turn again.
local function runServices(self)
    for _, service in ipairs(self._.registeredServices) do
        if not self._.paused[service] then
            local ok, err = xpcall(service.Pulse, debug.traceback)
            if ok then
                self._.failStreaks[service] = 0
            else
                recordFailure(self, service, "service:" .. tostring(service.key), err, service.Stop)
            end
        end
    end
end

local function runChecks(self)
    for _, state in ipairs(self._.registeredStates) do
        ---@type BaseState
        state = state

        if not self._.paused[state] and runState(self, state) then
            return
        end
    end
end

---@param state BaseState
function StateMachine:Register(state)
    table.insert(self._.registeredStates, state)
end

---Register something that must run every frame regardless of which state is busy. A service
---is any module exposing `key` and `Pulse()`, plus an optional `Stop()` used to shut it down
---if it is auto-paused for repeated failures.
---@param service table
function StateMachine:RegisterService(service)
    table.insert(self._.registeredServices, service)
end

---@param service table
function StateMachine:UnregisterService(service)
    TableUtils.RemoveByValue(self._.registeredServices, service)
end

function StateMachine:Unregister(state)
    TableUtils.RemoveByValue(self._.registeredStates, state)
end

---@param delayMs number milliseconds between main loop passes
function StateMachine:SetLoopDelay(delayMs)
    self._.loopDelayMs = math.max(1, delayMs)
end

function StateMachine:Start()
    self._.started = true
    while (self._.started) do
        mq.doevents()
        runServices(self)
        runChecks(self)
        mq.delay(self._.loopDelayMs)
    end
end

function StateMachine:Stop()
    self._.started = false
    for _, service in ipairs(self._.registeredServices) do
        if service.Stop ~= nil then
            pcall(service.Stop)
        end
    end
end

return StateMachine
