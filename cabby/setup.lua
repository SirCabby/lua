local mq = require("mq")

local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")

local CommandConfig = require("cabby.configs.commandConfig")
local DebugConfig = require("cabby.configs.debugConfig")
local GeneralConfig = require("cabby.configs.generalConfig")
local Commands = require("cabby.commands.commands")
local Owners = require("cabby.commands.owners")
local FollowState = require("cabby.states.followState")

local Setup = {
    key = "Setup",
    config = {},
    owners = {}
}

local function DebugLog(str)
    Debug.Log(Setup.key, str)
end

local function CheckPlugin(name)
    local ftkey = Global.tracing.open("Checking Plugin ("..name..")")
    if tostring(mq.TLO.Plugin(name)) == "NULL" then
        print("Plugin [" .. name .. "] was not loaded. Loading...")
        mq.cmd("/plugin " .. name)
        mq.delay("10s", function() return tostring(mq.TLO.Plugin(name)) ~= "NULL" end)
        if tostring(mq.TLO.Plugin(name)) == "NULL" then
            print("Failed to bring up required plugin [" .. name .. "]. Aborting...")
            mq.exit()
        end
    end
    Global.tracing.close(ftkey)
end

local function SetupEqbc()
    local ftkey = Global.tracing.open("Setting up EQBC")
    if tostring(mq.TLO.EQBC.Connected) == "FALSE" then
        DebugLog("MQ2EQBC was not connected, connecting...")
        mq.cmd("/bccmd connect")
        mq.delay("5s", function() return tostring(mq.TLO.EQBC.Connected) ~= "FALSE" end)
        if tostring(mq.TLO.EQBC.Connected) == "FALSE" then
            print("Could not connect to MQ2EQBC. Aborting...")
            mq.exit()
        end
        DebugLog("MQ2EQBC is connected")
        if tostring(mq.TLO.EQBC.Setting("localecho")) ~= "FALSE" then
            DebugLog("Setting EQBC localecho off")
            mq.cmd("/bccmd set localecho off")
        end
    end
    Global.tracing.close(ftkey)
end

local function PluginSetup()
    local ftkey = Global.tracing.open("Plugin Setup")

    CheckPlugin("MQ2EQBC")
    SetupEqbc()
    CheckPlugin("MQ2MoveUtils")
    CheckPlugin("MQ2AdvPath")
    CheckPlugin("MQ2Rez")
    CheckPlugin("MQ2Twist")
    CheckPlugin("MQ2Melee")
    CheckPlugin("MQ2Cast")

    Global.tracing.close(ftkey)
end

---@param configFilePath string
local function ConfigSetup(configFilePath)
    local ftkey = Global.tracing.open("Config Setup")

    PluginSetup()

    local ftkey2 = Global.tracing.open("Config new")
    Setup.config = Config.new(configFilePath)
    if Setup.config:GetConfigRoot()[CommandConfig.key] == nil then
        Setup.config:GetConfigRoot()[CommandConfig.key] = {}
    end
    if Setup.config:GetConfigRoot()[CommandConfig.key][Owners.key] == nil then
        Setup.config:GetConfigRoot()[CommandConfig.key][Owners.key] = {}
    end
    Global.tracing.close(ftkey2)

    local ftkey3 = Global.tracing.open("Owners Setup")
    Setup.owners = Owners.new(Setup.config, Setup.config:GetConfigRoot()[CommandConfig.key][Owners.key])
    Global.tracing.close(ftkey3)
    
    Commands.Init(Setup.config, Setup.owners)
    GeneralConfig.Init(Setup.config)
    DebugConfig.Init(Setup.config)
    CommandConfig.Init(Setup.config)

    Global.tracing.close(ftkey)
end

---@param stateMachine StateMachine
local function StateSetup(stateMachine)
    local ftkey = Global.tracing.open("State Setup")

    stateMachine:Register(FollowState.Init())

    Global.tracing.close(ftkey)
    
-- | 1 My commands / Task / DZ
-- | 19 Passive Mode
-- | 29 Cure
-- | 39 Heal
-- | 49 Pulling
-- | -- IN COMBAT --
-- | 59 Mez
-- | 69 Tank / grab aggro
-- | 79 Dps
-- | -- OUT COMBAT
-- | 89 Looting
-- | 99 Anchor
-- | 109 Following
-- | 119 Buff
-- | 129 Misc
end

---@param configFilePath string
---@param stateMachine StateMachine
function Setup:Init(configFilePath, stateMachine)
    DebugLog("Starting Cabby Setup...")

    ConfigSetup(configFilePath)
    StateSetup(stateMachine)

    DebugLog("Finished Cabby Setup")
end

return Setup
