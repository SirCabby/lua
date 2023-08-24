local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local Commands = require("cabby.commands.commands")
local Menu = require("cabby.menu")

---@type CabbyConfig
local DebugConfig = {
    key = "DebugConfig",
    _ = {
        isInit = false,
        config = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(DebugConfig.key, str)
end

local function initAndValidate()
    if DebugConfig._.config:GetConfigRoot()[DebugConfig.key] == nil then
        DebugLog("DebugConfig Section was not set, updating...")
        DebugConfig._.config:GetConfigRoot()[DebugConfig.key] = {}
    end
    if DebugConfig._.config:GetConfigRoot()[DebugConfig.key].all == nil then
        DebugLog("Debug 'all' option was not set, setting to false")
        DebugConfig._.config:GetConfigRoot()[DebugConfig.key].all = false
    end
end

local function getConfigSection()
    return DebugConfig._.config:GetConfigRoot()[DebugConfig.key]
end

---Initialize the static object, only done once
---@param config Config
---@diagnostic disable-next-line: duplicate-set-field
function DebugConfig.Init(config)
    if not DebugConfig._.isInit then
        local ftkey = Global.tracing.open("DebugConfig Setup")
        DebugConfig._.config = config

        -- Sync Debug with DebugConfig on this ctor
        initAndValidate()
        local debugConfig2 = getConfigSection()
        for k, v in pairs(debugConfig2) do
            Debug.SetToggle(k, v)
        end
        DebugConfig._.config:GetConfigRoot()[DebugConfig.key] = Debug._.toggles

        local function Bind_Debug(...)
            local args = {...} or {}
            if args == nil or #args < 1 or #args > 2 or args[1]:lower() == "help" then
                print("(/debug) Toggle debug tracing by debug category key")
                print(" -- Usage (toggle): /debug key")
                print(" -- Usage (1 = on, 0 = off): /debug key <0|1>")
                print(" -- To find a list of keys, use /debug list")
            elseif args[1]:lower() == "list" then
                print("Debug Toggles:")
                DebugConfig:Print()
            elseif #args == 2 then
                if args[2] == "0" then
                    DebugConfig.SetDebugToggle(args[1], false)
                    print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig.GetDebugToggle(args[1])))
                elseif args[2] == "1" then
                    DebugConfig.SetDebugToggle(args[1], true)
                    print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig.GetDebugToggle(args[1])))
                else
                    print("(/debug) Invalid second argument: [" .. args[2] .."]")
                    print(" -- Valid values: [0, 1]")
                end
            else
                DebugConfig.FlipDebugToggle(args[1])
                print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig.GetDebugToggle(args[1])))
            end
        end
        Commands.RegisterSlashCommand("debug", Bind_Debug)

        Menu.RegisterConfig(DebugConfig)

        DebugConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

function DebugConfig.GetDebugToggle(key)
    return Debug.GetToggle(key)
end

function DebugConfig.SetDebugToggle(key, value)
    Debug.SetToggle(key, value)
    DebugConfig._.config:SaveConfig()
    DebugLog("Set debug toggle: [" .. key .. "] : [" .. tostring(value) .. "]")
end

function DebugConfig.FlipDebugToggle(key)
    Debug.Toggle(key)
    DebugConfig._.config:SaveConfig()
    DebugLog("Flipped debug toggle: [" .. key .. "] : [" .. tostring(Debug.GetToggle(key)) .. "]")
end

function DebugConfig.Print()
    TableUtils.Print(Debug._.toggles)
end

return DebugConfig
