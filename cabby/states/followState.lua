local mq = require("mq")
local Commands = require("cabby.commands")
local Debug = require("utils.Debug.Debug")
local Timer = require("utils.Timer.Timer")

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
        owners = {},
        followMeActions = {},
        currentActionIndex = 0,
        previousActionIndex = 0,
        currentActionTimer = {},
        lastLoc = { x = 0, y = 0, z = 0, zoneId = 0 },
        followTarget = ""
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
end

function FollowState.Init(owners)
    if not FollowState._.isInit then
        FollowState._.owners = owners

        local function event_FollowMe(_, speaker)
            if FollowState._.owners:IsOwner(speaker) then
                DebugLog("Activating followme of speaker [" .. speaker .. "]")
                FollowState._.followTarget = speaker
                FollowState._.currentActionIndex = 1
            else
                DebugLog("Ignoring followme of speaker [" .. speaker .. "]")
            end
        end
        local function followMeHelp()
            print("(followme) Tells listener(s) to begin autofollow on speaker")
            print(" -- Assuming [bc] is an active channel, example: /bc followme")
        end
        Commands.RegisterCommEvent(FollowState.eventIds.followMe, "followme", event_FollowMe, followMeHelp)

        local function event_StopFollow(_, speaker)
            if FollowState._.owners:IsOwner(speaker) then
                DebugLog("Stopping follow of speaker [" .. speaker .. "]")
                FollowState._.followTarget = ""
                FollowState._.currentActionIndex = 1
            else
                DebugLog("Ignoring stopfollow of speaker [" .. speaker .. "]")
            end
        end
        local function stopfollowHelp()
            print("(followme) Tells listener(s) to begin autofollow on speaker")
            print(" -- Assuming [bc] is an active channel, example: /bc followme")
        end
        Commands.RegisterCommEvent(FollowState.eventIds.followMe, "followme", event_StopFollow, stopfollowHelp)

        FollowState._.followMeActions[1] = function()
            mq.cmd("/mqtarget " .. FollowState._.followTarget .. " radius 200")
            FollowState._.previousActionIndex = 1
            FollowState._.currentActionIndex = 2
        end

        FollowState._.followMeActions[2] = function()
            mq.cmd("/afollow on")
            FollowState._.previousActionIndex = 2
            FollowState._.currentActionIndex = 3
        end

        FollowState._.isInit = true
    end
end

---@param interrupted boolean
---@return boolean hasAction true if there's action to take, false to sleep
function FollowState.Check(interrupted)
    if FollowState._.currentActionIndex == 1 then
        FollowState._.currentActionTimer = Timer:new(2)
        return true
    end
    if FollowState._.currentActionIndex == 2 then
        if interrupted then
            FollowState._.currentActionTimer = Timer:new(2)
        end

        if FollowState._.currentActionTimer:timer_expired() then
            mq.cmd("/bc Unable to find [" .. FollowState._.followTarget .. "] to follow")
            Reset()
            return false
        end

        return mq.TLO.Target.Name() == FollowState._.followTarget
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
