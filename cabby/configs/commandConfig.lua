local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local Broadcast = require("cabby.commands.broadcast")
local Commands = require("cabby.commands.commands")
local Owners = require("cabby.commands.owners")

---@class CommandConfig
local CommandConfig = {
    key = "CommandConfig",
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
    local configRoot = CommandConfig._.config:GetConfigRoot()

    -- init config structure if missing
    local taint = false
    if configRoot.CommandConfig == nil then
        DebugLog("CommandConfig Section was not set, updating...")
        configRoot.CommandConfig = {}
        taint = true
    end
    CommandConfig._.configData = configRoot.CommandConfig
    if CommandConfig._.configData.activeChannels == nil then
        DebugLog("Active Channels were not set, updating...")
        CommandConfig._.configData.activeChannels = {}
        taint = true
    end
    if CommandConfig._.configData.owners == nil then
        DebugLog("Owners were not set, updating...")
        CommandConfig._.configData.owners = {}
        taint = true
    end
    if CommandConfig._.configData.commandOverrides == nil then
        DebugLog("CommandOverrides were not set, updating...")
        CommandConfig._.configData.commandOverrides = {}
        taint = true
    end
    if CommandConfig._.configData.eventOverrides == nil then
        DebugLog("EventOverrides were not set, updating...")
        CommandConfig._.configData.eventOverrides = {}
        taint = true
    end
    if taint then
        CommandConfig._.config:SaveConfig()
    end

    -- load overrides for commands
    for command, overrides in pairs(CommandConfig._.configData.commandOverrides) do
        if overrides.activeChannels ~= nil then
            Commands.SetPhrasePatternOverrides(command, Broadcast.GetPhrasePatterns(overrides.activeChannels))
        end

        if overrides.owners ~= nil then
            Commands.SetCommandOwnersOverrides(command, Owners.new(CommandConfig._.config, overrides.owners))
        end
    end

    -- load overrides for events
    for event, overrides in pairs(CommandConfig._.configData.eventOverrides) do
        if overrides.owners ~= nil then
            Commands.SetEventOwnersOverrides(event, Owners.new(CommandConfig._.config, overrides.owners))
        end
    end

    -- Init Commands
    local owners = Owners.new(CommandConfig._.config, CommandConfig._.configData.owners)
    Commands.Init(CommandConfig._.config, owners)
end

---Initialize the static object, only done once
---@param config Config
function CommandConfig.Init(config)
    if not CommandConfig._.isInit then
        local ftkey = Global.tracing.open("CommandConfig Setup")
        CommandConfig._.config = config

        -- Init any keys that were not setup
        initAndValidate()

        local configForCommands = CommandConfig._.configData

        -- Validation reminders

        if #configForCommands.activeChannels < 1 then
            print("Not currently listening on any active channels. To learn more, /chelp activechannels")
        else
            print("Currently listening on active channels: [" .. StringUtils.Join(CommandConfig._.configData.activeChannels, ", ") .. "]")
        end

        -- Binds

        local function Bind_ActiveChannels(...)
            local args = {...} or {}
            -- /activechannels
            if args == nil or #args < 1 then
                print("(/activechannels) Currently active channels: [" .. StringUtils.Join(CommandConfig._.configData.activeChannels, ", ") .. "]")
                return
            elseif #args == 1 then
                -- /activechannels <channel type>
                if Broadcast.IsChannelType(args[1]:lower()) then
                    print("(/activechannels " .. args[1] .. "):")
                    CommandConfig.ToggleActiveChannel(args[1]:lower())
                    return
                -- /activechannels <command>
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                    local command = args[1]:lower()
                    if configForCommands.commandOverrides[command] == nil or configForCommands.commandOverrides[command].activeChannels == nil then
                        print("(/activechannels ".. command .. ") No activechannel overrides for command [" .. command .. "]")
                    else
                        print("(/activechannels " .. command .. ") Currently active channels: [" .. StringUtils.Join(configForCommands.commandOverrides[command].activeChannels, ", ") .. "]")
                    end
                    return
                end
            -- /activechannels <command> <channel type | reset>
            elseif #args == 2 then
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                    local command = args[1]:lower()
                    local channelType = args[2]:lower()

                    if channelType == "reset" then
                        if configForCommands.commandOverrides[command] ~= nil then
                            configForCommands.commandOverrides[command].activeChannels = nil
                            CommandConfig._.config:SaveConfig()
                        end
                        Commands.SetPhrasePatternOverrides(command, nil)
                        print("(activechannels "..command.." "..channelType..") Removed active channel override for command: [" .. command .. "]")
                        return
                    end

                    -- init override
                    if configForCommands.commandOverrides[command] == nil then
                        configForCommands.commandOverrides[command] = {}
                    end
                    if configForCommands.commandOverrides[command].activeChannels == nil then
                        configForCommands.commandOverrides[command].activeChannels = {}
                    end

                    print("(/activechannels " .. args[1] .. " " .. args[2] .. "):")
                    CommandConfig.ToggleActiveChannel(channelType, configForCommands.commandOverrides[command])
                    Commands.SetPhrasePatternOverrides(command, Broadcast.GetPhrasePatterns(configForCommands.commandOverrides[command].activeChannels))
                    return
                end
            end

            print("(/activechannels) Channels used for listening to commands")
            print("To toggle an active channel, use: /activechannels <channel type>")
            print(" -- Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Broadcast.GetAllChannelTypes()), ", ") .. "]")
            print(" -- Currently active channels: [" .. StringUtils.Join(CommandConfig._.configData.activeChannels, ", ") .. "]")
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
                -- /owners open
                if args[1]:lower() == "open" then
                    local owners = Commands.GetCommandOwners("dne-global-owners")
                    owners:Open(not owners:IsOpen())
                    print("(/owners open) Set owners open: " .. owners:IsOpen())
                    return
                -- /owners <command>
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]) then
                    local command = args[1]:lower()
                    if configForCommands.commandOverrides[command] == nil or configForCommands.commandOverrides[command] == nil or configForCommands.commandOverrides[command].owners == nil then
                        print("(/owners "..command..") No owners overrides for command")
                    else
                        print("(/owners "..command..") Current owners: [" .. StringUtils.Join(configForCommands.commandOverrides[command].owners, ", ") .. "]")
                    end
                    return
                -- /owners <event>
                elseif TableUtils.ArrayContains(Commands.GetEventIds(), args[1]) then
                    local event = args[1]:lower()
                    if configForCommands.eventOverrides[event] == nil or configForCommands.eventOverrides[event].owners == nil then
                        print("(/owners "..event..") No owners overrides for command")
                    else
                        print("(/owners "..event..") Current owners: [" .. StringUtils.Join(configForCommands.eventOverrides[event].owners, ", ") .. "]")
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
            elseif #args == 2 then
                -- /owners <command> <name>
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]) then
                    local command = args[1]:lower()
                    local name = args[2]:lower()

                    -- /ownrs <command> reset
                    if name == "reset" then
                        if configForCommands.commandOverrides[command] ~= nil then
                            configForCommands.commandOverrides[command].owners = nil
                            CommandConfig._.config:SaveConfig()
                        end
                        Commands.SetCommandOwnersOverrides(command, nil)
                        print("(/owners "..command.." "..name..") Removed owner override for command: [" .. command .. "]")
                        return
                    end

                    -- init override
                    if configForCommands.commandOverrides[command] == nil then
                        configForCommands.commandOverrides[command] = {}
                    end
                    if configForCommands.commandOverrides[command].owners == nil then
                        configForCommands.commandOverrides[command].owners = {}
                        Commands.SetCommandOwnersOverrides(command, Owners.new(CommandConfig._.config, configForCommands.commandOverrides[command].owners))
                    end

                    -- /owners <command> open
                    if name == "open" then
                        local owners = Commands.GetCommandOwners(command)
                        owners:Open(not owners:IsOpen())
                        print("(/owners open) Set owners open: " .. tostring(owners:IsOpen()))
                        return
                    end

                    local owners = Commands.GetCommandOwners(command)
                    print("(/owners "..command.." "..name.."):")
                    if owners:IsOwner(name) then
                        owners:Remove(name)
                    else
                        owners:Add(name)
                    end
                    return
                -- /owners <event> <name>
                elseif TableUtils.ArrayContains(Commands.GetEventIds(), args[1]) then
                    local event = args[1]:lower()
                    local name = args[2]:lower()

                    -- /owners <event> reset
                    if name == "reset" then
                        if configForCommands.eventOverrides[event] ~= nil then
                            configForCommands.eventOverrides[event].owners = nil
                            CommandConfig._.config:SaveConfig()
                        end
                        Commands.SetEventOwnersOverrides(event, nil)
                        print("(/owners "..event.." "..name..") Removed owner override for command: [" .. event .. "]")
                        return
                    end

                    -- init override
                    if configForCommands.eventOverrides[event] == nil then
                        configForCommands.eventOverrides[event] = {}
                    end
                    if configForCommands.eventOverrides[event].owners == nil then
                        configForCommands.eventOverrides[event].owners = {}
                        Commands.SetEventOwnersOverrides(event, Owners.new(CommandConfig._.config, configForCommands.eventOverrides[event].owners))
                    end

                    -- /owners <event> open
                    if name == "open" then
                        local owners = Commands.GetCommandOwners(event)
                        owners:Open(not owners:IsOpen())
                        print("(/owners open) Set owners open: " .. tostring(owners:IsOpen()))
                        return
                    end

                    local owners = Commands.GetEventOwners(event)
                    print("(/owners "..event.." "..name.."):")
                    if owners:IsOwner(name) then
                        owners:Remove(name)
                    else
                        owners:Add(name)
                    end
                    return
                end
            end

            print("(/owners) Manage owners to take commands from")
            print("To add/remove owners, use: /owners <name>")
            print("To override owners for a specific communication command or event, use: /owners <command|event> <owner>")
            print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
            print(" -- Currently registered events: [" .. StringUtils.Join(Commands.GetEventIds(), ", ") .. "]")
            print(" -- View command overrides with: /owners <command|event>")
            print(" -- Reset command overrides with: /owners <command|event> reset")
            print(" -- To toggle allowing of any owner: /owners [<command|event>] open")
            Commands.GetCommandOwners("dne-global-owners"):Print()
        end
        Commands.RegisterSlashCommand("owners", Bind_Owners)

        CommandConfig.UpdateEventChannels()
        CommandConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---Toggles an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.ToggleActiveChannel(channel, configLocation)
    local generalConfig = configLocation or CommandConfig._.configData
    if not Broadcast.IsChannelType(channel) then
        print(" -- Invalid Channel Type [" .. channel .. "]. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Broadcast.GetAllChannelTypes()), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig.activeChannels, channel) then
        TableUtils.RemoveByValue(generalConfig.activeChannels, channel)
        print(" -- Removed [" .. channel .. "] as active channel")
    else
        generalConfig.activeChannels[#generalConfig.activeChannels + 1] = channel
        print(" -- Added [" .. channel .. "] to active channels")
    end
    CommandConfig._.config:SaveConfig()
    CommandConfig.UpdateEventChannels()
end

---Adds an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.AddChannel(channel, configLocation)
    local generalConfig = configLocation or CommandConfig._.configData
    if not Broadcast.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Broadcast.GetAllChannelTypes()), ", ") .. "]")
        return
    end
    if not TableUtils.ArrayContains(generalConfig.activeChannels, channel) then
        generalConfig.activeChannels[#generalConfig.activeChannels + 1] = channel
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
    local generalConfig = configLocation or CommandConfig._.configData
    if not Broadcast.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Broadcast.GetAllChannelTypes()), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig.activeChannels, channel) then
        TableUtils.RemoveByValue(generalConfig.activeChannels, channel)
        CommandConfig._.config:SaveConfig()
        print("Removed [" .. channel .. "] as active channel")
        CommandConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was not an active channel")
end

---Syncs registered events to all active channels
function CommandConfig.UpdateEventChannels()
    Commands.SetChannelPatterns(Broadcast.GetPhrasePatterns(CommandConfig._.configData.activeChannels))
end

function CommandConfig.Print()
    TableUtils.Print(CommandConfig._.configData)
end

return CommandConfig
