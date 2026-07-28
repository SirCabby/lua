---@diagnostic disable: undefined-field
local CommonUI = require("cabby.ui.commonUI")
local RestStateConfig = require("cabby.configs.restStateConfig")

local RestStateMenu = {}

---@param restState RestState
function RestStateMenu.BuildMenu(restState)
    ImGui.Text("Rest State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", restState.IsEnabled())
    if enabledClicked then
        restState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("restStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(restState.Describe())

        -- only the pools this character actually has: a warrior has no mana row to read
        for _, pool in ipairs(restState.GetPools()) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text(pool.label:gsub("^%l", string.upper))
            ImGui.TableNextColumn()
            ImGui.Text(tostring(math.floor(pool.pct)) .. "%")
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("restSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local sitBelow, sitChanged = ImGui.DragInt("Sit below %", RestStateConfig.GetSitBelowPct(), 1, 1, 100)
        if sitChanged then
            RestStateConfig.SetSitBelowPct(sitBelow)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Sit down once health, mana or stamina drops below this. 100 sits for anything short of full.")

        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local standAt, standChanged = ImGui.DragInt("Stand at %", RestStateConfig.GetStandAtPct(), 1, 1, 100)
        if standChanged then
            RestStateConfig.SetStandAtPct(standAt)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Get back up once every one of them is at or above this. It is never allowed below the sit point, which would stand the character up on the pass after it sat down.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local inCombat, inCombatClicked = ImGui.Checkbox("Rest during a fight", RestStateConfig.GetInCombat())
        if inCombatClicked then
            RestStateConfig.SetInCombat(inCombat)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Sit while there is a fight going on that this character has not joined. Being engaged stops it whatever this is set to.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()
end

return RestStateMenu
