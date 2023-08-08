--- Author judged

local mq = require("mq")
local FileSystem = require("utils.FileSystem.FileSystem")

local Setup = require("cabby.setup")
local StateMachine = require("cabby.stateMachine")

Global = {
    tracing = {
        enabled = false,
        flowTracer = require("utils.Debug.FlowTracer").new(),
        open = function(message)
            if Global.tracing.enabled then
                return Global.tracing.flowTracer:open(message)
            end
        end,
        split = function(message)
            if Global.tracing.enabled then
                Global.tracing.flowTracer:split(message)
            end
        end,
        close = function(key)
            if Global.tracing.enabled then
                Global.tracing.flowTracer:close(key)
            end
        end
    }
}

local ftkey = Global.tracing.open("Cabby Script")

-- Debug toggles
-- local Debug = require("utils.Debug.Debug")
-- Debug.writeFile = true
-- Debug.all = true
-- Debug.SetToggle(Setup.key, true)
-- ---@type Config
-- local Config = require("utils.Config.Config")
-- Debug.SetToggle(Config.key, true)

-- start
mq.cmd("/mqclear")
print("Loading Cabby script...")

local configFilePath = FileSystem.PathJoin(mq.configDir, "cabby", mq.TLO.Me.Name() .. "-Config.json")
local stateMachine = StateMachine:new()
Setup:Init(configFilePath, stateMachine)

print("/chelp for help")
print("Cabby script is running...")
Global.tracing.close(ftkey)

stateMachine:Start()
