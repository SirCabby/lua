local TableUtils = require("utils.TableUtils.TableUtils")

local EditAbilityAction = require("cabby.ui.actions.editAbilityAction")
local EditAction = require("cabby.ui.actions.editAction")

---@class ActionUI
local ActionUI = {
    _ = {
        actions = {} -- { liveaction = editAction }
    }
}

local actionTypes = {
    [EditAction.actionType] =           "<Select Type>",
    [EditAction.actionType.."1"] =      "AA",
    [EditAbilityAction.actionType] =    "Ability",
    [EditAction.actionType.."2"] =      "Combat Ability",
    [EditAction.actionType.."3"] =      "Discipline",
    [EditAction.actionType.."4"] =      "Item Click",
    [EditAction.actionType.."5"] =      "Spell"
}

local orderedActionTypes = {
    EditAction.actionType,
    EditAction.actionType.."1",
    EditAbilityAction.actionType,
    EditAction.actionType.."2",
    EditAction.actionType.."3",
    EditAction.actionType.."4",
    EditAction.actionType.."5"
}

---@param expectedActionType string
---@param action EditAction
---@return EditAction
local function GetUpdatedActionType(expectedActionType, action)
    local updatedAction = action

    if action.actionType ~= expectedActionType then
        if expectedActionType == EditAbilityAction.actionType then
            updatedAction = action:SwitchType(EditAbilityAction)
        else
            updatedAction = action:SwitchType(EditAction)
            updatedAction.editing = true
        end
    end

    return updatedAction
end

---@param liveAction table
---@return EditAction editAction
local function GetEditAction(liveAction)
    local result = ActionUI._.actions[liveAction]
    if result == nil then
        result = GetUpdatedActionType(liveAction.actionType, EditAction.new(liveAction))
        ActionUI._.actions[liveAction] = result
    end
    return result
end

---@param liveAction EditAction
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
        height = 64
    end

    local childFlags = bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.AutoResizeX)
    if ImGui.BeginChild("actionChild" .. tostring(actionIndex), math.max(width, 532), height, childFlags) then
        local isValid = true
        if editAction.editing or editAction.actionType == EditAction.actionType or editAction.name == "" or editAction.name == "none" then
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
        ImGui.PushItemWidth(130)
        if ImGui.BeginCombo("##type" .. actionIndex, actionTypes[editAction.actionType]) then
            for _, actionType in ipairs(orderedActionTypes) do
                local typeActions = {}
                if actionType == EditAbilityAction.actionType then
                    typeActions = availableActions.abilities
                end

                if #typeActions > 0 or actionType == EditAction.actionType then
                    local _, pressed = ImGui.Selectable(actionTypes[actionType], editAction.actionType == actionType)
                    if pressed then
                        if editAction.actionType ~= actionType then
                            editAction = GetUpdatedActionType(actionType, editAction)
                            editAction.editing = true
                            editAction.name = nil
                            ActionUI._.actions[editAction.liveAction] = editAction
                        end
                    end
                end
            end
            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()
        if not editAction.editing then
            ImGui.EndDisabled()
        end

        local hasNoActions = false
        if not editAction.editing or editAction.actionType == EditAction.actionType then
            ImGui.BeginDisabled()
            hasNoActions = true
        end
        ImGui.SameLine()
        ImGui.PushItemWidth(200)
        if ImGui.BeginCombo("##name" .. actionIndex, editAction.name) then
            local actionChoices = {}
            if editAction.actionType == EditAbilityAction.actionType then
                actionChoices = availableActions.abilities
            end

            for _, action in ipairs(actionChoices) do
                ---@type Action
                action = action
                local _, pressed = ImGui.Selectable(action:Name(), editAction.name == action:Name())
                if pressed then
                    editAction.name = action:Name()
                end
            end

            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()
        if hasNoActions then
            ImGui.EndDisabled()
        end

        if editAction.editing then
            ImGui.SameLine(math.max(width - 89, 443))
            if ImGui.Button("Cancel", 50, 22) then
                editAction:CancelEdit()
                if editAction.actionType == EditAction.actionType then
                    ActionUI._.actions[editAction] = nil
                    table.remove(actions, actionIndex)
                    Global.configStore:SaveConfig()
                end
            end
        else
            ImGui.SameLine(math.max(width - 89, 443))
            if ImGui.Button("Edit", 50, 22) then
                editAction.editing = true
            end
        end

        ImGui.SameLine(math.max(width - 32, 500))
        if ImGui.Button("X", 24, 22) then
            ActionUI._.actions[editAction] = nil
            table.remove(actions, actionIndex)
            Global.configStore:SaveConfig()
        end

        ---- EDITING ----
        if editAction.editing then
            ImGui.Text("")
            ImGui.SameLine(math.max(width - 89, 443))
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
        end
    end
    ImGui.EndChild()

    if editMode then
        ImGui.PopStyleColor()
    end
end

return ActionUI
