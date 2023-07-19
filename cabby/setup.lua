local mq = require("mq")
local Commands = require("cabby.commands")
---@type Config
local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local DebugConfig = require("cabby.configs.debugConfig")
local GeneralConfig = require("cabby.configs.generalConfig")
---@type Owners
local Owners = require("utils.Owners.Owners")

local Setup = { key = "Setup" }

local function DebugLog(str)
    Debug.Log(Setup.key, str)
end

local function CheckPlugin(name)
    if tostring(mq.TLO.Plugin(name)) == "NULL" then
        print("Plugin [" .. name .. "] was not loaded. Loading...")
        mq.cmd("/plugin " .. name)
        mq.delay("10s", function() return tostring(mq.TLO.Plugin(name)) ~= "NULL" end)
        if tostring(mq.TLO.Plugin(name)) == "NULL" then
            print("Failed to bring up required plugin [" .. name .. "]. Aborting...")
            mq.exit()
        end
    end
end

local function SetupEqbc()
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
end

local function PluginSetup()
    CheckPlugin("MQ2EQBC")
    SetupEqbc()
    CheckPlugin("MQ2MoveUtils")
    CheckPlugin("MQ2AdvPath")
    CheckPlugin("MQ2Rez")
    CheckPlugin("MQ2Twist")
    CheckPlugin("MQ2Melee")
    CheckPlugin("MQ2Cast")
end

---@param configFilePath string
local function ConfigSetup(configFilePath)
    PluginSetup()
    local config = Config:new(configFilePath)
    local owners = Owners:new(configFilePath)
    GeneralConfig.Init(config, owners)
    DebugConfig.Init(config)
end

function Setup:Init(configFilePath)
    DebugLog("Starting Cabby Setup...")

    ConfigSetup(configFilePath)
    Commands.Init()

    DebugLog("Finished Cabby Setup")
end

return Setup
