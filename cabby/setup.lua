local mq = require("mq")
local GeneralConfig = require("cabby.configs.GeneralConfig")

local Setup = { debug = false }

local function Debug(str)
    if Setup.debug then print(str) end
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
        Debug("MQ2EQBC was not connected, connecting...")
        mq.cmd("/bccmd connect")
        mq.delay("5s", function() return tostring(mq.TLO.EQBC.Connected) ~= "FALSE" end)
        if tostring(mq.TLO.EQBC.Connected) == "FALSE" then
            print("Could not connect to MQ2EQBC. Aborting...")
            mq.exit()
        end
        Debug("MQ2EQBC is connected")
        if tostring(mq.TLO.EQBC.Setting("localecho")) ~= "FALSE" then
            Debug("Setting EQBC localecho off")
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

local function ConfigSetup(configFilePath)
    GeneralConfig:new(configFilePath)
end

function Setup:Init(configFilePath)
    Debug("Starting Cabby Setup...")
    PluginSetup()
    ConfigSetup(configFilePath)
    Debug("Finished Cabby Setup")
end

return Setup
