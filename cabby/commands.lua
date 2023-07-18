local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local DebugConfig = require("cabby.configs.debugConfig")
local GeneralConfig = require("cabby.configs.generalConfig")
---@type Owners
local Owners = require("utils.Owners.Owners")
local Priorities = require("cabby.priorities")
local PriorityQueueJob = require("utils.PriorityQueue.PriorityQueueJob")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Commands
local Commands = {
    key = "Commands",
    _registeredComms = {},
    _registeredSlashCommands = {}
}

---@param priorityQueue PriorityQueue
---@return Commands
function Commands:new(configFilePath, priorityQueue)
    local commands = {}
    setmetatable(commands, self)
    self.__index = self

    commands.priorityQueue = priorityQueue
    local debugConfig = DebugConfig:new(configFilePath)
    local owners = Owners:new(configFilePath)
    Debug:new()

    local function DebugLog(str)
        Debug:Log(Commands.key, str)
    end

    ---@param command string
    ---@param callback function
    local function RegisterSlashCommand(command, callback)
        command = command:lower()
        if command:sub(1, 1) ~= "/" then
            command = "/" .. command
        end

        mq.bind(command, callback)
        Commands._registeredSlashCommands[#Commands._registeredSlashCommands + 1] = command
        table.sort(Commands._registeredSlashCommands)
    end

    ---Decides if should listen to command, then schedules it in the priority queue
    ---@param speaker string - Who issued command, must be listed in owners to listen
    ---@param job PriorityQueueJob
    ---@param who? string This command was told to this name specifically
    ---@return boolean - true if command scheduled, false if ignored
    local function ScheduleCommand(speaker, job, who)
        who = who or "all"
        DebugLog("Received command from [" .. speaker .. "] with priority [" .. tostring(job:GetPriority()) .. "] directed at: [" .. who .. "]: " .. job:GetIdentity())
        if who ~= "all" and who:lower() ~= mq.TLO.Me.Name():lower() then
            DebugLog("Ignoring command, was issued to: [" .. mq.TLO.Me.Name() .. "]")
            return false
        end

        if not Owners:IsOwner(speaker) then
            DebugLog("Ignoring command, speaker was not an owner [" .. speaker .. "]")
            return false
        end

        DebugLog("Inserting command: " .. job:GetIdentity())
        commands.priorityQueue:InsertJob(job)
        return true
    end

    -----------------------------------------------------------------------------
    ------------------------------- COMMS ---------------------------------------
    -----------------------------------------------------------------------------

    local function event_FollowMe(_, speaker, who)
        local job = PriorityQueueJob:new("Follow me - " .. speaker, Priorities.Following, exeFunc, nil, true)
        ScheduleCommand(speaker, job, who)
    end

    local function event_StopFollow(_, speaker, who)
        local job = PriorityQueueJob:new("Stop Follow - " .. speaker, Priorities.Following, exeFunc, nil, true)
        ScheduleCommand(speaker, job, who)
    end

    --TODO move these into follow state and setup method for registering state files

    local function RegisterAllComms()
        --GeneralConfig:UpdateEventChannels(FollowState.eventIds.followMe, "followme", event_FollowMe)
        --GeneralConfig:UpdateEventChannels(FollowState.eventIds.stopFollow, "stopfollow", event_StopFollow)
    end

    -----------------------------------------------------------------------------
    ----------------------------- END COMMS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------ EVENTS ---------------------------------------
    -----------------------------------------------------------------------------

    local function event_TellToMe(_, speaker, message)
        local job = PriorityQueueJob:new("Tell to me - " .. speaker, Priorities.Immediate, function() GeneralConfig:TellToMe(speaker, message) end, nil, true)
        commands.priorityQueue:InsertJob(job)
    end
    mq.event(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe)

    local function event_GroupInvited(_, speaker)
        local job = PriorityQueueJob:new("Invited to group by - " .. speaker, Priorities.Immediate, function() GeneralConfig:GroupInvited(speaker) end, nil, true)
        commands.priorityQueue:InsertJob(job)
    end
    mq.event(GeneralConfig.eventIds.groupInvited, "#1# invites you to join a group.", event_GroupInvited)

    -----------------------------------------------------------------------------
    ---------------------------- END EVENTS -------------------------------------
    -----------------------------------------------------------------------------
    ------------------------------- BINDS ---------------------------------------
    -----------------------------------------------------------------------------

    local function chelpPrint()
        print("(/chelp) Cabby Help menu")
        print(" -- Pick a help topic. Options: [Cvc, SlashCmds, Comms]")
        print("Additional options include any registered Comm or Slash Command listed in SlashCmds or Comms")
        print(" -- Example: /chelp activechannels")
        print("To learn more about the differences between SlashCmds vs Comms, use /chelp cvc")
    end
    local function Bind_Chelp(...)
        local args = {...} or {}
        if args == nil or #args < 1 or args[1]:lower() == "help" then
            chelpPrint()
        else
            arg = args[1]:lower()
            if arg == "cvc" then
                print("(/chelp cvc) Explanation of Comms vs Slash Commands:")
                print("Comms (Communications) are leveraged by speaking in active channels for other listeners to pick up")
                print(" -- /<channel> <command>, For example: /bc followme")
                print(" -- To manage active channels, use /activechannels")
                print(" -- To see all registered communication commands provided by this script, use /chelp comms")
                print("Slash Commands begin with a slash and are invoked by using the slash command on this char")
                print(" -- For example: /activechannels")
                print(" -- To see all registered slash commands provided by this script, use /chelp slashcmds")
            elseif arg == "comms" then
                print("Available Communication Commands: [" .. StringUtils.Join(Commands._registeredComms, ", ") .. "]")
            elseif arg == "slashcmds" then
                print("Available Slash Commands: [" .. StringUtils.Join(Commands._registeredSlashCommands, ", ") .. "]")
            elseif TableUtils.ArrayContains(Commands._registeredSlashCommands, "/" .. arg) then
                mq.cmd("/" .. arg .. " help")
            else
                chelpPrint()
            end
        end
    end
    RegisterSlashCommand("chelp", Bind_Chelp)

    -----------------------------------------------------------------------------

    local function Bind_ActiveChannels(...)
        local args = {...} or {}
        if args == nil or #args ~= 1 or args[1]:lower() == "help" then
            print("(/activechannels) Channels used for listening to commands")
            print("To toggle an active channel, use: /activechannels channel")
            print("Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
            print("Currently active channels: [" .. StringUtils.Join(GeneralConfig:GetActiveChannels(), ", ") .. "]")
        elseif GeneralConfig:ToggleActiveChannel(args[1]:lower()) then
            RegisterAllComms()
        end
    end
    RegisterSlashCommand("activechannels", Bind_ActiveChannels)

    -----------------------------------------------------------------------------

    local function Bind_Owners(...)
        local args = {...} or {}
        if args == nil or #args ~= 1 or args[1]:lower() == "help" then
            print("(/owners) Manage owners to take commands from")
            print("To add/remove owners, use: /owners name")
            print("Current owners:")
            owners:Print()
        elseif owners:IsOwner(args[1]) then
            owners:Remove(args[1])
        else
            owners:Add(args[1])
        end
    end
    RegisterSlashCommand("owners", Bind_Owners)

    -----------------------------------------------------------------------------

    local function Bind_SetRelayTellsToFunc(...)
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
    RegisterSlashCommand("relaytellsto", Bind_SetRelayTellsToFunc)

    -----------------------------------------------------------------------------

    local function Bind_Debug(...)
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
    RegisterSlashCommand("debug", Bind_Debug)

    -----------------------------------------------------------------------------
    ----------------------------- END BINDS -------------------------------------
    -----------------------------------------------------------------------------

    RegisterAllComms()

    return commands
end

return Commands
