local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")
local Timer = require("utils.Time.Timer")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local UserInput = require("cabby.utils.userinput")

local function passive()
    return false
end

---@class FollowState : State
local FollowState = {
    key = "FollowState",
    eventIds = {
        followMe = "followme",
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
    FollowState._.checkingStuck = false
    FollowState._.checkingRetry = false
    FollowState._.anchor.x = 0
    FollowState._.anchor.y = 0
end

local function CloseToLastLoc()
    return mq.TLO.Math.Distance(tostring(FollowState._.lastLoc.y) .. "," .. tostring(FollowState._.lastLoc.x) .. tostring(FollowState._.lastLoc.z))() < 30
end

FollowState._.followActions.findFollowTarget = function()
    -- Found target, begin follow mode
    if mq.TLO.Spawn("pc radius 200 los " .. FollowState._.followTarget).Name() ~= nil then
        FollowState._.checkingRetry = false
        mq.cmd("/afollow spawn " .. tostring(mq.TLO.Spawn("pc " .. FollowState._.followTarget).ID))
        FollowState._.currentAction = FollowState._.followActions.keepClose
        FollowState._.currentActionTimer = Timer.new(5000)
        return true
    end

    -- No target nearby, notify about waiting
    if not FollowState._.checkingRetry then
        local speak = Commands.GetCommandSpeak(FollowState.eventIds.followMe)
        if mq.TLO.Spawn("pc " .. FollowState._.followTarget).Name() ~= nil then
            speak:speak("Follow target [" .. FollowState._.followTarget .. "] out of range, waiting...")
        else
            DebugLog("Follow target [" .. FollowState._.followTarget .. "] no longer appears to be in the zone, waiting...")
        end
    end
    FollowState._.checkingRetry = true

    -- If following, must be something else, disable it
    if mq.TLO.AdvPath.Following() then
        mq.cmd("/afollow off")
    end

    -- waiting to find follow target, allow lower tier action
    return false
end

FollowState._.followActions.keepClose = function()
    -- Follow target not in zone? Go back to finding target or attempt zoning
    if mq.TLO.Spawn("pc " .. FollowState._.followTarget).Name() == nil then
        local corpse = mq.TLO.Spawn("corpse " .. FollowState._.followTarget)
        if corpse.Name() == nil or corpse.Distance() > 100 then
            -- target zoned without dying, check for nearby switch
            local switch = mq.TLO.Switch("nearest")
            if switch ~= nil and switch.Distance() < 100 then
                FollowState._.currentAction = FollowState._.clickZoneActions.findingSwitch
                return true
            end
        end

        FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        return true
    end

    -- If we're close, turn off autofollow and re-enable when we get distance again
    -- AdvPath is hardcoded to follow at distance 10, so we hardcode to 12
    if mq.TLO.Spawn("pc " .. FollowState._.followTarget).Distance3D() < 12 then
        UpdateLastLoc()
        if mq.TLO.AdvPath.Following() then
            mq.cmd("/afollow off")
        end
        FollowState._.checkingStuck = false

        -- we're close and waiting, allow lower tier action
        return false
    end

    -- Had previously locked onto another target to follow, turn off that follow and reset it
    if mq.TLO.AdvPath.Monitor() ~= nil and mq.TLO.AdvPath.Monitor():lower() ~= FollowState._.followTarget:lower() then
        mq.cmd("/afollow off")
    end

    -- Not following for some reason, resume
    if not mq.TLO.AdvPath.Following() then
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
            Commands.GetCommandSpeak(FollowState.eventIds.followMe):speak("I got stuck while following [" .. FollowState._.followTarget .. "], waiting...")
            FollowState._.currentAction = FollowState._.followActions.findFollowTarget
        else
            -- Not stuck, reset stuck check
            FollowState._.checkingStuck = false
        end
    end
    return true
end

FollowState._.clickZoneActions.findingSwitch = function()
    if mq.TLO.AdvPath.Following() then
        mq.cmd("/afollow off")
    end

    local switch = mq.TLO.Switch("nearest")
    if switch ~= nil and switch.Distance() < 100 then
        if switch.Distance() > 25 then
            local switch = mq.TLO.Switch("nearest")
            if switch ~= nil then
                mq.cmd("/moveto loc " .. tostring(switch.Y) .. " " .. tostring(switch.X))
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
    local switch = mq.TLO.Switch("nearest")
    if switch ~= nil and switch.Distance() < 25 then
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
    if mq.TLO.AdvPath.Following() then
        mq.cmd("/afollow off")
    end

    if not mq.TLO.MoveTo.Moving() and mq.TLO.Spawn("pc " .. mq.TLO.Me.Name() .. " radius 15 loc " .. FollowState._.anchor.x .. " " .. FollowState._.anchor.y).Name() == nil then
        mq.cmd("/moveto loc " .. FollowState._.anchor.y .. " " .. FollowState._.anchor.x)
        return true
    end
    return false
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
                FollowState._.currentAction = FollowState._.followActions.findFollowTarget
                FollowState._.checkingRetry = false
            else
                DebugLog("Ignoring followme of speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.followMe, event_FollowMe, followMeDocs))

        local stopFollowDocs = ChelpDocs.new(function() return {
            "(stopfollow) Tells listener(s) to stop autofollow on speaker"
        } end )
        local function event_StopFollow(_, speaker)
            if Commands.GetCommandOwners(FollowState.eventIds.stopFollow):HasPermission(speaker) then
                DebugLog("Stopping follow of speaker [" .. speaker .. "]")
                if mq.TLO.AdvPath.Monitor() ~= nil and mq.TLO.AdvPath.Monitor():lower() == FollowState._.followTarget:lower() then
                    mq.cmd("/afollow off")
                end
                Reset()
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
                if mq.TLO.AdvPath.Following() then
                    mq.cmd("/afollow off")
                end
                local spawn = mq.TLO.Spawn("pc radius 200 " .. speaker)
                if spawn ~= nil then
                    mq.cmd("/moveto id " .. tostring(spawn.ID))
                else
                    Commands.GetCommandSpeak(FollowState.eventIds.moveToMe):speak("M2m target [" .. speaker .. "] out of range, aborting...")
                end
                Reset()
            else
                DebugLog("Ignoring move to speaker [" .. speaker .. "]")
            end
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.moveToMe, event_MoveToMe, mtomDocs))

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
                    if spawn ~= nil then
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
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.anchor, event_Anchor, anchorDocs))

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
    local width = ImGui.GetContentRegionMax()
    local maxwidth = ImGui.GetWindowContentRegionMax()

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

        ImGui.EndTable()
    end
    ImGui.PopStyleVar()
end

return FollowState
