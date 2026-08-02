---@diagnostic disable: undefined-field
local Time = require("utils.Time.Time")

local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local CommonUI = require("cabby.ui.commonUI")
local CureTypes = require("cabby.actions.cureTypes")
local Curing = require("cabby.curing")
local HealStateConfig = require("cabby.configs.healStateConfig")
local Items = require("cabby.actions.items")
local Rezzes = require("cabby.actions.rezzes")
local Rezzing = require("cabby.rezzing")
local Roles = require("cabby.roles")
local Spells = require("cabby.actions.spells")

local HealStateMenu = {
    _ = {
        cures = nil,      -- what this character would answer each request with
        curesReadMs = 0
    }
}

local scopeOrder = {
    HealStateConfig.scopes.Any,
    HealStateConfig.scopes.Tank,
    HealStateConfig.scopes.Self,
    HealStateConfig.scopes.Others,
    HealStateConfig.scopes.Pet
}

local cureModeOrder = {
    HealStateConfig.cureModes.Off,
    HealStateConfig.cureModes.OutOfCombat,
    HealStateConfig.cureModes.Always
}

local rezModeOrder = {
    HealStateConfig.rezModes.Off,
    HealStateConfig.rezModes.OutOfCombat,
    HealStateConfig.rezModes.Always
}

---How long an answer to "what would I cure this with" is reused for.
---
---Working it out is a walk of the beneficial half of the book and the whole AA list, reading
---effects off each -- perfectly cheap once, and something no page should do sixty times a second
---while it is open. The answer only moves when the character levels or buys an AA.
local cureLookIntervalMs = 2000

---@return table cures { [type key] = { single = name|nil, group = name|nil, selfOnly = name|nil } }
local function getCures()
    local now = Time.current_time()
    if HealStateMenu._.cures == nil or now - HealStateMenu._.curesReadMs >= cureLookIntervalMs then
        HealStateMenu._.curesReadMs = now

        local cures = {}
        for _, cureType in ipairs(CureTypes.All()) do
            local single, group, selfOnly = CureTypes.Best(cureType)
            cures[cureType.key] = {
                single = single ~= nil and single:Name() or nil,
                group = group ~= nil and group:Name() or nil,
                selfOnly = selfOnly ~= nil and selfOnly:Name() or nil
            }
        end
        HealStateMenu._.cures = cures
    end

    return HealStateMenu._.cures
end

---How much room the per-slot heal controls need under the action row.
local extrasHeight = 26

---One of the two rez pickers.
---
---Every rez this character owns is offered, plus the worked-out answer at the top -- which is the
---default and is a real choice rather than an absence, so it says what it currently comes to right
---there in the label. A name that is set and not in this character's book is called out instead of
---quietly falling back, since that is exactly what a settings file copied between characters does.
---@param label string
---@param inCombat boolean which of the two settings this is
local function DrawRezPick(label, inCombat)
    local set = inCombat and HealStateConfig.GetBattleRezSpell() or HealStateConfig.GetRezSpell()
    local auto = HealStateConfig.AutoRez()
    local rez, isNamed, missing = Rezzing.RezFor(inCombat)

    local autoLabel = (inCombat and "Quickest I have" or "Best I have") ..
        (rez ~= nil and (" -- " .. Rezzes.Describe(rez)) or " -- nothing")

    ImGui.SetNextItemWidth(330)
    if ImGui.BeginCombo(label, isNamed and set or autoLabel) then
        local _, autoPressed = ImGui.Selectable(autoLabel, set == auto)
        if autoPressed then
            if inCombat then
                HealStateConfig.SetBattleRezSpell(auto)
            else
                HealStateConfig.SetRezSpell(auto)
            end
        end

        for _, known in ipairs(Rezzes.all) do
            local name = known.action:Name()
            local _, pressed = ImGui.Selectable(Rezzes.Describe(known), set == name)
            if pressed then
                if inCombat then
                    HealStateConfig.SetBattleRezSpell(name)
                else
                    HealStateConfig.SetRezSpell(name)
                end
            end
        end
        ImGui.EndCombo()
    end

    if missing ~= nil then
        ImGui.SameLine()
        ImGui.TextColored(1, 0.8, 0.2, 1, "[" .. missing .. "] is not in this character's book")
    end
end

---The class order: who is gone to first, and who a fight is interrupted for.
---
---One list read twice, the way the heal slots are one list read for several things -- the position
---is who goes first, and the box is whether a fight is interrupted for them -- so there is one thing
---to understand rather than two. There is no "rez this class at all" box: everybody on the list is
---rezzed once the fighting stops.
local function DrawRezClasses()
    local classes = HealStateConfig.GetRezClasses()

    local classFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner,
        ImGuiTableFlags.NoHostExtendX)
    if not ImGui.BeginTable("healRezClasses", 4, classFlags) then return end

    ImGui.TableSetupColumn("#", ImGuiTableColumnFlags.WidthFixed, 26)
    ImGui.TableSetupColumn("Class", ImGuiTableColumnFlags.WidthFixed, 60)
    ImGui.TableSetupColumn("In battle", ImGuiTableColumnFlags.WidthFixed, 80)
    ImGui.TableSetupColumn("Order", ImGuiTableColumnFlags.WidthFixed, 100)
    ImGui.TableHeadersRow()

    for index, entry in ipairs(classes) do
        ImGui.PushID(entry.class)
        ImGui.TableNextRow()

        ImGui.TableNextColumn()
        ImGui.Text(tostring(index))

        ImGui.TableNextColumn()
        ImGui.Text(entry.class)

        ImGui.TableNextColumn()
        local inCombat, inCombatClicked =
            ImGui.Checkbox("##incombat", HealStateConfig.GetRezClassEnabled(entry, true))
        if inCombatClicked then
            HealStateConfig.SetRezClassInCombat(entry.class, inCombat)
        end

        ImGui.TableNextColumn()
        if index == 1 then ImGui.BeginDisabled() end
        if ImGui.Button("Up", 40, 20) then
            HealStateConfig.MoveRezClass(index, -1)
        end
        if index == 1 then ImGui.EndDisabled() end

        ImGui.SameLine()
        if index == #classes then ImGui.BeginDisabled() end
        if ImGui.Button("Down", 50, 20) then
            HealStateConfig.MoveRezClass(index, 1)
        end
        if index == #classes then ImGui.EndDisabled() end

        ImGui.PopID()
    end

    ImGui.EndTable()
end

---What makes a heal slot a *heal* slot, drawn under the action itself: how hurt they have to be,
---and who it is for. What the heal can be aimed at is the spell's own business and is only
---reported -- along with the reason a slot will never fire, when there is one.
---@param liveAction Action what the controls here write to
---@param shownAction Action what the row is currently holding -- the staged pick while it is being
---edited -- which is what the spell is read from
---@param healState HealState
local function DrawHealFields(liveAction, shownAction, healState)
    local facts = healState.DescribeSlot(shownAction or liveAction)

    ImGui.SetNextItemWidth(90)
    local threshold, thresholdChanged = ImGui.DragInt("##threshold", HealStateConfig.GetThreshold(liveAction), 1, 1, 100)
    if thresholdChanged then
        HealStateConfig.SetThreshold(liveAction, threshold)
    end
    ImGui.SameLine()
    ImGui.Text("% and below")

    -- only the scopes this slot's spell can actually be given. A spell that lands on one kind of
    -- person has answered the question already, so the dial shows that answer and is not offered
    -- for editing -- rather than being hidden, which reads as "this heal is for nobody"
    local choices = {}
    for _, known in ipairs(scopeOrder) do
        if facts.scopes[known.value] then choices[#choices+1] = known end
    end

    if #choices > 0 then
        local decided = #choices == 1
        local scope = decided and choices[1].value or HealStateConfig.GetScope(liveAction)

        ImGui.SameLine()
        ImGui.SetNextItemWidth(110)
        if decided then ImGui.BeginDisabled() end
        if ImGui.BeginCombo("##scope", HealStateConfig.GetScopeDisplay(scope)) then
            for _, known in ipairs(choices) do
                local _, pressed = ImGui.Selectable(known.display, scope == known.value)
                if pressed then
                    HealStateConfig.SetScope(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        if decided then ImGui.EndDisabled() end
    end

    if facts.isGroup then
        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local groupMin, groupMinChanged = ImGui.DragInt("##groupmin", HealStateConfig.GetGroupMin(liveAction), 1, 1, 6)
        if groupMinChanged then
            HealStateConfig.SetGroupMin(liveAction, groupMin)
        end
        ImGui.SameLine()
        ImGui.Text("hurt")
        ImGui.SameLine()
        CommonUI.HelpMarker("This heal covers the whole group, so it is cast when at least this many of the people being watched are at or below the health above. Group heals are considered before single heals, unless someone is already below the emergency point.")
    end

    ImGui.SameLine()
    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end
    ImGui.TextDisabled(facts.aimText)
end

---@param healState HealState
function HealStateMenu.BuildMenu(healState)
    ImGui.Text("Heal State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", healState.IsEnabled())
    if enabledClicked then
        healState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("healStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(healState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last Heal")
        ImGui.TableNextColumn()
        ImGui.Text(healState.GetLastResult() or "<none yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("healSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local healGroup, healGroupClicked = ImGui.Checkbox("Watch group members", HealStateConfig.GetHealGroup())
        if healGroupClicked then
            HealStateConfig.SetHealGroup(healGroup)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Whether the rest of the group is somebody this character heals at all. On, everyone in the group window is watched and can be chosen for a heal; off, the only people watched are me and my pet, and a group-mate at 10% is left to somebody else. It is not about group heal *spells* -- one of those is chosen because enough of the people being watched are hurt, so switching this off shrinks what it is counting rather than stopping it. The Watching tab is the answer to what this is currently doing.")

        ImGui.SameLine()
        local healPets, healPetsClicked = ImGui.Checkbox("Watch my pet", HealStateConfig.GetHealPets())
        if healPetsClicked then
            HealStateConfig.SetHealPets(healPets)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Off by default: a pet is cheaper to summon than the mana spent keeping it up. A pet class that means to keep its own pet up turns this on -- while it is off the pet is not watched at all, so even a heal that can only land on a pet has nothing to fire for.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local emergency, emergencyChanged = ImGui.DragInt("Emergency at %", HealStateConfig.GetEmergencyPct(), 1, 1, 99)
        if emergencyChanged then
            HealStateConfig.SetEmergencyPct(emergency)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Below this, someone is in trouble rather than merely hurt. It does not choose a heal -- the slots below do that -- it decides what is worth throwing away a heal in progress for, it holds back group heals while somebody is about to die, and it is what curing waits for.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local cureMode = HealStateConfig.GetCureMode()
        ImGui.SetNextItemWidth(190)
        if ImGui.BeginCombo("Curing", HealStateConfig.GetCureModeDisplay(cureMode)) then
            for _, known in ipairs(cureModeOrder) do
                local _, pressed = ImGui.Selectable(known.display, cureMode == known.value)
                if pressed then
                    HealStateConfig.SetCureMode(known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Whether this character answers cure requests, and when. Somebody carrying a poison, disease, curse or corruption with more than a minute left on it asks the group for a cure -- every character does that, whether or not it can cure anything -- and this decides whether this one answers. Cures are cast ahead of ordinary heals, because a cure ends a cost instead of paying it back, and behind anybody below the emergency point. The Cures tab shows what would be cast for each kind and who is waiting.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local rezMode = HealStateConfig.GetRezMode()
        ImGui.SetNextItemWidth(190)
        if ImGui.BeginCombo("Rezzing", HealStateConfig.GetRezModeDisplay(rezMode)) then
            for _, known in ipairs(rezModeOrder) do
                local _, pressed = ImGui.Selectable(known.display, rezMode == known.value)
                if pressed then
                    HealStateConfig.SetRezMode(known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Whether this character rezzes the corpses lying around it, and when. Group members' corpses within " .. tostring(Rezzing.GetRadius()) .. " are rezzed without being asked; anybody else asks with rezme. Which rez, and who first, are on the Rezzes tab. Rezzing is the last thing this state does, behind every heal and every cure, because everybody alive comes first. It walks nobody anywhere: get back to the corpses first.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    if ImGui.BeginTabBar("Heal Tabs") then
        if ImGui.BeginTabItem("Heals") then
            ImGui.TextDisabled("Tried in order, top to bottom: the first heal that suits the most hurt person wins.")
            ImGui.SameLine()
            CommonUI.HelpMarker("Each row is a heal, the health it is for, and who it is for. A big heal on the tank at 85% goes above a small heal on anyone at 60%; the state walks the list from the top for whoever is worst off. Only memorized spells are used, so keep the ones you rely on on the spell bar.")

            local actions = HealStateConfig.GetActions()
            local availableActions = AvailableActions.new()
            -- what this character can heal with, discovered from the client: the spells the book
            -- files as heals or as invulnerabilities, plus AAs and clickies, which are as often
            -- the emergency button as any spell is. The rest of the beneficial half is a switch
            -- away in the picker, for a heal the game filed somewhere unexpected.
            availableActions.spells = Spells.heals
            availableActions.allSpells = Spells.beneficial
            availableActions.aas = AAs.all
            availableActions.items = Items.all

            if ImGui.Button("Add##healAction", 50, 23) then
                actions[#actions+1] = {}
            end

            for index, action in ipairs(actions) do
                if index % 2 == 0 then
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.1, 0.1, 0.1, 1)
                else
                    ImGui.PushStyleColor(ImGuiCol.ChildBg, 0.15, 0.15, 0.15, 1)
                end
                ImGui.PushID(action)
                ActionUI.ActionControl(action, actions, availableActions, {
                    height = extrasHeight,
                    draw = function(liveAction, shownAction) DrawHealFields(liveAction, shownAction, healState) end
                })
                ImGui.PopID()
                ImGui.PopStyleColor()
            end

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Cures") then
            ImGui.TextDisabled("Nothing to fill in: whoever needs one names the kind, and the best of that kind this character owns answers it.")
            ImGui.SameLine()
            CommonUI.HelpMarker("A cure has no slot list because it cannot have one. The person afflicted is the only one who can see it -- another player's debuffs are unreadable until they are targeted -- and they have no idea what anybody hearing them can cast. So they say what is on them and every listener answers with its own best, which is the one with the most counters rather than the highest rank. Whether this character answers at all is the Curing setting above.")

            local cures = getCures()
            local cureFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner)
            if ImGui.BeginTable("healCures", 3, cureFlags) then
                ImGui.TableSetupColumn("Kind", ImGuiTableColumnFlags.WidthFixed, 110)
                ImGui.TableSetupColumn("One at a time", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn("On the group", ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableHeadersRow()

                for _, cureType in ipairs(CureTypes.All()) do
                    local cure = cures[cureType.key] or {}
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    ImGui.Text(cureType.key)

                    ImGui.TableNextColumn()
                    if cure.single ~= nil then
                        ImGui.Text(cure.single)
                    elseif cure.selfOnly ~= nil then
                        ImGui.TextDisabled(cure.selfOnly .. " (only on me)")
                    else
                        ImGui.TextDisabled("nothing")
                    end

                    ImGui.TableNextColumn()
                    if cure.group ~= nil then
                        ImGui.Text(cure.group)
                    else
                        ImGui.TextDisabled("nothing")
                    end
                end

                ImGui.EndTable()
            end

            ImGui.Spacing()
            ImGui.SeparatorText("Waiting")
            local requests = healState.GetCureRequests()
            if #requests < 1 then
                ImGui.TextDisabled("Nobody has asked for a cure")
            else
                for _, request in ipairs(requests) do
                    ImGui.Text(request.name .. ": " .. request.typeKey ..
                        " -- " .. request.action:Name() ..
                        (request.casts > 0 and (", cast " .. tostring(request.casts) .. "x") or ""))
                end
            end
            ImGui.SameLine()
            CommonUI.HelpMarker("Worked through oldest first, skipping anybody out of range for now rather than holding the rest up for them. A request stays here until the affliction is actually off them -- one cure strips a fixed number of counters and a big one carries more than that -- and it is dropped when they stop repeating it, which they do every twenty seconds for as long as it is still on them.")

            ImGui.Spacing()
            ImGui.SeparatorText("On me")
            local afflictions = Curing.GetAfflictions()
            local anything = false
            for _, cureType in ipairs(CureTypes.All()) do
                local remaining = afflictions[cureType.key]
                if remaining ~= nil then
                    anything = true
                    local seconds = tostring(math.floor(remaining / 1000)) .. "s left"
                    if remaining >= Curing.WorthCuringMs() then
                        ImGui.Text(cureType.key .. ": " .. seconds)
                    else
                        ImGui.TextDisabled(cureType.key .. ": " .. seconds .. " -- too short to be worth curing")
                    end
                end
            end
            if not anything then
                ImGui.TextDisabled("Nothing on me")
            end
            ImGui.SameLine()
            CommonUI.HelpMarker("What this character is carrying that a cure would take off, and how long it has left. Anything over a minute is asked about on a channel, once and then every twenty seconds until it is gone -- turn that off with the callcure command. It is asked about whatever this page says: answering and asking are separate, because every class has to ask and only some can answer.")

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Rezzes") then
            ImGui.TextDisabled("Which rez to spend, and whose corpse to go to first.")
            ImGui.SameLine()
            CommonUI.HelpMarker("A rez says what it is worth right there in its effect -- the percentage of the lost experience it hands back -- and its cast time says whether it could survive a fight. Both are read off the spell, so leaving these on their worked-out answers is a real answer; naming one is for when the group knows which rez it wants spent. Whether any of this happens at all is the Rezzing setting above.")

            ImGui.Spacing()
            DrawRezPick("Out of a fight", false)
            DrawRezPick("In a fight", true)

            ImGui.Spacing()
            ImGui.SeparatorText("Who first")

            local tankFirst, tankFirstClicked =
                ImGui.Checkbox("The main tank, whatever their class", HealStateConfig.GetRezTankFirst())
            if tankFirstClicked then
                HealStateConfig.SetRezTankFirst(tankFirst)
            end
            ImGui.SameLine()
            CommonUI.HelpMarker("On, the main tank's corpse goes ahead of the class order below -- the role is the job, not the class holding it. It is also the one corpse allowed ahead of a heal: if the rez in force has no cast bar at all, the tank is rezzed even while somebody is below the emergency point, because that spends a global cooldown the heal would have spent anyway. A rez with any cast bar never gets that, however short it is.")

            ImGui.TextDisabled("Everybody here is rezzed once the fighting stops. In battle is who a fight is interrupted for.")
            DrawRezClasses()
            ImGui.SameLine()
            CommonUI.HelpMarker("One list read twice: where a class sits is the order corpses are gone to in, under the tank switch above, and the box is whether a fight is interrupted for them. It is about when, never about whether -- every class here is rezzed once the fighting stops, and rezzing off is how a character is told to leave corpses alone entirely. Out of a fight a rez costs time nobody is using; during one it costs a cast somebody alive may need, so a group that will break off for its cleric and nobody else clears the box for everybody else. All on to start with, since rezzing in battle is already behind its own switch above.")

            ImGui.Spacing()
            ImGui.SeparatorText("Right now")
            local notRezzing = Rezzing.ReasonNotRezzing()
            if notRezzing ~= nil then
                ImGui.TextColored(1, 0.8, 0.2, 1, "Not rezzing: " .. notRezzing)
            else
                ImGui.Text(Rezzing.Describe())
            end

            local order = Rezzing.GetOrder()
            if order ~= nil then
                ImGui.Text("Asked to rez: " .. order.name)
            end

            local lastRez = healState.GetLastRezResult()
            if lastRez ~= nil then
                ImGui.TextDisabled("Last: " .. lastRez)
            end

            ImGui.Spacing()
            ImGui.SeparatorText("Corpses in reach")
            local corpses = Rezzing.GetCorpses()
            if #corpses < 1 then
                ImGui.TextDisabled("None -- only corpses of group members within " ..
                    tostring(Rezzing.GetRadius()) .. " are looked at, and this walks nobody there")
            else
                for _, corpse in ipairs(corpses) do
                    local held = Rezzing.ReasonHeld(corpse)
                    local note = corpse.name .. " (" .. tostring(corpse.class or "?") .. ") -- " ..
                        tostring(math.floor(corpse.distance)) .. " away" ..
                        (corpse.isTank and " (tank)" or "") ..
                        (corpse.isOrdered and " (asked for)" or "")
                    if held ~= nil then
                        ImGui.TextDisabled(note .. " -- " .. held)
                    else
                        ImGui.Text(note)
                    end
                end
            end
            ImGui.SameLine()
            CommonUI.HelpMarker("Listed in the order they would be rezzed: whoever said rezme, then the main tank, then the class order above, then whoever is nearest. The class comes off the corpse itself, which is how it is known for somebody who released and is standing in another zone. A corpse this character has already cast a rez at is left alone for half a minute, because nothing comes back to say whether the offer was taken -- the corpse stays lying there either way. After three unanswered offers it is left alone entirely, and saying rezme is what starts it again.")

            ImGui.EndTabItem()
        end

        if ImGui.BeginTabItem("Watching") then
            local candidates = healState.GetCandidates()
            if #candidates < 1 then
                ImGui.TextDisabled("Nobody yet -- this fills in while the state is running")
            else
                local watchFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInner)
                if ImGui.BeginTable("healWatching", 3, watchFlags) then
                    ImGui.TableSetupColumn("Who", ImGuiTableColumnFlags.WidthFixed, 160)
                    ImGui.TableSetupColumn("Health", ImGuiTableColumnFlags.WidthFixed, 70)
                    ImGui.TableSetupColumn("Role", ImGuiTableColumnFlags.WidthStretch)
                    ImGui.TableHeadersRow()

                    for _, candidate in ipairs(candidates) do
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.Text(candidate.name)
                        ImGui.TableNextColumn()
                        ImGui.Text(tostring(math.floor(candidate.pct)) .. "%")
                        ImGui.TableNextColumn()
                        local role = candidate.isSelf and "me" or ""
                        if candidate.isTank then role = "tank" end
                        if candidate.isPet then role = "pet" end
                        ImGui.Text(role)
                    end

                    ImGui.EndTable()
                end
            end

            ImGui.Spacing()
            ImGui.TextDisabled("The tank is whoever holds that role in the group window.")
            local mainTank = Roles.GetMainTank()
            if mainTank == nil then
                ImGui.TextDisabled("Nobody is assigned Main Tank, so tank-scoped heals will not fire.")
            else
                ImGui.TextDisabled("Main Tank: " .. mainTank.name .. (Roles.IsMainTank() and " (me)" or ""))
            end

            ImGui.EndTabItem()
        end

        ImGui.EndTabBar()
    end
end

return HealStateMenu
