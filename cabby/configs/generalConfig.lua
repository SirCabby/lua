local mq = require("mq")
local Commands = require("cabby.commands")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class GeneralConfig
local GeneralConfig = {
    key = "General",
    keys = {
        version = "version",
        relayTellsTo = "relayTellsTo",
        activeChannels = "activeChannels"
    },
    channelTypes = {
        bc = "bc",
        tell = "tell",
        raid = "raid",
        group = "group"
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

--- Defined here because it is registered last in the channel update
local function event_TellToMe(_, speaker, message)
    local tellTo = GeneralConfig.GetRelayTellsTo()
    if tellTo ~= "" and tellTo ~= nil and tellTo ~= speaker and mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
        mq.cmd("/tell " .. tellTo .. " " .. speaker .. " told me: " .. message)
    end
end

---Initialize the static object, only done once
---@param config Config
---@param owners Owners
function GeneralConfig.Init(config, owners)
    if not GeneralConfig._.isInit then
        GeneralConfig._.config = config
        GeneralConfig._.owners = owners

        -- Init any keys that were not setup
        local configForGeneral = GeneralConfig._.config:GetConfig(GeneralConfig.key)
        local taint = false
        if configForGeneral[GeneralConfig.keys.version] == nil then
            DebugLog("General Version was not set, updating...")
            configForGeneral[GeneralConfig.keys.version] = 1
            taint = true
        end
        if configForGeneral[GeneralConfig.keys.activeChannels] == nil then
            DebugLog("Active Channels were not set, updating...")
            configForGeneral[GeneralConfig.keys.activeChannels] = {}
            taint = true
        end
        if taint then GeneralConfig._.config:SaveConfig(GeneralConfig.key, configForGeneral) end

        -- Validation reminders
        if #configForGeneral[GeneralConfig.keys.activeChannels] < 1 then
            print("Not currently listening on any active channels. To learn more, /chelp activechannels")
        else
            print("Currently listening on active channels: [" .. StringUtils.Join(GeneralConfig.GetActiveChannels(), ", ") .. "]")
        end

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
        Commands.RegisterCommEvent(GeneralConfig.eventIds.restart, "restart", event_Restart, restartHelp)

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

        local function Bind_ActiveChannels(...)
            local args = {...} or {}
            if args == nil or #args ~= 1 or args[1]:lower() == "help" then
                print("(/activechannels) Channels used for listening to commands")
                print("To toggle an active channel, use: /activechannels channel")
                print("Valid Active Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
                print("Currently active channels: [" .. StringUtils.Join(GeneralConfig.GetActiveChannels(), ", ") .. "]")
            else
                GeneralConfig.ToggleActiveChannel(args[1]:lower())
            end
        end
        Commands.RegisterSlashCommand("activechannels", Bind_ActiveChannels)

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
        Commands.RegisterSlashCommand("owners", Bind_Owners)

        local function Bind_Restart(...)
            local args = {...} or {}
            if #args < 1 then
                mq.cmd("/luar cabby")
            else
                print("(/restart) Restart cabby script...")
            end
        end
        Commands.RegisterSlashCommand("restart", Bind_Restart)

        GeneralConfig.UpdateEventChannels()
        GeneralConfig._.isInit = true
    end
end

function GeneralConfig.GetRelayTellsTo()
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    return generalConfig[GeneralConfig.keys.relayTellsTo]
end

function GeneralConfig.SetRelayTellsTo(name)
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    generalConfig[GeneralConfig.keys.relayTellsTo] = name
    GeneralConfig._.config:SaveConfig(GeneralConfig.key, generalConfig)
    DebugLog("Set relayTellsTo: [" .. name .. "]")
end

---@return array
function GeneralConfig.GetActiveChannels()
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    return generalConfig[GeneralConfig.keys.activeChannels]
end

---Toggles an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
function GeneralConfig.ToggleActiveChannel(channel)
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key) or {}
    if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
        TableUtils.RemoveByValue(generalConfig[GeneralConfig.keys.activeChannels], channel)
        print("Removed [" .. channel .. "] as active channel")
    else
        generalConfig[GeneralConfig.keys.activeChannels][#generalConfig[GeneralConfig.keys.activeChannels] + 1] = channel
        print("Added [" .. channel .. "] to active channels")
    end
    GeneralConfig._.config:SaveConfig(GeneralConfig.key, generalConfig)
    GeneralConfig.UpdateEventChannels()
end

---Adds an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
function GeneralConfig.AddChannel(channel)
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key) or {}
    if not TableUtils.IsArray(generalConfig[GeneralConfig.keys.activeChannels]) then error("GeneralConfig.Channels config was not an array") end
    if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
        return
    end
    if not TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
        generalConfig[GeneralConfig.keys.activeChannels][#generalConfig[GeneralConfig.keys.activeChannels] + 1] = channel
        print("Added [" .. channel .. "] to active channels")
        GeneralConfig._.config:SaveConfig(GeneralConfig.key, generalConfig)
        GeneralConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was already an active channel")
end

---Removes an active command channel
---@param channel string Available types found in GeneralConfig.channelTypes
function GeneralConfig.RemoveChannel(channel)
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    if not TableUtils.IsArray(generalConfig[GeneralConfig.keys.activeChannels]) then error("Command.Channels config was not an array") end
    if not TableUtils.ArrayContains(TableUtils.GetValues(GeneralConfig.channelTypes), channel) then
        print("Invalid Channel Type. Valid Channel Types: [" .. StringUtils.Join(TableUtils.GetValues(GeneralConfig.channelTypes), ", ") .. "]")
        return
    end
    if TableUtils.ArrayContains(generalConfig[GeneralConfig.keys.activeChannels], channel) then
        TableUtils.RemoveByValue(generalConfig[GeneralConfig.keys.activeChannels], channel)
        GeneralConfig._.config:SaveConfig(GeneralConfig.key, generalConfig)
        print("Removed [" .. channel .. "] as active channel")
        GeneralConfig.UpdateEventChannels()
    end
    DebugLog(channel .. " was not an active channel")
end

---Syncs registered events to all active channels
function GeneralConfig.UpdateEventChannels()
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    local channels = generalConfig[GeneralConfig.keys.activeChannels] or {}

    local phrasePatterns = {}
    if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.bc) then
        table.insert(phrasePatterns, "<#1#> <<phrase>>")
        table.insert(phrasePatterns, "<#1#> #2# <<phrase>>")
        table.insert(phrasePatterns, "[#1#(msg)] <<phrase>>")
    end
    if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.tell) then
        table.insert(phrasePatterns, "#1# tells you, '<<phrase>>'")
    end
    if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.group) then
        table.insert(phrasePatterns, "#1# tells the group, '<<phrase>>'")
    end
    if TableUtils.ArrayContains(channels, GeneralConfig.channelTypes.raid) then
        table.insert(phrasePatterns, "#1# tells the raid, '<<phrase>>'")
    end

    Commands.SetChannelPatterns(phrasePatterns)

    -- This is a catchall event for uncaught tell patterns and must be registered last so other tell commands have a chance to catch first
    mq.unevent(GeneralConfig.eventIds.tellToMe)
    mq.event(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe)
end

function GeneralConfig.Print()
    local generalConfig = GeneralConfig._.config:GetConfig(GeneralConfig.key)
    TableUtils.Print(generalConfig)
end

return GeneralConfig
