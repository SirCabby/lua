local mq = require("mq")

local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")

require("cabby.character")
local CabbyCasting = require("cabby.casting")
local Classes = require("cabby.classes.classes")
local CommandConfig = require("cabby.configs.commandConfig")
local CommandQueue = require("cabby.commandQueue")
local DebugConfig = require("cabby.configs.debugConfig")
local GeneralConfig = require("cabby.configs.generalConfig")
local HotbarConfig = require("cabby.configs.hotbarConfig")
local HotbarsUI = require("cabby.ui.hotbarsUI")
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
    HotbarConfig.Init()
    -- MeleeStateConfig belongs to MeleeState and is initialized by it, so the classes that
    -- register no melee state get no melee config either

    Global.tracing.close(ftkey)
end

---Which states this character runs, and in what order, is what its class *is*: the class
---module declares them with a priority band and `BaseClass` sorts and registers them
---(`classes/priorities.lua` holds the bands, `classes/baseClass.lua` does the assembly).
---@param stateMachine StateMachine
local function ClassSetup(stateMachine)
    local ftkey = Global.tracing.open("State Setup")

    local className = mq.TLO.Me.Class.ShortName()
    local class = Classes.Get(className)

    if class == nil then
        -- every EQ class has a module, so this is the client telling us something we do not
        -- recognize -- carrying on would leave a character registered to no states at all
        print("Cabby does not know the class [" .. tostring(className) .. "]. Aborting...")
        mq.exit()
        return
    end

    class.Init(stateMachine)

    Global.tracing.close(ftkey)
end

---@param configFilePath string
---@param stateMachine StateMachine
function Setup:Init(configFilePath, stateMachine)
    DebugLog("Starting Cabby Setup...")

    ConfigSetup(configFilePath)
    CommandQueue.Init(stateMachine) -- anything drawn in ImGui runs its commands through this
    -- Casting registers ahead of movement, and so pulses ahead of it: a cast that has to stop
    -- the character to get started asks movement to stop, and movement's own pulse -- the only
    -- thing that talks to the keys -- then releases them in that same frame rather than the next
    CabbyCasting.Init(stateMachine)
    CabbyMovement.Init(stateMachine) -- states expect the movement service to exist before they register
    ClassSetup(stateMachine)

    HotbarsUI.Init()
    Menu.Init() -- Needs to be after all importing for imgui, so as last as possible

    DebugLog("Finished Cabby Setup")
end

return Setup
