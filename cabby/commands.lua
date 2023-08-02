local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Commands
local Commands = {
    key = "Commands",
    _ = {
        isInit = false,
        phrasePatternOverrides = {}, -- { <command id> = { array of patterns } }
        registeredComms = {}, -- { <command id> = <command> }
        registeredSlashCommands = {}, -- { "/cmd1", "/cmd2" }
        registeredChannelPatterns = {}, -- { "some pattern with <<phrase>> in it, which will be replaced later with registeredComms.commandId.phrase" }
        registeredEvents = {}, -- todo use for relaytellsto after refactor?
        reRegisterOnEventUpdates = {} -- { id = { phrase = "", eventFunc = function } }
    }
}

local function DebugLog(str)
    Debug.Log(Commands.key, str)
end

function Commands.Init()
    if not Commands._.isInit then
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
                    local comms = Commands.GetCommsPhrases()
                    print("Available Communication Commands: [" .. StringUtils.Join(comms, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif arg == "slashcmds" then
                    print("Available Slash Commands: [" .. StringUtils.Join(Commands._.registeredSlashCommands, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif TableUtils.ArrayContains(Commands._.registeredSlashCommands, "/" .. arg) then
                    mq.cmd("/" .. arg .. " help")
                elseif TableUtils.ArrayContains(Commands.GetCommsPhrases(), arg) then
                    for _,command in pairs(Commands._.registeredComms) do
                        if command.phrase == arg then
                            command.helpFunction()
                            return
                        end
                    end
                else
                    chelpPrint()
                end
            end
        end
        Commands.RegisterSlashCommand("chelp", Bind_Chelp)
    end
end

---@param command string
---@param callback function
function Commands.RegisterSlashCommand(command, callback)
    command = command:lower()
    if command:sub(1, 1) ~= "/" then
        command = "/" .. command
    end

    if TableUtils.ArrayContains(Commands._.registeredSlashCommands, command) then
        DebugLog("Slash command was already registered: [" .. command .. "]")
        return
    end

    mq.bind(command, callback)
    table.insert(Commands._.registeredSlashCommands, command)
    table.sort(Commands._.registeredSlashCommands)
end

function Commands.GetCommsPhrases()
    local comms = {}
    for _,command in pairs(Commands._.registeredComms) do
        table.insert(comms, command.phrase)
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
    if Commands._.phrasePatternOverrides[command.phrase] ~= nil then
        patternArray = Commands._.phrasePatternOverrides[command.phrase]
    else
        patternArray = Commands._.registeredChannelPatterns
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
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registeredComms), command.id) then
        Commands._.registeredComms[command.id] = command
        command.registeredEvents = {}
        UpdateCommEvent(command)
    else
        print("Cannot re-register same command Id: ["..command.id.."]")
    end
end

---Syncs registered commands to currently active channels
local function UpdateCommChannels()
    for _,command in pairs(Commands._.registeredComms) do
        UpdateCommEvent(command)
    end

    -- These events are intentionally added last to act as catchalls for similar event patterns
    for id, event in pairs(Commands._.reRegisterOnEventUpdates) do
        mq.unevent(id)
        mq.event(id, event.phrase, event.eventFunc)
    end
end

---Replaces current patterns with those provided
---@param channelPatterns array
function Commands.SetChannelPatterns(channelPatterns)
    Commands._.registeredChannelPatterns = channelPatterns
    UpdateCommChannels()
end

---Adds event to re-register on event updates to preserve ordering of fallthrough events
---@param id string
---@param phrase string
---@param eventFunc function
function Commands.ReRegisterOnEventUpdates(id, phrase, eventFunc)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.reRegisterOnEventUpdates), id) then
        Commands._.reRegisterOnEventUpdates[id] = {
            phrase = phrase,
            eventFunc = eventFunc
        }
    else
        print("Cannot re-register same event Id: ["..id.."]")
    end
end

---@param phrase string
---@param phrasePatternOverrides array?
function Commands.SetPhrasePatternOverrides(phrase, phrasePatternOverrides)
    Commands._.phrasePatternOverrides[phrase] = phrasePatternOverrides
    UpdateCommChannels()
end

return Commands
