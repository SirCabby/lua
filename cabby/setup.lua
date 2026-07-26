local mq = require("mq")

local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")

require("cabby.character")
local CommandConfig = require("cabby.configs.commandConfig")
local DebugConfig = require("cabby.configs.debugConfig")
local GeneralConfig = require("cabby.configs.generalConfig")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local Menu = require("cabby.ui.menu")
local CabbyMovement = require("cabby.movement")

local Setup = {
    key = "Setup"
}

local function DebugLog(str)
    Debug.Log(Setup.key, str)
end

---@param name string
---@param isOptional? boolean true to warn and keep going when the plugin cannot be loaded
---@return boolean isLoaded
local function CheckPlugin(name, isOptional)
    local ftkey = Global.tracing.open("Checking Plugin ("..name..")")
    if tostring(mq.TLO.Plugin(name)) == "NULL" then
        print("Plugin [" .. name .. "] was not loaded. Loading...")
        mq.cmd("/plugin " .. name)
        mq.delay("10s", function() return tostring(mq.TLO.Plugin(name)) ~= "NULL" end)
        if tostring(mq.TLO.Plugin(name)) == "NULL" then
            if isOptional then
                print("Plugin [" .. name .. "] is unavailable. Continuing without it.")
                Global.tracing.close(ftkey)
                return false
            end
            print("Failed to bring up required plugin [" .. name .. "]. Aborting...")
            mq.exit()
        end
    end
    Global.tracing.close(ftkey)
    return true
end

local function SetupEqbc()
    local ftkey = Global.tracing.open("Setting up EQBC")
    if tostring(mq.TLO.EQBC.Connected) == "FALSE" then
        DebugLog("MQ2EQBC was not connected, connecting...")
        mq.cmd("/bccmd connect")
        mq.delay("5s", function() return tostring(mq.TLO.EQBC.Connected) ~= "FALSE" end)
        if tostring(mq.TLO.EQBC.Connected) == "FALSE" then
            print("Could not connect to MQ2EQBC. Continuing without the bc and bct channels.")
            Global.tracing.close(ftkey)
            return
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

    if CheckPlugin("MQ2EQBC", true) then
        SetupEqbc()
    end
    -- Movement is ours now (utils/Movement), so MQ2MoveUtils and MQ2AdvPath are not loaded
    -- CheckPlugin("MQ2Rez")
    -- CheckPlugin("MQ2Twist")
    -- CheckPlugin("MQ2Melee")
    -- CheckPlugin("MQ2Cast")

    Global.tracing.close(ftkey)
end

---@param configFilePath string
local function ConfigSetup(configFilePath)
    local ftkey = Global.tracing.open("Config Setup")

    PluginSetup()

    local ftkey2 = Global.tracing.open("Config new")
    Global.configStore = Config.new(configFilePath)
    Global.tracing.close(ftkey2)

    CommandConfig.Init()
    DebugConfig.Init()
    GeneralConfig.Init()
    MeleeStateConfig.Init()

    Global.tracing.close(ftkey)
end

---@param stateMachine StateMachine
local function ClassSetup(stateMachine)
    local ftkey = Global.tracing.open("State Setup")

    local className = mq.TLO.Me.Class.ShortName()
    ---@type BaseClass
    local class
    if className == "BRD" then
    elseif className == "BST" then
    elseif className == "BER" then
    elseif className == "CLR" then
    elseif className == "DRU" then
    elseif className == "ENC" then
    elseif className == "MAG" then
    elseif className == "MNK" then
        class = require("cabby.classes.monk")
    elseif className == "NEC" then
    elseif className == "PAL" then
    elseif className == "RNG" then
    elseif className == "SHD" then
    elseif className == "SHM" then
    elseif className == "WAR" then
        class = require("cabby.classes.warrior")
    elseif className == "WIZ" then
    end

    class.Init(stateMachine)

    Global.tracing.close(ftkey)
    
-- | 1 My commands / Task / DZ

-- | 19 Passive Mode

-- | 29 Cure
-- | 39 Heal

-- | 49 Pulling

-- | -- IN COMBAT --
-- | 59 Mez

-- | 69 Tank / grab aggro
-- | 79 Dps (melee / spells)

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
    CabbyMovement.Init(stateMachine) -- states expect the movement service to exist before they register
    ClassSetup(stateMachine)

    Menu.Init() -- Needs to be after all importing for imgui, so as last as possible

    DebugLog("Finished Cabby Setup")
end

return Setup
