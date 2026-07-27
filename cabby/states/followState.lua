local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")
local Timer = require("utils.Time.Timer")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local Speak = require("cabby.commands.speak")
local UserInput = require("cabby.utils.userinput")

-- how close the movement service holds us to the follow target
local followDistance = 10
-- and how close we have to be before we stop hogging the frame from lower priority states
local keepCloseDistance = 12
-- how close to an anchor still counts as being parked on it
local anchorRadius = 15
-- how long to leave a failed attempt at clicking through a zone line alone. Without it, a door
-- that will not take us anywhere is clicked again on the pass after each failure, forever.
local clickZoneRetryMs = 15000

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
        -- who we were told to follow
        followTarget = "",
        -- 0 while we are holding the target by name (see FollowTargetSpawn), the spawn id we
        -- are holding them by otherwise
        followTargetId = 0,
        -- which command put us on this target, so that what the follow says about it later
        -- (waiting, stuck) is said wherever that command is configured to speak
        followCommand = "",
        -- the spawn the movement service is following, re-resolved whenever it is not following
        followSpawnId = 0,
        -- where we were told to stand
        anchor = { set = false, x = 0, y = 0 },
        -- Progress through clicking a zone line: the door has been clicked and the zone is
        -- coming, which is not something a fresh look at the world can reconstruct. The one
        -- piece of held state here that is not an order.
        clickZone = { step = nil, timer = nil, lastFailedMs = 0 },
        -- stuck detection, which is a measurement rather than a decision
        stuck = { checking = false, timer = nil, lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 } },
        waitingReported = false
    }
}

---Steps of the click-zone procedure, in order.
local clickZoneSteps = {
    findingSwitch = "findingSwitch",
    clickingSwitch = "clickingSwitch",
    waitingToZone = "waitingToZone"
}

---@param str string
local function DebugLog(str)
    Debug.Log(FollowState.key, str)
end

local function UpdateLastLoc()
    local lastLoc = FollowState._.stuck.lastLoc
    lastLoc.x = mq.TLO.Me.X()
    lastLoc.y = mq.TLO.Me.Y()
    lastLoc.z = mq.TLO.Me.Z()
    lastLoc.zoneId = mq.TLO.Zone.ID()
end

---Stop following, and forget everything measured about doing it.
local function ClearFollowOrder()
    FollowState._.followTarget = ""
    FollowState._.followTargetId = 0
    FollowState._.followSpawnId = 0
    FollowState._.stuck.checking = false
    FollowState._.waitingReported = false
    Movement.StopFor(FollowState.key)
end

---Stop holding a spot.
local function ClearAnchorOrder()
    FollowState._.anchor = { set = false, x = 0, y = 0 }
    Movement.StopFor(FollowState.key)
end

---Forget every order and everything measured about carrying one out.
local function Reset()
    FollowState._.followTarget = ""
    FollowState._.followTargetId = 0
    FollowState._.followCommand = FollowState.eventIds.followMe
    FollowState._.followSpawnId = 0
    FollowState._.anchor = { set = false, x = 0, y = 0 }
    FollowState._.clickZone = { step = nil, timer = nil, lastFailedMs = 0 }
    FollowState._.stuck = { checking = false, timer = nil, lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 } }
    FollowState._.waitingReported = false
end



local function CloseToLastLoc()
    local lastLoc = FollowState._.stuck.lastLoc
    return mq.TLO.Math.Distance(tostring(lastLoc.y) .. "," .. tostring(lastLoc.x) .. "," .. tostring(lastLoc.z))() < 30
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

---Say, once, that we are waiting on the follow target rather than every pass.
---@param message string
local function ReportWaiting(message)
    if FollowState._.waitingReported then return end
    FollowState._.waitingReported = true
    Commands.GetCommandSpeak(FollowState._.followCommand):speak(message)
end

---Are we stuck trying to get to the follow target?
---
---A measurement, not a decision: it compares where we are against where we were, and the only
---thing it decides is whether to give up on this attempt and go back to looking.
---@return boolean isStuck
local function CheckStuck()
    -- we have escaped the bubble of lastloc, so things are going fine
    if not CloseToLastLoc() then
        UpdateLastLoc()
        FollowState._.stuck.checking = false
        return false
    end

    -- first pass in one place: start the clock and remember where "here" was
    if not FollowState._.stuck.checking then
        FollowState._.stuck.timer = Timer.new(5000)
        UpdateLastLoc()
        FollowState._.stuck.checking = true
        return false
    end

    if FollowState._.stuck.timer:timer_expired() and CloseToLastLoc() then
        return true
    end

    return false
end

---Whether clicking through a zone line is worth trying: not while we have just failed at it.
---@return boolean
local function MayClickZone()
    return Time.current_time() - FollowState._.clickZone.lastFailedMs >= clickZoneRetryMs
end

---Start clicking through a zone line. Progress from here is held, because the world cannot tell
---us that the door has been clicked and the zone is on its way.
local function BeginClickZone()
    FollowState._.clickZone.step = clickZoneSteps.findingSwitch
    FollowState._.clickZone.timer = Timer.new(10000)
end

---@param failed boolean whether the procedure gave up rather than finishing
local function EndClickZone(failed)
    FollowState._.clickZone.step = nil
    FollowState._.clickZone.timer = nil
    FollowState._.clickZone.lastFailedMs = failed and Time.current_time() or 0
end

---One pass of following whoever we were told to follow.
---
---Everything it decides is decided here, from the world: whether they are in the zone, whether we
---are close enough, whether a follow is running, and whether it is getting anywhere. What it
---keeps is what it cannot ask for again -- who we were told to follow.
---@return boolean isBusy
local function Follow()
    local targetSpawn = FollowTargetSpawn()

    if targetSpawn.Name() == nil then
        -- Their breadcrumb trail outlives them leaving; walk it out first, which puts us at the
        -- zone line (or their corpse) before we decide what to do about it.
        if Movement.IsFollowing(FollowState._.followSpawnId) then
            return true
        end

        -- A target held by spawn id is not coming back once that id stops resolving -- it died,
        -- despawned, or we left the zone it was in -- so there is nothing here to wait for.
        if FollowState._.followTargetId > 0 then
            Commands.GetCommandSpeak(FollowState._.followCommand):speak(
                "Follow target [" .. FollowState._.followTarget .. "] is gone, stopping follow")
            ClearFollowOrder()
            return false
        end

        -- Only a player walks out through a zone line. If they are not lying dead next to us,
        -- assume they zoned and go through after them.
        local corpse = mq.TLO.Spawn("corpse " .. FollowState._.followTarget)
        if corpse.Name() == nil or corpse.Distance() > 100 then
            local switchDistance = mq.TLO.Switch("nearest").Distance()
            if switchDistance ~= nil and switchDistance < 100 and MayClickZone() then
                BeginClickZone()
                return true
            end
        end

        Movement.StopFor(FollowState.key)
        ReportWaiting("Follow target [" .. FollowState._.followTarget .. "] is not here, waiting...")
        -- nothing to do but wait, so let lower tier actions have the frame
        return false
    end

    -- Close enough: the follow task parks itself, and so do we
    local targetDistance = targetSpawn.Distance3D()
    if targetDistance ~= nil and targetDistance < keepCloseDistance then
        UpdateLastLoc()
        FollowState._.stuck.checking = false
        FollowState._.waitingReported = false
        return false
    end

    -- Not close enough, so a follow should be running. It will not be on the first pass, after a
    -- zone, or when something with higher priority took movement over.
    if not Movement.IsFollowing(FollowState._.followSpawnId) then
        local followSpawnId = FollowTargetInReachId()
        if followSpawnId == nil or followSpawnId <= 0 then
            Movement.StopFor(FollowState.key)
            ReportWaiting("Follow target [" .. FollowState._.followTarget .. "] out of range, waiting...")
            return false
        end

        FollowState._.waitingReported = false
        FollowState._.followSpawnId = followSpawnId
        FollowState._.stuck.checking = false
        Movement.Follow(followSpawnId, { distance = followDistance, owner = FollowState.key })
        return true
    end

    if CheckStuck() then
        Commands.GetCommandSpeak(FollowState._.followCommand):speak(
            "I got stuck while following [" .. FollowState._.followTarget .. "], waiting...")
        Movement.StopFor(FollowState.key)
        FollowState._.followSpawnId = 0
        FollowState._.stuck.checking = false
        return true
    end

    -- mid-run: nothing weaker should start moving us somewhere else
    return true
end

---One pass of standing where we were told to stand.
---@return boolean isBusy
local function HoldAnchor()
    if not FollowState._.anchor.set then return false end

    -- already walking back to it, let that finish
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

---One pass of the click-zone procedure: find the door, walk to it, click it, wait for the zone.
---
---This is the one place in this state that holds a mode, because it is the one thing the world
---cannot describe: a door that has been clicked looks exactly like one that has not.
---@return boolean isBusy
local function ClickZone()
    local step = FollowState._.clickZone.step

    if step == clickZoneSteps.waitingToZone then
        if FollowState._.stuck.lastLoc.zoneId ~= mq.TLO.Zone.ID() then
            EndClickZone(false)
            return true
        end

        if FollowState._.clickZone.timer:timer_expired() then
            Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("I failed to click into the zone. Waiting...")
            EndClickZone(true)
        end
        return true
    end

    local switchDistance = mq.TLO.Switch("nearest").Distance()

    if step == clickZoneSteps.clickingSwitch then
        if switchDistance ~= nil and switchDistance < 25 then
            UpdateLastLoc()
            mq.cmd("/invoke ${Switch[nearest].Target}")
            mq.cmd("/click left switch")
            FollowState._.clickZone.step = clickZoneSteps.waitingToZone
            FollowState._.clickZone.timer = Timer.new(10000)
            return true
        end

        if FollowState._.clickZone.timer:timer_expired() then
            Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("I failed to navigate to click zone. Waiting...")
            EndClickZone(true)
        end
        return true
    end

    -- findingSwitch
    Movement.StopFor(FollowState.key)

    if switchDistance == nil or switchDistance >= 100 then
        Commands.GetCommandSpeak(FollowState.eventIds.clickZone):speak("Failed to click zone, could not find nearby switch")
        EndClickZone(true)
        return true
    end

    if switchDistance > 25 then
        local switchY = mq.TLO.Switch("nearest").Y()
        local switchX = mq.TLO.Switch("nearest").X()
        if switchY ~= nil and switchX ~= nil then
            Movement.MoveToLoc(switchY, switchX, { distance = 20, timeoutMs = 10000, owner = FollowState.key })
        end
        FollowState._.clickZone.step = clickZoneSteps.clickingSwitch
    else
        UpdateLastLoc()
        mq.cmd("/invoke ${Switch[nearest].Target}")
        mq.cmd("/click left switch")
        FollowState._.clickZone.step = clickZoneSteps.waitingToZone
    end
    FollowState._.clickZone.timer = Timer.new(10000)
    return true
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
    FollowState._.followSpawnId = 0
    FollowState._.waitingReported = false
    -- being told to follow somebody cancels being told to stand somewhere
    ClearAnchorOrder()
    return nil
end

---Stop following and hand back the movement we were using, leaving a move somebody else has
---since started alone. Safe to call from a render callback, same as StartFollowingTarget.
---Stop following and hand back the movement we were using, leaving a move somebody else has
---since started alone.
function FollowState.StopFollowing()
    ClearFollowOrder()
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
                FollowState._.followSpawnId = 0
                FollowState._.waitingReported = false
                ClearAnchorOrder()
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
                BeginClickZone()
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
                    ClearAnchorOrder()
                else
                    local spawn = mq.TLO.Spawn("pc radius 200 " .. speaker)
                    if (spawn.ID() or 0) > 0 then
                        FollowState._.anchor = { set = true, x = spawn.X(), y = spawn.Y() }
                        -- being told to stand somewhere cancels being told to follow somebody
                        ClearFollowOrder()
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

        Reset()
        Menu.RegisterState(FollowState)

        FollowState._.isInit = true
    end
end

---One pass: a procedure in progress first, then whichever order is standing.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function FollowState.Go()
    -- Clicking through a zone line is the one thing here that is genuinely part-way done rather
    -- than a decision to re-make, so it comes first and finishes before anything else is asked.
    if FollowState._.clickZone.step ~= nil then
        return ClickZone()
    end

    -- Following and anchoring are contradictory orders, so only one of them is ever standing:
    -- whichever was asked for last cancelled the other when it arrived. That is what makes
    -- "which am I doing" something to read rather than something to remember.
    if FollowState._.followTarget ~= "" then return Follow() end
    if FollowState._.anchor.set then return HoldAnchor() end

    return false
end

---@return string description of what this state is doing, for the page and /state
function FollowState.Describe()
    if FollowState._.clickZone.step ~= nil then return "Clicking to Zone" end
    if FollowState._.followTarget ~= "" then return "Following" end
    if FollowState._.anchor.set then return "Anchoring" end
    return "Standby"
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
        ImGui.Text(FollowState.Describe())

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
