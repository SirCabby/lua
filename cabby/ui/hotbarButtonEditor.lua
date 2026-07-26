local ImGui = require("ImGui")

local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

local Commands = require("cabby.commands.commands")
local CommonUI = require("cabby.ui.commonUI")
local HotbarConfig = require("cabby.configs.hotbarConfig")
local Speak = require("cabby.commands.speak")

---Editor window for one hotbar button: its label and the command lines it runs.
---
---Lines are plain text, the same text the user could type into the game. The action picker
---below them is only a text generator -- it knows how to turn "the followme command, spoken on
---bc" into "/bc followme", writes that into a line, and then gets out of the way. That is what
---makes an assigned action editable afterwards: "/bc attack" is just text until the user turns
---it into "/bc attack ${Target.ID}", and nothing in the config remembers where the line came
---from.
---
---Editing is staged. The working copy is written back to the live button only on Save, so
---Cancel can walk away from a half-finished line (same shape as ui/actions/editAction.lua).
---@class HotbarButtonEditor
local HotbarButtonEditor = {
    key = "HotbarButtonEditor",
    commandTypes = {
        comm = "Cabby Command",
        slash = "Slash Command"
    },
    _ = {
        edit = nil, -- { bar, button, index, label, lines }
        picker = {
            typeIndex = 1,
            commandIndex = 0,
            slashIndex = 0,
            channelIndex = 1,
            tellName = "",
            args = ""
        }
    }
}

local commandTypeOptions = {
    HotbarButtonEditor.commandTypes.comm,
    HotbarButtonEditor.commandTypes.slash
}

---@param str string
---@return string trimmed
local function trim(str)
    return (str:match("^%s*(.-)%s*$"))
end

---@return table phrases registered comm command phrases, alphabetical
local function CommsPhrases()
    local phrases = Commands.GetCommsPhrases()
    table.sort(phrases)
    return phrases
end

---@return table names registered slash command names, alphabetical
local function SlashCommandNames()
    local names = Commands.GetSlashCommandNames()
    table.sort(names)
    return names
end

---@param bar table
---@param index number
function HotbarButtonEditor.Open(bar, index)
    local button = bar.buttons[index]
    if button == nil then return end

    HotbarButtonEditor._.edit = {
        bar = bar,
        button = button,
        index = index,
        label = button.label,
        -- work on a copy: Cancel has to be able to throw the whole thing away
        lines = TableUtils.DeepClone(HotbarConfig.GetButtonLines(button)) or {},
        selectedIndex = nil,  -- the line the picker is pointed at, when any
        pickerLoaded = false  -- whether the picker actually managed to represent it
    }

    -- the picked command is cleared, but the channel and type are deliberately kept: binding a
    -- run of commands to the same channel is the common case
    local picker = HotbarButtonEditor._.picker
    picker.commandIndex = 0
    picker.slashIndex = 0
    picker.tellName = ""
    picker.args = ""
end

function HotbarButtonEditor.Close()
    HotbarButtonEditor._.edit = nil
end

---@return boolean isOpen
function HotbarButtonEditor.IsOpen()
    return HotbarButtonEditor._.edit ~= nil
end

---@param bar table
---@param index number
---@return boolean isEditing whether this exact button is the one being edited
function HotbarButtonEditor.IsEditing(bar, index)
    local edit = HotbarButtonEditor._.edit
    return edit ~= nil and edit.bar == bar and edit.index == index
end

local function Save()
    local edit = HotbarButtonEditor._.edit
    if edit == nil then return end

    HotbarConfig.SetButton(edit.button, edit.label, edit.lines)
    HotbarButtonEditor.Close()
end

---Drop the working text into the first line that is still blank, or onto the end
---@param text string
local function InsertLine(text)
    local edit = HotbarButtonEditor._.edit
    for index, line in ipairs(edit.lines) do
        if trim(line) == "" then
            edit.lines[index] = text
            return
        end
    end
    edit.lines[#edit.lines+1] = text
end

---A button called "New" has never been named, so name it after the action being added. An
---edited label is the user's and is left alone.
---@param name string
local function NameButtonAfter(name)
    local edit = HotbarButtonEditor._.edit
    if trim(edit.label) == "" or edit.label == HotbarConfig.defaults.buttonLabel then
        edit.label = name
    end
end

---@param commandType string one of HotbarButtonEditor.commandTypes
---@param name string comm command phrase, or slash command name without its slash
---@return Command|SlashCmd|nil command as registered, so the picker can read what it declares
local function FindCommand(commandType, name)
    if name == nil or trim(name) == "" then return nil end

    if commandType == HotbarButtonEditor.commandTypes.slash then
        return Commands.GetSlashCommand(name)
    end
    return Commands.GetCommand(name)
end

---@param commandType string one of HotbarButtonEditor.commandTypes
---@param name string comm command phrase, or slash command name without its slash
---@return CommandArgs? argsSpec what that command says it expects after its phrase, if anything
function HotbarButtonEditor.GetArgsSpec(commandType, name)
    local command = FindCommand(commandType, name)
    if command == nil then return nil end
    return command.argsSpec
end

---The whole of what picking an action means: which text ends up in the command line. A comm
---command carries its channel with it -- the local channel dispatches through /cself, a tell
---channel needs a recipient, everything else is the channel's own slash command -- and a slash
---command is already addressed to this character. Arguments go on the end either way.
---
---Returning a reason instead of a line is how an incomplete pick is caught before it becomes a
---button: `attack` with no spawn id is a line that looks finished and does nothing.
---@param commandType string one of HotbarButtonEditor.commandTypes
---@param name string comm command phrase, or slash command name without its slash
---@param channel string? channel to speak a comm command on
---@param tellName string? recipient, required by tell-type channels
---@param args string? arguments to follow the command
---@return string? line nil when the selection cannot make a line yet
---@return string? reason what is missing, when there is no line
function HotbarButtonEditor.BuildActionLine(commandType, name, channel, tellName, args)
    if name == nil or trim(name) == "" then return nil, "Select a command" end
    name = trim(name)

    local line
    if commandType == HotbarButtonEditor.commandTypes.slash then
        line = "/" .. name
    elseif channel == nil or not Speak.IsChannelType(channel) then
        return nil, "Select a channel"
    elseif Speak.IsLocalType(channel) then
        local command = FindCommand(commandType, name)
        if command ~= nil and command.actsOnSpeaker then
            return nil, name .. " acts on whoever says it -- pick a channel to say it on"
        end
        line = "/" .. Commands.selfCommand .. " " .. name
    elseif Speak.IsTellType(channel) then
        tellName = trim(tellName or "")
        if tellName == "" then return nil, "Enter a name to tell" end
        line = "/" .. Speak.channelTypes[channel].command .. " " .. tellName .. " " .. name
    else
        line = "/" .. Speak.channelTypes[channel].command .. " " .. name
    end

    args = trim(args or "")

    local argsSpec = HotbarButtonEditor.GetArgsSpec(commandType, name)
    if args == "" and argsSpec ~= nil and argsSpec.required then
        return nil, "Enter " .. (argsSpec.hint or "arguments") .. " for " .. name
    end

    if args ~= "" then
        line = line .. " " .. args
    end
    return line
end

---@param words table
---@param index number first word to take
---@return string text those words back as one string
local function JoinFrom(words, index)
    local rest = {}
    for wordIndex = index, #words do
        rest[#rest+1] = words[wordIndex]
    end
    return StringUtils.Join(rest, " ")
end

---@param slashCommand string a line's leading word, without its slash
---@return string? channel the channel that word speaks on
---@return number? phraseIndex which word of the line carries the command phrase
local function ChannelOf(slashCommand)
    if slashCommand == Commands.selfCommand then
        return Speak.channelTypes.self.name, 2
    end

    for _, channel in ipairs(Speak.GetListenChannelTypes()) do
        if Speak.channelTypes[channel].command == slashCommand then
            -- a tell addresses its recipient first, so the phrase sits one word later
            return channel, Speak.IsTellType(channel) and 3 or 2
        end
    end
    return nil, nil
end

---Read a line back into the pieces the picker is made of -- the inverse of BuildActionLine, so
---a line the picker wrote can be handed back to it and edited with the same controls that built
---it. Returns nil for anything the picker could not have produced (a raw game command, or a
---phrase this character has not registered and so cannot offer in its list); those lines are
---still perfectly good, they just have to be edited as text.
---@param line string
---@return table? action { commandType, name, channel, tellName, args }
function HotbarButtonEditor.ParseActionLine(line)
    line = trim(line or "")
    if line:sub(1, 1) ~= "/" then return nil end

    local words = StringUtils.Split(line)
    local channel, phraseIndex = ChannelOf(words[1]:sub(2):lower())

    if channel ~= nil then
        local command = Commands.GetCommand(words[phraseIndex] or "")
        if command == nil then return nil end

        return {
            commandType = HotbarButtonEditor.commandTypes.comm,
            -- the registered spelling, so it matches an entry in the picker's list
            name = StringUtils.Split(command.command)[1],
            channel = channel,
            tellName = (phraseIndex == 3 and words[2]) or "",
            args = JoinFrom(words, phraseIndex + 1)
        }
    end

    local slashCommand = Commands.GetSlashCommand(words[1])
    if slashCommand == nil then return nil end

    return {
        commandType = HotbarButtonEditor.commandTypes.slash,
        name = slashCommand.command,
        channel = nil,
        tellName = "",
        args = JoinFrom(words, 2)
    }
end

---Point the picker's controls at an existing line so it can be edited with them
---@param line string
---@return boolean loaded false when the line is not one the picker can represent
local function LoadPicker(line)
    local action = HotbarButtonEditor.ParseActionLine(line)
    if action == nil then return false end

    local picker = HotbarButtonEditor._.picker
    picker.typeIndex = math.max(1, TableUtils.ArrayIndexOf(commandTypeOptions, action.commandType))

    if action.commandType == HotbarButtonEditor.commandTypes.slash then
        picker.slashIndex = math.max(0, TableUtils.ArrayIndexOf(SlashCommandNames(), action.name))
    else
        picker.commandIndex = math.max(0, TableUtils.ArrayIndexOf(CommsPhrases(), action.name))
        picker.channelIndex = math.max(1, TableUtils.ArrayIndexOf(Speak.GetAllChannelTypes(), action.channel))
    end

    picker.tellName = action.tellName
    picker.args = action.args
    return true
end

---Select a line for editing with the picker, or clear the selection when it is clicked again.
---A line that the picker cannot represent still selects: saying so is more use than ignoring
---the click.
---@param index number?
local function SelectLine(index)
    local edit = HotbarButtonEditor._.edit

    if index == nil or edit.selectedIndex == index then
        edit.selectedIndex = nil
        edit.pickerLoaded = false
        return
    end

    edit.selectedIndex = index
    edit.pickerLoaded = LoadPicker(edit.lines[index])
end

---Look over a finished line for the mistakes we can actually be sure about. Only lines that
---carry one of our commands are judged, and how far we can judge one depends on where it is
---going: a `/cself` line runs against *our* registry, so an unknown phrase there is certainly
---wrong, while a phrase spoken on a channel may be one only the characters listening have
---registered (a warrior broadcasting `heal` to clerics is not a mistake). Argument rules are
---the command's own, so they hold wherever it lands.
---@param line string
---@return string? warning nil when there is nothing worth pointing at
function HotbarButtonEditor.CheckLine(line)
    line = trim(line or "")
    if line:sub(1, 1) ~= "/" then return nil end

    local words = StringUtils.Split(line)
    local slashCommand = words[1]:sub(2):lower()

    -- where the command phrase sits in the line, which is one word later for tell channels
    -- because they address a recipient first
    local phraseIndex
    local isLocal = slashCommand == Commands.selfCommand
    if isLocal then
        phraseIndex = 2
    else
        for _, channel in ipairs(Speak.GetListenChannelTypes()) do
            if Speak.channelTypes[channel].command == slashCommand then
                phraseIndex = Speak.IsTellType(channel) and 3 or 2
                break
            end
        end
    end
    if phraseIndex == nil then return nil end -- some other slash command; not ours to judge

    local phrase = words[phraseIndex]
    if phrase == nil then
        return "Nothing follows " .. words[1] .. " to run"
    end

    local command = Commands.GetCommand(phrase)
    if command == nil then
        if isLocal then
            return "[" .. phrase .. "] is not one of this script's commands"
        end
        return nil -- spoken to characters that may well know it even though we do not
    end

    if isLocal and command.actsOnSpeaker then
        return "[" .. phrase .. "] acts on whoever says it, so sent to yourself it does nothing"
    end

    if command.argsSpec ~= nil and command.argsSpec.required and words[phraseIndex + 1] == nil then
        return "[" .. phrase .. "] needs " .. (command.argsSpec.hint or "arguments") .. " after it"
    end

    return nil
end

---@param message string
local function WarningMarker(message)
    ImGui.TextColored(1, 0.8, 0.2, 1, "(!)")
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0)
        ImGui.TextUnformatted(message)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

---@return string? line the line the current picker selection would insert
---@return string? reason what the selection is still missing, when there is no line
local function PickedLine()
    local picker = HotbarButtonEditor._.picker

    if commandTypeOptions[picker.typeIndex] == HotbarButtonEditor.commandTypes.slash then
        return HotbarButtonEditor.BuildActionLine(
            HotbarButtonEditor.commandTypes.slash,
            SlashCommandNames()[picker.slashIndex],
            nil,
            nil,
            picker.args)
    end

    return HotbarButtonEditor.BuildActionLine(
        HotbarButtonEditor.commandTypes.comm,
        CommsPhrases()[picker.commandIndex],
        Speak.GetAllChannelTypes()[picker.channelIndex],
        picker.tellName,
        picker.args)
end

---@return string? name whichever command the picker currently has selected
local function PickedName()
    local picker = HotbarButtonEditor._.picker
    if commandTypeOptions[picker.typeIndex] == HotbarButtonEditor.commandTypes.slash then
        return SlashCommandNames()[picker.slashIndex]
    end
    return CommsPhrases()[picker.commandIndex]
end

---@return CommandArgs? argsSpec for whichever command the picker currently has selected
local function PickedArgsSpec()
    return HotbarButtonEditor.GetArgsSpec(commandTypeOptions[HotbarButtonEditor._.picker.typeIndex], PickedName())
end

---Offer the newly selected command's suggested arguments. Picking `attack` should hand back a
---button that attacks your target, not one that needs to be edited before it does anything.
local function ResetArgsForSelection()
    local picker = HotbarButtonEditor._.picker
    local argsSpec = PickedArgsSpec()
    picker.args = (argsSpec ~= nil and argsSpec.default) or ""
end

---@return ChelpDocs? docs help for whatever the picker has selected
local function PickedDocs()
    local picker = HotbarButtonEditor._.picker

    if commandTypeOptions[picker.typeIndex] == HotbarButtonEditor.commandTypes.slash then
        local command = Commands.GetSlashCommand(SlashCommandNames()[picker.slashIndex] or "")
        if command == nil then return nil end
        return command.docs
    end

    local command = Commands.GetCommand(CommsPhrases()[picker.commandIndex] or "")
    if command == nil then return nil end
    return command.docs
end

---@param label string
---@param list table
---@param selectedIndex number
---@param width number
---@param hint string shown when nothing is selected yet
---@return number selectedIndex
---@return boolean changed whether this frame is the one that changed the selection
local function DrawCombo(label, list, selectedIndex, width, hint)
    local changed = false
    ImGui.SetNextItemWidth(width)
    if ImGui.BeginCombo(label, list[selectedIndex] or hint) then
        for index, value in ipairs(list) do
            if ImGui.Selectable(value, selectedIndex == index) then
                changed = selectedIndex ~= index
                selectedIndex = index
            end
        end
        ImGui.EndCombo()
    end
    return selectedIndex, changed
end

local function DrawCommandLines()
    local edit = HotbarButtonEditor._.edit

    ImGui.SeparatorText("Commands")
    ImGui.SameLine()
    CommonUI.HelpMarker("Lines run top to bottom when the button is pressed, each as if typed in game -- ${Target.ID} and other TLOs are resolved at press time. A line starting with / is a slash command (yours or the game's); a line without one is a Cabby command issued to this character only, never spoken.\n\nClick a line's number to load it into the picker below and edit it there instead of by hand. Click the number again to stop editing it.")

    -- always leave a blank line to type into, so the list grows as it is filled in
    if #edit.lines < 1 or trim(edit.lines[#edit.lines]) ~= "" then
        edit.lines[#edit.lines+1] = ""
    end

    local width = ImGui.GetContentRegionAvail()
    local removeIndex = nil
    local selectIndex = nil
    for index, line in ipairs(edit.lines) do
        ImGui.PushID(index)

        -- the number doubles as the handle for editing that line with the picker; the trailing
        -- blank row has nothing to edit yet, so its number is inert
        local _, numberPressed = ImGui.Selectable(tostring(index), edit.selectedIndex == index, 0, 22, ImGui.GetFrameHeight())
        if numberPressed and trim(line) ~= "" then
            selectIndex = index
        end
        ImGui.SameLine()

        ImGui.SetNextItemWidth(math.max(120, width - 84))
        local text, changed = ImGui.InputText("##line", line)
        if changed then
            edit.lines[index] = text
        end
        -- follow a hand edit of the line being picked at, so the picker never sits on top of
        -- text it no longer describes and overwrites it on the next Update
        if edit.selectedIndex == index and ImGui.IsItemDeactivatedAfterEdit() then
            edit.pickerLoaded = LoadPicker(edit.lines[index])
        end

        -- the trailing blank line is what new lines are typed into, so it has nothing to remove
        if index < #edit.lines then
            ImGui.SameLine()
            if ImGui.Button("x", 22, 0) then
                removeIndex = index
            end

            local warning = HotbarButtonEditor.CheckLine(edit.lines[index])
            if warning ~= nil then
                ImGui.SameLine()
                WarningMarker(warning)
            end
        end

        ImGui.PopID()
    end

    if selectIndex ~= nil then
        SelectLine(selectIndex)
    end

    if removeIndex ~= nil then
        table.remove(edit.lines, removeIndex)
        -- the lines below it just shifted up, so whatever was selected no longer is
        SelectLine(nil)
    end
end

local function DrawActionPicker()
    local edit = HotbarButtonEditor._.edit
    local picker = HotbarButtonEditor._.picker
    local isEditingLine = edit.selectedIndex ~= nil and edit.pickerLoaded

    if isEditingLine then
        ImGui.SeparatorText("Editing Line " .. tostring(edit.selectedIndex))
    else
        ImGui.SeparatorText("Add an Action")
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("Pick something this script can do and it is written into the next free command line, channel and all. Click a line's number above to load that line back in here and change it with these controls instead of editing its text.")

    if edit.selectedIndex ~= nil and not edit.pickerLoaded then
        ImGui.TextColored(1, 0.8, 0.2, 1, "Line " .. tostring(edit.selectedIndex) .. " was not written by this picker -- edit its text above")
    end

    local typeChanged, commandChanged = false, false
    picker.typeIndex, typeChanged = DrawCombo("Type", commandTypeOptions, picker.typeIndex, 160, commandTypeOptions[1])

    if commandTypeOptions[picker.typeIndex] == HotbarButtonEditor.commandTypes.slash then
        picker.slashIndex, commandChanged = DrawCombo("Command", SlashCommandNames(), picker.slashIndex, 160, "<Select Command>")
    else
        picker.commandIndex, commandChanged = DrawCombo("Command", CommsPhrases(), picker.commandIndex, 160, "<Select Command>")

        local channels = Speak.GetAllChannelTypes()
        picker.channelIndex = DrawCombo("Channel", channels, picker.channelIndex, 160, "<Select Channel>")
        ImGui.SameLine()
        CommonUI.HelpMarker("[self] runs the command on this character only and says nothing anywhere. Any other channel speaks the command so that every character listening on it -- including your own others -- picks it up.")

        local channel = channels[picker.channelIndex]
        if channel ~= nil and Speak.IsTellType(channel) then
            ImGui.SetNextItemWidth(160)
            picker.tellName = ImGui.InputTextWithHint("Name", "Enter Name", picker.tellName)
        end
    end

    if typeChanged or commandChanged then
        ResetArgsForSelection()
    end

    -- arguments are always offered: a command can take more than it declares, and a declared
    -- default is only ever a starting point
    local argsSpec = PickedArgsSpec()
    ImGui.SetNextItemWidth(220)
    picker.args = ImGui.InputTextWithHint("Arguments", (argsSpec ~= nil and argsSpec.hint) or "(optional)", picker.args)
    ImGui.SameLine()
    CommonUI.HelpMarker("Whatever the command needs after its name -- a spawn id, a slot, on/off. ${Target.ID} and other TLOs are resolved when the button is pressed, so a button reading `attack ${Target.ID}` always means your current target.")

    local picked, reason = PickedLine()

    local isDisabled = picked == nil
    if isDisabled then ImGui.BeginDisabled() end

    if isEditingLine then
        if ImGui.Button("Update Line", 120, 24) and picked ~= nil then
            edit.lines[edit.selectedIndex] = picked
            NameButtonAfter(PickedName())
        end
        ImGui.SameLine()
        if ImGui.Button("Add as New", 120, 24) and picked ~= nil then
            InsertLine(picked)
            NameButtonAfter(PickedName())
        end
    elseif ImGui.Button("Add to Button", 120, 24) and picked ~= nil then
        InsertLine(picked)
        NameButtonAfter(PickedName())
    end

    if isDisabled then ImGui.EndDisabled() end

    ImGui.SameLine()
    ImGui.AlignTextToFramePadding()
    if picked ~= nil then
        ImGui.TextDisabled(picked)
    else
        ImGui.TextColored(1, 0.8, 0.2, 1, reason or "Select a command")
    end

    local docs = PickedDocs()
    if docs ~= nil then
        local width, height = ImGui.GetContentRegionAvail()
        local childFlags = bit32.bor(ImGuiChildFlags.Border)
        if ImGui.BeginChild("actionDocs", width, math.max(60, height - 44), childFlags) then
            for _, line in ipairs(docs:GetLines()) do
                ImGui.TextWrapped(line)
            end
        end
        ImGui.EndChild()
    end
end

---Draw the editor window, if a button is being edited. Called from the hotbars render
---callback so it lives on the same ImGui pass as the bars it edits.
function HotbarButtonEditor.Draw()
    local edit = HotbarButtonEditor._.edit
    if edit == nil then return end

    -- the bar or the button can be removed from under us by another window's context menu
    local barIndex = TableUtils.ArrayIndexOf(HotbarConfig.GetBars(), edit.bar)
    local buttonIndex = TableUtils.ArrayIndexOf(edit.bar.buttons, edit.button)
    if barIndex < 1 or buttonIndex < 1 then
        HotbarButtonEditor.Close()
        return
    end
    edit.index = buttonIndex

    ImGui.SetNextWindowSize(520, 520, ImGuiCond.FirstUseEver)
    local open, show = ImGui.Begin("Edit Hotbar Button###cabbyHotbarButtonEditor", true)

    -- the title bar's close box clears `open` while the window is still being drawn this
    -- frame, so the working copy is dropped after the draw, not out from under it
    if show then
        ImGui.TextDisabled(edit.bar.name .. "  -  Button " .. tostring(edit.index))

        ImGui.SetNextItemWidth(200)
        local label, labelChanged = ImGui.InputText("Label", edit.label)
        if labelChanged then
            edit.label = label
        end

        DrawCommandLines()
        DrawActionPicker()

        ImGui.Separator()
        if ImGui.Button("Save", 90, 24) then
            Save()
        end
        ImGui.SameLine()
        if ImGui.Button("Cancel", 90, 24) then
            HotbarButtonEditor.Close()
        end
    end
    ImGui.End()

    if not open then
        HotbarButtonEditor.Close()
    end
end

return HotbarButtonEditor
