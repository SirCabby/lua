local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@type Owners
local Owners = require("cabby.commands.owners")

---@class Commands
local Commands = {
    key = "Commands",
    _ = {
        isInit = false,
        config = {},
        owners = {},
        registrations = {
            commands = {
                registeredCommands = {}, -- { <command id> = <command> }
                defaultChannelPatterns = {}, -- { "some pattern with <<phrase>> in it, which will be replaced later with registeredComms.commandId.phrase" }
                phrasePatternOverrides = {}, -- { <command id> = { array of patterns } }
                ownersOverrides = {} -- { <command id> = { owners } }
            },
            slashcommands = {
                registeredSlashCommands = {} -- { "/cmd1", "/cmd2" }
            },
            events = {
                registeredEvents = {}, -- { <event id> = <event> }
                ownersOverrides = {} -- { <event id> = { owners } }
            }
        }
    }
}

local function DebugLog(str)
    Debug.Log(Commands.key, str)
end

---@param config Config
function Commands.Init(config, owners)
    if not Commands._.isInit then
        local ftkey = Global.tracing.open("Commands Init")
        Commands._.config = config
        Commands._.owners = owners

        local function chelpPrint()
            print("(/chelp) Cabby Help menu")
            print(" -- Pick a help topic. Options: [CES, Comms, Events, SlashCmds]")
            print("Additional options include any registered Comm, Event, or Slash Command listed in Comms, Events, or SlashCmds")
            print(" -- Example: /chelp activechannels")
            print("To learn more about the differences between Communications, Events, and Slash Commands, use /chelp ces")
        end
        local function Bind_Chelp(...)
            local args = {...} or {}
            if args == nil or #args < 1 or args[1]:lower() == "help" then
                chelpPrint()
            else
                arg = args[1]:lower()
                if arg == "ces" then
                    print("(/chelp ces) Explanation of Communications, Events, and Slash Commands:")
                    print("Comms (Communications) are leveraged by speaking in active channels for other listeners to pick up")
                    print(" -- /<channel> <command>, For example: /bc followme")
                    print(" -- To manage active channels, use /activechannels")
                    print(" -- To see all registered communication commands provided by this script, use /chelp comms")
                    print("Slash Commands begin with a slash and are invoked by using the slash command on this char")
                    print(" -- For example: /activechannels")
                    print(" -- To see all registered slash commands provided by this script, use /chelp slashcmds")
                elseif arg == "comms" then
                    local comms = Commands.GetCommsPhrases()
                    print("Available Communication Commands: [" .. StringUtils.Join(comms, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif arg == "events" then
                    local events = Commands.GetEventIds()
                    print("Available Events: [" .. StringUtils.Join(events, ", ") .. "]")
                    print("To learn more about a specific event, use /chelp <event>")
                elseif arg == "slashcmds" then
                    print("Available Slash Commands: [" .. StringUtils.Join(Commands._.registrations.slashcommands.registeredSlashCommands, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif TableUtils.ArrayContains(Commands._.registrations.slashcommands.registeredSlashCommands, "/" .. arg) then
                    mq.cmd("/" .. arg .. " help")
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), arg) then
                    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
                        if StringUtils.Split(command.phrase)[1] == arg then
                            command.helpFunction()
                            return
                        end
                    end
                elseif TableUtils.ArrayContains(Commands.GetEventIds(), arg) then
                    for _, event in pairs(Commands._.registrations.events.registeredEvents) do
                        if event.id:lower() == arg:lower() then
                            event.helpFunction()
                            return
                        end
                    end
                else
                    chelpPrint()
                end
            end
        end
        Commands.RegisterSlashCommand("chelp", Bind_Chelp)
        Global.tracing.close(ftkey)
    end
end

---@param command string
---@param callback function
function Commands.RegisterSlashCommand(command, callback)
    command = command:lower()
    if command:sub(1, 1) ~= "/" then
        command = "/" .. command
    end

    if TableUtils.ArrayContains(Commands._.registrations.slashcommands.registeredSlashCommands, command) then
        DebugLog("Slash command was already registered: [" .. command .. "]")
        return
    end

    mq.bind(command, callback)
    table.insert(Commands._.registrations.slashcommands.registeredSlashCommands, command)
end

function Commands.GetCommsPhrases()
    local comms = {}
    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
        table.insert(comms, StringUtils.Split(command.phrase)[1])
    end
    return comms
end

---@param command Command
local function UpdateCommEvent(command)
    for _,registeredEventId in ipairs(command.registeredEvents) do
        mq.unevent(registeredEventId)
    end
    command.registeredEvents = {}

    local patternArray
    if Commands._.registrations.commands.phrasePatternOverrides[StringUtils.Split(command.phrase)[1]] ~= nil then
        patternArray = Commands._.registrations.commands.phrasePatternOverrides[StringUtils.Split(command.phrase)[1]]
    else
        patternArray = Commands._.registrations.commands.defaultChannelPatterns
    end

    for _, pattern in ipairs(patternArray) do
        local thisPhrase = string.gsub(pattern, "<<phrase>>", command.phrase)
        local newEventId = command.id .. tostring(#command.registeredEvents + 1)
        table.insert(command.registeredEvents, newEventId)
        mq.event(newEventId, thisPhrase, command.eventFunction)
    end
end

---@param command Command
function Commands.RegisterCommEvent(command)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.commands.registeredCommands), command.id) then
        Commands._.registrations.commands.registeredCommands[command.id] = command
        command.registeredEvents = {}
        UpdateCommEvent(command)
    else
        print("Cannot re-register same command Id: ["..command.id.."]")
    end
end

---Syncs registered commands to currently active channels
local function UpdateCommChannels()
    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
        UpdateCommEvent(command)
    end

    -- These events are intentionally added last to act as catchalls for similar event patterns
    for id, event in pairs(Commands._.registrations.events.registeredEvents) do
        ---@type Event
        event = event
        if event.reregister then
            mq.unevent(id)
            mq.event(id, event.phrase, event.eventFunction)
        end
    end
end

---Replaces current patterns with those provided
---@param channelPatterns array
function Commands.SetChannelPatterns(channelPatterns)
    Commands._.registrations.commands.defaultChannelPatterns = channelPatterns
    UpdateCommChannels()
end

---@param phrase string
---@param phrasePatternOverrides array?
function Commands.SetPhrasePatternOverrides(phrase, phrasePatternOverrides)
    phrase = StringUtils.Split(phrase)[1]
    Commands._.registrations.commands.phrasePatternOverrides[phrase] = phrasePatternOverrides
    UpdateCommChannels()
end

---@param phrase string
---@param ownersOverrides array?
function Commands.SetCommandOwnersOverrides(phrase, ownersOverrides)
    phrase = StringUtils.Split(phrase)[1]
    Commands._.registrations.commands.ownersOverrides[phrase] = ownersOverrides
end

---@param phrase string
---@return Owners owners
function Commands.GetCommandOwners(phrase)
    phrase = StringUtils.Split(phrase)[1]
    local ownersOverrides = Commands._.registrations.commands.ownersOverrides[phrase]
    if ownersOverrides ~= nil then
        return ownersOverrides
    end
    return Commands._.owners
end

---@param event Event
function Commands.RegisterEvent(event)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.events.registeredEvents), event.id) then
        Commands._.registrations.events.registeredEvents[event.id] = event
        mq.event(event.id:lower(), event.phrase, event.eventFunction)
    else
        print("Cannot re-register same event Id: ["..event.id:lower().."]")
    end
end

function Commands.GetEventIds()
    local events = {}
    for _, event in pairs(Commands._.registrations.events.registeredEvents) do
        table.insert(events, event.id:lower())
    end
    return events
end

---@param eventId string
---@return Owners owners
function Commands.GetEventOwners(eventId)
    eventId = eventId:lower()
    local ownersOverrides = Commands._.registrations.events.ownersOverrides[eventId]
    if ownersOverrides ~= nil then
        return ownersOverrides
    end
    return Commands._.owners
end

---@param eventId string
---@param ownersOverrides array?
function Commands.SetEventOwnersOverrides(eventId, ownersOverrides)
    eventId = eventId:lower()
    Commands._.registrations.events.ownersOverrides[eventId] = ownersOverrides
end

return Commands
