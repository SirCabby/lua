local Commands = require("cabby.commands")
local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class DebugConfig
local DebugConfig = {
    key = "DebugConfig",
    _ = {
        isInit = false,
        config = {}
    }
}

---Initialize the static object, only done once
---@param config Config
function DebugConfig.Init(config)
    if not DebugConfig._.isInit then
        DebugConfig._.config = config

        -- Sync Debug with DebugConfig on this ctor
        local debugConfig2 = DebugConfig._.config:GetConfig(DebugConfig.key)
        for k, v in pairs(debugConfig2) do
            Debug.SetToggle(k, v)
        end
        config:SaveConfig(DebugConfig.key, Debug._toggles)

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
        DebugConfig._.isInit = true
    end
end

---------------- Config Management --------------------

---@param str string
local function DebugLog(str)
    Debug.Log(DebugConfig.key, str)
end

function DebugConfig.GetDebugToggle(key)
    return Debug.GetToggle(key)
end

function DebugConfig.SetDebugToggle(key, value)
    Debug.SetToggle(key, value)
    DebugConfig._.config:SaveConfig(DebugConfig.key, Debug._toggles)
    DebugLog("Set debug toggle: [" .. key .. "] : [" .. tostring(value) .. "]")
end

function DebugConfig.FlipDebugToggle(key)
    Debug.Toggle(key)
    DebugConfig._.config:SaveConfig(DebugConfig.key, Debug._toggles)
    DebugLog("Flipped debug toggle: [" .. key .. "] : [" .. tostring(Debug.GetToggle(key)) .. "]")
end

function DebugConfig.Print()
    TableUtils.Print(Debug._toggles)
end

return DebugConfig
