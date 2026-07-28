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
    ---{ state = BaseState, priority = number? }, in registration order
    self._.registeredStates = {}
    self._.registeredServices = {}
    ---functions returning a priority floor, or nil for "nothing to hold back"
    self._.priorityGates = {}
    self._.started = false
    -- MQ resumes the script at most once per game frame, so anything above one frame time
    -- makes passes skip frames: 25 here cost a whole extra frame of command latency per pass
    -- at 60fps. 10 stays under typical frame times, which means one pass every pulse.
    self._.loopDelayMs = 10
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

---What every gate is asking for this frame.
---
---A gate is how a *service* is busy at a band: it returns the weakest priority allowed to run
---right now, and every state weaker than that is starved exactly as if a state at that band had
---returned busy. Casting is the one that needs it -- a heal that has committed three seconds of
---cast time is lost the moment the follow state below it walks off, and the cast can be in the
---air with no state holding a frame for it (`/ccast` from a hotbar). Yielding is not enough on
---its own: the states below would happily take the frame the caster is not using, and that is
---exactly the frame that ruins the cast.
---
---A floor is all a gate may say. It cuts a contiguous tail off the chain, which is the only shape
---the ordering can express -- no exemptions, no holes. A job that must keep running below
---somebody's floor is a job registered at the wrong band, and the fix is where it sits, not a
---hole in the cut: travel mode is the worked example, suppressing by returning busy at the
---passive band and driving the traveling itself (`cabby.travel`) rather than gating the chain
---and exempting follow.
---@return table floors one floor per gate holding something back
local function activeGates(self)
    local floors = {}

    for _, gate in ipairs(self._.priorityGates) do
        local ok, floor = xpcall(gate, debug.traceback)
        if not ok then
            ErrorAlert.Record("priorityGate", floor)
        elseif type(floor) == "number" then
            floors[#floors+1] = floor
        end
    end

    return floors
end

---Is anything holding this state back this frame?
---@param floors table from activeGates
---@param priority number|nil the band it was registered at
---@return boolean isStarved
local function isStarved(floors, priority)
    -- a state registered without a priority takes no part in this: we have no way to judge it, and
    -- silently starving it would be worse than letting it run
    if priority == nil then return false end

    for _, floor in ipairs(floors) do
        if priority > floor then
            return true
        end
    end

    return false
end

local function runChecks(self)
    local floors = activeGates(self)

    for _, entry in ipairs(self._.registeredStates) do
        ---@type BaseState
        local state = entry.state

        if not isStarved(floors, entry.priority) and not self._.paused[state] and runState(self, state) then
            return
        end
    end
end

---@param state BaseState
---@param priority? number where this state sits in the chain; smaller is stronger. States
---registered with one can be starved by a priority gate (see RegisterPriorityGate).
function StateMachine:Register(state, priority)
    table.insert(self._.registeredStates, { state = state, priority = priority })
end

---Register something that can hold back the tail of the chain: a function returning the weakest
---priority allowed to run right now, or nil when it is not holding anything back.
---
---A gate is a service's way of being busy at a band -- see activeGates. It can only cut a
---contiguous tail, never punch holes: anything that must keep running below a floor is a job
---that belongs at a different band.
---@param gate fun(): number|nil
function StateMachine:RegisterPriorityGate(gate)
    table.insert(self._.priorityGates, gate)
end

---@param stateOrKey BaseState|string
---@return number|nil priority this state was registered at
function StateMachine:GetPriority(stateOrKey)
    for _, entry in ipairs(self._.registeredStates) do
        if entry.state == stateOrKey or entry.state.key == stateOrKey then
            return entry.priority
        end
    end
    return nil
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
    for index = #self._.registeredStates, 1, -1 do
        if self._.registeredStates[index].state == state then
            table.remove(self._.registeredStates, index)
        end
    end
end

---@param delayMs number milliseconds between main loop passes
function StateMachine:SetLoopDelay(delayMs)
    self._.loopDelayMs = math.max(1, delayMs)
end

---One pass of the main loop: chat events, then every service, then the state chain down to the
---first state that says it is busy. Split out of `Start` so a harness can drive frames without
---the loop and the delay around them.
function StateMachine:Frame()
    mq.doevents()
    runServices(self)
    runChecks(self)
end

function StateMachine:Start()
    self._.started = true
    while (self._.started) do
        self:Frame()
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
