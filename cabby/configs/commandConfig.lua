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
        config = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CommandConfig.key, str)
end

local function initAndValidate()
    local configData = CommandConfig._.config:GetConfigRoot()
    if configData[CommandConfig.key] == nil then
        DebugLog("CommandConfig Section was not set, updating...")
        configData[CommandConfig.key] = {}
    end
    if configData[CommandConfig.key][CommandConfig.keys.activeChannels] == nil then
        DebugLog("Active Channels were not set, updating...")
        configData[CommandConfig.key][CommandConfig.keys.activeChannels] = {}
    end
    if configData[CommandConfig.key][CommandConfig.keys.commandOverrides] == nil then
        DebugLog("CommandOverrides were not set, updating...")
        configData[CommandConfig.key][CommandConfig.keys.commandOverrides] = {}
    end

    for command, overrides in pairs(configData[CommandConfig.key][CommandConfig.keys.commandOverrides]) do
        Commands.SetPhrasePatternOverrides(command, CommandConfig.GetPhrasePatterns(overrides))
    end
end

local function getConfigSection()
    return CommandConfig._.config:GetConfigRoot()[CommandConfig.key]
end

---Initialize the static object, only done once
---@param config Config
function CommandConfig.Init(config)
    if not CommandConfig._.isInit then
        CommandConfig._.config = config

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
            -- /activechannels
            if args == nil or #args < 1 then
                print("(/activechannels) Currently active channels: [" .. StringUtils.Join(CommandConfig.GetActiveChannels(), ", ") .. "]")
                return
            elseif #args == 1 then
                -- /activechannels <channel type>
                if TableUtils.ArrayContains(TableUtils.GetValues(CommandConfig.channelTypes), args[1]:lower()) then
                    print("(/activechannels " .. args[1] .. "):")
                    CommandConfig.ToggleActiveChannel(args[1]:lower())
                    return
                -- /activechannels <command>
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                    local command = args[1]:lower()
                    if configForCommands[CommandConfig.keys.commandOverrides][command] == nil or configForCommands[CommandConfig.keys.commandOverrides][command] == nil or configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] == nil then
                        print("(/activechannels ".. command .. ") No activechannel overrides for command [" .. command .. "]")
                    else
                        print("(/activechannels " .. command .. ") Currently active channels: [" .. StringUtils.Join(configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels], ", ") .. "]")
                    end
                    return
                end
            -- /activechannels <command> <channel type | reset>
            elseif #args == 2 then
                local command = args[1]:lower()
                local channelType = args[2]:lower()

                if channelType == "reset" then
                    if configForCommands[CommandConfig.keys.commandOverrides][command] ~= nil then
                        configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] = nil
                        CommandConfig._.config:SaveConfig()
                    end
                    Commands.SetPhrasePatternOverrides(command, nil)
                    print("(activechannels "..command.." "..channelType..") Removed active channel override for command: [" .. command .. "]")
                    return
                end

                -- init override
                if configForCommands[CommandConfig.keys.commandOverrides][command] == nil then
                    configForCommands[CommandConfig.keys.commandOverrides][command] = {}
                end
                if configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] == nil then
                    configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.activeChannels] = {}
                end

                print("(/activechannels " .. args[1] .. " " .. args[2] .. "):")
                CommandConfig.ToggleActiveChannel(channelType, configForCommands[CommandConfig.keys.commandOverrides][command])
                Commands.SetPhrasePatternOverrides(command, CommandConfig.GetPhrasePatterns(configForCommands[CommandConfig.keys.commandOverrides][command]))
                return
            end

            print("(/activechannels) Channels used for listening to commands")
            print("To toggle an active channel, use: /activechannels <channel type>")
            print(" -- Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
            print(" -- Currently active channels: [" .. StringUtils.Join(CommandConfig.GetActiveChannels(), ", ") .. "]")
            print("To override active channels for a specific communication command, use: /activechannels <command> <channel type>")
            print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
            print(" -- View command overrides with: /activechannels <command>")
            print(" -- Reset command overrides with: /activechannels <command> reset")
        end
        Commands.RegisterSlashCommand("activechannels", Bind_ActiveChannels)

        local function Bind_Owners(...)
            local args = {...} or {}

            -- /owners
            if args == nil or #args < 1 then
                print("(/owners):")
                Commands.GetCommandOwners("dne-global-owners"):Print()
                return
            elseif #args == 1 and args[1]:lower() ~= "help" then
                -- /owners <command>
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                    local command = args[1]:lower()
                    if configForCommands[CommandConfig.keys.commandOverrides][command] == nil or configForCommands[CommandConfig.keys.commandOverrides][command] == nil or configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.owners] == nil then
                        print("(/owners "..command..") No owners overrides for command")
                    else
                        print("(/owners "..command..") Current owners: [" .. StringUtils.Join(configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.owners], ", ") .. "]")
                    end
                    return
                -- /owners <name>
                else
                    local owners = Commands.GetCommandOwners("dne-global-owners")
                    print("(/owners " .. args[1] .. "):")
                    if owners:IsOwner(args[1]) then
                        owners:Remove(args[1])
                    else
                        owners:Add(args[1])
                    end
                    return
                end
            elseif #args == 2 and TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                local command = args[1]:lower()
                local name = args[2]:lower()

                if name == "reset" then
                    if configForCommands[CommandConfig.keys.commandOverrides][command] ~= nil then
                        configForCommands[CommandConfig.keys.commandOverrides][command][CommandConfig.keys.owners] = nil
                        CommandConfig._.config:SaveConfig()
                    end
                    Commands.SetCommandOwnersOverrides(command, nil)
                    print("(/owners "..command.." "..name..") Removed owner override for command: [" .. command .. "]")
                    return
                end

                -- init override
                if configForCommands[CommandConfig.keys.commandOverrides][command] == nil then
                    configForCommands[CommandConfig.keys.commandOverrides][command] = {}
                end

                Commands.SetCommandOwnersOverrides(command, configForCommands[CommandConfig.keys.commandOverrides][command])
                local owners = Commands.GetCommandOwners(command)
                print("(/owners "..command.." "..name.."):")
                if owners:IsOwner(name) then
                    owners:Remove(name)
                else
                    owners:Add(name)
                end
                return
            end

            print("(/owners) Manage owners to take commands from")
            print("To add/remove owners, use: /owners <name>")
            print("To override owners for a specific communication command, use: /owners <command> <owner>")
            print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
            print(" -- View command overrides with: /owners <command>")
            print(" -- Reset command overrides with: /owners <command> reset")
            Commands.GetCommandOwners("dne-global-owners"):Print()
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
        print(" -- Invalid Channel Type [" .. channel .. "]. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(CommandConfig.channelTypes), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig[CommandConfig.keys.activeChannels], channel) then
        TableUtils.RemoveByValue(generalConfig[CommandConfig.keys.activeChannels], channel)
        print(" -- Removed [" .. channel .. "] as active channel")
    else
        generalConfig[CommandConfig.keys.activeChannels][#generalConfig[CommandConfig.keys.activeChannels] + 1] = channel
        print(" -- Added [" .. channel .. "] to active channels")
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
