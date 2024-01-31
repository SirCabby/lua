local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")

---@class GeneralConfig : BaseConfig
local GeneralConfig = {
    key = "GeneralConfig",
    keys = {
        version = "version"
    },
    eventIds = {
        groupInvited = "groupInvited",
        tellToMe = "tellToMe",
        inspectRequest = "inspect",
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
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.version] = "0.0.1"
        taint = true
    end
    if taint then
        GeneralConfig._.config:SaveConfig()
    end

    mq.cmd("/squelch /alias /luar /lua run luarun")
end

local function getConfigSection()
    return GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key]
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function GeneralConfig.Init()
    if not GeneralConfig._.isInit then
        local ftkey = Global.tracing.open("GeneralConfig Setup")
        GeneralConfig._.config = Global.configStore

        -- Init any keys that were not setup
        initAndValidate()

        -- Events

        local groupInviteDocs = ChelpDocs.new(function() return {
            "(event: "..GeneralConfig.eventIds.groupInvited..") Accepts or declines invitations to groups, depending on rights of inviter"
        } end )
        local function event_GroupInvited(_, speaker)
            if Commands.GetEventOwners(GeneralConfig.eventIds.groupInvited):HasPermission(speaker) then
                DebugLog("Joining group of speaker [" .. speaker .. "]")
                mq.cmd("/invite")
            else
                DebugLog("Declining group of speaker [" .. speaker .. "]")
                mq.cmd("/disband")
            end
        end
        Commands.RegisterEvent(Event.new(GeneralConfig.eventIds.groupInvited, "#1# invites you to join a group.", event_GroupInvited, groupInviteDocs))

        local inspectDocs = ChelpDocs.new(function() return {
            "(inspect <slot>) Slot types: [" .. StringUtils.Join(GeneralConfig.equipmentSlots, ", ") .. "]"
        } end )
        local function event_InspectRequest(_, speaker, args)
            if Commands.GetCommandOwners(GeneralConfig.eventIds.inspectRequest):HasPermission(speaker) then
                args = StringUtils.Split(StringUtils.TrimFront(args))

                if #args == 1 and TableUtils.ArrayContains(GeneralConfig.equipmentSlots, args[1]:lower()) then
                    Speak.Respond(_, speaker, args[1]:lower()..": "..mq.TLO.Me.Inventory(args[1]).ItemLink("CLICKABLE")())
                    return
                end

                Speak.Respond(_, speaker, "(inspect <slot>) Slot types: [" .. StringUtils.Join(GeneralConfig.equipmentSlots, ", ") .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.inspectRequest, event_InspectRequest, inspectDocs))

        local restartDocs = ChelpDocs.new(function() return {
            "(restart) Tells listener(s) to restart cabby script"
        } end )
        local function event_Restart(_, speaker)
            if Commands.GetCommandOwners(GeneralConfig.eventIds.restart):HasPermission(speaker) then
                DebugLog("Restarting on request of speaker [" .. speaker .. "]")
                mq.cmd("/luar cabby")
            else
                DebugLog("Ignoring restart request of speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.restart, event_Restart, restartDocs))

        -- Binds

        local slashRestartDocs = ChelpDocs.new(function() return {
            "(/restart) Restart cabby script"
        } end )
        local function Bind_Restart(...)
            local args = {...} or {}
            if #args < 1 then
                mq.cmd("/luar cabby")
            else
                slashRestartDocs:Print()
            end
        end
        Commands.RegisterSlashCommand(SlashCmd.new(GeneralConfig.eventIds.restart, Bind_Restart, slashRestartDocs))

        local tellToMeDocs = ChelpDocs.new(function() return {
            "(event "..GeneralConfig.eventIds.tellToMe..") Forwards any received tells that were not part of an issued command to the speak channel"
        } end )
        local function event_TellToMe(_, speaker, message)
            if mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
                Commands.GetEventSpeak(GeneralConfig.eventIds.tellToMe):speak(speaker .. " told me: " .. message)
            end
        end
        Commands.RegisterEvent(Event.new(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe, tellToMeDocs, true))

        Menu.RegisterConfig(GeneralConfig)

        GeneralConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function GeneralConfig.BuildMenu()
    local generalConfig = getConfigSection()
    ImGui.Text("Config Version: " .. generalConfig[GeneralConfig.keys.version])
end

---@diagnostic disable-next-line: duplicate-set-field
function GeneralConfig.Print()
    local generalConfig = getConfigSection()
    TableUtils.Print(generalConfig)
end

return GeneralConfig
