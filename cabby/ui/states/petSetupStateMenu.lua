---@diagnostic disable: undefined-field
local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local CommonUI = require("cabby.ui.commonUI")
local Items = require("cabby.actions.items")
local PetSetupStateConfig = require("cabby.configs.petSetupStateConfig")
local Spells = require("cabby.actions.spells")

local PetSetupStateMenu = {}

---How much room the per-slot controls need under the action row.
local extrasHeight = 28

---What a pet slot amounts to, drawn under the action itself. Nothing here is a control: whether
---a spell summons a pet is the spell's own business, and this row exists to say so -- a slot
---holding something that does not is otherwise a silent puzzle.
---@param liveAction Action
---@param shownAction Action what the row is currently holding, which is what the spell is read from
---@param petState PetSetupState
local function DrawPetFields(liveAction, shownAction, petState)
    local facts = petState.DescribeSlot(shownAction or liveAction, false)

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end

    -- what the world said the last time this one was tried, which is where a missing reagent
    -- turns up: a magician's elemental will not go off without malachite in the bags
    if facts.lastProblem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, "last try: " .. facts.lastProblem)
        return
    end

    ImGui.TextDisabled("summons a pet")
end

---What makes a gear slot a *gear* slot: how many of it this pet should end up with. What the
---slot conjures, and what it is called, are read off the spell and only reported.
---@param liveAction Action
---@param shownAction Action
---@param petState PetSetupState
local function DrawGearFields(liveAction, shownAction, petState)
    local facts = petState.DescribeSlot(shownAction or liveAction, true)

    ImGui.SetNextItemWidth(130)
    local count, countChanged = ImGui.DragInt("##count", PetSetupStateConfig.GetGearCount(liveAction), 0.1, 1, 4, "hand over %d")
    if countChanged then
        PetSetupStateConfig.SetGearCount(liveAction, count)
    end
    ImGui.SameLine()

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end

    if facts.lastProblem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, "last try: " .. facts.lastProblem)
        return
    end

    local what = facts.itemName or ("item " .. tostring(facts.itemId))
    ImGui.TextDisabled(what .. " -- " .. tostring(facts.given) .. " of " .. tostring(facts.wanted) .. " handed over")
end

---@param petState PetSetupState
---@param actions table the list being drawn
---@param isGear boolean
---@param availableActions AvailableActions
local function DrawList(petState, actions, isGear, availableActions)
    if ImGui.Button(isGear and "Add##petGearAction" or "Add##petAction", 50, 23) then
        actions[#actions+1] = {}
    end

    local extras = {
        height = extrasHeight,
        draw = function(liveAction, shownAction)
            if isGear then
                DrawGearFields(liveAction, shownAction, petState)
            else
                DrawPetFields(liveAction, shownAction, petState)
            end
        end
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

---@param petState PetSetupState
function PetSetupStateMenu.BuildMenu(petState)
    ImGui.Text("Pet Setup Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", petState.IsEnabled())
    if enabledClicked then
        petState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("petStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(petState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Pet")
        ImGui.TableNextColumn()
        local pet = petState.GetPet()
        if pet == nil then
            ImGui.Text("<none>")
        elseif pet.gearing then
            ImGui.Text(pet.name)
        elseif pet.wasHereAtStartup then
            ImGui.Text(pet.name .. " (already here when the script started -- left as it is)")
        else
            ImGui.Text(pet.name .. " (was already equipped when we found it)")
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last")
        ImGui.TableNextColumn()
        ImGui.Text(petState.GetLastResult() or "<nothing yet>")

        local request = petState.GetRequest()
        if request ~= nil then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.Text("Asked to gear")
            ImGui.TableNextColumn()
            ImGui.Text(request.name .. " (" .. request.speaker .. "'s)")
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("petSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local summoning, summoningClicked = ImGui.Checkbox("Summon the pet", PetSetupStateConfig.GetSummoning())
        if summoningClicked then
            PetSetupStateConfig.SetSummoning(summoning)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("On, a pet that dies or is let go is replaced with the first ready entry on the Pet tab -- a few seconds later, so letting one go by hand is not undone on the spot.")

        ImGui.SameLine()
        local gearing, gearingClicked = ImGui.Checkbox("Gear the pet", PetSetupStateConfig.GetGearing())
        if gearingClicked then
            PetSetupStateConfig.SetGearing(gearing)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("On, everything on the Gear tab is conjured and handed to the pet, in order, once there is a pet to hand it to.")

        ImGui.SameLine()
        local inCombat, inCombatClicked = ImGui.Checkbox("During combat", PetSetupStateConfig.GetInCombat())
        if inCombatClicked then
            PetSetupStateConfig.SetInCombat(inCombat)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Off, nothing is summoned or handed over while this character is fighting, and what is in the air is called off when a fight starts.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- neither of these talks to the client, so they are safe from a render callback: they
        -- write down an order, and the state carries it out on its next pass
        if ImGui.Button("Summon a pet now", 150, 21) then
            petState.OrderSummon()
        end
        ImGui.SameLine()
        if ImGui.Button("Gear the pet now", 150, 21) then
            petState.OrderGear()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Forgets what this pet has been handed and gives it the whole list again -- which is also how a pet that was already standing here when the script started gets equipped, since one we did not summon is left as we found it.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    if ImGui.BeginTabBar("Pet Tabs") then
        if ImGui.BeginTabItem("Pet") then
            ImGui.TextDisabled("Cast in order, top to bottom: the first one ready is the pet that gets summoned.")
            ImGui.SameLine()
            CommonUI.HelpMarker("Each row is something that summons a pet -- a spell, an AA or a clicky. Switching a row off is how a magician picks today's elemental without deleting the others. Only memorized spells are used, so keep the one you rely on on the spell bar. Most pet spells eat a component every cast (malachite for a magician's elementals, a bone chip for the undead ones): without one in the bags the cast is refused, and the row says so.")

            local availableActions = AvailableActions.new()
            -- what this character can summon a pet with: read off the spells' own effects rather
            -- than off a heading, with the rest of the beneficial half a switch away in the
            -- picker for anything the effects missed
            availableActions.spells = Spells.petSummons
            availableActions.allSpells = Spells.beneficial
            availableActions.aas = AAs.all
            availableActions.items = Items.all

            DrawList(petState, PetSetupStateConfig.GetActions(), false, availableActions)

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Gear") then
            ImGui.TextDisabled("Conjured and handed over in order, top to bottom, once there is a pet.")
            ImGui.SameLine()
            CommonUI.HelpMarker("Each row is something that conjures an item, plus how many of that item the pet should end up with -- two for a pet that dual wields. What the spell makes is read off the spell itself. What a pet has been given is remembered for as long as it is the same pet: a pet that dies and is summoned again is equipped again.")

            local availableActions = AvailableActions.new()
            availableActions.spells = Spells.itemSummons
            availableActions.allSpells = Spells.beneficial
            availableActions.aas = AAs.all
            availableActions.items = Items.all

            DrawList(petState, PetSetupStateConfig.GetGearActions(), true, availableActions)

            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

return PetSetupStateMenu
