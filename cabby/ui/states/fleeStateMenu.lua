---@diagnostic disable: undefined-field
local CommonUI = require("cabby.ui.commonUI")

local FleeStateMenu = {}

---@param fleeState FleeState
function FleeStateMenu.BuildMenu(fleeState)
    ImGui.Text("Flee State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    -- the switch and the mode are the same thing here, so the checkbox says what it does rather
    -- than saying "Enabled" like the pages whose state has a job of its own
    local fleeing, clicked = ImGui.Checkbox("Fleeing", fleeState.IsEnabled())
    if clicked then
        fleeState.SetEnabled(fleeing)
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("Travel mode: follow, and nothing else. No fighting back, no healing, no buffing, no resting -- so a long run does not stop for every add on the way. It needs a follow order to be worth anything; give a (followme) first.")

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("fleeStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(fleeState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Still running")
        ImGui.TableNextColumn()
        ImGui.Text(fleeState.IsEnabled() and "Follow only" or "The whole chain")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.Spacing()
    ImGui.TextWrapped("While this is on, every state below the flee band is held back and only " ..
        "Follow gets a turn -- which covers anchoring and clicking through zone lines, since " ..
        "those are the same state. Orders, the menu and hotbar buttons keep working, so `flee " ..
        "off` is always reachable.")
end

return FleeStateMenu
