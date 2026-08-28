---@diagnostic disable: undefined-field
local CommonUI = require("cabby.ui.commonUI")

local Roles = require("cabby.roles")

local StandoffStateMenu = {}

---@param standoffState StandoffState
function StandoffStateMenu.BuildMenu(standoffState)
    ImGui.Text("Standoff State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, clicked = ImGui.Checkbox("Enabled", standoffState.IsEnabled())
    if clicked then
        standoffState.SetEnabled(enabled)
    end
    ImGui.SameLine()
    CommonUI.HelpMarker("A rooted mob cannot reach whoever it hates most, so it hits whoever is standing in its reach instead. On the mob the group's main tank is holding, everyone else backs off until they are behind the tank -- straight back, and only for as long as the mob stays in sight. It only ever reaches a character with nothing else to do in the fight -- anything with a job in hand is busy at a band above this one and is never moved -- so a melee character in there swinging is left exactly where it is.")

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("standoffStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(standoffState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Roles")
        ImGui.TableNextColumn()
        ImGui.Text(Roles.Describe())

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Spacing()

    ImGui.Text("Room to keep")
    ImGui.SameLine()
    CommonUI.HelpMarker("Nothing to set: how far out is measured every pass, and it is measured against the tank. Standing further from the mob than the main tank is standing is far enough, because the tank is the body it swings at. The mob's own reach comes into it once, as a gate -- outside it you are not being hit at all, so nothing happens.")

    ImGui.Spacing()
    ImGui.TextWrapped("Only the main tank's own target is looked at, and only while it reads as " ..
        "rooted. Nothing else in the zone moves this character: a rooted add off to the side that " ..
        "nobody is fighting is not a question about who takes a beating, because nobody is taking one.")

    ImGui.Spacing()
    ImGui.TextWrapped("Inside that mob's reach, this character backs off to a step past wherever the " ..
        "tank is standing -- not past the mob's reach, which on something large would walk a healer " ..
        "out of the fight to fix what the tank standing at fourteen had already fixed. Nobody is sent " ..
        "past about seventeen units whatever the mob is. If there is no tank to compare against -- " ..
        "none named, out of zone, or dead -- nothing moves, because there is no comparison to make.")

    ImGui.Spacing()
    ImGui.TextWrapped("The other half of this lives on the Melee State page and is the exact mirror: " ..
        "the main tank measures the other bodies near that same mob and closes inside whichever is " ..
        "nearest (roottank), as far in as zero if that is what it takes, so that the body in reach " ..
        "is the one wearing the armour. Neither half reads the other -- they both read bodies and a " ..
        "mob -- and they cannot fight, because this one only ever moves back and that one only ever " ..
        "moves in.")

    ImGui.Spacing()
    ImGui.TextWrapped("Pets are counted over there but have no half of their own here: a pet holds " ..
        "its melee range on the mob for the whole fight and is not going to walk backwards, and " ..
        "calling it off its target to move it would be undoing an order its owner gave. So the tank " ..
        "closes inside pets too, and further than it would for a person, since a pet is standing " ..
        "closer to start with and nothing is coming the other way to meet it.")

    ImGui.Spacing()
    ImGui.TextWrapped("A mob only counts as rooted while the client is showing its debuffs, which " ..
        "it does for whoever has it targeted -- /cmobs says which mobs read rooted.")
end

return StandoffStateMenu
