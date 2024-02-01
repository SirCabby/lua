local TableUtils = require("utils.TableUtils.TableUtils")

local AbilityAction = require("cabby.actions.abilityAction")
local BaseAction = require("cabby.actions.baseAction")

---@class CommonUI
local CommonUI = {
    _ = {
        actions = {} -- { liveaction = baseAction }
    }
}

CommonUI.HelpMarker = function(message)
    ImGui.TextDisabled("(?)");
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip();
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 35.0);
        ImGui.TextUnformatted(message);
        ImGui.PopTextWrapPos();
        ImGui.EndTooltip();
    end
end

local actionTypes = {
    [BaseAction.actionType] =       "<Select Type>",
    [BaseAction.actionType.."1"] =  "AA",
    [AbilityAction.actionType] =    "Ability",
    [BaseAction.actionType.."2"] =  "Combat Ability",
    [BaseAction.actionType.."3"] =  "Discipline",
    [BaseAction.actionType.."4"] =  "Item Click",
    [BaseAction.actionType.."5"] =  "Spell"
}

local orderedActionTypes = {
    BaseAction.actionType,
    BaseAction.actionType.."1",
    AbilityAction.actionType,
    BaseAction.actionType.."2",
    BaseAction.actionType.."3",
    BaseAction.actionType.."4",
    BaseAction.actionType.."5"
}

---@param liveAction table
---@return BaseAction baseAction
local function GetBaseAction(liveAction)
    local result = CommonUI._.actions[liveAction]
    if result == nil then
        result = BaseAction.new(liveAction)
        CommonUI._.actions[liveAction] = result
        result.actionType = "none"
    end
    return result
end

---@param liveAction BaseAction
---@param actions table
CommonUI.ActionControl = function(liveAction, actions)
    local width = ImGui.GetContentRegionAvail()
    local baseAction = GetBaseAction(liveAction)
    local actionIndex = TableUtils.ArrayIndexOf(actions, liveAction)

    local childFlags = bit32.bor(ImGuiChildFlags.Border, ImGuiChildFlags.AutoResizeX)
    if ImGui.BeginChild("actionChild" .. tostring(actionIndex), math.max(width, 532), 38, childFlags) then
        ImGui.BeginDisabled()
        local enabled, pressed = ImGui.Checkbox("Enabled", baseAction.editing)
        if pressed then
            baseAction.editing = enabled
        end
        ImGui.EndDisabled()

        if not baseAction.editing then
            ImGui.BeginDisabled()
        end
        ImGui.SameLine()
        ImGui.PushItemWidth(130)
        if ImGui.BeginCombo("##type" .. actionIndex, actionTypes[baseAction.actionType]) then
            for _, actionType in ipairs(orderedActionTypes) do
                local _, pressed = ImGui.Selectable(actionTypes[actionType], baseAction.actionType == actionType)
                if pressed then
                    if baseAction.actionType ~= actionType then
                        if actionType == AbilityAction.actionType then
                            baseAction = baseAction:SwitchType(AbilityAction)
                        else
                            baseAction = baseAction:SwitchType(BaseAction)
                        end
                        baseAction.editing = true
                        CommonUI._.actions[baseAction.liveAction] = baseAction
                    end
                end
            end
            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()
        if not baseAction.editing then
            ImGui.EndDisabled()
        end

        ImGui.BeginDisabled()
        ImGui.SameLine()
        ImGui.PushItemWidth(200)
        if ImGui.BeginCombo("##name" .. actionIndex, baseAction.name) then
            ImGui.EndCombo()
        end
        ImGui.PopItemWidth()
        ImGui.EndDisabled()

        if baseAction.editing then
            ImGui.SameLine(math.max(width - 89, 443))
            if ImGui.Button("Cancel", 50, 22) then
                baseAction:CancelEdit()
            end
        else
            ImGui.SameLine(math.max(width - 89, 443))
            if ImGui.Button("Edit", 50, 22) then
                baseAction.editing = true
            end
        end

        ImGui.SameLine(math.max(width - 32, 500))
        if ImGui.Button("X", 24, 22) then
            -- TODO remove from list
            CommonUI._.actions[baseAction] = nil
            table.remove(actions, actionIndex)
            Global.configStore:SaveConfig()
        end
    end
    ImGui.EndChild()
end

return CommonUI
