local mq = require("mq")
local ImGui = require("ImGui")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CommonUI = require("cabby.ui.commonUI")
local Event = require("cabby.commands.event")
local HotbarConfig = require("cabby.configs.hotbarConfig")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")
local ToggleCommand = require("cabby.commands.toggleCommand")

---@class GeneralConfig : BaseConfig
local GeneralConfig = {
    key = "GeneralConfig",
    keys = {
        version = "version",
        tellToMe = "tellToMe"
    },
    eventIds = {
        groupInvited = "groupInvited",
        tellToMe = "tellToMe",
        inspectRequest = "inspect",
        restart = "restart",
        doType = "dotype"
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
    if GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.tellToMe] == nil then
        DebugLog("General tellToMe was not set, updating...")
        -- on: forwarding is the reason the event exists, and with no speak override it only
        -- reaches this character's own console, so leaving it on broadcasts nothing
        GeneralConfig._.config:GetConfigRoot()[GeneralConfig.key][GeneralConfig.keys.tellToMe] = true
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
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.inspectRequest, event_InspectRequest, inspectDocs)
            :WithArgs({ required = true, hint = "an equipment slot", default = "mainhand" }))

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

        local doTypeDocs = ChelpDocs.new(function() return {
            "(dotype /<command>) Tells listener(s) to type the given slash command line as their own",
            " -- Example: /bc dotype /camp desktop"
        } end )
        local function event_DoType(_, speaker, args)
            if Commands.GetCommandOwners(GeneralConfig.eventIds.doType):HasPermission(speaker) then
                local commandLine = StringUtils.TrimFront(args or "")
                if commandLine:sub(1, 1) ~= "/" then
                    Speak.Respond(_, speaker, "(dotype /<command>) The line to type must start with a slash, e.g.: dotype /camp desktop")
                    return
                end
                DebugLog("Typing [" .. commandLine .. "] on request of speaker [" .. speaker .. "]")
                mq.cmd(commandLine)
            else
                DebugLog("Ignoring dotype request of speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(GeneralConfig.eventIds.doType, event_DoType, doTypeDocs)
            :WithArgs({ required = true, hint = "a slash command line, e.g. /camp desktop" }))

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
            "(event "..GeneralConfig.eventIds.tellToMe..") Forwards any received tells that were not part of an issued command",
            " -- Turn it on or off with (telltome <on | off | toggle>), the General menu page, or a hotbar button",
            " -- Forwards arrive on this character's own console unless a speak override for this event says otherwise: /speak telltome <channel>",
            " -- Tells from NPCs are not forwarded"
        } end )
        local function event_TellToMe(_, speaker, message)
            if not GeneralConfig.GetTellToMe() then return end
            if mq.TLO.SpawnCount("npc " .. speaker)() < 1 then
                local line = speaker .. " told me: " .. message
                -- A tell is private. The default speak list is where group-facing chatter goes,
                -- so it is deliberately not consulted here: with no override of its own, the
                -- forward stays on this character's console instead of going out on a channel.
                local speak = Commands.GetEventSpeakOverride(GeneralConfig.eventIds.tellToMe)
                if speak ~= nil then
                    speak:speak(line)
                else
                    print(line)
                end
            end
        end
        Commands.RegisterEvent(Event.new(GeneralConfig.eventIds.tellToMe, "#1# tells you, '#2#'", event_TellToMe, tellToMeDocs, true))

        ToggleCommand.Register({
            key = GeneralConfig.key,
            phrase = GeneralConfig.eventIds.tellToMe:lower(),
            summary = "Turns forwarding of received tells on or off",
            about = {
                "Forwards arrive on this character's own console. To send them somewhere else,",
                "set a speak override for the telltome event: /speak telltome <channel>.",
                "Tells from NPCs are never forwarded."
            },
            get = GeneralConfig.GetTellToMe,
            set = GeneralConfig.SetTellToMe
        })

        Menu.RegisterConfig(GeneralConfig)

        GeneralConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---@return boolean isEnabled whether received tells are forwarded
function GeneralConfig.GetTellToMe()
    return getConfigSection()[GeneralConfig.keys.tellToMe] == true
end

---@param enable boolean
function GeneralConfig.SetTellToMe(enable)
    getConfigSection()[GeneralConfig.keys.tellToMe] = enable == true
    GeneralConfig._.config:SaveConfig()
    print("Forwarding received tells is Enabled: [" .. tostring(enable) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function GeneralConfig.BuildMenu()
    local generalConfig = getConfigSection()
    ImGui.Text("Config Version: " .. generalConfig[GeneralConfig.keys.version])

    ImGui.SeparatorText("Tells")
    local tellToMe, tellToMeClicked = ImGui.Checkbox("Forward received tells", GeneralConfig.GetTellToMe())
    if tellToMeClicked then
        GeneralConfig.SetTellToMe(tellToMe)
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("Repeat tells from other players on this character's own console, so a question aimed at one boxed character is not missed. Tells that were one of this script's commands, and tells from NPCs, are not repeated. The forwards stay on this console -- the group-facing default speak list is deliberately not used. To send them somewhere else (a tell to your driver, for example), set a speak override for the telltome event under Command > Speak Channels, or /speak telltome <channel>. Toggle from chat or a hotbar button with: telltome")

    ImGui.SeparatorText("Hotbars")
    ImGui.SameLine()
    CommonUI.HelpMarker("A hotbar is a floating window of buttons. Resize it to lay its buttons out as a horizontal bar, a vertical bar, or a grid. Right-click a hotbar to rename it, resize its buttons, add or remove a button, lock its position so it cannot be dragged, or remove the hotbar. Right-click a button and pick Edit Commands to choose what it runs.")

    if ImGui.Button("Add Hotbar", 100, 24) then
        HotbarConfig.AddBar()
    end

    local bars = HotbarConfig.GetBars()
    if #bars < 1 then
        ImGui.TextDisabled("No hotbars yet")
        return
    end

    for barIndex, bar in ipairs(bars) do
        ImGui.PushID(barIndex)
        local visible, pressed = ImGui.Checkbox("##visible", bar.visible)
        if pressed then
            HotbarConfig.SetBarVisible(bar, visible)
        end
        ImGui.SameLine()
        ImGui.Text(bar.name .. " (" .. tostring(#bar.buttons) .. " buttons)")
        ImGui.PopID()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function GeneralConfig.Print()
    local generalConfig = getConfigSection()
    TableUtils.Print(generalConfig)
end

return GeneralConfig
