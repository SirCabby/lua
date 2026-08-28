---@diagnostic disable: undefined-field
local mq = require("mq")

local CommonUI = require("cabby.ui.commonUI")
local TradeskillJobConfig = require("cabby.configs.tradeskillJobConfig")

---The Tradeskill job's page.
---
---Two halves, and the line between them is what a run is allowed to change under itself: the top
---is what is happening now and the buttons that start and stop it; the bottom is the setup, which
---is greyed out while a run is going rather than left editable, because pulling a material out of
---the list mid-combine would leave the container holding half a recipe with nothing in the setup
---to explain it.
---
---Nothing here talks to the client except the two scans -- the container list the picker offers,
---which the job keeps current on its own pulse, and the inventory list, which is read on the press
---that opens the picker. Reads are safe from a render callback; commands are not, and every one
---this job issues comes out of its pulse.
local TradeskillJobMenu = {}

---What is typed into the "add by name" box, and the last look at inventory the picker offers.
---Neither belongs in config: one is half-finished input and the other is the world.
TradeskillJobMenu._ = {
    typed = "",
    inventory = {},
    filter = ""
}

---@param container table a row from the job's container scan
---@return string label how it reads in the picker
local function candidateLabel(container)
    if container.kind == TradeskillJobConfig.kinds.world then
        return container.name .. "  (open in the world)"
    end

    local label = container.name .. "  (bag " .. tostring(container.pack) .. ")"
    if container.combines == nil then
        return label .. "  -- closed, combines unknown"
    end
    if not container.combines then
        return label .. "  -- no Combine button"
    end
    return label
end

---@param container table|nil the chosen container
---@param candidates table what is out there right now
local function DrawContainerPicker(container, candidates)
    ImGui.SetNextItemWidth(math.max(180, ImGui.GetContentRegionAvail() - 30))
    if ImGui.BeginCombo("##container", TradeskillJobConfig.DescribeContainer(container)) then
        if #candidates < 1 then
            ImGui.TextDisabled("No containers -- open a forge or carry a tradeskill bag")
        end

        for _, candidate in ipairs(candidates) do
            local chosen = container ~= nil
                and container.kind == candidate.kind
                and container.pack == candidate.pack

            local _, pressed = ImGui.Selectable(candidateLabel(candidate), chosen)
            if pressed then
                TradeskillJobConfig.SetContainer(candidate.kind, candidate.pack, candidate.name)
            end
        end

        if container ~= nil then
            ImGui.Separator()
            if ImGui.Button("Forget it##forgetContainer", 100, 21) then
                TradeskillJobConfig.ClearContainer()
            end
        end

        ImGui.EndCombo()
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("Where the combines happen: a forge, brew barrel or oven standing in the " ..
        "world with its window open, or a tradeskill container in one of this character's bags. " ..
        "A bag is opened once when the run starts and never reopened -- closing it is how you " ..
        "stop the run by hand. Whether a container can combine at all is only readable off its " ..
        "own window, so a closed bag is offered without an answer and checked when it opens.")
end

---@param tradeskillJob TradeskillJob
local function DrawMaterials(tradeskillJob)
    local items = TradeskillJobConfig.GetItems()
    local available = ImGui.GetContentRegionAvail()

    if ImGui.Button("Add from inventory##addMaterial", 150, 23) then
        -- the press is what refreshes it: a walk over every bag is not something to do at frame
        -- rate, and this is the moment somebody wants an answer about now
        TradeskillJobMenu._.inventory = tradeskillJob.ScanInventory()
        TradeskillJobMenu._.filter = ""
        ImGui.OpenPopup("materialPicker")
    end

    if ImGui.BeginPopup("materialPicker") then
        if ImGui.IsWindowAppearing() then
            ImGui.SetKeyboardFocusHere()
        end
        ImGui.SetNextItemWidth(240)
        local typed, changed = ImGui.InputTextWithHint("##materialFilter", "Filter", TradeskillJobMenu._.filter)
        if changed then TradeskillJobMenu._.filter = typed end
        ImGui.Separator()

        local needle = TradeskillJobMenu._.filter:lower()
        local shown = 0
        for _, item in ipairs(TradeskillJobMenu._.inventory) do
            if needle == "" or item.name:lower():find(needle, 1, true) ~= nil then
                shown = shown + 1
                local _unused, pressed = ImGui.Selectable(item.name .. "  (" .. tostring(item.count) .. ")")
                if pressed then
                    TradeskillJobConfig.AddItem(item.name, 1)
                    ImGui.CloseCurrentPopup()
                end
            end
        end

        if shown < 1 then
            ImGui.TextDisabled("Nothing in inventory matches")
        end

        ImGui.EndPopup()
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("One row per item that goes in, and the number is how many slots of the " ..
        "container it takes -- a recipe wanting two of something wants it in two slots, because " ..
        "that is how the server matches a recipe. They are picked up one at a time off a stack " ..
        "for the same reason: a whole stack dropped in would be destroyed by the first combine.")

    -- the typed name gets a line of its own and is sized to whatever room is left, rather than
    -- sharing one with the picker button: three fixed-width controls on one line set a width the
    -- whole page then has to be as wide as
    ImGui.SetNextItemWidth(math.max(120, available - 62))
    -- EnterReturnsTrue, so the second return is "they are done typing" rather than "a key went
    -- down": without it every letter of an item name would add a row of its own
    local name, entered = ImGui.InputTextWithHint("##materialName", "or type an item name",
        TradeskillJobMenu._.typed, ImGuiInputTextFlags.EnterReturnsTrue)
    TradeskillJobMenu._.typed = name
    ImGui.SameLine()
    local addPressed = ImGui.Button("Add##addTypedMaterial", 50, 23)
    if addPressed or entered then
        TradeskillJobConfig.AddItem(TradeskillJobMenu._.typed, 1)
        TradeskillJobMenu._.typed = ""
    end

    if #items < 1 then
        ImGui.TextDisabled("Nothing chosen -- a combine needs at least one material")
        return
    end

    local tableFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner)
    if ImGui.BeginTable("tradeskillMaterials", 4, tableFlags) then
        -- the name takes what is left over; everything to its right is fixed and narrow, so the
        -- row buttons stay on the page however tight the pane is
        ImGui.TableSetupColumn("Material", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Per combine", ImGuiTableColumnFlags.WidthFixed, 86)
        ImGui.TableSetupColumn("Carried", ImGuiTableColumnFlags.WidthFixed, 56)
        ImGui.TableSetupColumn("##rowButtons", ImGuiTableColumnFlags.WidthFixed, 104)
        ImGui.TableHeadersRow()

        local removeAt = nil
        local moveAt, moveBy = nil, nil

        for index, material in ipairs(items) do
            ImGui.PushID(index)
            ImGui.TableNextRow()

            ImGui.TableNextColumn()
            ImGui.Text(tostring(material.name))

            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(78)
            local count, countChanged = ImGui.DragInt("##count", math.max(1, tonumber(material.count) or 1), 1, 1, 10)
            if countChanged then
                TradeskillJobConfig.SetItemCount(index, count)
            end

            ImGui.TableNextColumn()
            local carried = tonumber(mq.TLO.FindItemCount("=" .. tostring(material.name))()) or 0
            if carried < 1 then
                ImGui.TextColored(1, 0.5, 0.4, 1, "none")
            else
                ImGui.Text(tostring(carried))
            end

            ImGui.TableNextColumn()
            if ImGui.SmallButton("^") then moveAt, moveBy = index, -1 end
            ImGui.SameLine()
            if ImGui.SmallButton("v") then moveAt, moveBy = index, 1 end
            ImGui.SameLine()
            if ImGui.SmallButton("Remove") then removeAt = index end

            ImGui.PopID()
        end

        ImGui.EndTable()

        -- applied after the draw: removing a row out from under the loop that is drawing it is
        -- the same mistake the hotbars defer for
        if moveAt ~= nil then TradeskillJobConfig.MoveItem(moveAt, moveBy) end
        if removeAt ~= nil then TradeskillJobConfig.RemoveItem(removeAt) end
    end
end

local function DrawLimits(tradeskills)
    ImGui.TextDisabled("Stops on whichever of these comes first. With none of them ticked it runs " ..
        "until the materials are gone.")

    local stopAtSkill, skillClicked = ImGui.Checkbox("Reached skill level", TradeskillJobConfig.GetStopAtSkill())
    if skillClicked then
        TradeskillJobConfig.SetStopAtSkill(stopAtSkill)
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("Stops once the client reads this skill at or above the number, checked " ..
        "after each combine. Left on Auto it does not need telling which skill: a combine that " ..
        "raises one prints which one, and nothing else is acting while the job is running, so the " ..
        "first skill-up of the run settles it. Until one arrives the limit has not come due -- " ..
        "which is right, because the line that would settle it is the same line that could trip " ..
        "it. Name one instead if the recipe is already trivial and no skill-up is ever coming.")

    ImGui.SameLine()
    ImGui.SetNextItemWidth(130)
    local chosen = TradeskillJobConfig.GetSkill()
    if ImGui.BeginCombo("##skill", chosen ~= "" and chosen or "Auto") then
        -- Auto first, and the default: a combine that raises a skill says which one, so the run
        -- learns it rather than being told it
        local _auto, autoPressed = ImGui.Selectable("Auto -- learn it from the first skill-up", chosen == "")
        if autoPressed then
            TradeskillJobConfig.SetSkill("")
        end
        ImGui.Separator()

        for _, skill in ipairs(tradeskills) do
            local value = tonumber(mq.TLO.Me.Skill(skill)()) or 0
            local _unused, pressed = ImGui.Selectable(skill .. "  (" .. tostring(value) .. ")", skill == chosen)
            if pressed then
                TradeskillJobConfig.SetSkill(skill)
            end
        end
        ImGui.EndCombo()
    end

    ImGui.SameLine()
    ImGui.SetNextItemWidth(84)
    local level, levelChanged = ImGui.DragInt("##skillLevel", TradeskillJobConfig.GetSkillLevel(), 1, 1, 350, "at %d")
    if levelChanged then
        TradeskillJobConfig.SetSkillLevel(level)
    end

    local stopAfter, afterClicked = ImGui.Checkbox("Number of combines", TradeskillJobConfig.GetStopAfterCombines())
    if afterClicked then
        TradeskillJobConfig.SetStopAfterCombines(stopAfter)
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("Counts every combine the server actually made, whether it succeeded or " ..
        "ate the materials -- so this is how much material to spend, not how many items to end " ..
        "up with. A combine it refused is not one of these; that stops the run instead.")

    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)
    local combines, combinesChanged = ImGui.DragInt("##combines", TradeskillJobConfig.GetCombines(), 1, 1, 10000, "%d combines")
    if combinesChanged then
        TradeskillJobConfig.SetCombines(combines)
    end

    local stopSucceeded, succeededClicked = ImGui.Checkbox("Number of successes", TradeskillJobConfig.GetStopAfterSuccesses())
    if succeededClicked then
        TradeskillJobConfig.SetStopAfterSuccesses(stopSucceeded)
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("Counts only the combines that produced something. This is the one to use " ..
        "when the number you want is a number of items: a combine the server made and lost still " ..
        "ate the materials, so counting attempts instead stops short of what you set out to make " ..
        "whenever the recipe is anywhere near your skill.")

    ImGui.SameLine()
    ImGui.SetNextItemWidth(120)
    local successes, successesChanged = ImGui.DragInt("##successes", TradeskillJobConfig.GetSuccesses(), 1, 1, 10000, "%d made")
    if successesChanged then
        TradeskillJobConfig.SetSuccesses(successes)
    end

    local trivial, trivialClicked = ImGui.Checkbox("The recipe goes trivial", TradeskillJobConfig.GetStopWhenTrivial())
    if trivialClicked then
        TradeskillJobConfig.SetStopWhenTrivial(trivial)
    end

    ImGui.SameLine()
    CommonUI.HelpMarker("Stops the first time the server says this combine can no longer raise " ..
        "the skill. Worth ticking on a skill-up run and leaving off on one that is making things " ..
        "to keep.")
end

---@param tradeskillJob TradeskillJob
function TradeskillJobMenu.BuildMenu(tradeskillJob)
    local running = tradeskillJob.IsEnabled()

    ImGui.Text("Tradeskill Job Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    -- a job is started, not enabled: the switch is the errand, and it is never on at startup
    if running then
        if ImGui.Button("Stop", 80, 23) then
            tradeskillJob.SetEnabled(false)
        end
    else
        if ImGui.Button("Start", 80, 23) then
            tradeskillJob.SetEnabled(true)
        end
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("tradeskillStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(tradeskillJob.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Combines")
        ImGui.TableNextColumn()
        ImGui.Text(tostring(tradeskillJob.GetCombines()) .. " made -- " ..
            tostring(tradeskillJob.GetSucceeded()) .. " produced something, " ..
            tostring(tradeskillJob.GetFailed()) .. " lost the materials")

        if TradeskillJobConfig.GetStopAtSkill() then
            local skill = tradeskillJob.GetWatchedSkill()

            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text(skill or "Skill")
            ImGui.TableNextColumn()
            if skill == nil then
                ImGui.TextDisabled("waiting for a skill-up to say which")
            else
                local value = tonumber(mq.TLO.Me.Skill(skill)()) or 0
                local started = tradeskillJob.GetStartedSkill()
                local gained = (started ~= nil and value > started)
                    and ("  (+" .. tostring(value - started) .. " this run)") or ""
                local how = tradeskillJob.IsSkillDetected() and "  [detected]" or ""
                ImGui.Text(tostring(value) .. " of " .. tostring(TradeskillJobConfig.GetSkillLevel()) ..
                    gained .. how)
            end
        end

        if tradeskillJob.GetLastProduct() ~= nil then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text("Recipe")
            ImGui.TableNextColumn()
            ImGui.Text(tostring(tradeskillJob.GetLastProduct()))
        end

        if tradeskillJob.IsTrivial() then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text("Trivial")
            ImGui.TableNextColumn()
            ImGui.Text("this combine can no longer raise the skill")
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.Spacing()

    if running then ImGui.BeginDisabled(true) end

    -- Headings rather than a one-column table holding the three sections. A table sizes its column
    -- to the widest row it holds, and the materials table nested in one would then be stretched to
    -- *that* width -- which is set by the longest line of controls on the page, not by the pane --
    -- and its right-hand columns pushed off the edge. Nothing here is nested, so every part sizes
    -- itself against the pane it is actually being drawn in.
    ImGui.SeparatorText("Container")
    DrawContainerPicker(TradeskillJobConfig.GetContainer(), tradeskillJob.GetContainerCandidates())

    ImGui.SeparatorText("Materials")
    DrawMaterials(tradeskillJob)

    ImGui.SeparatorText("Stop when")
    DrawLimits(tradeskillJob.tradeskills)

    if running then ImGui.EndDisabled() end

    ImGui.Spacing()
    ImGui.Separator()

    ImGui.TextWrapped("Fills the container with the materials above, presses Combine, puts what " ..
        "it made away, and does it again. It is a job, not a state: while it runs nothing else " ..
        "this character does gets a turn, and it takes the character's feet on the way in, so a " ..
        "follow order cannot walk it away from the forge. It stops on a limit above, when a " ..
        "material runs out, when the container is closed, or on Stop -- and it never starts by " ..
        "itself, so a fresh script is always standing still.")
end

return TradeskillJobMenu
