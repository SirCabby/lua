---@diagnostic disable: undefined-field
local mq = require("mq")

local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local CanniStateConfig = require("cabby.configs.canniStateConfig")
local CommonUI = require("cabby.ui.commonUI")
local Items = require("cabby.actions.items")
local Spells = require("cabby.actions.spells")

local CanniStateMenu = {}

---How much room the per-slot line needs under the action row.
local extrasHeight = 22

---What a slot amounts to: what one use trades, whether it arrives over a duration, and whether the
---character is currently carrying the health to pay for it. All of it read off the spell rather
---than configured, and all of it worth printing -- the size of a trade is what the health floor
---above is set against, and a slot sitting quiet is otherwise a silent puzzle.
---@param liveAction Action
---@param shownAction Action what the row is currently holding -- the staged pick while it is being
---edited -- which is what the spell is read from
---@param canniState CanniState
local function DrawCanniFields(liveAction, shownAction, canniState)
    local facts = canniState.DescribeSlot(shownAction or liveAction)

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end

    if facts.cost <= 0 and facts.gain <= 0 then
        ImGui.TextDisabled("what it trades is not readable from here")
        return
    end

    local text = tostring(facts.cost) .. " health for " .. tostring(facts.gain) .. " mana" ..
        (facts.lasting and ", a tick at a time" or "")

    -- Said plainly, because it is the one thing here that cannot be worked out by looking at the
    -- item: the server refused it once for combat, so it is kept for the quiet. Left unsaid it is a
    -- slot that fires between pulls and mysteriously does not during them.
    if facts.combatBarred then
        ImGui.TextDisabled(text .. " -- only while nothing is fighting us")
        return
    end

    if facts.affordable then
        ImGui.TextDisabled(text)
    else
        -- a slot the character cannot currently pay for is the one thing on this row worth
        -- colouring: it is temporary, and it otherwise looks like a slot that is simply broken
        ImGui.TextColored(0.7, 0.7, 0.4, 1, text .. " -- more health than we have right now")
    end
end

---@param canniState CanniState
function CanniStateMenu.BuildMenu(canniState)
    ImGui.Text("Canni State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", canniState.IsEnabled())
    if enabledClicked then
        canniState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("canniStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(canniState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Health")
        ImGui.TableNextColumn()
        ImGui.Text(tostring(math.floor(tonumber(mq.TLO.Me.PctHPs()) or 0)) .. "%")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Mana")
        ImGui.TableNextColumn()
        -- a character with no mana bar reads 0% forever, and saying so is kinder than a number
        -- that looks like an emergency
        if (tonumber(mq.TLO.Me.MaxMana()) or 0) > 0 then
            ImGui.Text(tostring(math.floor(tonumber(mq.TLO.Me.PctMana()) or 0)) .. "%")
        else
            ImGui.Text("no mana bar")
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Use")
        ImGui.TableNextColumn()
        ImGui.Text(canniState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("canniSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local minHp, minHpChanged = ImGui.DragInt("Stop below %", CanniStateConfig.GetMinHpPct(), 1, 1, 99)
        if minHpChanged then
            CanniStateConfig.SetMinHpPct(minHp)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Where trading stops. Nothing is traded below this -- it is asked before a use, not after it, so a trade is still allowed to take the character well underneath: a shaman's Cannibalization AA costs a third of the bar in one click, and a floor that refused anything landing below itself would refuse that at every setting worth picking. Health comes back afterwards, which is what makes the trade worth making. Each slot says what it costs on its own row, so this is set knowing the size of what it allows. Trading does not start again the moment health is back above this -- Resume at % is where it starts again, and the gap between the two is what stops the character standing up to trade every regen tick. This one is asked whatever else is true, though: it is the only number here that is about safety rather than efficiency, and it is what holds while the character is on its feet and Resume at % is not being consulted. The one thing that is not a preference: nothing is ever fired that costs more health than the character is carrying.")

        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local resumeHp, resumeHpChanged = ImGui.DragInt("Resume at %", CanniStateConfig.GetResumeHpPct(), 1, 1, 100)
        if resumeHpChanged then
            CanniStateConfig.SetResumeHpPct(resumeHp)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Health to come back to before trading starts again. This is the number that makes sitting worth anything: with it set to the stop point the character trades down to the floor, sits, takes one regen tick back over it, stands up to spend that tick and sits again -- a stand and a sit per tick, and the out-of-combat regen bonus never applies for long enough to matter. A gap between the two turns that into a burst of trading and then a rest worth sitting through. Never below the stop point, and set to 100 the character will wait for the very last of its health, which is the slowest part of the bar to come back. Ignored entirely while the character is on its feet, in a fight or out of one: nothing is medding then, and what this is there to stop is a trade breaking a rest in half -- which a trade taken standing does not do, since the sit after it is one sit and a longer one. Standing in a fight that means the stop point is the only line, and the character trades down to it, takes a heal and trades down again. Standing after one it means the character takes its trade on the way into the rest rather than waiting out a resume point it only ever owed to a sit. A fight it is sitting through (see Resting during a fight) still counts as a rest and is still waited out.")

        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local maxMana, maxManaChanged = ImGui.DragInt("Trade below mana %", CanniStateConfig.GetMaxManaPct(), 1, 1, 100)
        if maxManaChanged then
            CanniStateConfig.SetMaxManaPct(maxMana)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Mana to stop at. Above this there is nothing worth spending health on, and the state stands down and hands its frames back to the damage rotation below it. Set it low to trade only in an emergency, high to keep the bar topped up between pulls -- near 100 spends health on mana that would have come back on its own.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local inCombat, inCombatClicked = ImGui.Checkbox("Trade during a fight", CanniStateConfig.GetInCombat())
        if inCombatClicked then
            CanniStateConfig.SetInCombat(inCombat)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("On is what this is worth most for: a fight is when the mana is actually being spent, and a healer that runs dry halfway through one is the thing this job prevents. It covers the group's fight rather than only one this character has engaged, so it works on a healer that never takes a target of its own. Off is for a character whose health is wanted for something else -- a tank, or anyone being hit -- though the health floor above is the finer answer to that.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.SeparatorText("Trades")
    ImGui.SameLine()
    CommonUI.HelpMarker("Tried in order, top to bottom: the first one ready and payable is used, then the state waits for it to finish before choosing again. Put the expensive ones first -- a slot the character has not got the health to pay for is passed over rather than ending the walk, so a big AA at the top and a small spell under it means the big one fires while there is health for it and the small one carries on afterwards. Anything that trades health for mana belongs here: a shaman's cannibalize and its AA, a magician's modulation rods, a manastone, a necromancer's Death Bloom. A lich, which drains for ten minutes rather than converting on the spot, is a buff and belongs on the Buff State page instead.")

    local actions = CanniStateConfig.GetActions()
    local availableActions = AvailableActions.new()
    -- what trades health for mana, found by what the spells actually do rather than by what the
    -- client files them under: no heading collects them, and the one that sounds right (Mana Flow)
    -- is full of the regen buffs that cost nothing. The whole book is a switch away in the picker
    -- for anything the effects missed, and the AA and clicky lists carry the rest of the family --
    -- the Cannibalization AA, a summoned rod, a manastone
    availableActions.spells = Spells.manaConversions
    availableActions.allSpells = Spells.all
    availableActions.aas = AAs.all
    availableActions.items = Items.all

    if ImGui.Button("Add##canniAction", 50, 23) then
        actions[#actions+1] = {}
    end

    local extras = {
        height = extrasHeight,
        draw = function(liveAction, shownAction) DrawCanniFields(liveAction, shownAction, canniState) end
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

return CanniStateMenu
