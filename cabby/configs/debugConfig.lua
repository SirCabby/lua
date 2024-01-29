local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.menu")
local SlashCmd = require("cabby.commands.slashcmd")

---@class CabbyConfig
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

local function getConfigSection()
    return DebugConfig._.config:GetConfigRoot()[DebugConfig.key]
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

    local debugConfig2 = getConfigSection()
    for k, v in pairs(debugConfig2) do
        Debug.SetToggle(k, v)
    end
    DebugConfig._.config:GetConfigRoot()[DebugConfig.key] = Debug._.toggles
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function DebugConfig.Init()
    if not DebugConfig._.isInit then
        local ftkey = Global.tracing.open("DebugConfig Setup")
        DebugConfig._.config = Global.configStore

        -- Sync Debug with DebugConfig on this ctor
        initAndValidate()

        local debugDocs = ChelpDocs.new(function() return {
            "(/debug) Toggle debug tracing by debug category key",
            " -- Usage (toggle): /debug key",
            " -- Usage (1 = on, 0 = off): /debug key <0|1>",
            " -- To find a list of keys, use /debug list"
        } end )
        local function Bind_Debug(...)
            local args = {...} or {}
            if args == nil or #args < 1 or #args > 2 or args[1]:lower() == "help" then
                debugDocs:Print()
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
        Commands.RegisterSlashCommand(SlashCmd.new("debug", Bind_Debug, debugDocs))

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

---@diagnostic disable-next-line: duplicate-set-field
function DebugConfig.Print()
    TableUtils.Print(Debug._.toggles)
end

---@diagnostic disable-next-line: duplicate-set-field
function DebugConfig.BuildMenu()
    ImGui.Text("Toggle debug logging for the following areas")
    ImGui.Text("")

    local sortedKeys = TableUtils.GetKeys(Debug._.toggles)
    table.sort(sortedKeys)
    for _, key in ipairs(sortedKeys) do
        ---@type boolean
        local clicked
        Debug._.toggles[key], clicked = ImGui.Checkbox(key, Debug._.toggles[key])
        if clicked then
            DebugConfig._.config:SaveConfig()
        end
    end
end

return DebugConfig
