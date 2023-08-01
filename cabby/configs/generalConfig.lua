local mq = require("mq")
local Command = require("cabby.command")
local Commands = require("cabby.commands")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class GeneralConfig
local GeneralConfig = {
    key = "General",
    keys = {
        version = "version",
        relayTellsTo = "relayTellsTo"
    },
    eventIds = {
        groupInvited = "Invited to Group",
        tellToMe = "Tell to Me",
        inspectRequest = "Request to inspect",
        restart = "Restart Cabby Script"
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
        config = {},
        owners = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(GeneralConfig.key, str)
end

local function initAndValidate()
    if GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key] == nil then
        DebugLog("General Section was not set, updating...")
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key] = {}
    end
    if GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.version] == nil then
        DebugLog("General Version was not set, updating...")
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.version] = "1"
    end
end

local function getConfigSection()
    return GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key]
end

---Initialize the static object, only done once
---@param config Config
---@param owners Owners
function GeneralConfig.Init(config, owners)
    if not GeneralConfig._.isInit then
        GeneralConfig._.config = config
        GeneralConfig._.owners = owners

        -- Init any keys that were not setup
        initAndValidate()
        GeneralConfig._.config:SaveConfig()

        -- Events

        local function event_GroupInvited(_, speaker)
            if GeneralConfig._.owners:IsOwner(speaker) then
                DebugLog("Joining group of speaker [" .. speaker .. "]")
                mq.cmd("/invite")
            else
                DebugLog("Declining group of speaker [" .. speaker .. "]")
                mq.cmd("/disband")
            end
        end
        mq.event(GeneralConfig.eventIds.groupInvited, "#1# invites you to join a group.", event_GroupInvited)

        local function event_InspectRequest(_, speaker, message)
            local function doHelp()
                mq.cmd("/tell "..speaker.."(restart) Stops the currently running lua script and restarts it.")
            end

            if GeneralConfig._.owners:IsOwner(speaker) then
                local args = StringUtils.Split(StringUtils.TrimFront(message), " ")
                if #args > 0 then
                    doHelp()
                    return
                end

                local slot = args[1]:lower()
                DebugLog("Request for inspection: [" .. speaker .. "], slot: [" .. slot .. "]")
                if TableUtils.ArrayContains(GeneralConfig.equipmentSlots, slot) then
                    mq.cmd("/tell "..speaker.." "..slot..": "..mq.TLO.Me.Inventory(slot).ItemLink("CLICKABLE")())
                else
                    doHelp()
                end
            end
        end
        mq.event(GeneralConfig.eventIds.inspectRequest, "#1# tells you, 'inspect#2#'", event_InspectRequest)

        local function event_Restart(_, speaker)
            if GeneralConfig._.owners:IsOwner(speaker) then
                DebugLog("Restarting on request of speaker [" .. speaker .. "]")
                mq.cmd("/luar cabby")
            else
                DebugLog("Ignoring followme of speaker [" .. speaker .. "]")
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

        local function event_TellToMe(_, speaker, message)
            local tellTo = GeneralConfig.GetRelayTellsTo()
            if tellTo ~= "" and tellTo ~= nil and tellTo ~= speaker and mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
                mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
            end
        end
        Commands.ReRegisterOnEventUpdates(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe)

        GeneralConfig._.isInit = true
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
