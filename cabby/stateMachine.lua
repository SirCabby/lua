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

-- Consecutive failures before a state is paused; resume from its alert in the Cabby Alerts window
local maxFailStreak = 3

function StateMachine.new()
    local self = setmetatable({}, StateMachine)

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.registeredStates = {}
    self._.started = false
    self._.loopDelayMs = 25
    self._.pausedStates = {}
    self._.failStreaks = {}

    return self
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

    local streak = (self._.failStreaks[state] or 0) + 1
    self._.failStreaks[state] = streak
    local alert = ErrorAlert.Record("state:" .. tostring(state.key), result)
    if streak >= maxFailStreak then
        self._.pausedStates[state] = true
        alert.paused = true
        alert.onResume = function()
            self._.pausedStates[state] = nil
            self._.failStreaks[state] = 0
        end
    end
    return false
end

local function runChecks(self)
    for _, state in ipairs(self._.registeredStates) do
        ---@type BaseState
        state = state

        if not self._.pausedStates[state] and runState(self, state) then
            return
        end
    end
end

---@param state BaseState
function StateMachine:Register(state)
    table.insert(self._.registeredStates, state)
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
        runChecks(self)
        mq.delay(self._.loopDelayMs)
    end
end

function StateMachine:Stop()
    self._.started = false
end

return StateMachine
