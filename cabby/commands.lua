local mq = require("mq")
local Config = require("utils.Config.Config")
local GeneralConfig = require("cabby.configs.GeneralConfig")
local Owners = require("utils.Owners.Owners")
local Priorities = require("cabby.priorities")
local PriorityQueueFunctionContent = require("utils.PriorityQueue.PriorityQueueFunctionContent")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Commands
local Commands = {
    debug = false,
    configKey = "Commands",
    eventIds = {
        followMe = "Follow Me",
        stopFollow = "Stop Follow",
        moveToMe = "Move to Me",
        tellToMe = "Tell to Me"
    },
    channelTypes = {
        bc = "bc",
        tell = "tell",
        raid = "raid",
        group = "group"
    },
    eventsRegistered = false
}

---comment
---@param priorityQueue PriorityQueue
---@return Commands
function Commands:new(configFilePath, priorityQueue)
    local commands = {}
    setmetatable(commands, self)
    self.__index = self
    commands.priorityQueue = priorityQueue
    local config = Config:new(configFilePath)
    local owners = Owners:new(configFilePath)

    local function Debug(str)
        if Commands.debug then print(str) end
    end

    ---Decides if should listen to command, then schedules it in the priority queue
    ---@param speaker string - Who issued command, must be listed in owners to listen
    ---@param priority number
    ---@param command FunctionContent
    ---@param who? string This command was told to this name specifically
    ---@return boolean - true if command scheduled, false if ignored
    local function ScheduleCommand(speaker, priority, command, who)
        who = who or "all"
        Debug("Received command from [" .. speaker .. "] with priority [" .. tostring(priority) .. "] directed at: [" .. who .. "]: " .. command.identity)
        if who ~= "all" and who:lower() ~= mq.TLO.Me.Name():lower() then
            Debug("Ignoring command, was issued to: [" .. mq.TLO.Me.Name() .. "]")
            return false
        end

        if not Owners:IsOwner(speaker) then
            Debug("Ignoring command, speaker was not an owner [" .. speaker .. "]")
            return false
        end

        Debug("Inserting command: " .. command.identity)
        commands.priorityQueue:InsertNewJob(priority, command)
        return true
    end

    ---Adds this event to all registered channels
    ---@param eventId string
    ---@param phrase string
    ---@param eventFunction function
    local function AddEventChannels(eventId, phrase, eventFunction)
        mq.unevent(eventId)
        local commandsConfig = config:GetConfig(Commands.configKey)
        local channels = commandsConfig.Channels or {}
        if TableUtils.ArrayContains(channels, Commands.channelTypes.bc) then
            mq.event(eventId, "<#1#> " .. phrase, eventFunction)
            mq.event(eventId, "<#1#> #2# " .. phrase, eventFunction)
            mq.event(eventId, "[#1#(msg)] " .. phrase, eventFunction)
        end
        if TableUtils.ArrayContains(channels, Commands.channelTypes.tell) then
            mq.event(eventId, "<#1#> tells you, '" .. phrase .. "'", eventFunction)
        end
        if TableUtils.ArrayContains(channels, Commands.channelTypes.group) then
            mq.event(eventId, "<#1#> tells the group, '" .. phrase .. "'", eventFunction)
        end
        if TableUtils.ArrayContains(channels, Commands.channelTypes.raid) then
            mq.event(eventId, "<#1#> tells the raid, '" .. phrase .. "'", eventFunction)
        end
    end

    -----------------------------------------------------------------------------
    ------------------------------- COMMS ---------------------------------------
    -----------------------------------------------------------------------------

    local function event_FollowMe(_, speaker, who)
        local followMe = PriorityQueueFunctionContent:new("Follow Me - " .. speaker, function() return print("insert follow me here") end)
        ScheduleCommand(speaker, Priorities.Following, followMe, who)
    end

    local function event_StopFollow(_, speaker, who)
        local stopFollow = PriorityQueueFunctionContent:new("Stop Follow - " .. speaker, function() return print("insert follow me here") end)
        ScheduleCommand(speaker, Priorities.Following, stopFollow, who)
    end

    -----------------------------------------------------------------------------
    ----------------------------- END COMMS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------ EVENTS ---------------------------------------
    -----------------------------------------------------------------------------

    local function tellToMe(speaker, message)
        local generalConfig = GeneralConfig:new(configFilePath)
        local tellTo = generalConfig:GetRelayTellsTo()
        if tellTo ~= speaker and mq.TLO.SpawnCount("npc speaker")() < 1 then
            mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
        end
        return true
    end
    local function event_TellToMe(_, speaker, message)
        local tellToMeFunc = PriorityQueueFunctionContent:new("Tell to me - " .. speaker, function() return tellToMe(speaker, message) end)
        commands.priorityQueue:InsertNewJob(Priorities.Immediate, tellToMeFunc)
    end
    mq.event(Commands.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe)

    -----------------------------------------------------------------------------
    ---------------------------- END EVENTS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------- BINDS ---------------------------------------
    -----------------------------------------------------------------------------

    local function chelpPrint()
        print("(/chelp) Cabby Help menu")
        print(" -- Pick a help topic. Options: [Comms, Commands]")
    end
    local function Bind_Chelp(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            chelpPrint()
        elseif args[1]:lower() == "comms" then
            print("(/chelp comms) Leverage these by speaking in active channels")
            print(" -- For example: /bc followme")
            print(" -- To see active channels, use /activechannels")
            print(" -- To add / remove channels, use /addchannel name, /removechannel name")
            print("Command list:")
            print(" -- followme")
            print(" -- stopfollow")
        elseif args[1]:lower() == "commands" then
            print("(/chelp commands) Slash Commands:")
            print(" -- /chelp")
            print(" -- /addowner")
            print(" -- /removeowner")
            print(" -- /showowners")
        else
            chelpPrint()
        end
    end
    mq.bind("/chelp", Bind_Chelp)

    -----------------------------------------------------------------------------

    local function addOwner(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            print("(/addowner) Adds Owners to listen to")
            print(" -- Usage: /addowner name")
        else
            owners:Add(args[1])
        end
    end
    mq.bind("/addowner", addOwner)

    -----------------------------------------------------------------------------

    local function removeOwner(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            print("(/removeowner) Removes Owners to listen to")
            print(" -- Usage: /removeowner name")
        else
            owners:Remove(args[1])
        end
    end
    mq.bind("/removeowner", removeOwner)

    -----------------------------------------------------------------------------

    local function showOwners(...)
        owners:Print()
    end
    mq.bind("/showowners", showOwners)

    -----------------------------------------------------------------------------

    local function setRelayTellsToFunc(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            print("(/relaytellsto) Relays tells received to this character")
            print(" -- Usage: /relaytellsto name")
        else
            local generalConfig = GeneralConfig:new(configFilePath)
            generalConfig:SetRelayTellsTo(args[1])
            print("Relaying future tells to: [" .. generalConfig:GetRelayTellsTo() .. "]")
        end
    end
    mq.bind("/relaytellsto", setRelayTellsToFunc)

    -----------------------------------------------------------------------------
    ----------------------------- END BINDS -------------------------------------
    -----------------------------------------------------------------------------

    local function RegisterAllComms()
        if Commands.eventsRegistered then return end
        Commands.eventsRegistered = true
        AddEventChannels(Commands.eventIds.followMe, "followme", event_FollowMe)
        AddEventChannels(Commands.eventIds.stopFollow, "stopfollow", event_StopFollow)
    end

    ---Adds a new event channel to listen to
    ---Available types found in Commands.channelTypes
    ---@param channel string
    function Commands:Add(channel)
        local commandsConfig = config:GetConfig(Commands.configKey)
        if not TableUtils.IsArray(commandsConfig.Channels) then error("Command.Channels config was not an array") end
        if not TableUtils.ArrayContains(commandsConfig.Channels, channel) then
            commandsConfig.Channels[#commandsConfig.Channels + 1] = channel
            print("Added [" .. channel .. "] to active channels")
            Config:SaveConfig(Commands.configKey, commandsConfig)
            RegisterAllComms()
            return
        end
        Debug(channel .. " was already an active channel")
    end

    function Commands:Remove(channel)
        local commandsConfig = config:GetConfig(Commands.configKey)
        if not TableUtils.IsArray(commandsConfig.Channels) then error("Command.Channels config was not an array") end
        if TableUtils.ArrayContains(commandsConfig.Channels, channel) then
            TableUtils.RemoveByValue(commandsConfig, channel)
            print("Removed [" .. channel .. "] as active channel")
            Config:SaveConfig(Commands.configKey, commandsConfig)
            RegisterAllComms()
            return
        end
        Debug(channel .. " was not an active channel")
    end

    function Commands:Print()
        local commandsConfig = config:GetConfig(Commands.configKey)
        TableUtils.Print(commandsConfig)
    end

    RegisterAllComms()

    return commands
end

return Commands
