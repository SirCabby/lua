local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local Timer = require("utils.Time.Timer")

local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")

---@class FollowState
local FollowState = {
    key = "FollowState",
    eventIds = {
        followMe = "Follow Me",
        stopFollow = "Stop Follow",
        moveToMe = "Move to Me"
    },
    _ = {
        isInit = false,
        paused = false,
        followMeActions = {},
        currentActionIndex = 0,
        currentActionTimer = {},
        lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 },
        followTarget = "",
        checkingStuck = false,
        checkingRetry = false
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
    FollowState._.currentActionIndex = 0
    FollowState._.followTarget = ""
    FollowState._.lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 }
    FollowState._.checkingStuck = false
    FollowState._.checkingRetry = false
end

local function CloseToLastLoc()
    return mq.TLO.Math.Distance(tostring(FollowState._.lastLoc.y) .. "," .. tostring(FollowState._.lastLoc.x) .. tostring(FollowState._.lastLoc.z))() < 30
end

function FollowState.Init()
    if not FollowState._.isInit then

        local function event_FollowMe(_, speaker)
            if Commands.GetCommandOwners("followme"):IsOwner(speaker) then
                DebugLog("Activating followme of speaker [" .. speaker .. "]")
                FollowState._.followTarget = speaker
                FollowState._.currentActionIndex = 1
            else
                DebugLog("Ignoring followme of speaker [" .. speaker .. "]")
            end
        end
        local function followMeHelp()
            print("(followme) Tells listener(s) to begin autofollow on speaker")
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.followMe, "followme", event_FollowMe, followMeHelp))

        local function event_StopFollow(_, speaker)
            if Commands.GetCommandOwners("stopfollow"):IsOwner(speaker) then
                DebugLog("Stopping follow of speaker [" .. speaker .. "]")
                if mq.TLO.AdvPath.Monitor() ~= nil and mq.TLO.AdvPath.Monitor():lower() == FollowState._.followTarget:lower() then
                    mq.cmd("/afollow off")
                end
                Reset()
            else
                DebugLog("Ignoring stopfollow of speaker [" .. speaker .. "]")
            end
        end
        local function stopfollowHelp()
            print("(stopfollow) Tells listener(s) to stop autofollow on speaker")
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.stopFollow, "stopfollow", event_StopFollow, stopfollowHelp))

        local function event_MoveToMe(_, speaker)
            if Commands.GetCommandOwners("m2m"):IsOwner(speaker) then
                DebugLog("Moving to speaker [" .. speaker .. "]")
                if mq.TLO.AdvPath.Following() then
                    mq.cmd("/afollow off")
                end
                local spawn = mq.TLO.Spawn("pc radius 200 " .. speaker)
                if spawn ~= nil then
                    mq.cmd("/moveto id " .. tostring(spawn.ID))
                else
                    mq.cmd("/bc Follow target [" .. FollowState._.followTarget .. "] out of range, aborting...")
                end
                Reset()
            else
                DebugLog("Ignoring move to speaker [" .. speaker .. "]")
            end
        end
        local function moveToMeHelp()
            print("(stopfollow) Tells listener(s) to stop autofollow on speaker")
        end
        Commands.RegisterCommEvent(Command.new(FollowState.eventIds.moveToMe, "m2m", event_MoveToMe, moveToMeHelp))

        FollowState._.followMeActions[1] = function()
            mq.cmd("/afollow spawn " .. tostring(mq.TLO.Spawn("pc " .. FollowState._.followTarget).ID))
            FollowState._.currentActionIndex = 2
        end

        FollowState._.followMeActions[2] = function()
            -- Stop progression beyond this State without performing a function
        end

        FollowState._.isInit = true
    end
end

---@return boolean hasAction true if there's action to take, false to continue to next state
function FollowState.Check()
    if FollowState._.currentActionIndex == 1 then
        if mq.TLO.Spawn("pc radius 200 los " .. FollowState._.followTarget).Name() ~= nil then
            FollowState._.checkingRetry = true
            return true
        end

        if not FollowState._.checkingRetry then
            if mq.TLO.Spawn("pc " .. FollowState._.followTarget).Name() ~= nil then
                mq.cmd("/bc Follow target [" .. FollowState._.followTarget .. "] out of range, waiting...")
            else
                mq.cmd("/bc Follow target [" .. FollowState._.followTarget .. "] no longer appears to be in the zone, waiting...")
            end
        end
        FollowState._.checkingRetry = true
        mq.cmd("/afollow off")
        return false
    elseif FollowState._.currentActionIndex == 2 then
        -- If we're close, turn off autofollow and re-enable when we get distance again
        if mq.TLO.Spawn("pc " .. FollowState._.followTarget).Distance3D() < 12 then
            UpdateLastLoc()
            mq.cmd("/afollow off")
            FollowState._.checkingStuck = false
            return true
        end

        -- Had previously locked onto another target to follow, turn off that follow and reset it
        if mq.TLO.AdvPath.Monitor() ~= nil and mq.TLO.AdvPath.Monitor():lower() ~= FollowState._.followTarget:lower() then
            mq.cmd("/afollow off")
        end

        -- Not following for some reason, resume
        if not mq.TLO.AdvPath.Following() then
            FollowState._.currentActionIndex = 1
            return true
        end

        -- We are still following our target, are we stuck trying to follow?

        -- We have escaped the bubble of lastloc, things are good
        if not CloseToLastLoc() then
            UpdateLastLoc()
            FollowState._.checkingStuck = false
            return false
        end

        -- We're not at our target yet, let's see if we're stuck in the same area for too long

        -- Signal the first time through loop to setup the timer and reference loc
        if not FollowState._.checkingStuck then
            FollowState._.currentActionTimer = Timer:new(5000)
            UpdateLastLoc()
            FollowState._.checkingStuck = true
            return false
        end

        -- If we've timed out in this position, abort
        if FollowState._.currentActionTimer:timer_expired() then
            if CloseToLastLoc() then
                mq.cmd("/bc I got stuck while following [" .. FollowState._.followTarget .. "], aborting...")
                mq.cmd("/afollow off")
                Reset()
            else
                -- Not stuck, reset stuck check
                FollowState._.checkingStuck = false
            end
        end
        return false
    end
    return false
end

---To be called when the state is allowed to perform action. May be resuming from a prior interrupt.
function FollowState.Go()
    FollowState._.followMeActions[FollowState._.currentActionIndex]()
end







-- ---@class FollowState
-- local FollowState = {
--     debug = false,
--     paused = false,
--     followCheckJobKey = 0,
--     followTarget = "",
--     lastLoc = {
--         x = 0,
--         y = 0,
--         z = 0,
--         zoneId = 0
--     },
--     eventIds = {
--         followMe = "Follow Me",
--         stopFollow = "Stop Follow",
--         moveToMe = "Move to Me"
--     }
-- }

-- ---@param priorityQueue PriorityQueue
-- function FollowState:new(priorityQueue)
--     local followState = {}
--     setmetatable(followState, self)
--     self.__index = self



--     function followState.Pause()
--         FollowState.paused = true
--         mq.cmd("/afollow off")
--     end

--     function followState.Resume()
--         -- followstate check will resume follow with additional logic
--         FollowState.paused = false
--     end

--     function followState.WaitForFollowTarget()
--         -- add a recurring check here in the queue 
--     end

--     function followState:FollowMe(followTarget)
--         mq.cmd("/target " .. followTarget .. " radius 200")
--         mq.delay("1s", function() return mq.TLO.Target.Name() == followTarget end)
--         if mq.TLO.Target.Name() == followTarget then
--             mq.cmd("/afollow on")
--             FollowState.followTarget = followTarget
--             local followCheck = FunctionContent:new("Follow Check", function() return      end)
--             priorityQueue:InsertNewJob(Priorities.Following, followCheck, 5, true)
--         else
--             mq.cmd("/bc Unable to find [" .. followTarget .. "] to follow")
--         end
--     end

--     function followState:StopFollow()
--         mq.cmd("/afollow off")
--         FollowState.paused = false
--         FollowState.lastLoc.x = 0
--         FollowState.lastLoc.y = 0
--         FollowState.lastLoc.z = 0
--         FollowState.lastLoc.zoneId = 0

--         if FollowState.followCheckJobKey ~= 0 then priorityQueue:CompleteJobByKey(FollowState.followCheckJobKey) end
--         FollowState.followCheckJobKey = 0
--     end

--     function followState:MoveToMe(moveTarget)
--         self:StopFollow()
--         mq.cmd("/target " .. moveTarget .. " radius 200")
--         mq.delay("1s", function() return mq.TLO.Target.Name() == moveTarget end)
--         if mq.TLO.Target.Name() == moveTarget then
--             mq.cmd("/squelch /moveto ID " .. tostring(mq.TLO.Target.ID))
--         else
--             mq.cmd("/bc Unable to find [" .. moveTarget .. "] to move to")
--         end
--     end

--     function followState:ClickZone()
--         self.Pause()
--         mq.cmd("/doortarget")
--         if mq.TLO.DoorTarget.Distance < 100 then
--             mq.cmd("/squelch /moveto loc " .. tostring(mq.TLO.DoorTarget.Y) .. " " .. tostring(mq.TLO.DoorTarget.X) .. " dist 10")
--             local retryTimer = Timer:new(10)
--             while not retryTimer:timer_expired() do
--                 mq.cmd("/squelch /click left door")
--                 mq.delay("3s")
--                 if FollowState.lastLoc.zoneId ~= mq.TLO.Zone.ID then
--                     break
--                 end
--             end
--             if FollowState.lastLoc.zoneId == mq.TLO.Zone.ID then
--                 mq.cmd("/bc Failed to click into zone, aborting follow...")
--                 self:StopFollow()
--             else
--                 UpdateLastLoc()
--                 self:Resume()
--             end
--         end
--     end
-- end

return FollowState
