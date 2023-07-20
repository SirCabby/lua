--- Author judged

local mq = require("mq")
local FileSystem = require("utils.FileSystem.FileSystem")
local Setup = require("cabby.setup")
---@type StateMachine
local StateMachine = require("cabby.stateMachine")

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

stateMachine:Start()
