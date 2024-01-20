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

---@diagnostic disable-next-line: inject-field
    self._ = {}
    self._.registeredStates = {}
    self._.started = false

    return self
end

local function runChecks(self)
    for _, state in ipairs(self._.registeredStates) do
        ---@type State
        state = state

        if state:IsEnabled() then
            if state:Go() then
                return
            end
        end
    end
end

---@param state State
function StateMachine:Register(state)
    table.insert(self._.registeredStates, state)
end

function StateMachine:Unregister(state)
    TableUtils.RemoveByValue(self._.registeredStates, state)
end

function StateMachine:Start()
    self._.started = true
    while (self._.started) do
        mq.doevents()
        runChecks(self)
        mq.delay(1)
    end
end

function StateMachine:Stop()
    self._.started = false
end

return StateMachine
