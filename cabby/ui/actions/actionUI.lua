local mq = require("mq")

local TableUtils = require("utils.TableUtils.TableUtils")

local Action = require("cabby.actions.action")
local Actions = require("cabby.actions.actions")
local ActionType = require("cabby.actions.actionType")
local CommonUI = require("cabby.ui.commonUI")
local EditAction = require("cabby.ui.actions.editAction")

---@class ActionUI
local ActionUI = {
    _ = {
        actions = {} -- { liveaction = editAction }
    }
}

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
ActionUI.ActionControl = function(liveAction, actions, availableActions)
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

    local childFlags = bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.AutoResizeX)
    if ImGui.BeginChild("actionChild" .. tostring(actionIndex), 623, height, childFlags) then
        local isValid = true
        if editAction.editing or editAction.actionType == ActionType.Edit or editAction.name == "" or editAction.name == "none" then
            isValid = false
            ImGui.BeginDisabled()
        end
        local enabled, pressed = ImGui.Checkbox("Enabled", editAction.enabled)
        if pressed then
            editAction.enabled = enabled
            Global.configStore:SaveConfig()
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
                    typeActions = availableActions.spells or typeActions
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
        if ImGui.BeginCombo("##name" .. actionIndex, editAction.name) then
            local actionChoices = {}
            if editAction.actionType == ActionType.Ability then
                actionChoices = availableActions.abilities
            elseif editAction.actionType == ActionType.Discipline then
                actionChoices = availableActions.discs
            end

            for _, action in ipairs(actionChoices) do
                ---@type ActionType
                action = action

                local name = action:Name()

                local _, pressed = ImGui.Selectable(name, editAction.name == action:Name())
                if pressed then
                    editAction.name = action:Name()
                end
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
            table.remove(actions, actionIndex)
            Global.configStore:SaveConfig()
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
