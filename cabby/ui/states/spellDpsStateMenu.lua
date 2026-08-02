---@diagnostic disable: undefined-field
local mq = require("mq")

local AAs = require("cabby.actions.aas")
local ActionUI = require("cabby.ui.actions.actionUI")
local AvailableActions = require("cabby.actions.availableActions")
local Combat = require("cabby.combat")
local CombatConfig = require("cabby.configs.combatConfig")
local CommonUI = require("cabby.ui.commonUI")
local Cons = require("cabby.cons")
local Items = require("cabby.actions.items")
local Roles = require("cabby.roles")
local SpellDpsStateConfig = require("cabby.configs.spellDpsStateConfig")
local Spells = require("cabby.actions.spells")

local SpellDpsStateMenu = {}

local scopeOrder = {
    SpellDpsStateConfig.scopes.Any,
    SpellDpsStateConfig.scopes.Tank,
    SpellDpsStateConfig.scopes.Self,
    SpellDpsStateConfig.scopes.Others,
    SpellDpsStateConfig.scopes.Pet
}

---Earliest in a fight first, which is the order they are being chosen between in.
local timingOrder = {
    SpellDpsStateConfig.timings.Always,
    SpellDpsStateConfig.timings.Hurt,
    SpellDpsStateConfig.timings.Fleeing
}

---How much room the per-slot rotation controls need under the action row.
local extrasHeight = 26

---What a rotation slot needs saying about it beyond which spell it is: how much of a fight it is
---worth using on, who it is for when it is cast on somebody rather than at what we are fighting,
---and when in a fight it has its moment when it is aimed at the mob. What it can be aimed at is the
---spell's own business and is only reported -- along with the reason a slot will never fire, when
---there is one.
---@param liveAction Action what the controls here write to
---@param shownAction Action what the row is currently holding -- the staged pick while it is being
---edited -- which is what the spell is read from
---@param spellDpsState SpellDpsState
local function DrawDpsFields(liveAction, shownAction, spellDpsState)
    local facts = spellDpsState.DescribeSlot(shownAction or liveAction)

    -- how much of a fight it has to be, which is the coarsest question here and the only one both
    -- halves of the list are asked: everything after it is about *how* the slot is aimed, and this
    -- is about whether the fight is worth it at all
    if facts.conable then
        local con = SpellDpsStateConfig.GetMinCon(liveAction)

        ImGui.SetNextItemWidth(105)
        if ImGui.BeginCombo("##con", Cons.ThresholdDisplay(con)) then
            for _, known in ipairs(Cons.ladder) do
                local _, pressed = ImGui.Selectable(Cons.ThresholdDisplay(known.value), con == known.value)
                if pressed then
                    SpellDpsStateConfig.SetMinCon(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("How much of a fight the mob has to be before this slot is worth using. Any con is everything, which is what a slot does until it is told otherwise; above that it holds back, and what it holds back is the effort -- a four second cast, an item on a long timer, the mana in a damage shield -- for the pulls that are actually going to be a fight. It is read off the mob the cast is aimed at, and off what we are fighting for a shield, since how much trouble we are in is a fact about the mob and not about whoever ends up wearing it. A mob the client will not con counts as not tough enough rather than as tough enough, so nothing expensive goes out on a guess. It only ever narrows: the slot still has to come up in the order and get past everything else.")
        ImGui.SameLine()
    end

    -- only the scopes this slot's spell can actually be given. A spell that lands on one kind of
    -- person has answered the question already, so the dial shows that answer and is not offered
    -- for editing -- rather than being hidden, which reads as "this is for nobody". A spell aimed
    -- at what we are fighting has nobody to choose between at all, and gets no dial.
    local choices = {}
    for _, known in ipairs(scopeOrder) do
        if facts.scopes[known.value] then choices[#choices+1] = known end
    end

    if #choices > 0 then
        local decided = #choices == 1
        local scope = decided and choices[1].value or SpellDpsStateConfig.GetScope(liveAction)

        ImGui.SetNextItemWidth(110)
        if decided then ImGui.BeginDisabled() end
        if ImGui.BeginCombo("##scope", SpellDpsStateConfig.GetScopeDisplay(scope)) then
            for _, known in ipairs(choices) do
                local _, pressed = ImGui.Selectable(known.display, scope == known.value)
                if pressed then
                    SpellDpsStateConfig.SetScope(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        if decided then ImGui.EndDisabled() end
        ImGui.SameLine()
    end

    -- when in a fight, for the half of the list that is pointed at the mob. A nuke has nothing to
    -- say here and sits on the default; a debuff that leaves something behind is the reason the
    -- dial exists, and it is the same spell wanted at three different moments
    if facts.timed then
        local timing = SpellDpsStateConfig.GetTiming(liveAction)

        ImGui.SetNextItemWidth(130)
        if ImGui.BeginCombo("##when", SpellDpsStateConfig.GetTimingDisplay(timing)) then
            for _, known in ipairs(timingOrder) do
                local _, pressed = ImGui.Selectable(known.display, timing == known.value)
                if pressed then
                    SpellDpsStateConfig.SetTiming(liveAction, known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()

        if timing == SpellDpsStateConfig.timings.Hurt.value then
            ImGui.SetNextItemWidth(90)
            local pct, pctChanged = ImGui.DragInt("##whenpct", SpellDpsStateConfig.GetTimingPct(liveAction), 1, 1, 100)
            if pctChanged then
                SpellDpsStateConfig.SetTimingPct(liveAction, pct)
            end
            ImGui.SameLine()
            ImGui.Text("% and below")
            ImGui.SameLine()
        end

        CommonUI.HelpMarker("When this one has its moment, on top of its place in the order. Right away is the usual answer, and it is also all a debuff needs to be kept up: something that leaves an effect behind is not cast again while that effect is still on the mob, so it goes back up when it fades and not before. Once it is hurt saves it for the end of a fight -- a root or a snare kept back for the mob that is about to run. Once it runs waits for it to actually turn and go, which is read from the mob moving while pointed away from us, since the client has no flag for it. Two slots can hold the same spell with different answers, and the first whose moment has come is the one that fires.")
        ImGui.SameLine()
    end

    -- how many, for the debuff half of the list. Read and written on the live action like the
    -- dials beside it: it is something you reach for when the pull turns out to be three mobs.
    local spread = false
    if facts.spreadable then
        local pressed
        spread, pressed = ImGui.Checkbox("Every mob", SpellDpsStateConfig.GetSpread(liveAction))
        if pressed then
            SpellDpsStateConfig.SetSpread(liveAction, spread)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Put this on everything in the fight, not just on the one we are killing. The rotation does not move past this slot to the next action while any mob still lacks it, which is the point: a slow or a tash on the second mob is worth more than another nuke on the first. They are taken in turn as the gem comes up -- what we are killing first, then the rest -- and one that cannot be cast at right now (out of range, out of sight) is passed over rather than waited for. The fight is what is on your extended target window plus anything the group has called a (defend) on, so an add beating on the healer counts even though nothing is coming for you. Off, the slot is aimed only at what we are fighting.")
        ImGui.SameLine()
    end

    if facts.problem ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, facts.problem)
        return
    end
    ImGui.TextDisabled(spread and "at every mob in the fight" or facts.aimText)
end

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
            Combat.CallOff("the Back Off button")
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

        ImGui.SameLine()
        local callDefend, callDefendClicked = ImGui.Checkbox("Call Defend", CombatConfig.GetCallDefend())
        if callDefendClicked then
            CombatConfig.SetCallDefend(callDefend)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Anything actually coming for this character -- the top of a mob's hate list -- that nobody has yet called out is announced once as a (defend <id>) line, and the group's Main Tank engages it as soon as it is not already fighting something. Every character remembers the ids already called, its own and everyone else's, so one line covers a mob for as long as it lives in this zone -- bouncing between the tank and its victims is never re-announced. Its death, a zone, or a flee clears its entry. The fight the group was already put on is not reported, and the main tank itself never reports. Speaks over bc unless /speak defend says otherwise.")

        ImGui.SameLine()
        local easeOff, easeOffClicked = ImGui.Checkbox("Ease Off", CombatConfig.GetEaseOff())
        if easeOffClicked then
            CombatConfig.SetEaseOff(easeOff)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Stops hurting the mob once we have pulled it off the group's Main Tank -- it is coming for us and the tank should have it. Everything in the rotation aimed at the mob holds, exactly as Start below % holds it before the fight has settled, and a damage shield on somebody still goes up. Melee, where this character has any, drops the swing and its ability lists. Casting resumes the pass the tank is back on top of the mob's hate list. Nothing is eased off by the Main Tank itself, for a group that has named no tank, or for a mob the tank is on something else instead of -- that one is ours, and Call Defend is what is said about it.")

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
    CommonUI.HelpMarker("Tried in order, top to bottom: the first one ready is cast, then the state waits for it to finish before choosing again. Every slot says how much of a fight it is worth using on, which is how the expensive half of a rotation is kept for the pulls that need it and skipped on the ones that do not. A slot aimed at what we are fighting says when in a fight its moment is -- right away, once the mob is hurt, or once it turns and runs -- which is how the same root is a fight-opener on one slot and a runner-stopper on another, and a debuff can also say it belongs on every mob in the fight rather than only on the one being killed, in which case nothing below it is reached until they all have it. A damage shield is not aimed at the mob, so a slot holding one asks who it is for instead, the way a heal slot does, and is left alone once it is up on them. Only memorized spells are used, so keep the rotation on the spell bar. For anything more specific than that -- holding while the tank is low, saving a nuke for a named -- put it in a slot's LUA expression.")

    local actions = SpellDpsStateConfig.GetActions()
    local availableActions = AvailableActions.new()
    -- what damage is done with: what you point at something you are fighting to hurt it -- direct
    -- damage and the detrimental utility filed alongside it -- and the damage shields you put on
    -- somebody instead, which are damage filed under a buff heading. Plus the AAs and clickies
    -- that do either job. The rest of the book is a switch away in the picker, for something the
    -- headings missed.
    availableActions.spells = Spells.damage
    availableActions.allSpells = Spells.all
    availableActions.aas = AAs.all
    availableActions.items = Items.all

    if ImGui.Button("Add##spellDpsAction", 50, 23) then
        actions[#actions+1] = {}
    end

    local extras = {
        height = extrasHeight,
        draw = function(liveAction, shownAction) DrawDpsFields(liveAction, shownAction, spellDpsState) end
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

return SpellDpsStateMenu
