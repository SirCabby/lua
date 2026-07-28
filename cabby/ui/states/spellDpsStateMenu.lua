---@diagnostic disable: undefined-field
local mq = require("mq")

local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local Combat = require("cabby.combat")
local CombatConfig = require("cabby.configs.combatConfig")
local CommonUI = require("cabby.ui.commonUI")
local Items = require("cabby.actions.items")
local Roles = require("cabby.roles")
local SpellDpsStateConfig = require("cabby.configs.spellDpsStateConfig")
local Spells = require("cabby.actions.spells")

local SpellDpsStateMenu = {}

---@param spellDpsState SpellDpsState
function SpellDpsStateMenu.BuildMenu(spellDpsState)
    ImGui.Text("Spell DPS Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", spellDpsState.IsEnabled())
    if enabledClicked then
        spellDpsState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("spellDpsStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(spellDpsState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Fighting")
        ImGui.TableNextColumn()
        ImGui.Text(Combat.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Cast")
        ImGui.TableNextColumn()
        ImGui.Text(spellDpsState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("spellDpsSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- the same engagement the melee state fights, so the same buttons: both go through
        -- Combat, which runs no game commands and is therefore safe from a render callback
        local attackDisabled = mq.TLO.Target.ID() == nil
        if attackDisabled then ImGui.BeginDisabled(true) end
        if ImGui.Button("Attack", 60, 23) then
            Combat.Engage(mq.TLO.Target.ID(), "the Attack button")
        end
        if attackDisabled then ImGui.EndDisabled() end

        ImGui.SameLine()
        local backOffDisabled = not Combat.IsEngaged()
        if backOffDisabled then ImGui.BeginDisabled(true) end
        if ImGui.Button("Back Off", 70, 23) then
            Combat.Disengage("the Back Off button")
        end
        if backOffDisabled then ImGui.EndDisabled() end

        ImGui.SameLine()
        local autoEngage, autoEngageClicked = ImGui.Checkbox("Auto-Engage", CombatConfig.GetAutoEngage())
        if autoEngageClicked then
            CombatConfig.SetAutoEngage(autoEngage)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Picks a fight up without being told: the main assist's target first, and then whatever is attacking us. Off waits for an (attack) order or an (assist) call.")

        ImGui.SameLine()
        local callAssist, callAssistClicked = ImGui.Checkbox("Call Assist", CombatConfig.GetCallAssist())
        if callAssistClicked then
            CombatConfig.SetCallAssist(callAssist)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("While this character holds the group's Main Tank role, every change to what it is fighting is called out to the group as an (assist) line, and dropping the target calls the fight off. Nothing is said when somebody else is the tank. The channels it speaks on are the ones /speak sets.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- cached behind Roles' own scan interval, so this costs nothing per frame
        ImGui.TextDisabled("Group roles -- " .. Roles.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local startPct, startChanged = ImGui.DragInt("Start below %", SpellDpsStateConfig.GetStartPct(), 1, 1, 100)
        if startChanged then
            SpellDpsStateConfig.SetStartPct(startPct)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Nothing is cast until the target's health has dropped below this. The cheapest aggro management there is: it gives whoever is tanking a moment to land something first. 100 means start immediately.")

        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local stopPct, stopChanged = ImGui.DragInt("Stop below %", SpellDpsStateConfig.GetStopPct(), 1, 0, 99)
        if stopChanged then
            SpellDpsStateConfig.SetStopPct(stopPct)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Nothing new is started once the target is this close to dead -- a four second cast on a mob that dies in two is mana and a gem timer spent on nothing. A cast already in the air is left to finish.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local manaFloor, manaChanged = ImGui.DragInt("Keep mana above %", SpellDpsStateConfig.GetManaFloor(), 1, 0, 100)
        if manaChanged then
            SpellDpsStateConfig.SetManaFloor(manaFloor)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Damage stops here so that healing, or the next fight, still has something to work with. Set it to 0 to burn everything.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.SeparatorText("Rotation")
    ImGui.SameLine()
    CommonUI.HelpMarker("Tried in order, top to bottom: the first one ready is cast, then the state waits for it to finish before choosing again. Only memorized spells are used, so keep the rotation on the spell bar. For anything more specific than the numbers above -- holding while the tank is low, saving a nuke for a named -- put it in a slot's LUA expression.")

    local actions = SpellDpsStateConfig.GetActions()
    local availableActions = AvailableActions.new()
    -- what you point at something you are fighting: the harmful half of the book, plus the AAs
    -- and clickies that do the same job
    availableActions.spells = Spells.detrimental
    availableActions.aas = AAs.all
    availableActions.items = Items.all

    if ImGui.Button("Add##spellDpsAction", 50, 23) then
        actions[#actions+1] = {}
    end

    for index, action in ipairs(actions) do
        if index % 2 == 0 then
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

return SpellDpsStateMenu
