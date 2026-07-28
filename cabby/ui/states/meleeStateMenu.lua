local mq = require("mq")

local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local Character = require("cabby.character")
local Combat = require("cabby.combat")
local CombatConfig = require("cabby.configs.combatConfig")
local CommonUI = require("cabby.ui.commonUI")
local Disciplines = require("cabby.actions.disciplines")
local Items = require("cabby.actions.items")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local Roles = require("cabby.roles")
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
        ImGui.Text(meleeState.IsAttacking() and "Attacking" or "Standby")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Fighting")

        ImGui.TableNextColumn()
        ImGui.Text(Combat.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Group Roles")

        ImGui.TableNextColumn()
        -- cached behind Roles' own scan interval, so this costs nothing per frame
        ImGui.Text(Roles.Describe())

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
            -- through the state, not the config: turning it off releases a stick already running
            meleeState.SetStick(result)
        end

        ImGui.SameLine()
        ---@type boolean
        local clicked, result
        result, clicked = ImGui.Checkbox("Auto-Engage", CombatConfig.GetAutoEngage())
        if clicked then
            CombatConfig.SetAutoEngage(result)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Picks a fight up without being told: the main assist's target first, and then whatever is attacking us. Off waits for an (attack) order or an (assist) call.")

        ImGui.SameLine()
        ---@type boolean
        local clicked, result
        result, clicked = ImGui.Checkbox("Call Assist", CombatConfig.GetCallAssist())
        if clicked then
            CombatConfig.SetCallAssist(result)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("While this character holds the group's Main Tank role, every change to what it is fighting is called out to the group as an (assist) line, and dropping the target calls the fight off. Nothing is said when somebody else is the tank. The channels it speaks on are the ones /speak sets.")

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
            MeleeStateConfig.SetEngageDistance(100)
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- Both of these are the engagement, not this state: backing off means the character
        -- stops fighting the thing, and a paladin that stops swinging but keeps nuking is not
        -- what the button says. Combat runs no game commands, which is what makes pressing them
        -- from inside a render callback safe -- the old Attack button ran /mqtarget from here.
        local attackDisabled = mq.TLO.Target.ID() == nil or mq.TLO.Target.Type() == "Corpse"
        if attackDisabled then
            ImGui.BeginDisabled(true)
        end
        if ImGui.Button("Attack", 60, 23) then
            Combat.Engage(mq.TLO.Target.ID(), "the Attack button")
        end
        if attackDisabled then
            ImGui.EndDisabled()
        end

        ImGui.SameLine()
        local backOffDisabled = not Combat.IsEngaged()
        if backOffDisabled then
            ImGui.BeginDisabled(true)
        end
        if ImGui.Button("Back Off", 70, 23) then
            Combat.Disengage("the Back Off button")
        end
        if backOffDisabled then
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
                        availableActions.aas = AAs.taunt

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
                        availableActions.aas = AAs.hate

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
            -- AAs and clickies but no spells: the epic click at 80% health is exactly what this
            -- list replaced (see the MQ2Melee lines at the bottom of meleeState.lua), while a
            -- spell rotation belongs to the state built for one. A heal in here would be a
            -- second, worse heal state.
            availableActions.aas = AAs.all
            availableActions.items = Items.all

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
