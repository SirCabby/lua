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

---What every gate is asking for this frame.
---
---A gate says "nothing weaker than this may run right now", and may name states that run anyway.
---Casting is the first one: a heal that has committed three seconds of cast time is lost the moment
---the follow state below it walks off, so while that cast is in the air the chain has to stop at
---the heal. Yielding is not enough on its own -- the states below would happily take the frame the
---caster is not using, and that is exactly the frame that ruins the cast.
---
---The exemptions are the other half of it, and flee is what needs them: a mode that holds the whole
---chain back *except* for the one job it is still meant to be doing. A floor alone cannot say that,
---since what has to go is two disjoint ranges -- everything above follow and everything below it.
---@return table gates `{ floor = number|nil, exempt = table|nil }` per gate holding something back
local function activeGates(self)
    local gates = {}

    for _, gate in ipairs(self._.priorityGates) do
        local ok, floor, exempt = xpcall(gate, debug.traceback)
        if not ok then
            ErrorAlert.Record("priorityGate", floor)
        else
            local hasFloor = type(floor) == "number"
            if hasFloor or type(exempt) == "table" then
                gates[#gates+1] = { floor = hasFloor and floor or nil, exempt = type(exempt) == "table" and exempt or nil }
            end
        end
    end

    return gates
end

---Is anything holding this state back this frame?
---
---A state has to satisfy **every** gate, which is what keeps an exemption from being a way past
---somebody else's floor: follow is exempt from the flee gate and still starved by a cast in the
---air, and that is right -- a heal half cast is lost either way.
---@param gates table from activeGates
---@param state BaseState
---@param priority number|nil the band it was registered at
---@return boolean isStarved
local function isStarved(gates, state, priority)
    -- a state registered without a priority takes no part in this: we have no way to judge it, and
    -- silently starving it would be worse than letting it run
    if priority == nil then return false end

    for _, gate in ipairs(gates) do
        local isExempt = gate.exempt ~= nil and gate.exempt[state.key] == true
        if not isExempt and (gate.floor == nil or priority > gate.floor) then
            return true
        end
    end

    return false
end

local function runChecks(self)
    local gates = activeGates(self)

    for _, entry in ipairs(self._.registeredStates) do
        ---@type BaseState
        local state = entry.state

        if not isStarved(gates, state, entry.priority) and not self._.paused[state] and runState(self, state) then
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

---Register something that can hold back part of the chain: a function returning the weakest
---priority allowed to run right now, or nil when it is not holding anything back.
---
---A gate may also return, second, a set of state keys that run anyway (`{ FollowState = true }`) --
---for a gate that is not stopping the chain so much as narrowing it to one job, which is what flee
---does. Exemptions only ever apply to the gate that returned them; a state still has to satisfy
---every other gate.
---@param gate fun(): number|nil, table|nil
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
