--- Author judged

-- Run interpreted. LuaJIT's trace compiler has crashed this client three times from
-- lj_mcode_patch (lj_mcode.c:351): its MCode area search walks off the end of the chain and
-- reads NULL+4, which surfaces as an unhandled page fault on 00000004 -- a JIT-internal
-- invariant break that no amount of care in Lua can guard against. Cabby is nowhere near
-- CPU bound at a once-per-frame loop, so interpreting costs us nothing worth having.
--
-- Deliberately not calling jit.flush(): flushing traces is what *invokes* lj_mcode_patch,
-- so it would exercise the exact path we are avoiding. Existing traces from an earlier run
-- in this client survive; restart EQ for a clean state.
--
-- Note this is VM-wide (MQ2Lua shares one lua_State across scripts), and it is a workaround
-- for an upstream bug, not a fix. Revisit if the bundled LuaJIT is ever updated.
if jit ~= nil then
    jit.off()
end

local mq = require("mq")
local FileSystem = require("utils.FileSystem.FileSystem")

local ErrorAlert = require("cabby.errorAlert")
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
    },
    configStore = nil
}

local ftkey = Global.tracing.open("Cabby Script")

-- First time setup
-- local PackageMan = require("mq/PackageMan")
-- PackageMan.Install('luasocket')
-- PackageMan.Install("luafilesystem")

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

local configFilePath = FileSystem.PathJoin(mq.configDir, "cabby", mq.TLO.Me.Name() .. "-Config.lua")
ErrorAlert.Init(FileSystem.PathJoin(mq.configDir, "cabby", mq.TLO.Me.Name() .. "-errors.log"))
local stateMachine = StateMachine:new()
Setup:Init(configFilePath, stateMachine)

print("/chelp for help")
print("Cabby script is running...")
Global.tracing.close(ftkey)

stateMachine:Start()
