local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Follow = require("utils.Movement.Follow")
local Locomotion = require("utils.Movement.Locomotion")
local MoveTo = require("utils.Movement.MoveTo")
local MovementStatus = require("utils.Movement.MovementStatus")
local Stick = require("utils.Movement.Stick")

---The movement service: one active task, pulsed once per frame.
---
---This replaces the parts of MQ2MoveUtils and MQ2AdvPath that a bot actually needs, without
---the plugins. Callers hand it a task (`MoveToLoc`, `MoveToSpawn`, `Stick`, `Follow`) and it
---owns the movement keys until that task finishes or someone starts a different one -- only
---one task at a time, on purpose, because two behaviors holding movement keys is how you get
---a character running in circles.
---
---`Pulse()` must be called every frame by the host loop, not only by whichever behavior
---started the task; that is what guarantees the keys are released when a task ends and that
---nothing keeps running while we are stunned, mezzed, casting or sitting.
---@class Movement
local Movement = {
    author = "judged",
    key = "Movement",
    status = MovementStatus,
    taskTypes = {
        moveTo = MoveTo.key,
        stick = Stick.key,
        follow = Follow.key
    },
    _ = {
        task = nil,
        nextId = 1,
        status = MovementStatus.idle,
        blockedReason = nil,
        last = { id = nil, taskType = nil, status = nil, reason = nil, owner = nil }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Movement.key, str)
end

---Conditions under which we refuse to drive the character, the MQ2MoveUtils "autopause"
---equivalent. Sitting and ducking are stood up out of; everything else waits.
---@return string|nil reason nil when we are free to move
local function blockedReason()
    if mq.TLO.Me.Y() == nil then return "not in the world" end

    local state = mq.TLO.Me.State()
    if state == "DEAD" or state == "BIND" then return "state is " .. tostring(state) end
    if state == "FEIGN" then return "feigning" end
    if mq.TLO.Me.Stunned() then return "stunned" end
    if mq.TLO.Me.Mezzed() ~= nil then return "mezzed" end
    if mq.TLO.Me.Charmed() ~= nil then return "charmed" end

    -- bards move while they sing, everyone else would interrupt the cast
    if mq.TLO.Me.Casting() ~= nil and mq.TLO.Me.Class.ShortName() ~= "BRD" then return "casting" end

    if state == "SIT" or state == "DUCK" then
        Locomotion.StandIfNeeded()
        return "standing up"
    end

    return nil
end

---@param task MovementTask
---@return number taskId
local function start(task)
    if Movement._.task ~= nil then
        Movement._.task:Stop()
    end

    task.id = Movement._.nextId
    Movement._.nextId = Movement._.nextId + 1
    Movement._.task = task
    Movement._.status = MovementStatus.moving
    Movement._.blockedReason = nil

    DebugLog("Started task: " .. task:Describe())
    return task.id
end

---Release the movement keys, dropping anything we believe about their state. Call once at
---startup, where a previous run may have left a key down. Main loop only -- this one does
---talk to the client immediately.
function Movement.Init()
    Locomotion.ForceReleaseAll()
    Movement.Stop()
end

---Move to a fixed location
---@param y number
---@param x number
---@param options? table see MoveTo.new
---@return number taskId
function Movement.MoveToLoc(y, x, options)
    options = options or {}
    options.y = y
    options.x = x
    options.spawnId = nil
    return start(MoveTo.new(options))
end

---Move to wherever a spawn currently is
---@param spawnId number
---@param options? table see MoveTo.new
---@return number taskId
function Movement.MoveToSpawn(spawnId, options)
    options = options or {}
    options.spawnId = spawnId
    return start(MoveTo.new(options))
end

---Hold position on a spawn
---@param spawnId number
---@param options? table see Stick.new
---@return number taskId
function Movement.Stick(spawnId, options)
    return start(Stick.new(spawnId, options))
end

---Follow a spawn's trail
---@param spawnId number
---@param options? table see Follow.new
---@return number taskId
function Movement.Follow(spawnId, options)
    return start(Follow.new(spawnId, options))
end

---Cancel the active task, whoever owns it, and release the movement keys
function Movement.Stop()
    local task = Movement._.task
    if task ~= nil then
        DebugLog("Stopping task: " .. task:Describe())
        task:Stop()
        Movement._.task = nil
    end

    Locomotion.ReleaseAll()
    Movement._.status = MovementStatus.idle
    Movement._.blockedReason = nil
end

---Cancel the active task only while the given owner still holds it, so a behavior cleaning
---up after itself cannot cancel a move some higher priority behavior has since started.
---@param owner string
---@return boolean stopped
function Movement.StopFor(owner)
    if Movement._.task == nil or Movement._.task.owner ~= owner then return false end
    Movement.Stop()
    return true
end

---Run one frame of the active task.
---
---**Call this every frame from the host's main loop, and from nowhere else.** Everything
---that actually touches the client -- key commands, `/face`, `/stand` -- happens here and
---only here; the request functions above just record intent. That is what makes it safe to
---start or stop movement from an ImGui button or a chat event handler.
---@return string status
function Movement.Pulse()
    local task = Movement._.task
    if task == nil then
        Movement._.status = MovementStatus.idle
        Locomotion.Apply()
        return MovementStatus.idle
    end

    local reason = blockedReason()
    if reason ~= nil then
        if Movement._.blockedReason ~= reason then
            DebugLog("Movement blocked: " .. reason)
        end
        Locomotion.ReleaseAll()
        task:OnBlocked()
        Movement._.blockedReason = reason
        Movement._.status = MovementStatus.blocked
        Locomotion.Apply()
        return MovementStatus.blocked
    end
    Movement._.blockedReason = nil

    local status = task:Pulse()
    Movement._.status = status

    if MovementStatus.IsTerminal(status) then
        Movement._.last.id = task.id
        Movement._.last.taskType = task.key
        Movement._.last.status = status
        Movement._.last.reason = task:FailReason()
        Movement._.last.owner = task.owner
        DebugLog("Task finished [" .. status .. "]: " .. task:Describe())
        Movement.Stop()
    end

    Locomotion.Apply()
    return status
end

---@return boolean isActive true while a task is running
function Movement.IsActive()
    return Movement._.task ~= nil
end

---@return string status of the last pulse
function Movement.GetStatus()
    return Movement._.status
end

---@return string|nil reason why movement is currently held off
function Movement.GetBlockedReason()
    return Movement._.blockedReason
end

---@return string|nil taskType one of Movement.taskTypes
function Movement.GetTaskType()
    if Movement._.task == nil then return nil end
    return Movement._.task.key
end

---@return number|nil taskId of the active task
function Movement.GetTaskId()
    if Movement._.task == nil then return nil end
    return Movement._.task.id
end

---@return string|nil owner of the active task
function Movement.GetOwner()
    if Movement._.task == nil then return nil end
    return Movement._.task.owner
end

---@param owner string
---@return boolean isOwner true when the active task belongs to this owner
function Movement.IsOwnedBy(owner)
    return Movement._.task ~= nil and Movement._.task.owner == owner
end

---@return number|nil spawnId the active task is working against
function Movement.GetSpawnId()
    if Movement._.task == nil then return nil end
    return Movement._.task:GetSpawnId()
end

---How a task ended. Returns nil while it is still running, so a caller can poll the id it
---was handed without tracking anything else.
---@param taskId number
---@return string|nil status terminal status, or nil while the task is still running
---@return string|nil reason failure reason, when there was one
function Movement.GetResult(taskId)
    if Movement._.task ~= nil and Movement._.task.id == taskId then return nil, nil end
    if Movement._.last.id == taskId then return Movement._.last.status, Movement._.last.reason end
    return MovementStatus.failed, "cancelled"
end

---@param spawnId? number when given, also require the task to be following this spawn
---@return boolean isFollowing
function Movement.IsFollowing(spawnId)
    if Movement.GetTaskType() ~= Movement.taskTypes.follow then return false end
    return spawnId == nil or Movement.GetSpawnId() == spawnId
end

---@param spawnId? number when given, also require the task to be sticking to this spawn
---@return boolean isSticking
function Movement.IsSticking(spawnId)
    if Movement.GetTaskType() ~= Movement.taskTypes.stick then return false end
    return spawnId == nil or Movement.GetSpawnId() == spawnId
end

---@return boolean isMovingTo true while a MoveTo task is running
function Movement.IsMovingTo()
    return Movement.GetTaskType() == Movement.taskTypes.moveTo
end

---@return string description of what movement is doing, for status output
function Movement.Describe()
    if Movement._.task == nil then return "standby" end
    return Movement._.task:Describe()
end

return Movement
