local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")
local Timer = require("utils.Time.Timer")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local Speak = require("cabby.commands.speak")
local UserInput = require("cabby.utils.userinput")

local function passive()
    return false
end

-- how close the movement service holds us to the follow target
local followDistance = 10
-- and how close we have to be before we stop hogging the frame from lower priority states
local keepCloseDistance = 12
-- how close to an anchor still counts as being parked on it
local anchorRadius = 15

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
        isInit = false,
        currentAction = passive,
        currentActionTimer = nil,
        lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 },
        followTarget = "",
        -- 0 while we are holding the target by name (see FollowTargetSpawn), the spawn id we
        -- are holding them by otherwise
        followTargetId = 0,
        -- which command put us on this target, so that what the follow says about it later
        -- (waiting, stuck) is said wherever that command is configured to speak
        followCommand = "",
        followSpawnId = 0,
        checkingStuck = false,
        checkingRetry = false,
        anchor = {
            x = 0,
            y = 0
        },
        followActions = {
            findFollowTarget = passive,
            keepClose = passive
        },
        clickZoneActions = {
            findingSwitch = passive,
            clickingSwitch = passive,
            waitingToZone = passive
        },
        anchorActions = {
            stayingAtAnchor = passive
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(FollowState.key, str)
end

local function UpdateLastLoc()
    FollowState._.lastLoc.x = mq.TLO.Me.X()
    FollowState._.lastLoc.y = mq.TLO.Me.Y()
    FollowState._.lastLoc.z = mq.TLO.Me.Z()
    FollowState._.lastLoc.zoneId = mq.TLO.Zone.ID()
end

local function Reset()
    FollowState._.currentAction = passive
    FollowState._.currentActionTimer = Timer.new(0)
    FollowState._.lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 }
    FollowState._.followTarget = ""
    FollowState._.followTargetId = 0
    FollowState._.followCommand = FollowState.eventIds.followMe
    FollowState._.followSpawnId = 0
    FollowState._.checkingStuck = false
    FollowState._.checkingRetry = false
    FollowState._.anchor.x = 0
    FollowState._.anchor.y = 0
end

local function CloseToLastLoc()
    return mq.TLO.Math.Distance(tostring(FollowState._.lastLoc.y) .. "," .. tostring(FollowState._.lastLoc.x) .. "," .. tostring(FollowState._.lastLoc.z))() < 30
end

---Whoever we are following, whether or not they are currently around: an invalid spawn
---(`Name()` of nil) means they are not in the zone with us.
---
---A player is held by name, which is what lets us pick them back up after they zone or die --
---their spawn id does not survive either. Anything else is held as the one spawn it is: a name
---is shared by every copy of an npc in the zone and outlives none of them.
local function FollowTargetSpawn()
    if FollowState._.followTargetId > 0 then
        return mq.TLO.Spawn("id " .. FollowState._.followTargetId)
    end
    return mq.TLO.Spawn("pc " .. FollowState._.followTarget)
end

---The follow target's spawn id, but only while they are close enough and in sight to go and
---pick up. Held by name or by id the same way FollowTargetSpawn does.
local function FollowTargetInReachId()
    if FollowState._.followTargetId > 0 then
        return mq.TLO.Spawn("id " .. FollowState._.followTargetId .. " radius 200 los").ID()
    end
    return mq.TLO.Spawn("pc radius 200 los " .. FollowState._.followTarget).ID()
end

FollowState._.followActions.findFollowTarget = function()
    -- Found target, begin follow mode
    local followSpawnId = FollowTargetInReachId()
    if followSpawnId ~= nil and followSpawnId > 0 then
        FollowState._.checkingRetry = false
        FollowState._.followSpawnId = followSpawnId
        Movement.Follow(followSpawnId, { distance = followDistance, owner = FollowState.key })
        FollowState._.currentAction = FollowState._.followActions.keepClose
        FollowState._.currentActionTimer = Timer.new(5000)
        return true
    end

    -- Nothing to follow, so stop following (but leave anyone else's movement alone)
    Movement.StopFor(FollowState.key)

    local inZone = FollowTargetSpawn().Name() ~= nil

    -- A target held by spawn id is not coming back once that id stops resolving -- it died,
    -- despawned, or we left the zone it was in -- so there is nothing here to wait for
    if not inZone and FollowState._.followTargetId > 0 then
        Commands.GetCommandSpeak(FollowState._.followCommand):speak("Follow target [" .. FollowState._.followTarget .. "] is gone, stopping follow")
        Reset()
        return false
    end

    -- No target nearby, notify about waiting
    if not FollowState._.checkingRetry then
        local speak = Commands.GetCommandSpeak(FollowState._.followCommand)
        if inZone then
            speak:speak("Follow target [" .. FollowState._.followTarget .. "] out of range, waiting...")
        else
            DebugLog("Follow target [" .. FollowState._.followTarget .. "] no longer appears to be in the zone, waiting...")
        end
    end
    FollowState._.checkingRetry = true

    -- waiting to find follow target, allow lower tier action
    return false
end

FollowState._.followActions.keepClose = function()
    local targetSpawn = FollowTargetSpawn()

    -- Follow target not in zone? Go back to finding target or attempt zoning
    if targetSpawn.Name() == nil then
        -- their breadcrumb trail outlives them leaving; walk it out first, which puts us at
        -- the zone line (or their corpse) before we decide what to do about it
        if Movement.IsFollowing(FollowState._.followSpawnId) then
            return true
        end

        -- Only a player walks out through a zone line. Anything held by spawn id stopped
        -- existing rather than went somewhere, so there is no zone to chase it into --
        -- findFollowTarget calls that follow off.
        if FollowState._.followTargetId == 0 then
            local corpse = mq.TLO.Spawn("corpse " .. FollowState._.followTarget)
            if corpse.Name() == nil or corpse.Distance() > 100 then
                -- target zoned without dying, check for nearby switch
                local switchDistance = mq.TLO.Switch("nearest").Distance()
                if switchDistance ~= nil and switchDistance < 100 then
                    FollowState._.currentAction = FollowState._.clickZoneActions.findingSwitch
                    return true
                end
            end
        end

        FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        return true
    end

    -- If we're close the follow task parks itself, so let lower tier actions have the frame
    local targetDistance = targetSpawn.Distance3D()
    if targetDistance ~= nil and targetDistance < keepCloseDistance then
        UpdateLastLoc()
        FollowState._.checkingStuck = false

        -- we're close and waiting, allow lower tier action
        return false
    end

    -- Follow ended, failed, or something with higher priority took movement over. Either
    -- way we are no longer following our target, so go pick them back up.
    if not Movement.IsFollowing(FollowState._.followSpawnId) then
        FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        return true
    end

    -- We are still following our target, are we stuck trying to follow?

    -- We have escaped the bubble of lastloc, things are good
    if not CloseToLastLoc() then
        UpdateLastLoc()
        FollowState._.checkingStuck = false
        FollowState._.currentActionTimer:reset()

        -- we are mid-running, don't allow other things to interfere
        return true
    end

    -- We're not at our target yet, let's see if we're stuck in the same area for too long

    -- Signal the first time through loop to setup the timer and reference loc
    if not FollowState._.checkingStuck then
        FollowState._.currentActionTimer = Timer.new(5000)
        UpdateLastLoc()
        FollowState._.checkingStuck = true
        return true
    end

    -- If we've timed out in this position, abort
    if FollowState._.currentActionTimer:timer_expired() then
        if CloseToLastLoc() then
            Commands.GetCommandSpeak(FollowState._.followCommand):speak("I got stuck while following [" .. FollowState._.followTarget .. "], waiting...")
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            -- Not stuck, reset stuck check
            FollowState._.checkingStuck = false
        end
    end
    return true
end

FollowState._.clickZoneActions.findingSwitch = function()
    Movement.StopFor(FollowState.key)

    local switchDistance = mq.TLO.Switch("nearest").Distance()
    if switchDistance ~= nil and switchDistance < 100 then
        if switchDistance > 25 then
            local switchY = mq.TLO.Switch("nearest").Y()
            local switchX = mq.TLO.Switch("nearest").X()
            if switchY ~= nil and switchX ~= nil then
                Movement.MoveToLoc(switchY, switchX, { distance = 20, timeoutMs = 10000, owner = FollowState.key })
            end
            FollowState._.currentAction = FollowState._.clickZoneActions.clickingSwitch
        else
            UpdateLastLoc()
            mq.cmd("/invoke ${Switch[nearest].Target}")
            mq.cmd("/click left switch")
            FollowState._.currentAction = FollowState._.clickZoneActions.waitingToZone
        end
        FollowState._.currentActionTimer = Timer.new(10000)
    else
        Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("Failed to click zone, could not find nearby switch")
        if FollowState._.followTarget ~= "" then
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            Reset()
            return false
        end
    end
    return true
end

FollowState._.clickZoneActions.clickingSwitch = function()
    -- We found it, click and start waiting for zone
    local switchDistance = mq.TLO.Switch("nearest").Distance()
    if switchDistance ~= nil and switchDistance < 25 then
        UpdateLastLoc()
        mq.cmd("/invoke ${Switch[nearest].Target}")
        mq.cmd("/click left switch")
        FollowState._.currentActionTimer = Timer.new(10000)
        FollowState._.currentAction = FollowState._.clickZoneActions.waitingToZone
        return true
    end

    -- If we've timed out in this position, abort
    if FollowState._.currentActionTimer:timer_expired() then
        Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("I failed to navigate to click zone. Waiting...")
        if FollowState._.followTarget ~= "" then
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            Reset()
            return false
        end
    end
    return true
end

FollowState._.clickZoneActions.waitingToZone = function()
    -- Arrived at zone, continue following
    if FollowState._.lastLoc.zoneId ~= mq.TLO.Zone.ID() then
        if FollowState._.followTarget ~= "" then
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            Reset()
            return false
        end
        return true
    end

    -- If we've timed out in this position, abort
    if FollowState._.currentActionTimer:timer_expired() then
        Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("I failed to click into the zone. Waiting...")
        if FollowState._.followTarget ~= "" then
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            Reset()
            return false
        end
    end
    return true
end

FollowState._.anchorActions.stayingAtAnchor = function()
    -- already walking back to the anchor, let it finish
    if Movement.IsMovingTo() and Movement.IsOwnedBy(FollowState.key) then
        return true
    end

    local myY = mq.TLO.Me.Y()
    local myX = mq.TLO.Me.X()
    if myY == nil or myX == nil then return false end

    if Geometry.Distance2D(myY, myX, FollowState._.anchor.y, FollowState._.anchor.x) > anchorRadius then
        Movement.StopFor(FollowState.key)
        Movement.MoveToLoc(FollowState._.anchor.y, FollowState._.anchor.x, { owner = FollowState.key })
        return true
    end
    return false
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
---started by this state's own turn in the main loop.
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
    FollowState._.followTarget = name
    -- a player is still themselves after a zone, so hold them by name; anything else only ever
    -- exists as this spawn (see FollowTargetSpawn)
    FollowState._.followTargetId = target.Type() == "PC" and 0 or targetId
    FollowState._.followCommand = FollowState.eventIds.followTarget
    FollowState._.currentAction = FollowState._.followActions.findFollowTarget
    FollowState._.checkingRetry = false
    return nil
end

---Stop following and hand back the movement we were using, leaving a move somebody else has
---since started alone. Safe to call from a render callback, same as StartFollowingTarget.
function FollowState.StopFollowing()
    if Movement.IsFollowing(FollowState._.followSpawnId) then
        Movement.StopFor(FollowState.key)
    end
    Reset()
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
                FollowState._.followTarget = speaker
                FollowState._.followTargetId = 0
                FollowState._.followCommand = FollowState.eventIds.followMe
                FollowState._.currentAction = FollowState._.followActions.findFollowTarget
                FollowState._.checkingRetry = false
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
            "(stopfollow) Tells listener(s) to stop autofollow on speaker"
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
                Reset()
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
                FollowState._.currentAction = FollowState._.clickZoneActions.findingSwitch
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
                    FollowState._.anchor.x = 0
                    FollowState._.anchor.y = 0
                    if FollowState._.followTarget ~= "" then
                        FollowState._.currentAction = FollowState._.followActions.findFollowTarget
                    else
                        FollowState._.currentAction = passive
                    end
                else
                    local spawn = mq.TLO.Spawn("pc radius 200 " .. speaker)
                    if (spawn.ID() or 0) > 0 then
                        FollowState._.anchor.x = spawn.X()
                        FollowState._.anchor.y = spawn.Y()
                        FollowState._.currentAction = FollowState._.anchorActions.stayingAtAnchor
                    else
                        Commands.GetCommandSpeak(FollowState.eventIds.anchor):speak("Anchor target [" .. speaker .. "] out of range, aborting...")
                        if FollowState._.followTarget ~= "" then
                            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
                        else
                            FollowState._.currentAction = passive
                        end
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

        Reset()
        Menu.RegisterState(FollowState)

        FollowState._.isInit = true
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function FollowState.Go()
    return FollowState._.currentAction()
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

    local tableSorting_flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner, ImGuiTableFlags.NoHostExtendX)
    ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, ImVec2(4.0, 4.0))
    if ImGui.BeginTable("t1", 2, tableSorting_flags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthStretch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")

        ImGui.TableNextColumn()
        local currentTask = "Standby"
        if TableUtils.ArrayContains(TableUtils.GetValues(FollowState._.anchorActions), FollowState._.currentAction) then
            currentTask = "Anchoring"
        elseif TableUtils.ArrayContains(TableUtils.GetValues(FollowState._.followActions), FollowState._.currentAction) then
            currentTask = "Following"
        elseif TableUtils.ArrayContains(TableUtils.GetValues(FollowState._.clickZoneActions), FollowState._.currentAction) then
            currentTask = "Clicking to Zone"
        end
        ImGui.Text(currentTask)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Anchor Loc (x,y)")

        ImGui.TableNextColumn()
        ImGui.Text(tostring(math.floor(FollowState._.anchor.x * 100) / 100) .. ", " .. tostring(math.floor(FollowState._.anchor.y * 100) / 100))

        ImGui.TableNextColumn()
        ImGui.Text("Follow Target")

        ImGui.TableNextColumn()
        ImGui.Text(FollowState._.followTarget)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Movement")

        ImGui.TableNextColumn()
        ImGui.Text(Movement.Describe() .. " [" .. (Movement.GetBlockedReason() or Movement.GetStatus()) .. "]")

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()

    -- The same order (followtarget) a hotbar button carries, for the character being played by
    -- hand. Both buttons only move this state's own bookkeeping around, which is what makes
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
    local isFollowing = FollowState._.followTarget ~= ""
    if not isFollowing then ImGui.BeginDisabled(true) end
    if ImGui.Button("Stop Follow", 100, 23) then
        FollowState.StopFollowing()
    end
    if not isFollowing then ImGui.EndDisabled() end

    ImGui.SameLine()
    ImGui.Text(hasTarget and targetName or "<No Target>")
end

return FollowState
