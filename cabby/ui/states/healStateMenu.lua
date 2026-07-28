---@diagnostic disable: undefined-field
local AAs = require("cabby.actions.aas")
local Action = require("cabby.actions.action")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local CommonUI = require("cabby.ui.commonUI")
local HealStateConfig = require("cabby.configs.healStateConfig")
local Items = require("cabby.actions.items")
local Roles = require("cabby.roles")
local Spells = require("cabby.actions.spells")

local HealStateMenu = {}

local scopeOrder = {
    HealStateConfig.scopes.Any,
    HealStateConfig.scopes.Tank,
    HealStateConfig.scopes.Self,
    HealStateConfig.scopes.Others
}

---How much room the per-slot heal controls need under the action row.
local extrasHeight = 26

---@param liveAction Action
---@return boolean isGroupHeal whether this slot's spell heals the group rather than a target
local function IsGroupHeal(liveAction)
    local action = Action.GetActionType(liveAction)
    return action ~= nil and action.Subject ~= nil and not action:Subject():NeedsTarget()
end

---The two things that make a heal slot a *heal* slot, drawn under the action itself: who it is
---for, and how hurt they have to be.
---@param liveAction Action
local function DrawHealFields(liveAction)
    ImGui.SetNextItemWidth(90)
    local threshold, thresholdChanged = ImGui.DragInt("##threshold", HealStateConfig.GetThreshold(liveAction), 1, 1, 100)
    if thresholdChanged then
        HealStateConfig.SetThreshold(liveAction, threshold)
    end
    ImGui.SameLine()
    ImGui.Text("% and below")

    ImGui.SameLine()
    ImGui.SetNextItemWidth(110)
    local scope = HealStateConfig.GetScope(liveAction)
    if ImGui.BeginCombo("##scope", HealStateConfig.GetScopeDisplay(scope)) then
        for _, known in ipairs(scopeOrder) do
            local _, pressed = ImGui.Selectable(known.display, scope == known.value)
            if pressed then
                HealStateConfig.SetScope(liveAction, known.value)
            end
        end
        ImGui.EndCombo()
    end

    if IsGroupHeal(liveAction) then
        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local groupMin, groupMinChanged = ImGui.DragInt("##groupmin", HealStateConfig.GetGroupMin(liveAction), 1, 1, 6)
        if groupMinChanged then
            HealStateConfig.SetGroupMin(liveAction, groupMin)
        end
        ImGui.SameLine()
        ImGui.Text("hurt")
        ImGui.SameLine()
        CommonUI.HelpMarker("This heal covers the whole group, so it is cast when at least this many of the people being watched are at or below the health above. Group heals are considered before single heals, unless someone is already below the emergency point.")
    end
end

---@param healState HealState
function HealStateMenu.BuildMenu(healState)
    ImGui.Text("Heal State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", healState.IsEnabled())
    if enabledClicked then
        healState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("healStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(healState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Heal")
        ImGui.TableNextColumn()
        ImGui.Text(healState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("healSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local healGroup, healGroupClicked = ImGui.Checkbox("Heal the group", HealStateConfig.GetHealGroup())
        if healGroupClicked then
            HealStateConfig.SetHealGroup(healGroup)
        end

        ImGui.SameLine()
        local healPets, healPetsClicked = ImGui.Checkbox("Heal my pet", HealStateConfig.GetHealPets())
        if healPetsClicked then
            HealStateConfig.SetHealPets(healPets)
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local emergency, emergencyChanged = ImGui.DragInt("Emergency at %", HealStateConfig.GetEmergencyPct(), 1, 1, 99)
        if emergencyChanged then
            HealStateConfig.SetEmergencyPct(emergency)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Below this, someone is in trouble rather than merely hurt. It does not choose a heal -- the slots below do that -- it decides what is worth throwing away a heal in progress for, and it holds back group heals while somebody is about to die.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    if ImGui.BeginTabBar("Heal Tabs") then
        if ImGui.BeginTabItem("Heals") then
            ImGui.TextDisabled("Tried in order, top to bottom: the first heal that suits the most hurt person wins.")
            ImGui.SameLine()
            CommonUI.HelpMarker("Each row is a heal, the health it is for, and who it is for. A big heal on the tank at 85% goes above a small heal on anyone at 60%; the state walks the list from the top for whoever is worst off. Only memorized spells are used, so keep the ones you rely on on the spell bar.")

            local actions = HealStateConfig.GetActions()
            local availableActions = AvailableActions.new()
            -- what this character can heal with, discovered from the client: beneficial spells,
            -- plus AAs and clickies, which are as often the emergency button as any spell is
            availableActions.spells = Spells.beneficial
            availableActions.aas = AAs.all
            availableActions.items = Items.all

            if ImGui.Button("Add##healAction", 50, 23) then
                actions[#actions+1] = {}
            end

            for index, action in ipairs(actions) do
                if index % 2 == 0 then
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 1)
                else
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.15, 0.15, 0.15, 1)
                end
                ImGui.PushID(action)
                ActionUI.ActionControl(action, actions, availableActions, {
                    height = extrasHeight,
                    draw = DrawHealFields
                })
                ImGui.PopID()
                ImGui.PopStyleColor()
            end

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Watching") then
            local candidates = healState.GetCandidates()
            if #candidates < 1 then
                ImGui.TextDisabled("Nobody yet -- this fills in while the state is running")
            else
                local watchFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner)
                if ImGui.BeginTable("healWatching", 3, watchFlags) then
                    ImGui.TableSetupColumn("Who", ImGuiTableColumnFlags.WidthFixed, 160)
                    ImGui.TableSetupColumn("Health", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Role", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableHeadersRow()

                    for _, candidate in ipairs(candidates) do
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.Text(candidate.name)
                        ImGui.TableNextColumn()
                        ImGui.Text(tostring(math.floor(candidate.pct)) .. "%")
                        ImGui.TableNextColumn()
                        local role = candidate.isSelf and "me" or ""
                        if candidate.isTank then role = "tank" end
                        if candidate.isPet then role = "pet" end
                        ImGui.Text(role)
                    end

                    ImGui.EndTable()
                end
            end

            ImGui.Spacing()
            ImGui.TextDisabled("The tank is whoever holds that role in the group window.")
            local mainTank = Roles.GetMainTank()
            if mainTank == nil then
                ImGui.TextDisabled("Nobody is assigned Main Tank, so tank-scoped heals will not fire.")
            else
                ImGui.TextDisabled("Main Tank: " .. mainTank.name .. (Roles.IsMainTank() and " (me)" or ""))
            end

            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

return HealStateMenu
