---@diagnostic disable: undefined-field
local AAs = require("cabby.actions.aas")
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
    HealStateConfig.scopes.Others,
    HealStateConfig.scopes.Pet
}

---How much room the per-slot heal controls need under the action row.
local extrasHeight = 26

---What makes a heal slot a *heal* slot, drawn under the action itself: how hurt they have to be,
---and who it is for. What the heal can be aimed at is the spell's own business and is only
---reported -- along with the reason a slot will never fire, when there is one.
---@param liveAction Action what the controls here write to
---@param shownAction Action what the row is currently holding -- the staged pick while it is being
---edited -- which is what the spell is read from
---@param healState HealState
local function DrawHealFields(liveAction, shownAction, healState)
    local facts = healState.DescribeSlot(shownAction or liveAction)

    ImGui.SetNextItemWidth(90)
    local threshold, thresholdChanged = ImGui.DragInt("##threshold", HealStateConfig.GetThreshold(liveAction), 1, 1, 100)
    if thresholdChanged then
        HealStateConfig.SetThreshold(liveAction, threshold)
    end
    ImGui.SameLine()
    ImGui.Text("% and below")

    -- only the scopes this slot's spell can actually be given. A spell that lands on one kind of
    -- person has answered the question already, so the dial shows that answer and is not offered
    -- for editing -- rather than being hidden, which reads as "this heal is for nobody"
    local choices = {}
    for _, known in ipairs(scopeOrder) do
        if facts.scopes[known.value] then choices[#choices+1] = known end
    end

    if #choices > 0 then
        local decided = #choices == 1
        local scope = decided and choices[1].value or HealStateConfig.GetScope(liveAction)

        ImGui.SameLine()
        ImGui.SetNextItemWidth(110)
        if decided then ImGui.BeginDisabled() end
        if ImGui.BeginCombo("##scope", HealStateConfig.GetScopeDisplay(scope)) then
            for _, known in ipairs(choices) do
                local _, pressed = ImGui.Selectable(known.display, scope == known.value)
                if pressed then
                    HealStateConfig.SetScope(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        if decided then ImGui.EndDisabled() end
    end

    if facts.isGroup then
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

    ImGui.SameLine()
    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end
    ImGui.TextDisabled(facts.aimText)
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

        local healGroup, healGroupClicked = ImGui.Checkbox("Watch group members", HealStateConfig.GetHealGroup())
        if healGroupClicked then
            HealStateConfig.SetHealGroup(healGroup)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Whether the rest of the group is somebody this character heals at all. On, everyone in the group window is watched and can be chosen for a heal; off, the only people watched are me and my pet, and a group-mate at 10% is left to somebody else. It is not about group heal *spells* -- one of those is chosen because enough of the people being watched are hurt, so switching this off shrinks what it is counting rather than stopping it. The Watching tab is the answer to what this is currently doing.")

        ImGui.SameLine()
        local healPets, healPetsClicked = ImGui.Checkbox("Watch my pet", HealStateConfig.GetHealPets())
        if healPetsClicked then
            HealStateConfig.SetHealPets(healPets)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Off by default: a pet is cheaper to summon than the mana spent keeping it up. A pet class that means to keep its own pet up turns this on -- while it is off the pet is not watched at all, so even a heal that can only land on a pet has nothing to fire for.")

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
            -- what this character can heal with, discovered from the client: the spells the book
            -- files as heals or as invulnerabilities, plus AAs and clickies, which are as often
            -- the emergency button as any spell is. The rest of the beneficial half is a switch
            -- away in the picker, for a heal the game filed somewhere unexpected.
            availableActions.spells = Spells.heals
            availableActions.allSpells = Spells.beneficial
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
                    draw = function(liveAction, shownAction) DrawHealFields(liveAction, shownAction, healState) end
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
