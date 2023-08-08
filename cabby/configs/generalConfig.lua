local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local Broadcast = require("cabby.commands.broadcast")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")

---@class GeneralConfig
local GeneralConfig = {
    key = "General",
    keys = {
        version = "version",
        relayTellsTo = "relayTellsTo"
    },
    eventIds = {
        groupInvited = "groupInvited",
        tellToMe = "tellToMe",
        inspectRequest = "inspectRequest",
        restart = "restart"
    },
    equipmentSlots = {
        "charm",
        "leftear",
        "head",
        "face",
        "rightear",
        "neck",
        "shoulder",
        "arms",
        "back",
        "leftwrist",
        "rightwrist",
        "ranged",
        "hands",
        "mainhand",
        "offhand",
        "leftfinger",
        "rightfinger",
        "chest",
        "legs",
        "feet",
        "waist",
        "powersource",
        "ammo"
    },
    _ = {
        isInit = false,
        config = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(GeneralConfig.key, str)
end

local function initAndValidate()
    local taint = false
    if GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key] == nil then
        DebugLog("General Section was not set, updating...")
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key] = {}
        taint = true
    end
    if GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.version] == nil then
        DebugLog("General Version was not set, updating...")
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.version] = "1"
        taint = true
    end
    if taint then
        GeneralConfig._.config:SaveConfig()
    end
end

local function getConfigSection()
    return GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key]
end

---Initialize the static object, only done once
---@param config Config
function GeneralConfig.Init(config)
    if not GeneralConfig._.isInit then
        local ftkey = Global.tracing.open("GeneralConfig Setup")
        GeneralConfig._.config = config

        -- Init any keys that were not setup
        initAndValidate()

        -- Events

        local function groupInvitedHelp()
            print("(event: "..GeneralConfig.eventIds.groupInvited..") Accepts or declines invitations to groups, depending on rights of asker")
        end
        local function event_GroupInvited(_, speaker)
            if Commands.GetEventOwners(GeneralConfig.eventIds.groupInvited):HasPermission(speaker) then
                DebugLog("Joining group of speaker [" .. speaker .. "]")
                mq.cmd("/invite")
            else
                DebugLog("Declining group of speaker [" .. speaker .. "]")
                mq.cmd("/disband")
            end
        end
        Commands.RegisterEvent(Event.new(GeneralConfig.eventIds.groupInvited, "#1# invites you to join a group.", event_GroupInvited, groupInvitedHelp))

        local function inspectHelp()
            print("(inspect <slot>) Slot types: [" .. StringUtils.Join(GeneralConfig.equipmentSlots, ", ") .. "]")
        end
        local function event_InspectRequest(_, speaker, message)
            if Commands.GetCommandOwners("inspect"):HasPermission(speaker) then
                local args = StringUtils.Split(message, " ")

                if #args == 1 and TableUtils.ArrayContains(GeneralConfig.equipmentSlots, args[1]:lower()) then
                    Broadcast.Respond(_, speaker, args[1]:lower()..": "..mq.TLO.Me.Inventory(args[1]).ItemLink("CLICKABLE")())
                    return
                end

                Broadcast.Respond(_, speaker, "(inspect <slot>) Slot types: [" .. StringUtils.Join(GeneralConfig.equipmentSlots, ", ") .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.inspectRequest, "inspect #2#", event_InspectRequest, inspectHelp))

        local function event_Restart(_, speaker)
            if Commands.GetCommandOwners("restart"):HasPermission(speaker) then
                DebugLog("Restarting on request of speaker [" .. speaker .. "]")
                mq.cmd("/luar cabby")
            else
                DebugLog("Ignoring restart request of speaker [" .. speaker .. "]")
            end
        end
        local function restartHelp()
            print("(restart) Tells listener(s) to restart cabby script")
        end
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.restart, "restart", event_Restart, restartHelp))

        -- Binds

        local function Bind_SetRelayTellsToFunc(...)
            local args = {...} or {}
            if args == nil or #args < 1 or args[1]:lower() == "help" then
                print("(/relaytellsto) Relays tells received to this character")
                print(" -- Usage: /relaytellsto name|clear")
                local who = GeneralConfig.GetRelayTellsTo() or ""
                print(" -- Currently set to: [" .. who .. "]")
            else
                arg =  args[1]:lower()
                if arg == "clear" then
                    GeneralConfig.SetRelayTellsTo("")
                    print("Relaying tells is now disabled")
                else
                    GeneralConfig.SetRelayTellsTo(args[1])
                    local who = GeneralConfig.GetRelayTellsTo() or ""
                    print("Relaying future tells to: [" .. who .. "]")
                end
            end
        end
        Commands.RegisterSlashCommand("relaytellsto", Bind_SetRelayTellsToFunc)

        local function Bind_Restart(...)
            local args = {...} or {}
            if #args < 1 then
                mq.cmd("/luar cabby")
            else
                print("(/restart) Restart cabby script...")
            end
        end
        Commands.RegisterSlashCommand("restart", Bind_Restart)

        local function tellToMeHelp()
            print("(event "..GeneralConfig.eventIds.tellToMe..") Forwards any received tells that were not part of an issued command to the broadcast channel")
        end
        local function event_TellToMe(_, speaker, message)
            local tellTo = GeneralConfig.GetRelayTellsTo()
            if tellTo ~= "" and tellTo ~= nil and tellTo ~= speaker and mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
                mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
                Broadcast.Message(Broadcast.channelTypes.bc, speaker .. " told me: " .. message)
            end
        end
        Commands.RegisterEvent(Event.new(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe, tellToMeHelp, true))

        GeneralConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

function GeneralConfig.GetRelayTellsTo()
    local generalConfig = getConfigSection()
    return generalConfig[GeneralConfig.keys.relayTellsTo]
end

function GeneralConfig.SetRelayTellsTo(name)
    local generalConfig = getConfigSection()
    generalConfig[GeneralConfig.keys.relayTellsTo] = name
    GeneralConfig._.config:SaveConfig()
    DebugLog("Set relayTellsTo: [" .. name .. "]")
end

function GeneralConfig.Print()
    local generalConfig = getConfigSection()
    TableUtils.Print(generalConfig)
end

return GeneralConfig
