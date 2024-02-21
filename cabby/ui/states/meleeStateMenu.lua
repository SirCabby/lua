local mq = require("mq")

local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local Character = require("cabby.character")
local CommonUI = require("cabby.ui.commonUI")
local Disciplines = require("cabby.actions.disciplines")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local Skills = require("cabby.actions.skills")

local MeleeStateMenu = {}

local usageOrder = {
    MeleeStateConfig.usages.Always, MeleeStateConfig.usages.AsNeeded, MeleeStateConfig.usages.Off
}

---@param value string
---@return string display
local function GetUsageDisplayFromValue(value)
    for _, usage in pairs(MeleeStateConfig.usages) do
        if usage.value == value then
            return usage.display
        end
    end

    return MeleeStateConfig.usages.Off.display
end

---@param actions table
---@param availableActions table
local function BuildActions(actions, availableActions)
    for i, action in ipairs(actions) do
        ---@type Action
        action = action
        if i % 2 == 0 then
            ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 1)
        else
            ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.15, 0.15, 0.15, 1)
        end
        ImGui.PushID(action)
        ActionUI.ActionControl(action, actions, availableActions)
        ImGui.PopID()
        ImGui.PopStyleColor()
    end
end

---@param meleeState MeleeState
function MeleeStateMenu.BuildMenu(meleeState)
    ImGui.Text("Melee State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    ---@type boolean
    local clicked, result
    result, clicked = ImGui.Checkbox("Enabled", meleeState.IsEnabled())
    if clicked then
        meleeState.SetEnabled(result)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local tableSorting_flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("t1", 2, tableSorting_flags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")

        ImGui.TableNextColumn()
        local currentTask = "Standby"
        local attacking = false
        if meleeState._.currentAction == meleeState._.meleeActions.attackTarget then
            currentTask = "Attacking: " .. tostring(meleeState._.currentTargetID)
            attacking = true
        end
        ImGui.Text(currentTask)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Attack Target")

        ImGui.TableNextColumn()
        local targetName = "<NONE>"
        if attacking then
            targetName = mq.TLO.Spawn(meleeState._.currentTargetID).Name()
        end
        ImGui.Text(targetName)

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    local table2_flags = bit32.bor(ImGuiTableFlags.RowBg)
    if ImGui.BeginTable("t2", 1, table2_flags) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ---@type boolean
        local clicked, result
        result, clicked = ImGui.Checkbox("Stick", MeleeStateConfig:GetStick())
        if clicked then
            MeleeStateConfig.SetStick(result)
        end

        ImGui.SameLine()
        ---@type boolean
        local clicked, result
        result, clicked = ImGui.Checkbox("Auto-Engage", MeleeStateConfig:GetAutoEngage())
        if clicked then
            MeleeStateConfig.SetAutoEngage(result)
        end

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(40)
        ---@type integer
        local result
        ---@type boolean
        local selected
        result, selected = ImGui.DragInt("Engage Distance", MeleeStateConfig:GetEngageDistance(), 1, 0, 500)
        if selected then
            MeleeStateConfig.SetEngageDistance(result)
        end

        ImGui.SameLine()
        if ImGui.Button("Reset Default", 100, 23) then
            MeleeStateConfig.SetEngageDistance(50)
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local disabled = false
        if mq.TLO.Target() == nil then
            ImGui.BeginDisabled(true)
            disabled = true
        end
        if ImGui.Button("Attack", 60, 23) then
            local targetId = mq.TLO.Target.ID()
            meleeState.EngageTargetId(targetId)
            meleeState.StickToCurrentTarget(meleeState.GetSpawnMeleeRange(targetId))
        end
        if disabled then
            ImGui.EndDisabled()
        end

        ImGui.SameLine()
        if meleeState._.currentAction ~= meleeState._.meleeActions.attackTarget then
            ImGui.BeginDisabled(true)
            disabled = true
        end
        if ImGui.Button("Back Off", 70, 23) then
            meleeState.Reset()
        end
        if disabled then
            ImGui.EndDisabled()
        end

        local attackLabel = "<No Target>"
        if mq.TLO.Target() ~= nil then
            ---@type string
            ---@diagnostic disable-next-line: assign-type-mismatch
            attackLabel = mq.TLO.Target()
        end
        ImGui.SameLine()
        local width = ImGui.GetContentRegionAvail()
        ImGui.SetNextItemWidth(width)
        ImGui.LabelText("##f006", attackLabel)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(100)
        local primaryMeleeAbility = MeleeStateConfig.GetPrimaryCombatAbility():Name()
        if ImGui.BeginCombo("Primary Melee Skill##foo7", primaryMeleeAbility) then
            for _, skill in ipairs(Character.primaryMeleeAbilities) do
                ---@type Skill
                skill = skill
                local _, pressed = ImGui.Selectable(skill:Name(), primaryMeleeAbility == skill:Name())
                if pressed then
                    MeleeStateConfig.SetPrimaryCombatAbility(skill)
                end
            end
            ImGui.EndCombo()
        end

        if mq.TLO.Me.Class.ShortName() == "MNK" then
            ImGui.SameLine()
            ImGui.SetNextItemWidth(100)
            local secondaryMeleeAbility = MeleeStateConfig.GetSecondaryCombatAbility():Name()
            if ImGui.BeginCombo("Secondary Melee Skill##foo8", secondaryMeleeAbility) then
                for _, skill in ipairs(Character.secondaryMeleeAbilities) do
                    ---@type Skill
                    skill = skill
                    local _, pressed = ImGui.Selectable(skill:Name(), secondaryMeleeAbility == skill:Name())
                    if pressed then
                        MeleeStateConfig.SetSecondaryCombatAbility(skill)
                    end
                end
                ImGui.EndCombo()
            end
        end

        if Skills.bash:HasAction() then
            ImGui.Dummy(0, 0)
            ImGui.SameLine()

            ---@type boolean
            local clicked, result
            result, clicked = ImGui.Checkbox("Bash when shield equipped", MeleeStateConfig:GetBashOverride())
            if clicked then
                MeleeStateConfig.SetBashOverride(result)
            end

            ImGui.SameLine()
            CommonUI.HelpMarker("When enabled, bash will be used instead of the selected Primary Melee Skill only when a shield is presently equipped.")
        end
        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    if ImGui.BeginTabBar("Melee Tabs") then
        if Character.HasHates() or Character.HasTaunts() then
            local tabActive = true
            if not MeleeStateConfig:GetTanking() then
                tabActive = false
                ImGui.PushStyleColor(ImGuiCol.Tab, .2, .2, .2, 1)
                ImGui.PushStyleColor(ImGuiCol.TabActive, .2, .2, .2, 1)
            end

            if ImGui.BeginTabItem("Tanking") then
                ---@type boolean
                local clicked, result
                result, clicked = ImGui.Checkbox("Tanking", MeleeStateConfig:GetTanking())
                if clicked then
                    MeleeStateConfig.SetTanking(result)
                end

                if result then
                    if Character.HasTaunts() then
                        ImGui.LabelText("", "Taunts")
                        local actions = MeleeStateConfig.GetTauntActions()
                        local availableActions = AvailableActions.new()
                        if Skills.taunt:HasAction() then
                            availableActions.abilities = { Skills.taunt }
                        end
                        availableActions.discs = Disciplines.taunt

                        if ImGui.Button("Add##" .. tostring(actions), 50, 23) then
                            local newAction = {}
                            actions[#actions+1] = newAction
                        end

                        ImGui.SameLine()
                        ImGui.SetNextItemWidth(100)
                        local usage = MeleeStateConfig:GetTauntUsage()
                        if ImGui.BeginCombo("Usage##" .. tostring(actions), GetUsageDisplayFromValue(usage)) then
                            for _, usageType in ipairs(usageOrder) do
                                local _, pressed = ImGui.Selectable(usageType.display, usage == usageType.value)
                                if pressed then
                                    MeleeStateConfig.SetTauntUsage(usageType.value)
                                end
                            end
                            ImGui.EndCombo()
                        end

                        ImGui.SameLine()
                        CommonUI.HelpMarker("'Always' uses actions as soon as they are available. 'As Needed' will only use actions if character loses target aggro, sequentially with a short delay between.  'Off' to disable actions.")

                        BuildActions(actions, availableActions)
                    end

                    if Character.HasHates() then
                        ImGui.LabelText("", "Hates")
                        local actions = MeleeStateConfig.GetHateActions()
                        local availableActions = AvailableActions.new()
                        availableActions.discs = Disciplines.hate

                        if ImGui.Button("Add##" .. tostring(actions), 50, 23) then
                            local newAction = {}
                            actions[#actions+1] = newAction
                        end

                        ImGui.SameLine()
                        ImGui.SetNextItemWidth(100)
                        local usage = MeleeStateConfig:GetHateUsage()
                        if ImGui.BeginCombo("Usage##" .. tostring(actions), GetUsageDisplayFromValue(usage)) then
                            for _, usageType in ipairs(usageOrder) do
                                local _, pressed = ImGui.Selectable(usageType.display, usage == usageType.value)
                                if pressed then
                                    MeleeStateConfig.SetHateUsage(usageType.value)
                                end
                            end
                            ImGui.EndCombo()
                        end

                        ImGui.SameLine()
                        CommonUI.HelpMarker("'Always' uses actions as soon as they are available. 'As Needed' will only use actions if character loses target aggro, sequentially with a short delay between.  'Off' to disable actions.")

                        BuildActions(actions, availableActions)
                    end
                end

                ImGui.EndTabItem()
            end

            if not tabActive then
                ImGui.PopStyleColor(2)
            end
        end

        if ImGui.BeginTabItem("Melee") then
            local actions = MeleeStateConfig.GetActions()
            local availableActions = AvailableActions.new()
            availableActions.abilities = Character.meleeAbilities
            availableActions.discs = Disciplines.melee

            if ImGui.Button("Add##" .. tostring(actions), 50, 23) then
                local newAction = {}
                actions[#actions+1] = newAction
            end

            BuildActions(actions, availableActions)

            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

return MeleeStateMenu
