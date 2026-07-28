---@diagnostic disable: undefined-field
local AdvLootStateMenu = {}

---@param advLootState AdvLootState
function AdvLootStateMenu.BuildMenu(advLootState)
    ImGui.Text("AdvLoot State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", advLootState.IsEnabled())
    if enabledClicked then
        advLootState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("advLootStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(advLootState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Loot Controller")
        ImGui.TableNextColumn()
        ImGui.Text(advLootState.GetLooterLabel())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Waiting on us")
        ImGui.TableNextColumn()
        ImGui.Text(tostring(advLootState.GetPendingCount()) .. " roll(s)")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Rows showing")
        ImGui.TableNextColumn()
        ImGui.Text(tostring(advLootState.GetShowingCount()))

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.TextWrapped("With somebody else controlling the group's loot (the delegated looter, " ..
        "or the leader), every roll nobody has answered is answered Pass, so the looter alone " ..
        "deals with the items and no roll waits on this character. The looter itself, rolls " ..
        "already answered by hand, and free-for-all loot are all left alone.")
end

return AdvLootStateMenu
