---@diagnostic disable: undefined-field
local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class StateMachine
local StateMachine = { author = "judged", key = "StateMachine" }

StateMachine.__index = StateMachine
setmetatable(StateMachine, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

function StateMachine.new()
    local self = setmetatable({}, StateMachine)

    self.registeredStates = {}
    self.started = false

    return self
end

local function runChecks(self)
    for _, state in ipairs(self.registeredStates) do
        ---@type State
        state = state
        local hasAction = state:Check()
        if hasAction then
            state:Go()
            return
        end
    end
end

---@param state State
function StateMachine:Register(state)
    table.insert(self.registeredStates, state)
end

function StateMachine:Unregister(state)
    TableUtils.RemoveByValue(self.registeredStates, state)
end

function StateMachine:Start()
    self.started = true
    while (self.started) do
        mq.doevents()
        runChecks(self)
        mq.delay(1)
    end
end

function StateMachine:Stop()
    self.started = false
end

return StateMachine
