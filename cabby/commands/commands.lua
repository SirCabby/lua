local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local SlashCmd = require("cabby.commands.slashcmd")

---@class Commands
local Commands = {
    key = "Commands",
    _ = {
        isInit = false,
        speak = {},
        config = {},
        registrations = {
            commands = {
                registeredCommands = {}, -- { <phrase> = <command> }
                defaultChannelPatterns = {}, -- { "some pattern with <<phrase>> in it, which will be replaced later with registeredComms.commandId.phrase" }
                phrasePatternOverrides = {}, -- { <phrase> = { array of patterns } }
                ownersOverrides = {}, -- { <phrase> = { owners } }
                speakOverrides = {} -- { <phrase> = { speak } }
            },
            slashcommands = {
                registeredSlashCommands = {} -- { <command> = { slashCmd } }
            },
            events = {
                registeredEvents = {}, -- { <event id> = <event> }
                ownersOverrides = {}, -- { <event id> = { owners } }
                speakOverrides = {} -- { <event id> = { speak } }
            }
        }
    }
}

local function DebugLog(str)
    Debug.Log(Commands.key, str)
end

---@param config Config
---@param owners Owners
---@param speak Speak
function Commands.Init(config, owners, speak)
    if not Commands._.isInit then
        local ftkey = Global.tracing.open("Commands Init")
        Commands._.config = config
        Commands._.owners = owners

        local chelpDocs = ChelpDocs.new(function() return {
            "(/chelp) Cabby Help menu",
            " -- Pick a help topic. Options: [CES, Comms, Events, SlashCmds]",
            "Additional options include any registered Comm, Event, or Slash Command listed in Comms, Events, or SlashCmds",
            " -- Example: /chelp activechannels",
            "To learn more about the differences between Communications, Events, and Slash Commands, use /chelp ces"
        } end )
        chelpDocs:AddAdditionalLines("ces", function() return {
            "(/chelp ces) Explanation of Communications, Events, and Slash Commands:",
            "Comms (Communications) are leveraged by speaking in active channels for other listeners to pick up",
            " -- /<channel> <command>, For example: /bc followme",
            " -- To manage active channels, use /activechannels",
            " -- To see all registered communication commands provided by this script, use /chelp comms",
            "Slash Commands begin with a slash and are invoked by using the slash command on this char",
            " -- For example: /activechannels",
            " -- To see all registered slash commands provided by this script, use /chelp slashcmds"
        } end )
        chelpDocs:AddAdditionalLines("comms", function() return {
            "Available Communication Commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]",
            "To learn more about a specific command, use /chelp <command>"
        } end )
        chelpDocs:AddAdditionalLines("events", function() return {
            "Available Events: [" .. StringUtils.Join(Commands.GetEventIds(), ", ") .. "]",
            "To learn more about a specific event, use /chelp <event>"
        } end )
        chelpDocs:AddAdditionalLines("slashcmds", function() return {
            "Available Slash Commands: [" .. StringUtils.Join(TableUtils.GetKeys(Commands._.registrations.slashcommands.registeredSlashCommands), ", ") .. "]",
            "To learn more about a specific command, use /chelp <command>"
        } end )
        local function Bind_Chelp(...)
            local args = {...} or {}
            if args == nil or #args < 1 or args[1]:lower() == "help" then
                chelpDocs:Print()
            else
                arg = args[1]:lower()
                if arg == "ces" then
                    chelpDocs.additionalLines["ces"]:Print()
                elseif arg == "comms" then
                    chelpDocs.additionalLines["comms"]:Print()
                elseif arg == "events" then
                    chelpDocs.additionalLines["events"]:Print()
                elseif arg == "slashcmds" then
                    chelpDocs.additionalLines["slashcmds"]:Print()
                elseif TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.slashcommands.registeredSlashCommands), arg) then
                    ---@type SlashCmd
                    local command = Commands._.registrations.slashcommands.registeredSlashCommands[arg]
                    command.docs:Print()
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), arg) then
                    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
                        ---@type Command
                        command = command
                        if StringUtils.Split(command.command)[1] == arg then
                            command.docs:Print()
                            return
                        end
                    end
                elseif TableUtils.ArrayContains(Commands.GetEventIds(), arg) then
                    for _, event in pairs(Commands._.registrations.events.registeredEvents) do
                        ---@type Event
                        event = event
                        if event.command:lower() == arg:lower() then
                            event.docs:Print()
                            return
                        end
                    end
                else
                    chelpDocs:Print()
                end
            end
        end
        Commands.RegisterSlashCommand(SlashCmd.new("chelp", Bind_Chelp, chelpDocs))

        Commands.SetSpeak(speak)

        Global.tracing.close(ftkey)
    end
end

---@param speak Speak
function Commands.SetSpeak(speak)
    Commands._.speak = speak
end

---@param command SlashCmd
function Commands.RegisterSlashCommand(command)
    command.command = command.command:lower()
    if command.command:sub(1, 1) == "/" then
        command.command = command.command:sub(2)
    end

    if TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.slashcommands.registeredSlashCommands), command.command) then
        DebugLog("Slash command was already registered: [" .. command.command .. "]")
        return
    end

    mq.bind("/" .. command.command, command.cmdFunction)
    Commands._.registrations.slashcommands.registeredSlashCommands[command.command] = command
end

function Commands.GetCommsPhrases()
    local comms = {}
    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
        table.insert(comms, StringUtils.Split(command.command)[1])
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
    if Commands._.registrations.commands.phrasePatternOverrides[StringUtils.Split(command.command)[1]] ~= nil then
        patternArray = Commands._.registrations.commands.phrasePatternOverrides[StringUtils.Split(command.command)[1]]
    else
        patternArray = Commands._.registrations.commands.defaultChannelPatterns
    end

    for _, pattern in ipairs(patternArray) do
        local thisPhrase = string.gsub(pattern, "<<phrase>>", command.command)
        local newEventId = command.command .. tostring(#command.registeredEvents + 1)
        table.insert(command.registeredEvents, newEventId)
        mq.event(newEventId, thisPhrase, command.eventFunction)
    end
end

---@param command Command
function Commands.RegisterCommEvent(command)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.commands.registeredCommands), command.command) then
        Commands._.registrations.commands.registeredCommands[command.command] = command
        command.registeredEvents = {}
        UpdateCommEvent(command)
    else
        print("Cannot re-register same command: ["..command.command.."]")
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
            mq.event(id, event.command, event.eventFunction)
        end
    end
end

---Replaces current patterns with those provided
---@param channelPatterns table
function Commands.SetChannelPatterns(channelPatterns)
    Commands._.registrations.commands.defaultChannelPatterns = channelPatterns
    UpdateCommChannels()
end

---@param phrase string
---@param phrasePatternOverrides table?
function Commands.SetPhrasePatternOverrides(phrase, phrasePatternOverrides)
    phrase = StringUtils.Split(phrase)[1]
    Commands._.registrations.commands.phrasePatternOverrides[phrase] = phrasePatternOverrides
    UpdateCommChannels()
end

---@param phrase string
---@param ownersOverrides Owners?
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

---@param phrase string
---@return Speak speak
function Commands.GetCommandSpeak(phrase)
    phrase = StringUtils.Split(phrase)[1]
    local speakOverrides = Commands._.registrations.commands.speakOverrides[phrase]
    if speakOverrides ~= nil then
        return speakOverrides
    end
    return Commands._.speak
end

---@param phrase string
---@param speakOverrides Speak?
function Commands.SetCommandSpeakOverrides(phrase, speakOverrides)
    Commands._.registrations.commands.speakOverrides[phrase] = speakOverrides
end

---@param event Event
function Commands.RegisterEvent(event)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.events.registeredEvents), event.command) then
        Commands._.registrations.events.registeredEvents[event.command] = event
        mq.event(event.command:lower(), event.command, event.eventFunction)
    else
        print("Cannot re-register same event Id: ["..event.command:lower().."]")
    end
end

function Commands.GetEventIds()
    local events = {}
    for _, event in pairs(Commands._.registrations.events.registeredEvents) do
        table.insert(events, event.command:lower())
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
---@param ownersOverrides Owners?
function Commands.SetEventOwnersOverrides(eventId, ownersOverrides)
    eventId = eventId:lower()
    Commands._.registrations.events.ownersOverrides[eventId] = ownersOverrides
end

---@param eventId string
---@return Speak speak
function Commands.GetEventSpeak(eventId)
    eventId = eventId:lower()
    local speakOverrides = Commands._.registrations.events.speakOverrides[eventId]
    if speakOverrides ~= nil then
        return speakOverrides
    end
    return Commands._.speak
end

---@param eventId string
---@param speakOverrides Speak?
function Commands.SetEventSpeakOverrides(eventId, speakOverrides)
    eventId = eventId:lower()
    Commands._.registrations.events.speakOverrides[eventId] = speakOverrides
end

return Commands
