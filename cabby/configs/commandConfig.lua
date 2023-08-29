local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local Speak = require("cabby.commands.speak")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.menu")
local Owners = require("cabby.commands.owners")

---@type CabbyConfig
local CommandConfig = {
    key = "CommandConfig",
    _ = {
        isInit = false,
        config = {},
        menu = {
            activeChannels = {
                selectedCommandIndex = { value = 0 },
                selectedChannelIndex = { value = 0 },
                selectedAddChannelIndex = { value = 0 },
                selectedConfig = { value = {} },
                selectedUsesDefaults = { value = true }
            },
            speakChannels = {
                commands = {
                    selectedCommandIndex = { value = 0 },
                    selectedChannelIndex = { value = 0 },
                    selectedAddChannelIndex = { value = 0 },
                    selectedConfig = { value = {} },
                    selectedUsesDefaults = { value = true },
                    tellName = { value = "" }
                },
                events = {
                    selectedEventIndex = { value = 0 },
                    selectedChannelIndex = { value = 0 },
                    selectedAddChannelIndex = { value = 0 },
                    selectedConfig = { value = {} },
                    selectedUsesDefaults = { value = true },
                    tellName = { value = "" }
                }
            },
            owners = {
                commands = {
                    selectedCommandIndex = { value = 0 },
                    selectedChannelIndex = { value = 0 },
                    selectedAddChannelIndex = { value = 0 },
                    selectedConfig = { value = {} },
                    selectedUsesDefaults = { value = true },
                    tellName = { value = "" },
                    isOpen = { value = false }
                },
                events = {
                    selectedEventIndex = { value = 0 },
                    selectedChannelIndex = { value = 0 },
                    selectedAddChannelIndex = { value = 0 },
                    selectedConfig = { value = {} },
                    selectedUsesDefaults = { value = true },
                    tellName = { value = "" },
                    isOpen = { value = false }
                }
            }
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CommandConfig.key, str)
end

local function CleanSave()
    local configRoot = CommandConfig._.configData
    -- Clean empty command overrides
    for command, overrides in pairs(configRoot.commandOverrides) do
        if #TableUtils.GetKeys(overrides) <= 0 then
            configRoot.commandOverrides[command] = nil
        end
    end

    -- Clean empty event overrides
    for event, overrides in pairs(configRoot.eventOverrides) do
        if #TableUtils.GetKeys(overrides) <= 0 then
            configRoot.eventOverrides[event] = nil
        end
    end

    CommandConfig._.config:SaveConfig()
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
    if CommandConfig._.configData.speak == nil then
        DebugLog("Speak was not set, updating...")
        CommandConfig._.configData.speak = {}
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
            Commands.SetPhrasePatternOverrides(command, Speak.GetPhrasePatterns(overrides.activeChannels))
        end

        if overrides.owners ~= nil then
            Commands.SetCommandOwnersOverrides(command, Owners.new(CommandConfig._.config, overrides.owners))
        end

        if overrides.speak ~= nil then
            Commands.SetCommandSpeakOverrides(command, Speak.new(overrides.speak))
        end
    end

    -- load overrides for events
    for event, overrides in pairs(CommandConfig._.configData.eventOverrides) do
        if overrides.owners ~= nil then
            Commands.SetEventOwnersOverrides(event, Owners.new(CommandConfig._.config, overrides.owners))
        end

        if overrides.speak ~= nil then
            Commands.SetCommandSpeakOverrides(event, Speak.new(overrides.speak))
        end
    end

    -- Init Commands
    local owners = Owners.new(CommandConfig._.config, CommandConfig._.configData.owners)
    local speak = Speak.new(CommandConfig._.configData.speak)
---@diagnostic disable-next-line: param-type-mismatch
    Commands.Init(CommandConfig._.config, owners, speak)
end

---Initialize the static object, only done once
---@param config Config
---@diagnostic disable-next-line: duplicate-set-field
function CommandConfig.Init(config)
    if not CommandConfig._.isInit then
        local ftkey = Global.tracing.open("CommandConfig Setup")
        CommandConfig._.config = config

        -- Init any keys that were not setup
        initAndValidate()

        -- Validation reminders

        local configForCommands = CommandConfig._.configData
        if #configForCommands.activeChannels < 1 then
            print("Not currently listening on any active channels. To learn more, /chelp activechannels")
        else
            print("Currently listening on active channels: [" .. StringUtils.Join(CommandConfig._.configData.activeChannels, ", ") .. "]")
        end

        if #configForCommands.speak < 1 then
            print("Not currently speaking on any active channels. To learn more, /chelp speak")
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
                if Speak.IsChannelType(args[1]:lower()) then
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

                    print("(/activechannels " .. args[1] .. " " .. args[2] .. "):")
                    CommandConfig.ToggleActiveChannel(channelType, command)
                    Commands.SetPhrasePatternOverrides(command, Speak.GetPhrasePatterns(configForCommands.commandOverrides[command].activeChannels))
                    return
                end
            end

            print("(/activechannels) Channels used for listening to commands")
            print("To toggle an active channel, use: /activechannels <channel type>")
            print(" -- Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
            print(" -- Currently active channels: [" .. StringUtils.Join(CommandConfig._.configData.activeChannels, ", ") .. "]")
            print("To override active channels for a specific communication command, use: /activechannels <command> <channel type>")
            print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
            print(" -- View command overrides with: /activechannels <command>")
            print(" -- Reset command overrides with: /activechannels <command> reset")
        end
        Commands.RegisterSlashCommand("activechannels", Bind_ActiveChannels)

        local function Bind_Speak(...)
            local args = {...} or {}

            -- /speak
            if args == nil or #args < 1 then
                print("(/speak):")
                Commands.GetCommandSpeak("dne-global-speak"):Print()
                return
            elseif #args == 1 then
                -- /speak <channeltype>
                if Speak.IsChannelType(args[1]) and not Speak.IsTellType(args[1]) then
                    print("(/speak " .. args[1] .. "):")
                    CommandConfig.ToggleSpeakChannel(args[1]:lower())
                    return
                end

                -- /speak <command>
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]) then
                    local command = args[1]:lower()
                    print("(/speak " .. command .. "):")
                    Commands.GetCommandSpeak(command):Print()
                    return
                end

                -- /speak <event>
                if TableUtils.ArrayContains(Commands.GetEventIds(), args[1]) then
                    local event = args[1]:lower()
                    print("(/speak " .. event .. "):")
                    Commands.GetEventSpeak(event):Print()
                    return
                end
            elseif #args == 2 then
                -- /speak <channeltype> [tellto]
                if Speak.IsTellType(args[1]) then
                    print("(/speak " .. args[1] .. " " .. args[2] .. "):")
                    CommandConfig.ToggleSpeakChannel(args[1]:lower(), args[2]:lower())
                    return
                end

                -- /speak <command> <channeltype | reset>
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]) then
                    print("(/speak " .. args[1] .. " " .. args[2] .. ")")
                    CommandConfig.ToggleSpeakChannel(args[2]:lower(), nil, args[1]:lower())
                end

                -- /speak <event> <channeltype | reset>
                if TableUtils.ArrayContains(Commands.GetEventIds(), args[1]) then
                    print("(/speak " .. args[1] .. " " .. args[2] .. ")")
                    CommandConfig.ToggleSpeakChannel(args[2]:lower(), nil, args[1]:lower(), true)
                end
            elseif #args == 3 then
                print("(/speak " .. args[1] .. " " .. args[2] .. " " .. args[3] .. ")")

                -- /speak <command> <channeltype> [tellto]
                if TableUtils.ArrayContains(Commands.GetCommsPhrases(), args[1]:lower()) then
                    CommandConfig.ToggleSpeakChannel(args[2]:lower(), args[3], args[1]:lower())
                -- /speak <event> <channeltype> [tellto]
                elseif TableUtils.ArrayContains(Commands.GetEventIds(), args[1]) then
                    CommandConfig.ToggleSpeakChannel(args[2]:lower(), args[3], args[1]:lower(), true)
                end
            end

            -- /speak
            -- /speak <channeltype> [tellTo]
            -- /speak <command | event>
            -- /speak <command | event> <channeltype | reset> [tellTo]
            print("(/speak) Manage which channels that commands/events respond in")
            print(" -- To add/remove a speak channel, use: /speak <channel>")
            print(" -- To override speaks for a specific communication command or event, use: /speak <command|event> <channel>")
            print(" -- View command overrides with: /owners <command|event>")
            print(" -- To remove overrides, use: /speak <command|event> reset")
            print(" -- Currently registered commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]")
            print(" -- Currently registered events: [" .. StringUtils.Join(Commands.GetEventIds(), ", ") .. "]")
            Commands.GetCommandSpeak("dne-global-owners"):Print()
        end
        Commands.RegisterSlashCommand("speak", Bind_Speak)

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

                    -- /owners <command> reset
                    if name == "reset" then
                        if configForCommands.commandOverrides[command] ~= nil then
                            configForCommands.commandOverrides[command].owners = nil
                            CleanSave()
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
                            CleanSave()
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
        Menu.RegisterConfig(CommandConfig)

        CommandConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---Toggles an active command channel
---@param channel string Available types found in Speak.channelTypes
---@param command string? command phrase to work on active channels within
function CommandConfig.ToggleActiveChannel(channel, command)
    local config = CommandConfig._.configData
    if command ~= nil then
        config = config.commandOverrides[command]

        if channel == "reset" then
            Commands.SetPhrasePatternOverrides(command, nil)
            if config ~= nil then
                config.activeChannels = nil
                CleanSave()
            else
                CommandConfig._.config:SaveConfig()
            end
            CommandConfig.UpdateEventChannels()
            print("Removed active channel override for command: [" .. command .. "]")
            return
        end

        -- init override
        if config == nil then
            CommandConfig._.configData.commandOverrides[command] = {}
            config = CommandConfig._.configData.commandOverrides[command]
        end
        if config.activeChannels == nil then
            config.activeChannels = {}
        end
    end

    if not Speak.IsChannelType(channel) then
        print(" -- Invalid Channel Type [" .. channel .. "]. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(config.activeChannels, channel) then
        TableUtils.RemoveByValue(config.activeChannels, channel)
        print(" -- Removed [" .. channel .. "] as active channel")
    else
        config.activeChannels[#config.activeChannels + 1] = channel
        print(" -- Added [" .. channel .. "] to active channels")
    end
    CommandConfig._.config:SaveConfig()
    CommandConfig.UpdateEventChannels()
end

---Adds an active command channel
---@param channel string Available types found in Speak.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.AddActiveChannel(channel, configLocation)
    local generalConfig = configLocation or CommandConfig._.configData
    if not Speak.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
        return
    end

    if generalConfig.activeChannels == nil then
        generalConfig.activeChannels = {}
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
---@param channel string Available types found in Speak.channelTypes
---@param configLocation table? table to work on active channels within
function CommandConfig.RemoveActiveChannel(channel, configLocation)
    local generalConfig = configLocation or CommandConfig._.configData
    if not Speak.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
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

---Toggles a speak command channel
---@param channel string Available types found in Speak.channelTypes
---@param to string? required for tell speak types
---@param commandOrEvent string? command/event phrase to modify speak channels for
---@param isEventType boolean? Defaults to Command
function CommandConfig.ToggleSpeakChannel(channel, to, commandOrEvent, isEventType)
    if isEventType == nil then isEventType = false end
    local overrides = "commandOverrides"
    if isEventType then overrides = "eventOverrides" end

    local config = CommandConfig._.configData
    if commandOrEvent ~= nil then
        config = config[overrides][commandOrEvent]

        if channel == "reset" then
            if config ~= nil then
                config.speak = nil
                CleanSave()
            else
                CommandConfig._.config:SaveConfig()
            end

            if isEventType then
                Commands.SetEventSpeakOverrides(commandOrEvent, nil)
                print(" -- Removed speak override for event: [" .. commandOrEvent .. "]")
            else
                Commands.SetCommandSpeakOverrides(commandOrEvent, nil)
                print(" -- Removed speak override for command: [" .. commandOrEvent .. "]")
            end
            return
        end

        -- init override
        if config == nil then
            CommandConfig._.configData[overrides][commandOrEvent] = {}
            config = CommandConfig._.configData[overrides][commandOrEvent]
        end
        if config.speak == nil then
            config.speak = {}
        end
    end

    if not Speak.IsChannelType(channel) then
        print(" -- Invalid Channel Type [" .. channel .. "]. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
        return
    end

    if Speak.IsTellType(channel) == (to == nil) then
        print(" -- Invalid Channel with To. The `to` field must be used for tell-type channels.")
    end

    if to ~= nil then
        channel = channel .. " " .. to
    end

    if TableUtils.ArrayContains(config.speak, channel) then
        print("( -- Removed [" .. channel .. "] as speak channel")
        TableUtils.RemoveByValue(config.speak, channel)
    else
        print(" -- Added [" .. channel .. "] as speak channel")
        table.insert(config.speak, channel)
    end
    CommandConfig._.config:SaveConfig()

    local speak = Speak.new(config.speak)
    if commandOrEvent ~= nil then
        
        if isEventType then
            Commands.SetEventSpeakOverrides(commandOrEvent, speak)
        else
            Commands.SetCommandSpeakOverrides(commandOrEvent, speak)
        end
    else
        ---@diagnostic disable-next-line: param-type-mismatch
        Commands.SetSpeak(speak)
    end
end

---Adds a speak command channel
---@param channel string Available types found in Speak.channelTypes
---@param configLocation table? table to work on active channels within
---@param to string? required for tell speak types
function CommandConfig.AddSpeakChannel(channel, configLocation, to)
    local config = configLocation or CommandConfig._.configData
    if not Speak.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
        return
    end

    if config.speak == nil then
        config.speak = {}
    end

    if Speak.IsTellType(channel) == (to == nil) then
        print("Invalid Channel with To. The `to` field must be used for (and only for) tell-type channels.")
        return
    end

    if to ~= nil then
        channel = channel .. " " .. to
    end

    if not TableUtils.ArrayContains(config.speak, channel) then
        config.speak[#config.speak + 1] = channel
        print("Added [" .. channel .. "] as speak channel")
        CommandConfig._.config:SaveConfig()
    end
    DebugLog(channel .. " was already a speak channel")
end

---Removes a speak command channel
---@param channel string Available types found in Speak.channelTypes
---@param configLocation table? table to work on active channels within
---@param to string? required for tell speak types
function CommandConfig.RemoveSpeakChannel(channel, configLocation, to)
    local generalConfig = configLocation or CommandConfig._.configData
    if not Speak.IsChannelType(channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(Speak.GetAllChannelTypes()), ", ") .. "]")
        return
    end

    if Speak.IsTellType(channel) == (to == nil) then
        print("Invalid Channel with To. The `to` field must be used for tell-type channels.")
        return
    end

    if to ~= nil then
        channel = channel .. " " .. to
    end

    if TableUtils.ArrayContains(generalConfig.speak, channel) then
        TableUtils.RemoveByValue(generalConfig.speak, channel)
        CommandConfig._.config:SaveConfig()
        print("Removed [" .. channel .. "] as speak channel")
        CommandConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was not a speak channel")
end

---Toggles an owner
---@param name string Any character name, "reset", "open"
---@param commandOrEvent string? command/event phrase to modify owners for
---@param isEventType boolean? Defaults to Command
function CommandConfig.ToggleOwner(name, commandOrEvent, isEventType)
    if isEventType == nil then isEventType = false end
    local overrides = "commandOverrides"
    if isEventType then overrides = "eventOverrides" end

    local config = CommandConfig._.configData
    local owners = Commands.GetCommandOwners("dne-global-owners")
    if commandOrEvent ~= nil then
        config = config[overrides][commandOrEvent]

        if name == "reset" then
            if config ~= nil then
                config.owners = nil
                CleanSave()
            else
                CommandConfig._.config:SaveConfig()
            end

            if isEventType then
                Commands.SetEventOwnersOverrides(commandOrEvent, nil)
                print(" -- Removed owner override for event: [" .. commandOrEvent .. "]")
            else
                Commands.SetCommandOwnersOverrides(commandOrEvent, nil)
                print(" -- Removed owner override for command: [" .. commandOrEvent .. "]")
            end
            return
        end

        -- init override
        if config == nil then
            CommandConfig._.configData[overrides][commandOrEvent] = {}
            config = CommandConfig._.configData[overrides][commandOrEvent]
        end
        if config.owners == nil then
            config.owners = {}
            config.owners.open = false
        end
        config.owners.list = config.owners.list or {}
        owners = Owners.new(CommandConfig._.config, config)
    end

    if owners:IsOwner(name) then
        owners:Remove(name)
    else
        owners:Add(name)
    end

    if commandOrEvent ~= nil then
        if isEventType then
            Commands.SetEventOwnersOverrides(commandOrEvent, owners)
        else
            Commands.SetCommandOwnersOverrides(commandOrEvent, owners)
        end
    end

    CommandConfig._.config:SaveConfig()
end

---Adds an owner
---@param name string Any character name
---@param owners Owners
function CommandConfig.AddOwner(name, owners)
    if not owners:IsOwner(name) then
        owners:Add(name)
    end
    DebugLog(name .. " was already an owner")
end

---Removes an owner
---@param name string Any character name
---@param owners Owners
function CommandConfig.RemoveOwner(name, owners)
    if owners:IsOwner(name) then
        owners:Remove(name)
    end
    DebugLog(name .. " was not an owner")
end

---Syncs registered events to all active channels
function CommandConfig.UpdateEventChannels()
    Commands.SetChannelPatterns(Speak.GetPhrasePatterns(CommandConfig._.configData.activeChannels))
end

function CommandConfig.Print()
    TableUtils.Print(CommandConfig._.configData)
end

---@param commandOrEvent string "Command" or "Event"
---@param overrideHelpText string
---@param allCommandsOrEventsList table
---@param selectedCommandEventIndex table command combobox selected
---@param selectedSubtypeIndex table subtype listbox selected
---@param selectedAddSubtypeIndex table subtype combobox selected
---@param selectedConfig table CommandConfig or CommandConfig.xOverrides.commandEvent
---@param selectedUsesDefaults table
---@param tellName table? nil if don't need tell names
---@param subType string activeChannels, speak, owners
---@param allSubtypeList array? nil for no list, names only
---@param addFunc function
---@param removeFunc function
---@param isOpen table?
local function buildCommandEventEditor(commandOrEvent, overrideHelpText, allCommandsOrEventsList, selectedCommandEventIndex, selectedSubtypeIndex,
    selectedAddSubtypeIndex, selectedConfig, selectedUsesDefaults, tellName, subType, allSubtypeList, addFunc, removeFunc, isOpen)
    -- Build command/event list
    local commandOrEventOverrideType = commandOrEvent:lower() .. "Overrides"
    local selectedCommandEvent = "Default"
    if selectedCommandEventIndex.value > 0 then
        selectedCommandEvent = allCommandsOrEventsList[selectedCommandEventIndex.value]
    end

    -- Build commands/events combo box
    ImGui.AlignTextToFramePadding()
    ImGui.TextUnformatted(commandOrEvent .. ":")
    ImGui.SameLine()
    ImGui.PushItemWidth(120)
    if ImGui.BeginCombo("##foo1", selectedCommandEvent) then
        if ImGui.Selectable("Default", selectedCommandEventIndex.value == 0) then
            selectedCommandEventIndex.value = 0
        end

        for index, channel in ipairs(allCommandsOrEventsList) do
            if ImGui.Selectable(channel, selectedCommandEventIndex.value == index) then
                selectedCommandEventIndex.value = index
            end
        end
        selectedSubtypeIndex.value = 0
        selectedAddSubtypeIndex.value = 0
        ImGui.EndCombo()
    end

    -- Update subtype list for selected command/event
    if selectedCommandEventIndex.value <= 0 then
        selectedConfig.value = CommandConfig._.configData
        selectedUsesDefaults.value = true
    else
        local override = CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent]
        if override ~= nil and override[subType] ~= nil then
            selectedConfig.value = override
            selectedUsesDefaults.value = false
        else
            selectedConfig.value = CommandConfig._.configData
            selectedUsesDefaults.value = true
        end
    end

    -- Build subtype list
    local subTypeCount = 0
    ImGui.BeginChild("listItems", 200, 210, true)
        if selectedConfig.value[subType] ~= nil then
            local subTypeList = selectedConfig.value[subType]
            if allSubtypeList == nil then
                subTypeList = subTypeList.list
            end
            for i, subTypeItem in ipairs(subTypeList) do
                if ImGui.Selectable(subTypeItem, selectedSubtypeIndex.value == i) then
                    selectedSubtypeIndex.value = i
                end
                subTypeCount = subTypeCount + 1
            end
        end
    ImGui.EndChild()

    -- Fix for showing same default list for commands / events and removing the currently selected index for other side
    if subTypeCount < selectedSubtypeIndex.value then
        selectedSubtypeIndex.value = 0
    end

    -- Build right side options
    ImGui.SameLine()
    ImGui.BeginGroup()
        ImGui.BeginDisabled()
        ImGui.Checkbox("Uses Default", selectedUsesDefaults.value)
        ImGui.EndDisabled()

        -- Remove-Selected Button
        if selectedSubtypeIndex.value <= 0 then
            ImGui.BeginDisabled()
        end
        if ImGui.Button("Remove Selected", 120, 22) then
            if selectedSubtypeIndex.value > 0 then
                if allSubtypeList == nil then
                    ---@type Owners
                    local owners
                    if commandOrEvent:lower() == "command" then
                        owners = Commands.GetCommandOwners(selectedCommandEvent)
                    else
                        owners = Commands.GetEventOwners(selectedCommandEvent)
                    end
                    removeFunc(selectedConfig.value[subType].list[selectedSubtypeIndex.value], owners)
                else
                    if selectedUsesDefaults.value and selectedCommandEventIndex.value > 0 then
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] = CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] or {}
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent][subType] = TableUtils.DeepClone(CommandConfig._.configData[subType])
                        selectedConfig.value = CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent]
                    end
                    local removeValues = StringUtils.Split(selectedConfig.value[subType][selectedSubtypeIndex.value])
                    if #removeValues > 1 then
                        removeFunc(removeValues[1], selectedConfig.value, removeValues[2])
                    else
                        removeFunc(removeValues[1], selectedConfig.value)
                    end
                end
                selectedSubtypeIndex.value = 0
            end
        end
        if selectedSubtypeIndex.value <= 0 then
            ImGui.EndDisabled()
        end

        -- Reset Button
        if selectedUsesDefaults.value then
            ImGui.BeginDisabled()
        end
        if ImGui.Button("Reset to Defaults", 120, 22) then
            if CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] ~= nil then
                CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent][subType] = nil
                CleanSave()
            end
        end
        if selectedUsesDefaults.value then
            ImGui.EndDisabled()
        end

        -- IsOpen Checkbox
        if isOpen ~= nil then
            ---@type boolean
            local openClicked
            isOpen.value, openClicked = ImGui.Checkbox("Open", isOpen.value)
            if openClicked then
                if selectedCommandEventIndex.value > 0 then
                    -- init override
                    if CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] == nil then
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] = {}
                    end
                    if CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners == nil then
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners = TableUtils.DeepClone(CommandConfig._.configData.owners)
                        Commands.SetCommandOwnersOverrides(selectedCommandEvent, Owners.new(CommandConfig._.config, CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners))
                    end
                end

                ---@type Owners
                local owners
                if commandOrEvent:lower() == "command" then
                    owners = Commands.GetCommandOwners(selectedCommandEvent)
                else
                    owners = Commands.GetEventOwners(selectedCommandEvent)
                end
                ---@diagnostic disable-next-line: need-check-nil
                print(tostring(isOpen.value))
                owners:Open(isOpen.value)
            end
            ImGui.SameLine()
            Menu.HelpMarker("When Open, the list is ignored and all speakers are allowed to issue this command.")
        end

        -- Add Button here if no subType list
        ImGui.BeginChild("separator", 1, 70)
        ImGui.EndChild()
        if allSubtypeList == nil then
            local isDisabled = false
            if tellName == nil or tellName.value == "" then
                ImGui.BeginDisabled()
                isDisabled = true
            end
            if ImGui.Button("Add", 70, 22) then
                if selectedCommandEventIndex.value > 0 then
                    -- init override
                    if CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] == nil then
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] = {}
                    end
                    if CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners == nil then
                        CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners = TableUtils.DeepClone(CommandConfig._.configData.owners)
                        Commands.SetCommandOwnersOverrides(selectedCommandEvent, Owners.new(CommandConfig._.config, CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent].owners))
                    end
                end

                ---@type Owners
                local owners
                if commandOrEvent:lower() == "command" then
                    owners = Commands.GetCommandOwners(selectedCommandEvent)
                else
                    owners = Commands.GetEventOwners(selectedCommandEvent)
                end
                ---@diagnostic disable-next-line: need-check-nil
                addFunc(tellName.value, owners)

                selectedAddSubtypeIndex.value = 0
                if tellName ~= nil then tellName.value = "" end
            end
            if isDisabled then
                ImGui.EndDisabled()
            end
        end
    ImGui.EndGroup()

    -- Build available subtype Combo Box
    local comboDisplay = ""
    if allSubtypeList ~= nil then
        ---@type table
        ---@diagnostic disable-next-line: assign-type-mismatch
        local subtractConfig = TableUtils.DeepClone(selectedConfig.value[subType] or CommandConfig._.configData[subType])
        for index, subType in ipairs(subtractConfig) do
            subtractConfig[index] = StringUtils.Split(subType)[1]
        end
        local availableSubtypes = TableUtils.ArraySubtract(allSubtypeList, subtractConfig)
        if selectedAddSubtypeIndex.value > 0 then
            comboDisplay = availableSubtypes[selectedAddSubtypeIndex.value]
        end
        if ImGui.BeginCombo("##foo2", comboDisplay) then
            for index, channel in ipairs(availableSubtypes) do
                if ImGui.Selectable(channel, selectedAddSubtypeIndex.value == index) then
                    selectedAddSubtypeIndex.value = index
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()

        -- Build Add Button
        local needsTellName = tellName ~= nil and tellName.value == "" and Speak.IsTellType(comboDisplay)
        local isDisabled = false
        if comboDisplay == "" or needsTellName then
            ImGui.BeginDisabled()
            isDisabled = true
        end
        if ImGui.Button("Add", 70, 22) then
            if selectedUsesDefaults.value and selectedCommandEventIndex.value > 0 then
                CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] = CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent] or {}
                CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent][subType] = TableUtils.DeepClone(CommandConfig._.configData[subType])
                selectedConfig.value = CommandConfig._.configData[commandOrEventOverrideType][selectedCommandEvent]
            end

            if tellName ~= nil and tellName.value ~= "" and Speak.IsTellType(comboDisplay) then
                ---@diagnostic disable-next-line: need-check-nil
                addFunc(comboDisplay, selectedConfig.value, tellName.value)
            else
                addFunc(comboDisplay, selectedConfig.value)
            end

            selectedAddSubtypeIndex.value = 0
            if tellName ~= nil then tellName.value = "" end
        end
        if isDisabled then
            ImGui.EndDisabled()
        end
    end

    -- Build Tell Type
    if tellName ~= nil then
        if allSubtypeList ~= nil and not Speak.IsTellType(comboDisplay) then
            ImGui.BeginDisabled()
            ImGui.InputTextWithHint("Name##foo3", "(disabled)", "")
            ImGui.EndDisabled()
        else
            tellName.value = ImGui.InputTextWithHint("Name##foo4", "Enter Name", tellName.value)
        end
    end

    -- Build Override List
    ImGui.Text("")
    ImGui.Text("Overridden " .. commandOrEvent .. "s")
    ImGui.SameLine()
    Menu.HelpMarker(overrideHelpText)
    ImGui.BeginChild("overrideCommands" .. overrideHelpText, 200, 210, true)
        for thisCommand, overrides in pairs(CommandConfig._.configData[commandOrEventOverrideType]) do
            if overrides[subType] ~= nil then
                if ImGui.Selectable(thisCommand, false) then
                    for index, thatCommand in ipairs(allCommandsOrEventsList) do
                        if thisCommand == thatCommand then
                            selectedCommandEventIndex.value = index
                        end
                    end
                end
            end
        end
    ImGui.EndChild()
end

local function buildActiveChannelTab()
    if ImGui.BeginTabItem("Active Channels") then
        ImGui.Text("Active Channels are where this character will listen for commands from other characters.")
        ImGui.Text("")
        ImGui.PushID("activechannels")
        buildCommandEventEditor(
            "Command",
            "All commands follow the `Default` channel list but can be overridden. This list shows which commands have overrides.",
            Commands.GetCommsPhrases(),
            CommandConfig._.menu.activeChannels.selectedCommandIndex,
            CommandConfig._.menu.activeChannels.selectedChannelIndex,
            CommandConfig._.menu.activeChannels.selectedAddChannelIndex,
            CommandConfig._.menu.activeChannels.selectedConfig,
            CommandConfig._.menu.activeChannels.selectedUsesDefaults,
            nil,
            "activeChannels",
            Speak.GetAllChannelTypes(),
            CommandConfig.AddActiveChannel,
            CommandConfig.RemoveActiveChannel
        )
        ImGui.PopID()
        ImGui.EndTabItem()
    end
end

local function buildSpeakChannelTab()
    if ImGui.BeginTabItem("Speak Channels") then
        ImGui.Text("Speak Channels are where this character will broadcast information from commands or events.")
        ImGui.Text("")

        ImGui.BeginTable("speak table", 2, ImGuiTableFlags.BordersInnerV)
            ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed)
            ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableNextColumn()

            ImGui.PushID("speakcommands")
            buildCommandEventEditor(
                "Command",
                "All commands follow the `Default` speak list but can be overridden. This list shows which commands have overrides.",
                Commands.GetCommsPhrases(),
                CommandConfig._.menu.speakChannels.commands.selectedCommandIndex,
                CommandConfig._.menu.speakChannels.commands.selectedChannelIndex,
                CommandConfig._.menu.speakChannels.commands.selectedAddChannelIndex,
                CommandConfig._.menu.speakChannels.commands.selectedConfig,
                CommandConfig._.menu.speakChannels.commands.selectedUsesDefaults,
                CommandConfig._.menu.speakChannels.commands.tellName,
                "speak",
                Speak.GetAllChannelTypes(),
                CommandConfig.AddSpeakChannel,
                CommandConfig.RemoveSpeakChannel
            )
            ImGui.PopID()

            ImGui.TableNextColumn()
            ImGui.PushID("speakevents")
            buildCommandEventEditor(
                "Event",
                "All events follow the `Default` speak list but can be overridden. This list shows which events have overrides.",
                Commands.GetEventIds(),
                CommandConfig._.menu.speakChannels.events.selectedEventIndex,
                CommandConfig._.menu.speakChannels.events.selectedChannelIndex,
                CommandConfig._.menu.speakChannels.events.selectedAddChannelIndex,
                CommandConfig._.menu.speakChannels.events.selectedConfig,
                CommandConfig._.menu.speakChannels.events.selectedUsesDefaults,
                CommandConfig._.menu.speakChannels.events.tellName,
                "speak",
                Speak.GetAllChannelTypes(),
                CommandConfig.AddSpeakChannel,
                CommandConfig.RemoveSpeakChannel
            )
            ImGui.PopID()
        ImGui.EndTable()

        ImGui.EndTabItem()
    end
end

local function buildOwnerChannelTab()
    if ImGui.BeginTabItem("Owners") then
        ImGui.Text("Owners are who have rights to give this character commands or invoke certain events.")
        ImGui.Text("")

        ImGui.BeginTable("owner table", 2, ImGuiTableFlags.BordersInnerV)
            ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed)
            ImGui.TableSetupColumn("", ImGuiTableColumnFlags.WidthStretch)
            ImGui.TableNextColumn()

            ImGui.PushID("owner commands")
            buildCommandEventEditor(
                "Command",
                "All commands follow the `Default` owner list but can be overridden. This list shows which commands have overrides.",
                Commands.GetCommsPhrases(),
                CommandConfig._.menu.owners.commands.selectedCommandIndex,
                CommandConfig._.menu.owners.commands.selectedChannelIndex,
                CommandConfig._.menu.owners.commands.selectedAddChannelIndex,
                CommandConfig._.menu.owners.commands.selectedConfig,
                CommandConfig._.menu.owners.commands.selectedUsesDefaults,
                CommandConfig._.menu.owners.commands.tellName,
                "owners",
                nil,
                CommandConfig.AddOwner,
                CommandConfig.RemoveOwner,
                CommandConfig._.menu.owners.commands.isOpen
            )
            ImGui.PopID()

            ImGui.TableNextColumn()
            ImGui.PushID("owner events")
            buildCommandEventEditor(
                "Event",
                "All events follow the `Default` owner list but can be overridden. This list shows which events have overrides.",
                Commands.GetEventIds(),
                CommandConfig._.menu.owners.events.selectedEventIndex,
                CommandConfig._.menu.owners.events.selectedChannelIndex,
                CommandConfig._.menu.owners.events.selectedAddChannelIndex,
                CommandConfig._.menu.owners.events.selectedConfig,
                CommandConfig._.menu.owners.events.selectedUsesDefaults,
                CommandConfig._.menu.owners.events.tellName,
                "owners",
                nil,
                CommandConfig.AddOwner,
                CommandConfig.RemoveOwner,
                CommandConfig._.menu.owners.events.isOpen
            )
            ImGui.PopID()
        ImGui.EndTable()

        ImGui.EndTabItem()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CommandConfig.BuildMenu()
    ImGui.BeginTabBar("Command Tabs")
        buildActiveChannelTab()
        buildSpeakChannelTab()
        buildOwnerChannelTab()
    ImGui.EndTabBar()
end

return CommandConfig
