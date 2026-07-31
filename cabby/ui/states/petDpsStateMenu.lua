---@diagnostic disable: undefined-field
local Combat = require("cabby.combat")
local CommonUI = require("cabby.ui.commonUI")
local Pet = require("cabby.pet")
local PetDpsStateConfig = require("cabby.configs.petDpsStateConfig")

local PetDpsStateMenu = {}

---The order the dials are offered in: no opinion first, since that is what they ship as and what
---a player who flips these by hand wants left alone, then the answer worked out for you, then the
---two that are a standing order.
local postureOrder = {
    PetDpsStateConfig.postures.Leave,
    PetDpsStateConfig.postures.Auto,
    PetDpsStateConfig.postures.On,
    PetDpsStateConfig.postures.Off
}

---What the pet is for, in the order the two are offered: what it has always done first.
local jobOrder = {
    PetDpsStateConfig.jobs.Fight,
    PetDpsStateConfig.jobs.Protect
}

---What `Automatic` means, said where the dial that offers it is. Per switch, because the answer is
---a different question for each one and a shared sentence would be a vague one.
local autoAbout = {
    taunt = "Answered from the group every pass instead of set: off while the group's main tank is on what the pet is on, since a taunting pet there pulls the mob off the character built to hold it -- and on when there is no main tank at all, or the tank is demonstrably on something else and the pet is holding its own mob. A tank whose target this client cannot see (it calls no assist and does not hold the assist role either) is assumed to have it, because ripping a mob off a warrior is the expensive way to be wrong."
}

---@param facts table one PetToggleFacts from PetDpsState.DescribeToggles
---@param heard boolean whether this pet takes the toggles at all
local function DrawToggleRow(facts, heard)
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ImGui.Text(facts.display)

    ImGui.TableNextColumn()
    ImGui.SetNextItemWidth(120)
    ImGui.PushID(facts.key)
    if ImGui.BeginCombo("##posture", PetDpsStateConfig.GetPostureDisplay(facts.want)) then
        for _, known in ipairs(postureOrder) do
            -- a dial only offers the answer it has: nothing works out a hold or a focus for you
            if known.value ~= PetDpsStateConfig.postures.Auto.value
                or PetDpsStateConfig.SupportsAuto(facts.key) then
                local _, pressed = ImGui.Selectable(known.display, facts.want == known.value)
                if pressed then
                    PetDpsStateConfig.SetPosture(facts.key, known.value)
                end
            end
        end
        ImGui.EndCombo()
    end
    ImGui.PopID()

    ImGui.TableNextColumn()
    -- where it actually stands, which is the whole reason these are dials rather than checkboxes:
    -- the client keeps them per pet, and a new pet arrives with all four off
    local now = facts.is and "now on" or "now off"
    if facts.is == nil then
        ImGui.TextDisabled("no pet")
    elseif not heard then
        -- the dial is still worth setting -- the next pet may well take it -- but what it says is
        -- not happening to this one, and a page that quietly showed the wrong switch would be read
        -- as this script having flipped it
        ImGui.TextColored(1, 0.8, 0.2, 1, now .. " -- this pet does not take the switches")
    elseif facts.taken then
        -- the job has this switch, which is the one case where the dial on the left is not what is
        -- happening -- so it is the one that is said in colour rather than in grey
        ImGui.TextColored(0.4, 0.8, 1, 1, now .. " -- taken by the protect job")
    elseif facts.borrowed ~= nil then
        ImGui.TextColored(0.4, 0.8, 1, 1, now .. " -- going back to " ..
            (facts.borrowed and "on" or "off") .. " after the peel")
    elseif facts.graced then
        ImGui.TextColored(1, 0.8, 0.2, 1, "flipped by hand -- leaving it for a moment")
    elseif facts.want == PetDpsStateConfig.postures.Auto.value then
        -- the answer *and* why it is that: a dial nobody can see the reasoning behind is a dial
        -- nobody trusts with their pet
        ImGui.TextDisabled(now .. " -- " ..
            (facts.why or (facts.wanted == nil and "nothing to judge yet" or (facts.wanted and "on" or "off"))))
    else
        ImGui.TextDisabled(now)
    end

    ImGui.TableNextColumn()
    local about = facts.about
    if PetDpsStateConfig.SupportsAuto(facts.key) and autoAbout[facts.key] ~= nil then
        about = about .. "\n\nAutomatic: " .. autoAbout[facts.key]
    end
    CommonUI.HelpMarker(about)
end

---@param petDpsState PetDpsState
function PetDpsStateMenu.BuildMenu(petDpsState)
    ImGui.Text("Pet DPS Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    local enabled, enabledClicked = ImGui.Checkbox("Enabled", petDpsState.IsEnabled())
    if enabledClicked then
        petDpsState.SetEnabled(enabled)
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local statusFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("petDpsStatus", 2, statusFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")
        ImGui.TableNextColumn()
        ImGui.Text(petDpsState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Fighting")
        ImGui.TableNextColumn()
        ImGui.Text(Combat.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Pet")
        ImGui.TableNextColumn()
        if Pet.GetId() == nil then
            ImGui.Text("<none>")
        else
            local on = Pet.GetTargetName()
            -- what kind of pet it is belongs beside its name, because it decides whether anything
            -- else on this page means anything at all
            ImGui.Text(Pet.GetName() .. " (" .. tostring(Pet.DescribeKind()) .. ")" ..
                (on ~= nil and (" -- on " .. on) or ""))
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Last")
        ImGui.TableNextColumn()
        ImGui.Text(petDpsState.GetLastResult() or "<nothing yet>")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("petDpsSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        -- what the pet is *for*, above the settings about how it does it
        ImGui.SetNextItemWidth(180)
        if ImGui.BeginCombo("Job", PetDpsStateConfig.GetJobDisplay(PetDpsStateConfig.GetJob())) then
            for _, known in ipairs(jobOrder) do
                local _, pressed = ImGui.Selectable(known.display, PetDpsStateConfig.GetJob() == known.value)
                if pressed then
                    PetDpsStateConfig.SetJob(known.value)
                end
            end
            ImGui.EndCombo()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("What the pet is for. Fighting keeps it on whatever this character is fighting. Protecting puts one thing above that: a mob actually coming for you (the top of its hate list, the same reading the defend report uses) is taken off you first -- the pet is sent at it with taunt on, moves to the next one that is on you when that one has turned round, and goes back to the fight when nothing is. While it is peeling, taunt and focus are the job's rather than the dials' below, and a switch you told this script to leave alone is put back where it was found afterwards.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local sendPct, sendChanged = ImGui.DragInt("Send in below %", PetDpsStateConfig.GetSendPct(), 1, 1, 100)
        if sendChanged then
            PetDpsStateConfig.SetSendPct(sendPct)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("The pet is held back until what this character is fighting has dropped to this health, which gives whoever is tanking a moment to get a hold of it first. 100 sends the pet in as soon as there is a fight, which is what most pet classes want.")

        ImGui.SameLine()
        -- this only writes down an order -- the state carries it out on its next pass -- so it is
        -- safe from a render callback, where a game command is the crash-to-desktop hazard
        if ImGui.Button("Send the pet in now", 150, 21) then
            petDpsState.OrderAttack()
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Sends the pet at what this character is fighting whatever the health dial says. It waits fifteen seconds for something to send it at, and then stops being an order.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    ImGui.TextDisabled("How the pet is set up to fight. The client keeps these per pet, so a new one arrives with all four off.")
    ImGui.SameLine()
    CommonUI.HelpMarker("Left alone is this script having no opinion, which is not the same as an opinion that the switch should be off: set one to On or Off and it is a standing order, put back whenever the pet is found disagreeing with it. A switch flipped by hand is left standing for fifteen seconds first. Taunt also offers Automatic, which answers it from the group -- off while the main tank is on what the pet is on, on when nobody else is holding it.")

    -- said once, above the four rows, rather than four times inside them
    local takes = Pet.TakesOrders()
    if Pet.GetId() ~= nil and takes.why ~= nil then
        ImGui.TextColored(1, 0.8, 0.2, 1, "This pet: " .. takes.why)
        ImGui.SameLine()
        CommonUI.HelpMarker("An enchanter's animation is a pet in every way except that it takes no orders -- it is not sent in, it is not called off, and its four switches cannot be flipped from here. The Animation Empathy alternate ability is the only thing that changes that: rank 2 lets it be sent in, rank 3 buys back off and the switches. A charmed pet has none of this trouble and takes every order an elemental would.")
    end

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    local toggleFlags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    if ImGui.BeginTable("petDpsToggles", 4, toggleFlags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthFixed, 130)
        ImGui.TableSetupColumn("col3", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("col4", ImGuiTableColumnFlags.WidthFixed, 30)

        for _, facts in ipairs(petDpsState.DescribeToggles()) do
            DrawToggleRow(facts, takes.postures)
        end

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()
end

return PetDpsStateMenu
