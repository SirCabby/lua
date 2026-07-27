---@diagnostic disable: undefined-field
local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local BuffStateConfig = require("cabby.configs.buffStateConfig")
local Classes = require("cabby.classes.classes")
local CommonUI = require("cabby.ui.commonUI")
local Items = require("cabby.actions.items")
local Spells = require("cabby.actions.spells")

local BuffStateMenu = {}

local scopeOrder = {
    BuffStateConfig.scopes.Any,
    BuffStateConfig.scopes.Self,
    BuffStateConfig.scopes.Others
}

---How much room the per-slot buff controls need under the action row.
local extrasHeight = 28

---Classes per row in the class picker: four fits the popup without wrapping the labels, and the
---list is written in fours (plate, melee, hybrid, priest, caster).
local classesPerRow = 4

---@param ms number
---@return string text a duration a person would say out loud
local function DescribeDuration(ms)
    local minutes = math.floor(ms / 60000)
    if minutes < 1 then return tostring(math.floor(ms / 1000)) .. "s" end
    if minutes < 60 then return tostring(minutes) .. "m" end
    return tostring(math.floor(minutes / 60)) .. "h" .. tostring(minutes % 60) .. "m"
end

---The class list, as a button that opens a picker. Empty means everybody, which is both the
---default and the right answer for most buffs -- naming classes is for the ones where casting on
---the wrong half of the group is a wasted gem timer.
---@param liveAction Action
local function DrawClassPicker(liveAction)
    if ImGui.Button(BuffStateConfig.DescribeClasses(liveAction) .. "##classes", 200, 21) then
        ImGui.OpenPopup("classPicker")
    end

    if ImGui.BeginPopup("classPicker") then
        for index, shortName in ipairs(Classes.shortNames) do
            if index % classesPerRow ~= 1 then
                ImGui.SameLine()
            end
            local allowed = BuffStateConfig.IsClassAllowed(liveAction, shortName)
            -- with no filter every class reads as allowed, which is the truth: this is a list of
            -- who it will be cast on, not a list of what was clicked
            local _, pressed = ImGui.Checkbox(shortName, allowed)
            if pressed then
                BuffStateConfig.ToggleClass(liveAction, shortName)
            end
        end

        ImGui.Separator()
        if ImGui.Button("Any class", 90, 21) then
            BuffStateConfig.ClearClasses(liveAction)
        end

        ImGui.EndPopup()
    end
end

---What makes a buff slot a *buff* slot, drawn under the action itself: who it is for, and which
---classes are worth spending it on. What the spell can be aimed at, and how long it lasts, are
---the spell's own business and are only reported.
---@param liveAction Action
---@param buffState BuffState
local function DrawBuffFields(liveAction, buffState)
    local facts = buffState.DescribeSlot(liveAction)

    if facts.scoped then
        ImGui.SetNextItemWidth(110)
        local scope = BuffStateConfig.GetScope(liveAction)
        if ImGui.BeginCombo("##scope", BuffStateConfig.GetScopeDisplay(scope)) then
            for _, known in ipairs(scopeOrder) do
                local _, pressed = ImGui.Selectable(known.display, scope == known.value)
                if pressed then
                    BuffStateConfig.SetScope(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end

        ImGui.SameLine()
        DrawClassPicker(liveAction)
        ImGui.SameLine()
    end

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end

    ImGui.TextDisabled(facts.aimText .. ", lasts " .. DescribeDuration(facts.lastsMs))
end

---@param buffState BuffState
function BuffStateMenu.BuildMenu(buffState)
    ImGui.Text("Buff State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", buffState.IsEnabled())
    if enabledClicked then
        buffState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("buffStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(buffState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Buff")
        ImGui.TableNextColumn()
        ImGui.Text(buffState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("buffSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local buffGroup, buffGroupClicked = ImGui.Checkbox("Buff the group", BuffStateConfig.GetBuffGroup())
        if buffGroupClicked then
            BuffStateConfig.SetBuffGroup(buffGroup)
        end

        ImGui.SameLine()
        local buffPets, buffPetsClicked = ImGui.Checkbox("Buff my pet", BuffStateConfig.GetBuffPets())
        if buffPetsClicked then
            BuffStateConfig.SetBuffPets(buffPets)
        end

        ImGui.SameLine()
        local inCombat, inCombatClicked = ImGui.Checkbox("Buff during combat", BuffStateConfig.GetInCombat())
        if inCombatClicked then
            BuffStateConfig.SetInCombat(inCombat)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Off, nothing is buffed while this character is fighting, and a buff already in the air is called off when a fight starts.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(70)
        local rebuff, rebuffChanged = ImGui.DragInt("Rebuff under (s)", BuffStateConfig.GetRebuffSecs(), 5, 0, 3600)
        if rebuffChanged then
            BuffStateConfig.SetRebuffSecs(rebuff)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("A buff is recast once this much time or less is left on it. 0 waits for it to fade completely.")

        ImGui.SameLine()
        -- nothing here talks to the client, so it is safe from a render callback
        if ImGui.Button("Check everybody now", 150, 21) then
            buffState.Recheck()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Forgets what was worked out about who has what, so the next pass looks at every buff on everybody again. Worth pressing after somebody has been dispelled or has zoned back in.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    if ImGui.BeginTabBar("Buff Tabs") then
        if ImGui.BeginTabItem("Buffs") then
            ImGui.TextDisabled("Cast in order, top to bottom: the first buff somebody is missing is the one that goes out.")
            ImGui.SameLine()
            CommonUI.HelpMarker("Each row is a buff, who it is for, and which classes are worth spending it on. Whether it lands on the group, on a pet or on one person at a time is the spell's own business and is shown rather than set. Only memorized spells are used, so keep the ones you rely on on the spell bar.")

            local actions = BuffStateConfig.GetActions()
            local availableActions = AvailableActions.new()
            -- what this character can buff with: the beneficial half of the book, plus the AAs and
            -- clickies that hold as many buffs as the book does
            availableActions.spells = Spells.beneficial
            availableActions.aas = AAs.all
            availableActions.items = Items.all

            if ImGui.Button("Add##buffAction", 50, 23) then
                actions[#actions+1] = {}
            end

            local extras = {
                height = extrasHeight,
                draw = function(liveAction) DrawBuffFields(liveAction, buffState) end
            }

            for index, action in ipairs(actions) do
                if index % 2 == 0 then
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 1)
                else
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.15, 0.15, 0.15, 1)
                end
                ImGui.PushID(action)
                ActionUI.ActionControl(action, actions, availableActions, extras)
                ImGui.PopID()
                ImGui.PopStyleColor()
            end

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Watching") then
            local candidates = buffState.GetCandidates()
            if #candidates < 1 then
                ImGui.TextDisabled("Nobody yet -- this fills in while the state is running")
            else
                local watchFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner)
                if ImGui.BeginTable("buffWatching", 3, watchFlags) then
                    ImGui.TableSetupColumn("Who", ImGuiTableColumnFlags.WidthFixed, 160)
                    ImGui.TableSetupColumn("Class", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Reached by", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableHeadersRow()

                    for _, candidate in ipairs(candidates) do
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.Text(candidate.name)
                        ImGui.TableNextColumn()
                        ImGui.Text(candidate.class ~= "" and candidate.class or "?")
                        ImGui.TableNextColumn()
                        local reach = candidate.inGroup and "group buffs and single" or "single buffs only"
                        if candidate.isPet then reach = "pet buffs" end
                        ImGui.Text(reach)
                    end

                    ImGui.EndTable()
                end
            end

            ImGui.Spacing()
            ImGui.TextDisabled("/cbuff says how many buffs each of them is missing.")

            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

return BuffStateMenu
