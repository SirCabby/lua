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
---
---A task carries the **band** of whoever asked for it, the same way a cast does, because standing
---still and moving are two behaviors wanting the same character at once and the answer to that is
---never "whoever asked last": see `castHoldsUs` below and `CastTask.HoldStill` at the other end of
---the same question.
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
        castArbiter = nil,
        last = { id = nil, taskType = nil, status = nil, reason = nil, owner = nil }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Movement.key, str)
end

---Is the cast bar that is up right now one this task has to stand still for?
---
---Moving loses a cast, so the character cannot do both -- and which of the two gives way is a
---question of *whose* cast and *whose* movement, not of which happened to start first. The host
---knows the bands; this module does not, so it asks (`Movement.Init`'s `castArbiter`) and defaults
---to standing still for anything, which is what this did before there was anyone to ask.
---
---The answer that matters is the one about a **weaker** cast: a buff that cannot be cast while the
---group is running is a buff that fails and says so, not a reason to stop following. Pinning the
---character for it is how a follower ends up watching its group leave -- the cast is not lost by
---walking away, it is thrown away by standing there.
---@param task MovementTask the active task, which carries the band that asked for it
---@return boolean holdsUs
local function castHoldsUs(task)
    local arbiter = Movement._.castArbiter
    if arbiter == nil then return true end
    return arbiter(task.owner, task.priority) == true
end

---Conditions under which we refuse to drive the character, the MQ2MoveUtils "autopause"
---equivalent. Sitting and ducking are stood up out of; everything else waits.
---@param task MovementTask the active task, which gets a say in the sitting case
---@return string|nil reason nil when we are free to move
local function blockedReason(task)
    if mq.TLO.Me.Y() == nil then return "not in the world" end

    local state = mq.TLO.Me.State()
    if state == "BIND" then return "binding" end
    if state == "FEIGN" then return "feigning" end
    if mq.TLO.Me.Stunned() then return "stunned" end
    if mq.TLO.Me.Mezzed() ~= nil then return "mezzed" end
    if mq.TLO.Me.Charmed() ~= nil then return "charmed" end
    -- the same answer as the three above, arrived at from the other side: those three take the keys
    -- away, and a fear takes the steering -- where the character goes is the server's to say, and
    -- pressing into that is a contest we lose while wearing the movement keys out
    if mq.TLO.Me.Feared() ~= nil then return "feared" end

    -- bards move while they sing, and everyone else stands still for a cast worth more than
    -- whatever this task is doing -- which is a question for whoever knows the bands
    if mq.TLO.Me.Casting() ~= nil and mq.TLO.Me.Class.ShortName() ~= "BRD" and castHoldsUs(task) then
        return "casting"
    end

    if state == "SIT" or state == "DUCK" then
        -- A task with nothing to do this frame is not a reason to be on anyone's feet. A follow
        -- whose target is standing still is exactly that: it is alive and keeping its trail warm,
        -- and it stays alive for as long as the follow order does. Standing up for it means every
        -- sit is undone a second later, forever, which is a `/sit` and a `/stand` traded with the
        -- rest state for as long as `followme` is on -- and neither side is wrong, because
        -- standing up is part of *executing* a move rather than part of holding one.
        if task.IsParked ~= nil and task:IsParked() then
            return "sitting, with nothing to move toward"
        end

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
---@param options? table castArbiter: fun(owner: string|nil, priority: number|nil): boolean --
---does the cast in the air outrank this movement task? Defaults to yes for every cast, which is
---the answer for a host with no priority chain to compare them in (see `castHoldsUs`).
function Movement.Init(options)
    Movement._.castArbiter = (options or {}).castArbiter
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

---Cancel the active task and put the movement keys down *now*, for a caller that knows there
---will be no next frame -- a script about to stop itself, above all. `Stop` only records the
---release; the key commands are sent by `Pulse`, and a `/keypress <key> hold` outlives the
---script that pressed it, so stopping without this leaves the character running.
function Movement.StopNow()
    Movement.Stop()
    Locomotion.ForceReleaseAll()
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
    -- Death cancels the task rather than holding it. We come back at a bind point, and a plan
    -- made from where we fell -- above all a stick at whatever killed us -- must not be what
    -- the respawn wakes up to; the owner that could have tidied it up may not get a turn for a
    -- while (a healer has work exactly then). Cancelling costs nothing when the order behind
    -- the task still stands, because owners re-derive every pass and simply ask again --
    -- a follow order survives death on purpose and restarts from wherever we respawn.
    -- MQ2MoveUtils called this BreakOnDeath. HOVER is dead-but-not-released.
    local myState = mq.TLO.Me.State()
    if Movement._.task ~= nil and (myState == "DEAD" or myState == "HOVER") then
        DebugLog("Death cancels task: " .. Movement._.task:Describe())
        Movement.Stop()
    end

    local task = Movement._.task
    if task == nil then
        Movement._.status = MovementStatus.idle
        Locomotion.Apply()
        return MovementStatus.idle
    end

    local reason = blockedReason(task)
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

---Whether the active task has anything to do right now.
---
---Three different things a caller can mean by "are we moving", and this is the one the others
---cannot answer: *idle* is having no task at all, *blocked* is a task that wants to move and may
---not, and **parked** is a task that is alive and has nowhere to go -- a follow whose target is
---standing still. The distinction is what lets something else use the character while an order
---that is not asking for anything stays standing: resting, above all, which would otherwise never
---get a frame it could keep for as long as a follow order was in place.
---
---Tasks that cannot park say so by not implementing it. A `MoveToLoc` is never parked -- arriving
---is what ends it -- and a stick that has closed to range is holding a mob, which is not a moment
---to be sitting down in whatever the task thinks.
---@return boolean isParked false when there is no task, or the task wants to move
function Movement.IsParked()
    local task = Movement._.task
    if task == nil or task.IsParked == nil then return false end
    return task:IsParked() == true
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

---The band the active task was asked for at, for whoever has to weigh moving against something
---else the character could be doing instead -- a cast, above all.
---
---Published rather than looked up from the owner, because the owner is a *key* and not every mover
---is a state: `cabby.travel` carries the follow for two different states at two different bands, and
---a lookup by its name lands on nobody. A caller that could not rank it read that as "no rank at
---all" and overruled it, which is how a follow got cancelled by the buff below it (2026-08).
---@return number|nil priority nil when nothing is running, or when the mover declared no band
function Movement.GetPriority()
    if Movement._.task == nil then return nil end
    return Movement._.task.priority
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

---Retune how close a running follow holds station, while the given owner still holds it -- the
---same gate `StopFor` uses, and for the same reason: an answer this caller re-derives is about
---the follow *it* asked for, and a higher priority behaviour's follow is not its to reach into.
---
---Nothing else is disturbed: the trail, the hysteresis and the task's id all survive, which is
---what makes this the right shape for an answer that changes while the follow runs. A caller with
---a fixed answer says it once in the options to `Follow` and never comes back here.
---@param owner string
---@param distance number how close the follow closes to its target
---@param resumeDistance number how far the target gets before it closes again
---@param requireSight? boolean whether being in range is on its own a reason to stand still, or
---whether a target out of sight keeps the follow walking (see Follow:WithinHold)
---@return boolean applied false when this owner has no follow running
function Movement.SetFollowHold(owner, distance, resumeDistance, requireSight)
    if not Movement.IsFollowing() or not Movement.IsOwnedBy(owner) then return false end
    Movement._.task:SetHold(distance, resumeDistance, requireSight)
    return true
end

---Whether a running follow is walking only because it cannot see what it follows -- near enough
---to have parked, going anyway for a view of them (see `Follow:IsClosingForSight`).
---
---Worth asking about because it is a short move on purpose, so a caller that judges movement by
---ground covered has to know not to judge this one that way: `cabby.travel` holds its stuck check
---off it. Tasks that cannot answer say so by not implementing it, the same way parking works.
---@return boolean isClosingForSight false when there is no task, or the task never asked for sight
function Movement.IsClosingForSight()
    local task = Movement._.task
    if task == nil or task.IsClosingForSight == nil then return false end
    return task:IsClosingForSight() == true
end

---Retune how close a running stick holds, while the given owner still holds it -- the same gate
---`SetFollowHold` uses, and for the same reason: an answer this caller re-derives is about the stick
---*it* asked for, and a higher priority behaviour's stick is not its to reach into.
---
---Exists for the same reason its follow counterpart does: the distance is an answer that changes
---while the task runs. A main tank closing inside everybody else on a rooted mob is re-deriving that
---answer every pass off where the rest of the group is standing, and restarting the stick to say so
---would throw away the closing-speed history and the stuck detector on every one of them.
---@param owner string
---@param distance number how close the stick holds station
---@return boolean applied false when this owner has no stick running
function Movement.SetStickDistance(owner, distance)
    if not Movement.IsSticking() or not Movement.IsOwnedBy(owner) then return false end
    Movement._.task:SetDistance(distance)
    return true
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
