local mq = require("mq")
local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local DebugConfig = require("cabby.configs.DebugConfig")
local GeneralConfig = require("cabby.configs.GeneralConfig")
local Owners = require("utils.Owners.Owners")
local Priorities = require("cabby.priorities")
local PriorityQueueFunctionContent = require("utils.PriorityQueue.PriorityQueueFunctionContent")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Commands
local Commands = {
    key = "Commands",
    eventIds = {
        followMe = "Follow Me",
        stopFollow = "Stop Follow",
        moveToMe = "Move to Me",
        tellToMe = "Tell to Me",
        groupInvited = "Invited to Group"
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
    local debugConfig = DebugConfig:new(configFilePath)
    Debug:new()

    local function DebugLog(str)
        Debug:Log(Commands.key, str)
    end

    ---Decides if should listen to command, then schedules it in the priority queue
    ---@param speaker string - Who issued command, must be listed in owners to listen
    ---@param priority number
    ---@param command FunctionContent
    ---@param who? string This command was told to this name specifically
    ---@return boolean - true if command scheduled, false if ignored
    local function ScheduleCommand(speaker, priority, command, who)
        who = who or "all"
        DebugLog("Received command from [" .. speaker .. "] with priority [" .. tostring(priority) .. "] directed at: [" .. who .. "]: " .. command.identity)
        if who ~= "all" and who:lower() ~= mq.TLO.Me.Name():lower() then
            DebugLog("Ignoring command, was issued to: [" .. mq.TLO.Me.Name() .. "]")
            return false
        end

        if not Owners:IsOwner(speaker) then
            DebugLog("Ignoring command, speaker was not an owner [" .. speaker .. "]")
            return false
        end

        DebugLog("Inserting command: " .. command.identity)
        commands.priorityQueue:InsertNewJob(priority, command)
        return true
    end

    ---Adds this event to all registered channels
    ---@param eventId string
    ---@param phrase string
    ---@param eventFunction function
    local function AddEventChannels(eventId, phrase, eventFunction)
        mq.unevent(eventId)
        local commandsConfig = config:GetConfig(Commands.key)
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
    local function exeFunc()
        print("insert follow me here")
        return true;
    end

    local function event_FollowMe(_, speaker, who)
        local followMe = PriorityQueueFunctionContent:new("Follow Me - " .. speaker, exeFunc)
        ScheduleCommand(speaker, Priorities.Following, followMe, who)
    end

    local function event_StopFollow(_, speaker, who)
        local stopFollow = PriorityQueueFunctionContent:new("Stop Follow - " .. speaker, exeFunc)
        ScheduleCommand(speaker, Priorities.Following, stopFollow, who)
    end

    -----------------------------------------------------------------------------
    ----------------------------- END COMMS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------ EVENTS ---------------------------------------
    -----------------------------------------------------------------------------

    local function event_TellToMe(_, speaker, message)
        local function tellToMe(speaker, message)
            local generalConfig = GeneralConfig:new(configFilePath)
            local tellTo = generalConfig:GetRelayTellsTo()
            if tellTo ~= speaker and mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
                mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
            end
            return true
        end
        local tellToMeFunc = PriorityQueueFunctionContent:new("Tell to me - " .. speaker, function() return tellToMe(speaker, message) end)
        commands.priorityQueue:InsertNewJob(Priorities.Immediate, tellToMeFunc)
    end
    mq.event(Commands.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe)

    local function event_GroupInvited(_, speaker)
        local function groupInvited(speaker)
            if Owners:IsOwner(speaker) then
                DebugLog("Joining group of speaker [" .. speaker .. "]")
                mq.cmd("/invite")
            else
                DebugLog("Declining group of speaker [" .. speaker .. "]")
                mq.cmd("/disband")
            end
            return true
        end
        local groupInvitedFunc = PriorityQueueFunctionContent:new("Tell to me - " .. speaker, function() return groupInvited(speaker) end)
        commands.priorityQueue:InsertNewJob(Priorities.Immediate, groupInvitedFunc)
    end
    mq.event(Commands.eventIds.groupInvited, "#1# invites you to join a group.", event_GroupInvited)

    -----------------------------------------------------------------------------
    ---------------------------- END EVENTS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------- BINDS ---------------------------------------
    -----------------------------------------------------------------------------

    local function chelpPrint()
        print("(/chelp) Cabby Help menu")
        print(" -- Pick a help topic. Options: [Cvc, Debug, Owners, Follow]")
    end
    local function Bind_Chelp(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            chelpPrint()
        elseif args[1]:lower() == "cvc" then
            print("(/chelp cvc) Explanation of Comms vs Slash Commands")
            print("Comms are leveraged by speaking in active channels for other listeners to pick up")
            print(" -- For example: /bc followme")
            print(" -- To see active channels, use /activechannels")
            print(" -- To add / remove channels, use /addchannel name, /removechannel name")
            print("Commands begin with a slash and are invoked by using the slash command on this char")
            print(" -- For example: /activechannels")
        elseif args[1]:lower() == "debug" then
            print("(/chelp debug) Debug Commands")
            print(" -- To enable all debug tracing, use /debug all")
            print(" -- To see a list of currently used debug toggles, use /debug list")
            print(" -- To toggle a particular debug trace, find a key in the list command, then use /debug <key>")
        elseif args[1]:lower() == "follow" then
            print("(/chelp follow) Follow Commands:")
            print(" -- See also: /chelp cvc")
            print(" -- followme")
            print(" -- stopfollow")
        elseif args[1]:lower() == "owners" then
            print("(/chelp owners) Owner Commands:")
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

    local function debugCommand(...)
        local args = {...} or {}
        if args == nil or #args < 1 or #args > 2 or args[1]:lower() == "help" then
            print("(/debug) Toggle debug tracing by debug category key")
            print(" -- Usage (toggle): /debug key")
            print(" -- Usage (1 = on, 0 = off): /debug key <0|1>")
            print(" -- To find a list of keys, use /debug list")
        elseif args[1]:lower() == "list" then
            print("Debug Toggles:")
            debugConfig:Print()
        elseif #args == 2 then
            if args[2] == "0" then
                debugConfig:SetDebugToggle(args[1], false)
                print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig:GetDebugToggle(args[1])))
            elseif args[2] == "1" then
                debugConfig:SetDebugToggle(args[1], true)
                print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig:GetDebugToggle(args[1])))
            else
                print("(/debug) Invalid second argument: [" .. args[2] .."]")
                print(" -- Valid values: [0, 1]")
            end
        else
            debugConfig:FlipDebugToggle(args[1])
            print("Toggled debug tracing for [" .. args[1] .. "]: " .. tostring(DebugConfig:GetDebugToggle(args[1])))
        end
    end
    mq.bind("/debug", debugCommand)

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
        local commandsConfig = config:GetConfig(Commands.key)
        if not TableUtils.IsArray(commandsConfig.Channels) then error("Command.Channels config was not an array") end
        if not TableUtils.ArrayContains(commandsConfig.Channels, channel) then
            commandsConfig.Channels[#commandsConfig.Channels + 1] = channel
            print("Added [" .. channel .. "] to active channels")
            Config:SaveConfig(Commands.key, commandsConfig)
            RegisterAllComms()
            return
        end
        DebugLog(channel .. " was already an active channel")
    end

    function Commands:Remove(channel)
        local commandsConfig = config:GetConfig(Commands.key)
        if not TableUtils.IsArray(commandsConfig.Channels) then error("Command.Channels config was not an array") end
        if TableUtils.ArrayContains(commandsConfig.Channels, channel) then
            TableUtils.RemoveByValue(commandsConfig, channel)
            print("Removed [" .. channel .. "] as active channel")
            Config:SaveConfig(Commands.key, commandsConfig)
            RegisterAllComms()
            return
        end
        DebugLog(channel .. " was not an active channel")
    end

    function Commands:Print()
        local commandsConfig = config:GetConfig(Commands.key)
        TableUtils.Print(commandsConfig)
    end

    RegisterAllComms()

    return commands
end

return Commands
