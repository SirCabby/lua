local mq = require("mq")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class StateMachine
local StateMachine = { author = "judged", key = "StateMachine" }

---@meta StateMachine
---@param state State
function StateMachine:RegisterAndInit(state) end
---@param state State
function StateMachine:Unregister(state) end
function StateMachine:Start() end
function StateMachine:Stop() end

function StateMachine:new()
    local stateMachine = {}
    stateMachine.registeredStates = {}
    stateMachine.started = false

    local function runChecks()
        for _,state in ipairs(stateMachine.registeredStates) do
            ---@type State
            state = state
            local hasAction = state:Check()
            if hasAction then
                state:Go()
                break
            end
        end
    end

    ---@param state State
    function stateMachine:RegisterAndInit(state)
        state:Init()
        table.insert(stateMachine.registeredStates, state)
    end

    function stateMachine:Unregister(state)
        TableUtils.RemoveByValue(stateMachine.registeredStates, state)
    end

    function stateMachine:Start()
        stateMachine.started = true
        while (stateMachine.started) do
            mq.doevents()
            runChecks()
            mq.delay(1)
        end
    end

    function stateMachine:Stop()
        stateMachine.started = false
    end

    return stateMachine
end

return StateMachine
