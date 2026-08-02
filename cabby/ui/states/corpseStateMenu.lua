---@diagnostic disable: undefined-field
local CorpseStateMenu = {}

---@param corpseState CorpseState
function CorpseStateMenu.BuildMenu(corpseState)
    ImGui.Text("Corpse State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", corpseState.IsEnabled())
    if enabledClicked then
        corpseState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("corpseStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(corpseState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Asked for by")
        ImGui.TableNextColumn()
        ImGui.Text(corpseState.GetAskedBy() or "nobody")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Looted so far")
        ImGui.TableNextColumn()
        ImGui.Text(tostring(corpseState.GetLootedCount()) .. " item(s)")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    -- The same order the `lootcorpse` command carries, for the character being played by hand.
    -- Both buttons only move this state's own bookkeeping around, which is what makes them safe to
    -- press from a render callback -- every game command looting takes is issued from `Go()`.
    local isLooting = corpseState.IsLooting()

    if isLooting then ImGui.BeginDisabled(true) end
    if ImGui.Button("Loot Corpse", 100, 23) then
        local refusal = corpseState.StartLooting()
        if refusal ~= nil then
            print("(lootcorpse) " .. refusal)
        end
    end
    if isLooting then ImGui.EndDisabled() end

    ImGui.SameLine()
    if not isLooting then ImGui.BeginDisabled(true) end
    if ImGui.Button("Call It Off", 100, 23) then
        corpseState.CancelOrder()
    end
    if not isLooting then ImGui.EndDisabled() end

    ImGui.TextWrapped("Told to (lootcorpse), this character empties every corpse of its own lying " ..
        "within " .. tostring(corpseState.GetRadius()) .. " of it, one after another, and is then " ..
        "done -- it walks nowhere, so get the group back to the corpses first, though each corpse " ..
        "is pulled to its feet with /corpse before it is opened. A loot window open " ..
        "on somebody else's corpse is left alone; one already open on a corpse of ours is taken " ..
        "over. Anything that will not come off the corpse (bags full, a lore item already " ..
        "carried) is left there and reported.")
end

return CorpseStateMenu
