---@diagnostic disable: undefined-field
local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local Combat = require("cabby.combat")
local CommonUI = require("cabby.ui.commonUI")
local Items = require("cabby.actions.items")
local MezStateConfig = require("cabby.configs.mezStateConfig")
local Mobs = require("cabby.mobs")
local MobsConfig = require("cabby.configs.mobsConfig")
local Spells = require("cabby.actions.spells")

local MezStateMenu = {}

---Cheapest answer first, which is also the order they are being chosen between in.
local softenOrder = {
    MezStateConfig.softenWhen.Resisted,
    MezStateConfig.softenWhen.Always
}

local stunOrder = {
    MezStateConfig.stunWhen.OnMe,
    MezStateConfig.stunWhen.Casting,
    MezStateConfig.stunWhen.Either
}

---How much room the per-slot controls need under the action row.
local extrasHeight = 26

---What a control slot needs saying about it beyond which spell it is.
---
---Which of the three jobs it does is read off the spell and only *reported* -- a mez has no dial at
---all, because there is nothing about a mez that is a decision. The two that do have one are the
---two whose right answer is about the group rather than about the spell: when a softener is worth
---a cast, and what a stun is being kept for.
---@param liveAction Action what the controls here write to
---@param shownAction Action what the row is currently holding -- the staged pick while it is open
---@param mezState MezState
local function DrawMezFields(liveAction, shownAction, mezState)
    local facts = mezState.DescribeSlot(shownAction or liveAction)

    if facts.softenable then
        local when = MezStateConfig.GetSoftenWhen(liveAction)

        ImGui.SetNextItemWidth(170)
        if ImGui.BeginCombo("##soften", MezStateConfig.GetSoftenWhenDisplay(when)) then
            for _, known in ipairs(softenOrder) do
                local _, pressed = ImGui.Selectable(known.display, when == known.value)
                if pressed then
                    MezStateConfig.SetSoftenWhen(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("When this debuff is worth a cast of its own. Once it resists a mez is the usual answer and the honest one: we find out that a mob resists by having a mez bounce off it, and only then is a tash worth three seconds and a gem timer. Before every mez is for the zone where they all resist -- it costs a cast per add to find out nothing when they do not. Either way the mob is left alone once the debuff is on it, and a mob waiting on this is not mezzed in the meantime, so the order of the two slots does not matter.")
        ImGui.SameLine()
    end

    if facts.stunnable then
        local when = MezStateConfig.GetStunWhen(liveAction)

        ImGui.SetNextItemWidth(170)
        if ImGui.BeginCombo("##stun", MezStateConfig.GetStunWhenDisplay(when)) then
            for _, known in ipairs(stunOrder) do
                local _, pressed = ImGui.Selectable(known.display, when == known.value)
                if pressed then
                    MezStateConfig.SetStunWhen(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("What this stun is being kept for. When it turns on me is the one that buys the casts everything else here depends on -- a mob that has reached this character interrupts every mez that follows, and a stun is the cheapest way to get the seconds back. When it is casting holds a caster down mid-spell. A mob already mezzed is never stunned: it is held, and one more spell landing on it is one more thing that could wake it.")
        ImGui.SameLine()
    end

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end
    ImGui.TextDisabled(facts.roleText)
end

---@param mezState MezState
local function DrawMobTable(mezState)
    local rows = mezState.DescribeMobs()

    if #rows == 0 then
        ImGui.TextDisabled("Nothing in the fight.")
        return
    end

    local flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter,
        ImGuiTableFlags.BordersInner, ImGuiTableFlags.Resizable)
    if ImGui.BeginTable("mezMobs", 4, flags) then
        ImGui.TableSetupColumn("Mob", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("Held", ImGuiTableColumnFlags.WidthFixed, 70)
        ImGui.TableSetupColumn("Why", ImGuiTableColumnFlags.WidthFixed, 160)
        ImGui.TableSetupColumn("Seen by", ImGuiTableColumnFlags.WidthFixed, 200)
        ImGui.TableHeadersRow()

        for _, row in ipairs(rows) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text(row.name)

            ImGui.TableNextColumn()
            if row.status == "mezzed" then
                ImGui.TextColored(0.4, 0.9, 0.4, 1, "mezzed")
            elseif row.status == "loose" then
                ImGui.TextColored(1, 0.5, 0.4, 1, "loose")
            elseif row.status == "immune" then
                ImGui.TextColored(1, 0.8, 0.2, 1, "immune")
            elseif row.status == "unseen" then
                ImGui.TextColored(0.6, 0.6, 0.7, 1, "unseen")
            else
                ImGui.TextDisabled(row.status)
            end

            ImGui.TableNextColumn()
            ImGui.TextDisabled(row.note or "")

            ImGui.TableNextColumn()
            ImGui.TextDisabled(row.sources)
        end

        ImGui.EndTable()
    end
end

---@param mezState MezState
function MezStateMenu.BuildMenu(mezState)
    ImGui.Text("Mez Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", mezState.IsEnabled())
    if enabledClicked then
        mezState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter,
        ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("mezStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(mezState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Fighting")
        ImGui.TableNextColumn()
        ImGui.Text(Combat.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("The fight")
        ImGui.TableNextColumn()
        ImGui.Text(Mobs.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Cast")
        ImGui.TableNextColumn()
        ImGui.Text(mezState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("mezSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local stopPct, stopChanged = ImGui.DragInt("Leave below %", MezStateConfig.GetStopPct(), 1, 1, 100)
        if stopChanged then
            MezStateConfig.SetStopPct(stopPct)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("A mob hurt past this is left alone. It reads backwards until you have watched it go wrong: a mob below the line is not too healthy to mez, it is too nearly dead. Somebody has been killing it, there is damage in the air aimed at it, and a mez landing takes it out of reach of all of that so the group starts again on a full-health add instead.")

        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local manaFloor, manaChanged = ImGui.DragInt("Keep mana above %", MezStateConfig.GetManaFloor(), 1, 0, 100)
        if manaChanged then
            MezStateConfig.SetManaFloor(manaFloor)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Crowd control stops here. Lower than the damage rotation's floor is usually right: the last of the mana is better spent holding an add still than on one more nuke.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local aeMin, aeChanged = ImGui.DragInt("AE from", MezStateConfig.GetAeMin(), 1, 2, 20)
        if aeChanged then
            MezStateConfig.SetAeMin(aeMin)
        end
        ImGui.SameLine()
        ImGui.Text("loose mobs")
        ImGui.SameLine()
        CommonUI.HelpMarker("How many loose mobs an AE mez has to cover before it is worth casting. Below this a single-target mez covers the same ground without waking anything that was not already in the fight. The blast is aimed at whichever mob has the most loose neighbours inside its radius.")

        ImGui.SameLine()
        local aeConfirmed, aeConfirmedClicked = ImGui.Checkbox("Only where the fight is known",
            MezStateConfig.GetAeConfirmedOnly())
        if aeConfirmedClicked then
            MezStateConfig.SetAeConfirmedOnly(aeConfirmed)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("An AE mez is only aimed where the mobs that make it worth casting are ones something actually told us about -- what we are fighting, our own extended target window, or a group member's (defend) call. The roster's own sweep can see a mob in combat stance without being able to say it is in combat with us, and an AE aimed into a group of those is the classic way a camp pulls the room. Off blankets the area regardless.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(80)
        local lead, leadChanged = ImGui.DragInt("Refresh with ms to spare",
            MezStateConfig.GetRefreshLeadMs(), 100, 500, 30000)
        if leadChanged then
            MezStateConfig.SetRefreshLeadMs(lead)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("How much of a mez has to be left, on top of the time the cast itself takes, before the mob still counts as held. It is arithmetic rather than a timer: a mez with four seconds left that takes three to cast has to be started now or it wears off with the caster stood still mid-cast, which is the worst moment in the fight to hand an add back.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- the roster's own dial, shown here because this is the page where its answer is acted on
        local sweep, sweepClicked = ImGui.Checkbox("Sweep for mobs nearby", MobsConfig.GetSweep())
        if sweepClicked then
            MobsConfig.SetSweep(sweep)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("The mob roster always reads what the client is told: what we are fighting, the extended target window, and the group's (defend) calls. This is the fourth angle -- a sweep of the zone for anything in combat stance nearby -- and it is the only one that can see the add on its way in or the mob chewing on somebody's pet. It is also the only one that can be wrong about whether the mob is fighting us, which is what the AE setting above guards against. /cmobs reports all four.")

        if MobsConfig.GetSweep() then
            ImGui.SameLine()
            ImGui.SetNextItemWidth(60)
            local radius, radiusChanged = ImGui.DragInt("out", MobsConfig.GetRadius(), 1, 10, 500)
            if radiusChanged then
                MobsConfig.SetRadius(radius)
            end

            ImGui.SameLine()
            ImGui.SetNextItemWidth(60)
            local zradius, zradiusChanged = ImGui.DragInt("up and down", MobsConfig.GetZRadius(), 1, 5, 500)
            if zradiusChanged then
                MobsConfig.SetZRadius(zradius)
            end
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.SeparatorText("The fight")
    ImGui.SameLine()
    CommonUI.HelpMarker("Every mob this character believes is in the fight, what is holding it, and which of the roster's four angles saw it. This is the same reading the state acts on, worked out fresh -- so a mob showing loose here is one a mez is being chosen for right now.")

    DrawMobTable(mezState)

    ImGui.SeparatorText("Crowd Control")
    ImGui.SameLine()
    CommonUI.HelpMarker("Tried in order, top to bottom: the first slot with something to do is cast, then the state waits for it to finish before choosing again. What each slot is *for* is read off the spell and never configured -- three jobs and no others: a spell that mesmerizes is a mez, one that stuns is a stun, and one that lowers resists is the softener cast so a mez that was resisted lands next time. The stun is the strategy rather than a spare: a mez is a long cast and a mob that has reached you interrupts it, so the one swinging at you is stunned first and mezzed during the seconds that buys -- and a mob already mezzed is never stunned, because the stun would break the mez. Anything else (a slow, a snare, a root, a nuke) holds nothing still and is refused with the reason on its row. A mez is never aimed at what the group is killing, at something already held, or at something the world has said cannot be mesmerized. Only memorized spells are used, so keep these on the spell bar.")

    local actions = MezStateConfig.GetActions()
    local availableActions = AvailableActions.new()
    -- exactly three jobs, read off the spells' own effects and no heading: the mezzes, the resist
    -- debuffs that get one to land on something that shrugged it off, and the stuns that buy the
    -- seconds a long mez needs. A slow or a snare is not here on purpose -- it holds nothing still
    -- and is a damage rotation slot. The rest of the book is a switch away in the picker.
    availableActions.spells = Spells.control
    availableActions.allSpells = Spells.detrimental
    availableActions.aas = AAs.all
    availableActions.items = Items.all

    if ImGui.Button("Add##mezAction", 50, 23) then
        actions[#actions+1] = {}
    end

    local extras = {
        height = extrasHeight,
        draw = function(liveAction, shownAction) DrawMezFields(liveAction, shownAction, mezState) end
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
end

return MezStateMenu
