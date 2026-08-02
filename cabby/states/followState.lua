local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local StringUtils = require("utils.StringUtils.StringUtils")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CommonUI = require("cabby.ui.commonUI")
local Menu = require("cabby.ui.menu")
local Speak = require("cabby.commands.speak")
local Travel = require("cabby.travel")
local TravelConfig = require("cabby.configs.travelConfig")
local UserInput = require("cabby.utils.userinput")

---The order surface for going places, and the chain position the going runs at.
---
---The machinery itself -- the follow order, the trail-walking, the anchor and the zone-line
---follow-through procedures -- lives in `cabby.travel`, because travel mode (flee)
---drives the same machinery from the passive band and no state may read another. What is left
---here is what makes following a *state*: the commands that take the orders, the page that shows
---them, and this band in the chain -- following happens with the frames healing and fighting do
---not want, which is exactly what the follow band says.
---@class FollowState : BaseState
local FollowState = {
    key = "FollowState",
    eventIds = {
        followMe = "followme",
        followTarget = "followtarget",
        stopFollow = "stopfollow",
        moveToMe = "m2m",
        clickZone = "clickzone",
        anchor = "anchor"
    },
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(FollowState.key, str)
end

---Begin following whatever this character has targeted.
---
---This is (followme) turned around: the order comes from the character that will do the
---following rather than from the one being followed, so no speaker is needed and nothing is
---said. That is what makes follow reachable to someone playing this character themselves --
---a hotbar button running `/cself followtarget`, or the button on the Follow State page.
---
---Anything that can be targeted can be followed -- npcs, pets, mercenaries, a corpse. Only a
---player is followed by name and so waited on across a zone or a death; everything else is
---followed as the one spawn it is, and the follow ends when that spawn does.
---
---Safe to call from a render callback. Nothing here talks to the client; the follow itself is
---started by whichever state drives the travel core in the main loop.
---@return string? refusal why nothing happened, when there is nothing here to follow
function FollowState.StartFollowingTarget()
    if not FollowState.IsEnabled() then
        return "My follow state is turned off, so I cannot follow anyone"
    end

    local target = mq.TLO.Target
    local targetId = target.ID() or 0
    if targetId <= 0 then
        return "I have nothing targeted to follow"
    end

    if targetId == (mq.TLO.Me.ID() or 0) then
        return "I cannot follow myself"
    end

    local name = target.CleanName()
    if name == nil or name == "" then
        return "I cannot make out my target's name"
    end

    DebugLog("Activating followtarget of [" .. name .. "]")
    -- a player is still themselves after a zone, so hold them by name; anything else only ever
    -- exists as this spawn (see cabby.travel)
    Travel.SetFollowOrder(name, target.Type() == "PC" and 0 or targetId, FollowState.eventIds.followTarget)
    return nil
end

---Stop travelling -- end the follow and release the anchor -- handing back the movement we were
---using and leaving a move somebody else has since started alone.
---
---Both orders go because only one of them is ever standing (they cancel each other), so being
---told to stop is not a question of which one was meant: a character parked on an anchor that
---only ended its follow would walk straight back to the spot it was just told to leave.
---
---Safe to call from a render callback, same as StartFollowingTarget.
function FollowState.StopFollowing()
    Travel.ClearOrders()
end

---Whoever this character was told to follow, whether or not they are in the zone right now.
---@return string name "" when no follow order is standing
function FollowState.GetFollowTarget()
    return Travel.GetFollowTarget()
end

---@diagnostic disable-next-line: duplicate-set-field
function FollowState.Init()
    if not FollowState._.isInit then
        local followMeDocs = ChelpDocs.new(function() return {
            "(followme) Tells listener(s) to begin autofollow on speaker"
        } end )
        local function event_FollowMe(_, speaker)
            if Commands.GetCommandOwners(FollowState.eventIds.followMe):HasPermission(speaker) then
                DebugLog("Activating followme of speaker [" .. speaker .. "]")
                Travel.SetFollowOrder(speaker, 0, FollowState.eventIds.followMe)
            else
                DebugLog("Ignoring followme of speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.followMe, event_FollowMe, followMeDocs):ActsOnSpeaker())

        local followTargetDocs = ChelpDocs.new(function() return {
            "(followtarget) Tells listener(s) to begin autofollow on whatever they have targeted",
            " -- Anything in the zone will do; following anything but a player ends when it dies or despawns"
        } end )
        local function event_FollowTarget(line, speaker)
            if not Commands.GetCommandOwners(FollowState.eventIds.followTarget):HasPermission(speaker) then
                DebugLog("Ignoring followtarget of speaker [" .. speaker .. "]")
                return
            end

            -- answered back where it was asked: our own console for a button press or /cself,
            -- the channel it was spoken on for an order given to a group of us
            local refusal = FollowState.StartFollowingTarget()
            if refusal ~= nil then
                Speak.Respond(line, speaker, refusal)
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.followTarget, event_FollowTarget, followTargetDocs))

        local stopFollowDocs = ChelpDocs.new(function() return {
            "(stopfollow) Tells listener(s) to stop autofollow",
            " -- Also releases any anchor they are holding"
        } end )
        local function event_StopFollow(_, speaker)
            if Commands.GetCommandOwners(FollowState.eventIds.stopFollow):HasPermission(speaker) then
                DebugLog("Stopping follow of speaker [" .. speaker .. "]")
                FollowState.StopFollowing()
            else
                DebugLog("Ignoring stopfollow of speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.stopFollow, event_StopFollow, stopFollowDocs))

        local mtomDocs = ChelpDocs.new(function() return {
            "(m2m) Tells listener(s) to move to speaker once"
        } end )
        local function event_MoveToMe(_, speaker)
            if Commands.GetCommandOwners(FollowState.eventIds.moveToMe):HasPermission(speaker) then
                DebugLog("Moving to speaker [" .. speaker .. "]")
                Movement.StopFor(FollowState.key)
                local spawnId = mq.TLO.Spawn("pc radius 200 " .. speaker).ID()
                if spawnId ~= nil and spawnId > 0 then
                    Movement.MoveToSpawn(spawnId, { owner = FollowState.key })
                else
                    Commands.GetCommandSpeak(FollowState.eventIds.moveToMe):speak("M2m target [" .. speaker .. "] out of range, aborting...")
                end
                -- a one-shot move cancels the standing orders; the task itself is the movement
                -- service's from here
                Travel.Reset()
            else
                DebugLog("Ignoring move to speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.moveToMe, event_MoveToMe, mtomDocs):ActsOnSpeaker())

        local clickZoneDocs = ChelpDocs.new(function() return {
            "(clickzone) Tells listener(s) to click to zone"
        } end )
        local function event_ClickZone(_, speaker)
            if Commands.GetCommandOwners(FollowState.eventIds.clickZone):HasPermission(speaker) then
                DebugLog("Clickzone speaker [" .. speaker .. "]")
                Travel.BeginClickZone()
            else
                DebugLog("Ignoring clickzone speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.clickZone, event_ClickZone, clickZoneDocs))

        local anchorDocs = ChelpDocs.new(function() return {
            "(anchor) Tells listener(s) to anchor to speaker's current location",
            " -- to disable, use: anchor off"
        } end )
        local function event_Anchor(_, speaker, args)
            args = StringUtils.Split(StringUtils.TrimFront(args))

            if Commands.GetCommandOwners(FollowState.eventIds.anchor):HasPermission(speaker) then
                DebugLog("Anchor speaker [" .. speaker .. "]")

                -- disable anchor
                if #args == 1 and args[1]:lower() == "off" then
                    Travel.ClearAnchor()
                else
                    local spawn = mq.TLO.Spawn("pc radius 200 " .. speaker)
                    if (spawn.ID() or 0) > 0 then
                        Travel.SetAnchor(spawn.Y(), spawn.X())
                    else
                        Commands.GetCommandSpeak(FollowState.eventIds.anchor):speak("Anchor target [" .. speaker .. "] out of range, aborting...")
                    end
                end
            else
                DebugLog("Ignoring anchor speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.anchor, event_Anchor, anchorDocs)
            :WithArgs({ required = false, hint = "off to release the anchor" }))

        if Global.configStore:GetConfigRoot()[FollowState.key] == nil then
            Global.configStore:GetConfigRoot()[FollowState.key] = {}
            Global.configStore:SaveConfig()
        end
        if Global.configStore:GetConfigRoot()[FollowState.key].enabled == nil then
            Global.configStore:GetConfigRoot()[FollowState.key].enabled = true
            Global.configStore:SaveConfig()
        end

        Travel.Reset()
        Menu.RegisterState(FollowState)

        FollowState._.isInit = true
    end
end

---One pass: carry out whatever movement order is standing, at this band.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function FollowState.Go()
    return Travel.Drive()
end

---@return string description of what this state is doing, for the page and /state
function FollowState.Describe()
    return Travel.Describe()
end

---@diagnostic disable-next-line: duplicate-set-field
function FollowState.IsEnabled()
    return Global.configStore:GetConfigRoot()[FollowState.key] ~= nil and UserInput.IsTrue(Global.configStore:GetConfigRoot()[FollowState.key].enabled)
end

---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
function FollowState.SetEnabled(isEnabled)
    Global.configStore:GetConfigRoot()[FollowState.key].enabled = isEnabled
    Global.configStore:SaveConfig()
    print("FollowState is Enabled: [" .. tostring(isEnabled) .. "]")
end

---@diagnostic disable-next-line: duplicate-set-field
function FollowState.BuildMenu()
    local width = ImGui.GetContentRegionAvail()

    ImGui.Text("Follow State Status")

    ImGui.SameLine(math.max(width - 68, 200))
    ---@type boolean
    local clicked, result
    result, clicked = ImGui.Checkbox("Enabled", FollowState.IsEnabled())
    if clicked then
        FollowState.SetEnabled(result)
    end

    local anchor = Travel.GetAnchor()
    local followTarget = FollowState.GetFollowTarget()

    local tableSorting_flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    if ImGui.BeginTable("t1", 2, tableSorting_flags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")

        ImGui.TableNextColumn()
        ImGui.Text(FollowState.Describe())

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Anchor Loc (x,y)")

        ImGui.TableNextColumn()
        ImGui.Text(tostring(math.floor(anchor.x * 100) / 100) .. ", " .. tostring(math.floor(anchor.y * 100) / 100))

        ImGui.TableNextColumn()
        ImGui.Text("Follow Target")

        ImGui.TableNextColumn()
        ImGui.Text(followTarget)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Hold Distance")

        ImGui.TableNextColumn()
        -- the number in force this instant, not the pair below: it is how the relax is seen
        -- doing anything at all
        ImGui.Text(tostring(Travel.GetHoldDistance()))

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Movement")

        ImGui.TableNextColumn()
        ImGui.Text(Movement.Describe() .. " [" .. (Movement.GetBlockedReason() or Movement.GetStatus()) .. "]")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    -- The same order (followtarget) a hotbar button carries, for the character being played by
    -- hand. Both buttons only move the travel core's bookkeeping around, which is what makes
    -- them safe to press from a render callback.
    local targetName = mq.TLO.Target.CleanName()
    local hasTarget = (mq.TLO.Target.ID() or 0) > 0

    if not hasTarget then ImGui.BeginDisabled(true) end
    if ImGui.Button("Follow Target", 100, 23) then
        local refusal = FollowState.StartFollowingTarget()
        if refusal ~= nil then
            print("(followtarget) " .. refusal)
        end
    end
    if not hasTarget then ImGui.EndDisabled() end

    ImGui.SameLine()
    -- the button carries the same order (stopfollow) does, so it is live for either standing
    -- order: an anchor with no follow behind it is still something to be told to stop
    local isTravelling = followTarget ~= "" or anchor.set
    if not isTravelling then ImGui.BeginDisabled(true) end
    if ImGui.Button("Stop Follow", 100, 23) then
        FollowState.StopFollowing()
    end
    if not isTravelling then ImGui.EndDisabled() end

    ImGui.SameLine()
    ImGui.Text(hasTarget and targetName or "<No Target>")

    -- How much room the following keeps. Nothing here runs a game command -- the settings are
    -- written to config and the travel core reads them on its next pass, running follow or not --
    -- which is what makes them safe to change from a render callback.
    local maxDistance = TravelConfig.GetMaxDistance()

    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(7.0, 7.0))
    if ImGui.BeginTable("followSettings", 1, bit32.bor(ImGuiTableFlags.RowBg)) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        ImGui.SetNextItemWidth(60)
        local distance, distanceChanged = ImGui.DragInt("Follow distance",
            TravelConfig.GetFollowDistance(), 1, TravelConfig.GetMinDistance(), maxDistance)
        if distanceChanged then
            TravelConfig.SetFollowDistance(distance)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("How close to get to whoever this character is following before standing still. They get about three quarters of it again to move around in before the gap is closed once more, which is the room that keeps a follow from being a shadow.")

        ImGui.TableNextRow()
        ImGui.TableNextColumn()

        ImGui.Dummy(0, 0)
        ImGui.SameLine()

        local relax, relaxClicked = ImGui.Checkbox("Give the fight room", TravelConfig.GetCombatRelax())
        if relaxClicked then
            TravelConfig.SetCombatRelax(relax)
        end
        ImGui.SameLine()
        CommonUI.HelpMarker("Hold further back while there is a fight going on around the group -- ours, or one somebody else called out. It only ever reaches a character with nothing to do in that fight, since anything with a job in it is busy at a band above follow: what it stops is a caster parked in the melee ring, and a follower spending the fight closing a gap nobody needed closed instead of leaving those frames to buffing and resting. Off holds the same spacing whatever is happening.")

        local relaxOff = not TravelConfig.GetCombatRelax()
        if relaxOff then ImGui.BeginDisabled(true) end
        ImGui.SameLine()
        ImGui.SetNextItemWidth(60)
        local combatDistance, combatChanged = ImGui.DragInt("Fighting distance",
            TravelConfig.GetCombatFollowDistance(), 1, TravelConfig.GetFollowDistance(), maxDistance)
        if combatChanged then
            TravelConfig.SetCombatFollowDistance(combatDistance)
        end
        if relaxOff then ImGui.EndDisabled() end
        ImGui.SameLine()
        CommonUI.HelpMarker("How close to get while there is a fight on. Never nearer than the follow distance -- relaxing to somewhere closer is not relaxing. A run is not a fight either: travel mode holds the follow distance whatever this says.")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()
end

return FollowState
