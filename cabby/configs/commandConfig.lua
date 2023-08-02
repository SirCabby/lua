local Commands = require("cabby.commands")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class CommandConfig
local CommandConfig = {
    key = "CommandConfig",
    keys = {
        activeChannels = "activeChannels",
        commandOverrides = "commandOverrides",
        owners = "owners"
    },
    channelTypes = {
        bc = "bc",
        tell = "tell",
        raid = "raid",
        group = "group"
    },
    _ = {
        isInit = false,
        config = {},
        owners = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CommandConfig.key, str)
end

local function initAndValidate()
    if CommandConfig._.config:GetConfigRoot()[CommandConfig.key] == nil then
        DebugLog("CommandConfig Section was not set, updating...")
        CommandConfig._.config:GetConfigRoot()[CommandConfig.key] = {}
    end
    if CommandConfig._.config:GetConfigRoot()[CommandConfig.key][CommandConfig.keys.activeChannels] == nil then
        DebugLog("Active Channels were not set, updating...")
        CommandConfig._.config:GetConfigRoot()[CommandConfig.key][CommandConfig.keys.activeChannels] = {}
    end
    if CommandConfig._.config:GetConfigRoot()[CommandConfig.key][CommandConfig.keys.commandOverrides] == nil then
        DebugLog("CommandOverrides were not set, updating...")
        CommandConfig._.config:GetConfigRoot()[CommandConfig.key][CommandConfig.keys.commandOverrides] = {}
    end

    for command, overrides in pairs(CommandConfig._.config:GetConfigRoot()[CommandConfig.key][CommandConfig.keys.commandOverrides]) do
        Commands.SetPhrasePatternOverrides(command, CommandConfig.GetPhrasePatterns(overrides))
    end
end

local function getConfigSection()
    return CommandConfig._.config:GetConfigRoot()[CommandConfig.key]
end

---Initialize the static object, only done once
---@param config Config
---@param owners Owners
function CommandConfig.Init(config, owners)
    if not CommandConfig._.isInit then
        CommandConfig._.config = config
        CommandConfig._.owners = owners

        -- Init any keys that were not setup
        initAndValidate()
        local configForCommands = getConfigSection()
        CommandConfig._.config:SaveConfig()

        -- Validation reminders

        if #configForCommands[CommandConfig.keys.activeChannels] < 1 then
            print("Not currently listening on any active channels. To learn more, /chelp activechannels")
        else
            print("Currently listening on active channels: [" .. StringUtils.Join(CommandConfig.GetActiveChannels(), ", ") .. "]")
        end

        -- Binds

        local function Bind_ActiveChannels(...)
            local args = {...} or {}
            if args ~= nil and #args == 3 and args[2]:lower() == "command" then
                local command = args[3]:lower()
                if not TableUtils.ArrayContains(Commands.GetCommsPhrases(), command) then
                    print("(/activechannels <channel type> command <command>) [" .. args[3] .. "] is not a registered command.")
                    print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
                else
                    -- toggle active channels for this command only

                    if args[1]:lower() == "reset" then
                        configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] = nil
                        CommandConfig._.config:SaveConfig()
                        Commands.SetPhrasePatternOverrides(command, nil)
                        print("Removed active channel override for command: [" .. command .. "]")
                        return
                    end

                    -- init override
                    if configForCommands[CommandConfig.keys.commandOverrides][command] == nil then
                        configForCommands[CommandConfig.keys.commandOverrides][command] = {}
                    end
                    if configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] == nil then
                        configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] = {}
                    end

                    CommandConfig.ToggleActiveChannel(args[1]:lower(), configForCommands[CommandConfig.keys.commandOverrides][command])
                    Commands.SetPhrasePatternOverrides(command, CommandConfig.GetPhrasePatterns(configForCommands[CommandConfig.keys.commandOverrides][command]))
                end
            elseif args ~= nil and #args == 1 and args[1]:lower() ~= "help"then
                CommandConfig.ToggleActiveChannel(args[1]:lower())
            else
                print("(/activechannels) Channels used for listening to commands")
                print("To toggle an active channel, use: /activechannels <channel type>")
                print(" -- Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
                print(" -- Currently active channels: [" .. StringUtils.Join(CommandConfig.GetActiveChannels(), ", ") .. "]")
                print("To override active channels for a specific communication command, use: /activechannels <channel type> command <command>")
                print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
                print(" -- Reset command overrides with: /activechannels reset command <command>")
            end
        end
        Commands.RegisterSlashCommand("activechannels", Bind_ActiveChannels)

        local function Bind_Owners(...)
            local args = {...} or {}
            if args == nil or #args ~= 1 or args[1]:lower() == "help" then
                print("(/owners) Manage owners to take commands from")
                print("To add/remove owners, use: /owners name")
                owners:Print()
            elseif owners:IsOwner(args[1]) then
                owners:Remove(args[1])
            else
                owners:Add(args[1])
            end
        end
        Commands.RegisterSlashCommand("owners", Bind_Owners)

        CommandConfig.UpdateEventChannels()
        CommandConfig._.isInit = true
    end
end

---@return array
function CommandConfig.GetActiveChannels()
    return getConfigSection()[CommandConfig.keys.activeChannels]
end

---Toggles an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.ToggleActiveChannel(channel, configLocation)
    local generalConfig = configLocation or getConfigSection()
    if not TableUtils.ArrayContains(TableUtils.GetValues(CommandConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig[CommandConfig.keys.activeChannels], channel) then
        TableUtils.RemoveByValue(generalConfig[CommandConfig.keys.activeChannels], channel)
        print("Removed [" .. channel .. "] as active channel")
    else
        generalConfig[CommandConfig.keys.activeChannels][#generalConfig[CommandConfig.keys.activeChannels] + 1] = channel
        print("Added [" .. channel .. "] to active channels")
    end
    CommandConfig._.config:SaveConfig()
    CommandConfig.UpdateEventChannels()
end

---Adds an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.AddChannel(channel, configLocation)
    local generalConfig = configLocation or getConfigSection()
    if not TableUtils.IsArray(generalConfig[CommandConfig.keys.activeChannels]) then error("GeneralConfig.Channels config was not an array") end
    if not TableUtils.ArrayContains(TableUtils.GetValues(CommandConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
        return
    end
    if not TableUtils.ArrayContains(generalConfig[CommandConfig.keys.activeChannels], channel) then
        generalConfig[CommandConfig.keys.activeChannels][#generalConfig[CommandConfig.keys.activeChannels] + 1] = channel
        print("Added [" .. channel .. "] to active channels")
        CommandConfig._.config:SaveConfig()
        CommandConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was already an active channel")
end

---Removes an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.RemoveChannel(channel, configLocation)
    local generalConfig = configLocation or getConfigSection()
    if not TableUtils.IsArray(generalConfig[CommandConfig.keys.activeChannels]) then error("Command.Channels config was not an array") end
    if not TableUtils.ArrayContains(TableUtils.GetValues(CommandConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig[CommandConfig.keys.activeChannels], channel) then
        TableUtils.RemoveByValue(generalConfig[CommandConfig.keys.activeChannels], channel)
        CommandConfig._.config:SaveConfig()
        print("Removed [" .. channel .. "] as active channel")
        CommandConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was not an active channel")
end

---@param configLocation table? table to work on active channels within
function CommandConfig.GetPhrasePatterns(configLocation)
    local generalConfig = configLocation or getConfigSection()
    local channels = generalConfig[CommandConfig.keys.activeChannels] or {}

    local phrasePatterns = {}
    if TableUtils.ArrayContains(channels, CommandConfig.channelTypes.bc) then
        table.insert(phrasePatterns, "<#1#> <<phrase>>")
        table.insert(phrasePatterns, "<#1#> #2# <<phrase>>")
        table.insert(phrasePatterns, "[#1#(msg)] <<phrase>>")
    end
    if TableUtils.ArrayContains(channels, CommandConfig.channelTypes.tell) then
        table.insert(phrasePatterns, "#1# tells you, '<<phrase>>'")
    end
    if TableUtils.ArrayContains(channels, CommandConfig.channelTypes.group) then
        table.insert(phrasePatterns, "#1# tells the group, '<<phrase>>'")
    end
    if TableUtils.ArrayContains(channels, CommandConfig.channelTypes.raid) then
        table.insert(phrasePatterns, "#1# tells the raid, '<<phrase>>'")
    end

    return phrasePatterns
end

---Syncs registered events to all active channels
function CommandConfig.UpdateEventChannels()
    Commands.SetChannelPatterns(CommandConfig.GetPhrasePatterns())
end

function CommandConfig.Print()
    TableUtils.Print(getConfigSection())
end

return CommandConfig
