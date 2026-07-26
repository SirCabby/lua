local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local ErrorAlert = require("cabby.errorAlert")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")

---@class Commands
local Commands = {
    key = "Commands",
    ---slash command that issues a comm command to this character with no chat traffic
    selfCommand = "cself",
    _ = {
        isInit = false,
        speak = {},
        config = {},
        registrations = {
            commands = {
                registeredCommands = {}, -- { <phrase> = <command> }
                byPhrase = {}, -- { <lowercased first word of phrase> = <command> }
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

local unpack = unpack or table.unpack

---Wraps a handler so an error alerts and logs instead of killing the script
---@param sourceKey string
---@param handler function
---@return function
local function protect(sourceKey, handler)
    return function(...)
        local args = {...}
        local ok, err = xpcall(function() handler(unpack(args)) end, debug.traceback)
        if not ok then
            ErrorAlert.Record(sourceKey, err)
        end
    end
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
            "To learn more about the differences between Communications, Events, and Slash Commands, use /chelp ces",
            "Additional options include any registered Comm, Event, or Slash Command listed in Comms, Events, or SlashCmds",
            " -- Example: /chelp activechannels",
            "/cmenu to activate main menu"
        } end )
        chelpDocs:AddAdditionalLines("ces", function() return {
            "(/chelp ces) Explanation of Communications, Events, and Slash Commands:",
            "Comms (Communications) are leveraged by speaking in active channels for other listeners to pick up",
            " -- /<channel> <command>, For example: /bc followme",
            " -- To manage active channels, use /activechannels",
            " -- To see all registered communication commands provided by this script, use /chelp comms",
            "Events are triggered by certain message lines",
            " -- For example: #1# has invited you to join a group",
            " -- To see all registered events provided by this script, use /chelp events",
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
                local arg = args[1]:lower()
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
                        if event.id:lower() == arg:lower() then
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

        local cselfDocs = ChelpDocs.new(function() return {
            "(/" .. Commands.selfCommand .. ") Issue one of this script's communication commands to yourself",
            " -- Nothing is said in any channel. The command goes straight to its handler with",
            "    your own name as the speaker, so it runs here and only here.",
            " -- Usage: /" .. Commands.selfCommand .. " <command> [args]",
            " -- Example: /" .. Commands.selfCommand .. " stopfollow",
            " -- Available commands: [" .. StringUtils.Join(Commands.GetCommsPhrases(), ", ") .. "]"
        } end )
        local function Bind_CSelf(...)
            local args = {...} or {}
            if args == nil or #args < 1 or args[1]:lower() == "help" then
                cselfDocs:Print()
                return
            end

            if not Commands.Dispatch(StringUtils.Join(args, " ")) then
                print("(/" .. Commands.selfCommand .. ") Not a registered command: [" .. args[1] .. "]")
                cselfDocs:Print()
            end
        end
        Commands.RegisterSlashCommand(SlashCmd.new(Commands.selfCommand, Bind_CSelf, cselfDocs))

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

    mq.bind("/" .. command.command, protect("slashcmd:/" .. command.command, command.cmdFunction))
    Commands._.registrations.slashcommands.registeredSlashCommands[command.command] = command
end

function Commands.GetCommsPhrases()
    local comms = {}
    for _, command in pairs(Commands._.registrations.commands.registeredCommands) do
        table.insert(comms, StringUtils.Split(command.command)[1])
    end
    return comms
end

---@param phrase string command phrase, extra words are ignored ("attack 123" finds "attack")
---@return Command? command nil when the phrase is not a registered comm command
function Commands.GetCommand(phrase)
    if type(phrase) ~= "string" then return nil end

    -- indexed rather than searched, and matched rather than Split: this is on the hotbar's per
    -- frame path now (ReadLineState), and walking every registration to re-split its phrase built
    -- a debug string per candidate whether debugging was on or not
    local word = phrase:match("^%s*(%S+)")
    if word == nil then return nil end

    return Commands._.registrations.commands.byPhrase[word:lower()]
end

---@return table names registered slash commands, without their leading slash
function Commands.GetSlashCommandNames()
    return TableUtils.GetKeys(Commands._.registrations.slashcommands.registeredSlashCommands)
end

---@param name string slash command name, with or without its leading slash
---@return SlashCmd? command nil when the name is not a registered slash command
function Commands.GetSlashCommand(name)
    if name == nil or name == "" then return nil end

    name = name:lower()
    if name:sub(1, 1) == "/" then
        name = name:sub(2)
    end
    return Commands._.registrations.slashcommands.registeredSlashCommands[name]
end

---Run a comm command on this character with no chat traffic: the phrase is handed straight to
---its registered handler with our own name as the speaker. This is the local ("self") channel
---behind /cself and hotbar buttons -- it lets a button fire the same commands other characters
---send us over chat, without broadcasting an order meant for one character to the whole group.
---@param commandLine string command phrase plus any arguments, e.g. "attack 12345"
---@param speaker string? who to attribute the command to, defaults to this character
---@return boolean handled false when no comm command matches the phrase
function Commands.Dispatch(commandLine, speaker)
    commandLine = StringUtils.TrimFront(commandLine or "")
    if commandLine == "" then return false end

    local phrase = StringUtils.Split(commandLine)[1]
    local command = Commands.GetCommand(phrase)
    if command == nil then return false end

    local myName = mq.TLO.Me.CleanName() or ""
    speaker = speaker or myName

    -- "follow me" said to yourself is a request to follow yourself. Report it rather than
    -- running it: the handler would happily take our own name as its target and chase it.
    if command.actsOnSpeaker and speaker:lower() == myName:lower() then
        print("(" .. phrase .. ") acts on whoever asks for it, so issuing it to yourself does nothing.")
        return true
    end

    -- mq hands comm handlers (line, <#1#> speaker, <#2#> trailing args), where the args
    -- capture keeps the space that separated it from the phrase. Build the same shape so
    -- handlers cannot tell a dispatched command from a spoken one.
    local args = commandLine:sub(#phrase + 1)
    local line = Speak.BuildLine(Speak.channelTypes.self.name, speaker, commandLine)

    DebugLog("Dispatching [" .. commandLine .. "] as speaker [" .. speaker .. "]")
    local handler = command.wrappedEventFunction or command.eventFunction
    handler(line, speaker, args)
    return true
end

---Read the on/off state a command line reflects, for lines that flip something readable
---(`Command:WithState`). This is what lets a hotbar button carrying `stick toggle` be drawn as the
---stick setting rather than as anonymous text -- nothing is persisted about a button's lines, so
---the meaning has to be recovered from the text, the same way ParseActionLine recovers it.
---
---Only lines that run *here* are answered for: bare text, which CommandQueue dispatches to this
---character, and the `/cself` spelling of the same thing. A line spoken on a channel is an order to
---the others listening on it -- EQBC does not echo to the speaker, so our own setting is not what
---that line changes, and showing it would be showing the wrong character's state.
---@param line string a command line as a hotbar button holds it
---@return boolean? state nil when the line flips nothing readable
---@return string? phrase the command phrase it read, when it read one
function Commands.ReadLineState(line)
    if type(line) ~= "string" then return nil, nil end

    -- matched rather than Split: this runs for every button of every bar, every frame
    local first, rest = line:match("^%s*(%S+)%s*(.-)%s*$")
    if first == nil then return nil, nil end

    local phrase, args
    if first:sub(1, 1) ~= "/" then
        phrase, args = first, rest
    elseif first:sub(2):lower() == Commands.selfCommand then
        phrase, args = rest:match("^(%S+)%s*(.-)$")
    end
    if phrase == nil then return nil, nil end

    local command = Commands.GetCommand(phrase)
    if command == nil or command.stateReader == nil then return nil, nil end

    return command.stateReader(args or ""), phrase:lower()
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
        mq.event(newEventId, thisPhrase, command.wrappedEventFunction or command.eventFunction)
    end
end

---@param command Command
function Commands.RegisterCommEvent(command)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.commands.registeredCommands), command.command) then
        Commands._.registrations.commands.registeredCommands[command.command] = command
        Commands._.registrations.commands.byPhrase[StringUtils.Split(command.command)[1]:lower()] = command
        command.wrappedEventFunction = protect("command:" .. StringUtils.Split(command.command)[1], command.eventFunction)
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
    for _, event in pairs(Commands._.registrations.events.registeredEvents) do
        ---@type Event
        event = event
        if event.reregister then
            mq.unevent(event.id:lower())
            mq.event(event.id:lower(), event.command, event.wrappedEventFunction or event.eventFunction)
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
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registrations.events.registeredEvents), event.id) then
        Commands._.registrations.events.registeredEvents[event.id] = event
        event.wrappedEventFunction = protect("event:" .. event.id, event.eventFunction)
        mq.event(event.id:lower(), event.command, event.wrappedEventFunction)
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
