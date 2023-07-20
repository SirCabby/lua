local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Commands
local Commands = {
    key = "Commands",
    _ = {
        isInit = false,
        registeredComms = {}, -- { eventId1 = { phrase = "someString", eventFunction = someFunc, helpFunction = someFunc2, registeredEvents = { "id1", "id2" } }, eventId2 = {} },
        registeredSlashCommands = {}, -- { "/cmd1", "/cmd2" }
        registeredChannelPatterns = {} -- { "some pattern with <<phrase>> in it, which will be replaced later with registeredComms.eventId.phrase" }
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
        local function getCommsPhrases()
            local comms = {}
            for _,event in pairs(Commands._.registeredComms) do
                table.insert(comms, event.phrase)
            end
            return comms
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
                    local comms = getCommsPhrases()
                    print("Available Communication Commands: [" .. StringUtils.Join(comms, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif arg == "slashcmds" then
                    print("Available Slash Commands: [" .. StringUtils.Join(Commands._.registeredSlashCommands, ", ") .. "]")
                    print("To learn more about a specific command, use /chelp <command>")
                elseif TableUtils.ArrayContains(Commands._.registeredSlashCommands, "/" .. arg) then
                    mq.cmd("/" .. arg .. " help")
                elseif TableUtils.ArrayContains(getCommsPhrases(), arg) then
                    for _,event in pairs(Commands._.registeredComms) do
                        if event.phrase == arg then
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

local function UpdateCommEvent(eventId)
    local commObj = Commands._.registeredComms[eventId]

    for _,registeredEventId in ipairs(commObj.registeredEvents) do
        mq.unevent(registeredEventId)
    end
    commObj.registeredEvents = {}

    for i, pattern in ipairs(Commands._.registeredChannelPatterns) do
        local thisPhrase = string.gsub(pattern, "<<phrase>>", commObj.phrase)
        local newEventId = eventId .. tostring(#commObj.registeredEvents + 1)
        table.insert(commObj.registeredEvents, newEventId)
        mq.event(newEventId, thisPhrase, commObj.eventFunction)
    end
end

function Commands.RegisterCommEvent(eventId, phrase, eventFunction, helpFunction)
    if not TableUtils.ArrayContains(TableUtils.GetKeys(Commands._.registeredComms), eventId) then
        Commands._.registeredComms[eventId] = {
            eventFunction = eventFunction,
            phrase = phrase,
            helpFunction = helpFunction,
            registeredEvents = {}
        }
        UpdateCommEvent(eventId)
    else
        print("Cannot re-register same eventId: ["..eventId.."]")
    end
end

---Syncs registered events to currently active channels
local function UpdateCommChannels()
    for eventId,_ in pairs(Commands._.registeredComms) do
        UpdateCommEvent(eventId)
    end
end

--- Replaces current patterns with those provided
---@param channelPatterns array
function Commands.SetChannelPatterns(channelPatterns)
    Commands._.registeredChannelPatterns = channelPatterns
    UpdateCommChannels()
end

return Commands
