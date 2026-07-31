local mq = require("mq")

local TableUtils = require("utils.TableUtils.TableUtils")

local Action = require("cabby.actions.action")
local Actions = require("cabby.actions.actions")
local ActionType = require("cabby.actions.actionType")
local CommonUI = require("cabby.ui.commonUI")
local EditAction = require("cabby.ui.actions.editAction")
local Spells = require("cabby.actions.spells")

---@class ActionUI
local ActionUI = {
    _ = {
        actions = {}, -- { liveaction = editAction }
        filters = {}, -- { liveaction = <what was typed into that picker's filter box> }
        showAll = {}  -- { liveaction = <that picker is showing the unnarrowed spell list> }
    }
}

---A spellbook runs to hundreds of entries, so past this many the picker grows a filter box.
---Skills and disciplines never reach it and are left alone.
local filterThreshold = 12

local actionTypes = {
    [ActionType.Edit] =           "<Select Type>",
    [ActionType.AA] =             "AA",
    [ActionType.Ability] =        "Ability",
    [ActionType.Discipline] =     "Discipline",
    [ActionType.Item] =           "Item Click",
    [ActionType.Spell] =          "Spell"
}

local orderedActionTypes = {
    ActionType.Edit,
    ActionType.AA,
    ActionType.Ability,
    ActionType.Discipline,
    ActionType.Item,
    ActionType.Spell
}

local orderedValueTypes = {
    Action.valueTypes.Percent,
    Action.valueTypes.Raw,
    Action.valueTypes.Minimum
}

---What this type can be picked from. Every one of these lists is discovered from the client
---(`cabby.character`), so it answers "what does this character have" at the moment the combo is
---opened rather than what it had at login.
---@param actionType string
---@param availableActions AvailableActions
---@param showAll? boolean offer the wider spell list rather than the state's narrowed one
---@return table choices array of ActionType
local function ChoicesFor(actionType, availableActions, showAll)
    if actionType == ActionType.Ability then return availableActions.abilities or {} end
    if actionType == ActionType.Discipline then return availableActions.discs or {} end
    if actionType == ActionType.Spell then
        if showAll then return availableActions.allSpells or availableActions.spells or {} end
        return availableActions.spells or {}
    end
    if actionType == ActionType.AA then return availableActions.aas or {} end
    if actionType == ActionType.Item then return availableActions.items or {} end
    return {}
end

---Does this picker have a wider list to offer than the one it is showing?
---@param actionType string
---@param availableActions AvailableActions
---@return boolean
local function HasWiderList(actionType, availableActions)
    if actionType ~= ActionType.Spell then return false end
    return #(availableActions.allSpells or {}) > #(availableActions.spells or {})
end

---What a picked action is called in the list.
---
---A spell that is not on the spell bar is worth saying out loud: an action slot only fires what
---is memorized, so a slot holding an unmemorized spell is configured correctly and will still
---never go off, which is otherwise a silent puzzle.
---
---What the book files a spell under is worth saying out loud too, but only once the narrowing is
---off: that is the moment somebody is looking for a spell the categories did not offer them, and
---the heading it turned out to have is the answer to why.
---@param action ActionType
---@param category? string
---@return string label
local function ChoiceLabel(action, category)
    local label = action:Name()
    if action.IsMemorized ~= nil and not action:IsMemorized() then
        label = label .. "  (not memorized)"
    end
    if category ~= nil and category ~= "" then
        label = label .. "  -- " .. category
    end
    return label
end

---@param liveAction Action
---@return EditAction editAction
local function GetEditAction(liveAction)
    local result = ActionUI._.actions[liveAction]
    if result == nil then
        result = EditAction.new(liveAction)
        ActionUI._.actions[liveAction] = result
    end
    return result
end

---@param value string
---@return string display
local function GetUsageValueTypeDisplayFromValue(value)
    for _, valueType in pairs(Action.valueTypes) do
        if valueType.value == value then
            return valueType.display
        end
    end

    return Action.valueTypes.Minimum.display
end

---@param liveAction Action
---@param actions table
---@param availableActions AvailableActions
---@param extras? table `{ height = number, draw = fun(liveAction, shownAction) }` -- controls
---belonging to the state that owns this list rather than to the action itself. A heal slot's
---threshold is one: which heal this is, is an action; who it is for and how hurt they have to be,
---is healing. Like the Enabled switch, and unlike everything staged behind Save, these write
---straight to the live action -- they are dials you reach for while watching a fight go badly.
---
---`shownAction` is what the row *currently holds*: the staged edit while the row is being edited,
---the live action otherwise. Anything a control reads off the chosen spell -- who a heal can be
---aimed at, whether it lasts -- reads it from there, so picking a spell answers on the spot
---instead of after Save. Anything a control *writes* still writes to `liveAction`.
ActionUI.ActionControl = function(liveAction, actions, availableActions, extras)
    local width = ImGui.GetContentRegionAvail()
    local editAction = GetEditAction(liveAction)
    local actionIndex = TableUtils.ArrayIndexOf(actions, liveAction)

    local height = 38
    local editMode = editAction.editing
    if editMode then
        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.2, 0.13, 0, 1)
        if editAction.luaEnabled then
            height = 324
        else
            height = 64
        end
    end
    if extras ~= nil then
        height = height + (extras.height or 0)
    end

    local childFlags = bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.AutoResizeX)
    if ImGui.BeginChild("actionChild" .. tostring(actionIndex), 623, height, childFlags) then
        local isValid = true
        if editAction.editing or editAction.actionType == ActionType.Edit or editAction.name == "" or editAction.name == "none" then
            isValid = false
            ImGui.BeginDisabled()
        end
        -- the switch is the only control here that is not staged: it reads and writes the live
        -- action, so it takes effect on the next pulse the way an in-combat switch has to, and so
        -- it shows a flip that came from somewhere else (a hotbar button, a chat order) instead
        -- of a value copied when this row was first drawn
        local enabled, pressed = ImGui.Checkbox("Enabled", Action.IsEnabled(liveAction))
        if pressed then
            Action.SetEnabled(liveAction, enabled)
        end
        if not isValid then
            ImGui.EndDisabled()
        end

        if not editAction.editing then
            ImGui.BeginDisabled()
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(120)
        if ImGui.BeginCombo("##type" .. actionIndex, actionTypes[editAction.actionType]) then
            for _, actionType in ipairs(orderedActionTypes) do
                local typeActions = {}
                if actionType == ActionType.AA then
                    typeActions = availableActions.aas or typeActions
                elseif actionType == ActionType.Ability then
                    typeActions = availableActions.abilities or typeActions
                elseif actionType == ActionType.Discipline then
                    typeActions = availableActions.discs or typeActions
                elseif actionType == ActionType.Item then
                    typeActions = availableActions.items or typeActions
                elseif actionType == ActionType.Spell then
                    -- what the narrowing left is not the question here: this decides whether the
                    -- character has spells to offer at all, and hiding the type over an empty
                    -- category list would put the switch that widens it out of reach
                    typeActions = availableActions.allSpells or typeActions
                    if #typeActions < 1 then typeActions = availableActions.spells or typeActions end
                end

                if #typeActions > 0 or actionType == ActionType.Edit then
                    local _, pressed = ImGui.Selectable(actionTypes[actionType], editAction.actionType == actionType)
                    if pressed then
                        if editAction.actionType ~= actionType then
                            editAction:SwitchType(actionType)
                            editAction.editing = true
                            editAction.name = nil
                            ActionUI._.actions[liveAction] = editAction
                        end
                    end
                end
            end
            ImGui.EndCombo()
        end
        if not editAction.editing then
            ImGui.EndDisabled()
        end

        local hasNoActions = false
        if not editAction.editing or editAction.actionType == ActionType.Edit then
            ImGui.BeginDisabled()
            hasNoActions = true
        end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(200)
        if ImGui.BeginCombo("##name" .. actionIndex, editAction.name or "") then
            -- The narrowing is by the category the game filed a spell under, which is data rather
            -- than a promise: a spell filed somewhere unexpected would otherwise be unreachable
            -- from the menu with no way to tell that was what happened. The switch stays with the
            -- row rather than resetting with the combo, because it is a mode somebody chose.
            local showAll = ActionUI._.showAll[liveAction] or false
            if HasWiderList(editAction.actionType, availableActions) then
                local wanted, pressed = ImGui.Checkbox("Show every spell##showAll" .. actionIndex, showAll)
                if pressed then
                    showAll = wanted
                    ActionUI._.showAll[liveAction] = wanted
                end
                ImGui.SameLine()
                CommonUI.HelpMarker("Off, this offers the spells the game files under headings that suit this list. On, it offers everything of that kind in the book and says what each one is filed under -- which is how to find a spell the headings missed.")
            end

            local actionChoices = ChoicesFor(editAction.actionType, availableActions, showAll)
            local filter = ActionUI._.filters[liveAction] or ""

            if #actionChoices > filterThreshold then
                -- A spellbook is not a list anyone scrolls. The box starts empty and focused
                -- every time the combo opens, so it is a place to type rather than one more
                -- piece of state to remember to clear.
                if ImGui.IsWindowAppearing() then
                    filter = ""
                    ActionUI._.filters[liveAction] = filter
                    ImGui.SetKeyboardFocusHere()
                end

                ImGui.SetNextItemWidth(190)
                local typed, changed = ImGui.InputText("##filter" .. actionIndex, filter)
                if changed then
                    filter = typed
                    ActionUI._.filters[liveAction] = typed
                end
                ImGui.Separator()
            end

            local needle = filter:lower()
            local shown = 0
            for _, action in ipairs(actionChoices) do
                ---@type ActionType
                action = action

                local name = action:Name()
                -- a heading is worth typing at as well as reading: "invuln" should find the
                -- spells filed there without anyone knowing what they are called
                local category = showAll and Spells.CategoryOf(name) or ""
                local matches = needle == "" or name:lower():find(needle, 1, true) ~= nil
                    or (category ~= "" and category:lower():find(needle, 1, true) ~= nil)

                if matches then
                    shown = shown + 1
                    local _, pressed = ImGui.Selectable(ChoiceLabel(action, category), editAction.name == name)
                    if pressed then
                        editAction.name = name
                    end
                end
            end

            if shown < 1 then
                ImGui.TextDisabled(#actionChoices > 0 and "Nothing matches" or "Nothing available")
            end

            ImGui.EndCombo()
        end
        if hasNoActions then
            ImGui.EndDisabled()
        end

        if editAction.editing then
            ImGui.SameLine()
            if ImGui.Button("Cancel", 50, 22) then
                editAction:CancelEdit()
                if editAction.actionType == ActionType.Edit or editAction.actionType == nil then
                    ActionUI._.actions[liveAction] = nil
                    table.remove(actions, actionIndex)
                    Global.configStore:SaveConfig()
                end
            end
        else
            ImGui.SameLine()
            if ImGui.Button("Edit", 50, 22) then
                editAction.editing = true
            end
        end

        local atTop = false
        if actionIndex == 1 then
            atTop = true
            ImGui.BeginDisabled()
        end
        ImGui.SameLine()
        if ImGui.Button("Up", 40, 22) then
            ActionUI._.actions[liveAction] = nil
            table.remove(actions, actionIndex)
            table.insert(actions, actionIndex-1, liveAction)
            Global.configStore:SaveConfig()
        end
        if atTop then
            ImGui.EndDisabled()
        end

        local atBottom = false
        if actionIndex == #actions then
            atBottom = true
            ImGui.BeginDisabled()
        end
        ImGui.SameLine()
        if ImGui.Button("Down", 50, 22) then
            ActionUI._.actions[liveAction] = nil
            table.remove(actions, actionIndex)
            table.insert(actions, actionIndex+1, liveAction)
            Global.configStore:SaveConfig()
        end
        if atBottom then
            ImGui.EndDisabled()
        end

        ImGui.SameLine()
        if ImGui.Button("X", 24, 22) then
            ActionUI._.actions[liveAction] = nil
            ActionUI._.filters[liveAction] = nil
            ActionUI._.showAll[liveAction] = nil
            table.remove(actions, actionIndex)
            Global.configStore:SaveConfig()
        end

        if extras ~= nil and extras.draw ~= nil then
            -- the staged edit while one is open: `editAction` is an action-shaped clone carrying
            -- the type and name the row is showing, so a control reading the chosen spell sees the
            -- pick immediately rather than the one Save last wrote
            extras.draw(liveAction, editAction.editing and editAction or liveAction)
        end

        ---- EDITING ----
        if editAction.editing then
            local action = Actions.Get(editAction.actionType, editAction.name)
            if action ~= nil and action:EndCost() > 0 then
                ImGui.Text("Endurance Threshold")

                ImGui.SameLine()
                ImGui.SetNextItemWidth(100)
                if ImGui.BeginCombo("##threshold" .. tostring(actions), GetUsageValueTypeDisplayFromValue(editAction.end_type)) then
                    for _, valueType in ipairs(orderedValueTypes) do
                        local _, pressed = ImGui.Selectable(valueType.display, editAction.end_type == valueType.value)
                        if pressed then
                            editAction.end_type = valueType.value
                        end
                    end
                    ImGui.EndCombo()
                end

                if editAction.end_type ~= Action.valueTypes.Minimum.value then
                    ImGui.SameLine()
                    ImGui.SetNextItemWidth(40)
                    local min = 0
                    local max = 100
                    if editAction.end_type == Action.valueTypes.Raw.value then
                        min = action:EndCost()
                        max = mq.TLO.Me.MaxEndurance()
                    else
                        min = math.ceil(action:EndCost() / mq.TLO.Me.MaxEndurance())
                    end

                    editAction.end_threshold = math.min(editAction.end_threshold or min, max)
                    editAction.end_threshold = math.max(editAction.end_threshold, min)

                    local result, selected = ImGui.DragInt("##cost" .. tostring(actions), editAction.end_threshold, 1, min, max)
                    if selected then
                        editAction.end_threshold = result
                    end
                end

                ImGui.SameLine()
                CommonUI.HelpMarker("Use this action only when above a certain resource threshold. 'Percent' uses percentage-based thresholds. 'Raw' uses a raw resource value. 'Minimum' assumes the minimum amount required by the action.")
            else
                ImGui.Dummy(0, 0)
            end

            ImGui.SameLine(428)
            local cannotSave = false
            if editAction.name == nil or editAction.name == "" then
                ImGui.BeginDisabled()
                cannotSave = true
            end
            if ImGui.Button("Save", 50, 22) then
                editAction:SaveEdit()
            end
            if cannotSave then
                ImGui.EndDisabled()
            end

            ImGui.SameLine()
            local _, pressed = ImGui.Checkbox("LUA Enabled", editAction.luaEnabled)
            if pressed then
                editAction.luaEnabled = not editAction.luaEnabled
            end
            ImGui.SameLine()
            CommonUI.HelpMarker("Provide a lua expression that results in 'true'. This is evaluated when deciding if an action should be run.")

            if editAction.luaEnabled then
                local inputFlags = bit32.bor(ImGuiInputTextFlags.AllowTabInput)
                local displayText = ""
                if editAction.lua ~= nil and editAction.lua:len() > 0 then
                    displayText = editAction.lua:sub(3, -3)
                end
                local luaText, changed = ImGui.InputTextMultiline("##luaArea" .. actionIndex, displayText, width-16, ImGui.GetTextLineHeight() * 16, inputFlags)
                if changed then
                    editAction.lua = "[[" .. luaText .. "]]"
                end
            end
        end
    end
    ImGui.EndChild()

    if editMode then
        ImGui.PopStyleColor()
    end
end

return ActionUI
