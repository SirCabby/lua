---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local CastOutcome = require("utils.Casting.CastOutcome")
local CastStatus = require("utils.Casting.CastStatus")
local CastSubject = require("utils.Casting.CastSubject")
local CastTask = require("utils.Casting.CastTask")

---The casting service: one cast at a time, pulsed once per frame.
---
---This is to spells what `utils/Movement` is to movement keys, and for the same reasons. A cast
---takes seconds, cannot be hurried, and is lost if anything moves the character in the
---meantime, so it cannot be a function a state calls and waits on -- a script that blocks for
---three seconds hears no chat orders and watches nobody's health bar. Callers **request** a cast
---and poll the result by id.
---
---Three rules make it safe to share between behaviors that do not know about each other:
---
---1. **One cast at a time, and priority decides who gets it.** A request outranks the cast in
---    progress or it is refused; nothing queues up behind an in-flight heal hoping for a turn.
---    Interrupting is deliberate and traceable rather than emergent.
---2. **A cast in progress raises a priority floor.** While a cast owned by priority P is being
---    prepared or is in flight, the host's state chain must starve everything weaker than P --
---    otherwise the follow state walks off mid-cast and loses the heal that outranks it. The
---    host wires this up with `GetPriorityFloor`; see `cabby/casting.lua`.
---3. **Requests never touch the client; only `Pulse()` does.** Every game command -- targeting,
---    memorizing, `/cast`, `/stopcast` -- is issued from the pulse, so a cast can be asked for
---    from an ImGui button or a chat event handler without running EQ commands mid-frame, which
---    is a crash-to-desktop hazard.
---
---What it deliberately does not do: retry. A fizzle or a resist is reported to the caller, and
---the caller decides whether casting again is still the right thing to do.
---@class Casting
local Casting = {
    author = "judged",
    key = "Casting",
    status = CastStatus,
    outcomes = CastOutcome,
    kinds = CastSubject.kinds,
    ---Timings, all overridable through `Configure`. The host keeps the user-facing ones in
    ---config; the rest are here because nobody sensibly tunes them.
    settings = {
        ---gem to memorize into when a spell is not already memorized; 0 means the last gem
        memGem = 0,
        ---how long "stopped moving" has to hold before a cast is safe to start
        settleMs = 250,
        ---budget for everything before the cast is fired: targeting, standing still, memorizing
        prepareTimeoutMs = 5000,
        ---how long to wait on a gem that is nearly off cooldown before refusing the cast
        readyWaitMs = 1500,
        memorizeTimeoutMs = 15000,
        ---how long after a completed cast a "resisted"/"unaffected" line still belongs to it
        lateWindowMs = 2000
    },
    _ = {
        isInit = false,
        task = nil,
        pending = nil,
        nextId = 1,
        mayStopMovement = nil,
        last = {
            id = nil,
            status = nil,
            outcome = nil,
            reason = nil,
            owner = nil,
            subject = nil,
            finishedMs = 0
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Casting.key, str)
end

---Priorities are the host's numbers -- smaller is stronger, matching a state chain walked from
---the top. An unknown priority is treated as the weakest thing there is, so a caller that
---forgets to declare one cannot preempt anybody.
---@param priority number|nil
---@return number
local function comparable(priority)
    if type(priority) ~= "number" then return math.huge end
    return priority
end

---@param outcome string
---@param isLate boolean
local function onOutcomeLine(outcome, isLate)
    local task = Casting._.task

    -- Only a cast that has been fired can be the subject of these lines. While a cast is still
    -- being prepared nothing of ours is in the air, so a resist or a fizzle belongs to someone
    -- else -- a proc, a pet, another script -- and taking it would fail a cast that never
    -- started.
    if task ~= nil and CastStatus.IsCommitted(task:Status()) then
        DebugLog("Cast outcome line: " .. outcome)
        task:RecordOutcome(outcome)
        return
    end

    -- No cast in the air. A late line just after one completed is that cast's real result: the
    -- spell went off, so the cast bar closed and we reported success, and only now does the
    -- client mention that the target resisted it. Refine what we already reported rather than
    -- throwing it away -- a caller that polls the result a frame later sees the truth.
    if not isLate then return end

    local last = Casting._.last
    if last.id == nil or last.status ~= CastStatus.succeeded then return end
    if Time.current_time() - last.finishedMs > Casting.settings.lateWindowMs then return end

    DebugLog("Late cast outcome for id " .. tostring(last.id) .. ": " .. outcome)
    last.outcome = outcome
    last.reason = CastOutcome.Describe(outcome)
end

---@param options? table movementArbiter: fun(castPriority, movementOwner): boolean, plus any
---`Casting.settings` keys
function Casting.Init(options)
    if Casting._.isInit then return end
    options = options or {}

    Casting.Configure(options)
    Casting._.mayStopMovement = options.movementArbiter

    -- Registered here rather than at require time: requiring a module should not reach into the
    -- client. The host's main loop has to be calling mq.doevents() for these to arrive, which is
    -- also what puts them on the main loop, ahead of this service's pulse.
    CastOutcome.RegisterEvents(onOutcomeLine)

    Casting._.isInit = true
end

---Change timings at runtime. Only the keys present are touched, so a config page can push one
---setting without knowing about the others, and anything else in the table (the movement
---arbiter, say) is ignored rather than becoming a setting.
---@param settings table
function Casting.Configure(settings)
    for key, value in pairs(settings or {}) do
        if Casting.settings[key] ~= nil then
            Casting.settings[key] = value
        end
    end
end

---Which gem a spell that is not memorized should be memorized into. The last gem by default:
---it is the one a hand-played caster is least likely to have something they care about in.
---@param requested number|nil
---@return number gem
local function resolveGem(requested)
    local gems = tonumber(mq.TLO.Me.NumGems()) or 8
    local configured = Casting.settings.memGem
    if configured == nil or configured < 1 then configured = gems end
    local gem = requested or configured
    gem = math.floor(gem)
    if gem < 1 then gem = 1 end
    if gem > gems then gem = gems end
    return gem
end

---@param task CastTask
local function recordFinished(task)
    local last = Casting._.last
    last.id = task.id
    last.status = task:Status()
    last.outcome = task:Outcome()
    last.reason = task:Reason()
    last.owner = task.owner
    last.subject = task:Subject():Describe()
    last.finishedMs = Time.current_time()

    if task.onDone ~= nil then
        -- pcall'd on purpose: a caller's bad callback should not take the casting service down
        -- with it, and the host would otherwise pause casting for a fault that is not ours
        local ok, err = pcall(task.onDone, last.status, last.outcome, last.reason)
        if not ok then
            print("(Casting) Error in the completion callback for " .. tostring(last.subject) .. ": " .. tostring(err))
        end
    end
end

---Ask for a cast.
---
---@param subject CastSubject what to cast
---@param options? table
--- owner: string, which behavior this cast belongs to -- used to stop it again later
--- priority: number, that behavior's place in the host's priority chain; smaller is stronger
--- targetId: number, target this spawn first
--- gem: number, override the memorize gem
--- onDone: fun(status, outcome, reason), called from the pulse once the cast is terminal. A
---   convenience over polling `GetResult`; note that it fires *before* any late resist line can
---   refine the result.
---@return number|nil taskId poll it with `GetResult`; nil when the request was refused
---@return string|nil refusedReason why, when it was refused
function Casting.Cast(subject, options)
    options = options or {}

    local active = Casting._.task
    local pending = Casting._.pending

    -- Two casts can be in the running at once for a frame: one in progress and one queued
    -- behind it. A new request has to outrank both, or the queue would be decided by whoever
    -- asked last rather than by priority.
    local incumbent = active
    if pending ~= nil and (incumbent == nil or comparable(pending.priority) < comparable(incumbent.priority)) then
        incumbent = pending
    end

    if incumbent ~= nil then
        -- Equal priority does not win: two behaviors at the same band asking at once means the
        -- one that got there first keeps the cast, rather than the two of them interrupting each
        -- other every frame. A caller that means to replace its own cast says so with
        -- `StopFor` first.
        if comparable(options.priority) >= comparable(incumbent.priority) then
            return nil, "already casting " .. incumbent:Describe()
        end

        DebugLog("Preempting " .. incumbent:Describe() .. " for " .. subject:Describe())

        if active ~= nil then
            active:RequestStop(CastOutcome.preempted)
        end
        if pending ~= nil then
            -- never started, so there is nothing to interrupt; record it so its owner gets a
            -- straight answer instead of the "cancelled" fallback
            pending:Abandon(CastOutcome.preempted)
            recordFinished(pending)
            Casting._.pending = nil
        end
    end

    local task = CastTask.new(subject, {
        owner = options.owner,
        priority = options.priority,
        targetId = options.targetId,
        onDone = options.onDone,
        gem = resolveGem(options.gem),
        settleMs = Casting.settings.settleMs,
        prepareTimeoutMs = Casting.settings.prepareTimeoutMs,
        readyWaitMs = Casting.settings.readyWaitMs,
        memorizeTimeoutMs = Casting.settings.memorizeTimeoutMs,
        mayStopMovement = Casting._.mayStopMovement
    })

    task.id = Casting._.nextId
    Casting._.nextId = Casting._.nextId + 1

    -- The new task waits for the pulse even when nothing was in its way, so that a cast asked
    -- for from an ImGui button behaves exactly like one asked for from a state, and so that a
    -- preempted cast gets its /stopcast in before this one starts.
    Casting._.pending = task
    DebugLog("Cast requested [" .. tostring(task.id) .. "]: " .. task:Describe())
    return task.id, nil
end

---@param name string spell name, as it appears in the spellbook
---@param options? table see Casting.Cast
---@return number|nil taskId
---@return string|nil refusedReason
function Casting.CastSpell(name, options)
    return Casting.Cast(CastSubject.Spell(name), options)
end

---@param name string item name, not the name of the spell on it
---@param options? table see Casting.Cast
---@return number|nil taskId
---@return string|nil refusedReason
function Casting.CastItem(name, options)
    return Casting.Cast(CastSubject.Item(name), options)
end

---@param name string alternate advancement ability name
---@param options? table see Casting.Cast
---@return number|nil taskId
---@return string|nil refusedReason
function Casting.CastAlt(name, options)
    return Casting.Cast(CastSubject.Alt(name), options)
end

---One frame of casting. **Call this every frame from the host's main loop, and from nowhere
---else** -- everything that talks to the client happens here.
---@return string status
function Casting.Pulse()
    local task = Casting._.task

    -- Promote a queued request only on a frame where nothing else is running, which gives an
    -- interrupted cast the frame it needs for its /stopcast to land before the next one starts
    if task == nil and Casting._.pending ~= nil then
        task = Casting._.pending
        Casting._.pending = nil
        Casting._.task = task
        DebugLog("Starting cast [" .. tostring(task.id) .. "]: " .. task:Describe())
    end

    if task == nil then return CastStatus.idle end

    local status = task:Pulse()

    if CastStatus.IsTerminal(status) then
        recordFinished(task)
        Casting._.task = nil
    end

    return status
end

---Cancel the cast in progress, whoever owns it. Takes effect on the next pulse.
---@param outcome? string defaults to aborted
---@return boolean stopped
function Casting.Interrupt(outcome)
    local task = Casting._.task
    if task == nil then
        if Casting._.pending == nil then return false end
        Casting._.pending = nil
        return true
    end

    task:RequestStop(outcome or CastOutcome.aborted)
    return true
end

---Cancel the cast only while this owner still holds it, so a behavior cleaning up after itself
---cannot cancel a cast some higher priority behavior has since started.
---@param owner string
---@return boolean stopped
function Casting.StopFor(owner)
    local task = Casting._.task
    if task ~= nil and task.owner == owner then
        task:RequestStop(CastOutcome.aborted)
        return true
    end

    local pending = Casting._.pending
    if pending ~= nil and pending.owner == owner then
        Casting._.pending = nil
        return true
    end

    return false
end

---Service contract: called when the host shuts down or pauses us for repeated failures. Unlike
---`Interrupt` this cannot wait for a pulse that may never come, so it talks to the client
---directly -- which is safe because the host calls it from the main loop.
function Casting.Stop()
    Casting._.pending = nil

    local task = Casting._.task
    if task == nil then return end

    task:Abandon(CastOutcome.aborted)
    recordFinished(task)
    Casting._.task = nil
end

---@return boolean isActive true while a cast is being prepared or is in flight
function Casting.IsActive()
    return Casting._.task ~= nil or Casting._.pending ~= nil
end

---Whether we are past the point of no return: the cast is up and anything that moves the
---character loses it.
---@return boolean isCommitted
function Casting.IsCommitted()
    local task = Casting._.task
    return task ~= nil and CastStatus.IsCommitted(task:Status())
end

---@return string status
function Casting.GetStatus()
    local task = Casting._.task
    if task == nil then
        return Casting._.pending ~= nil and CastStatus.preparing or CastStatus.idle
    end
    return task:Status()
end

---@return string|nil reason what casting is waiting on right now
function Casting.GetReason()
    local task = Casting._.task
    if task == nil then return nil end
    return task:Reason()
end

---@return string|nil owner of the cast in progress
function Casting.GetOwner()
    local task = Casting._.task or Casting._.pending
    if task == nil then return nil end
    return task.owner
end

---@return number|nil priority of the cast in progress
function Casting.GetPriority()
    local task = Casting._.task
    if task == nil then return nil end
    return task.priority
end

---@return number|nil taskId of the cast in progress
function Casting.GetTaskId()
    local task = Casting._.task or Casting._.pending
    if task == nil then return nil end
    return task.id
end

---@param owner string
---@return boolean isCasting true when the cast in progress belongs to this owner
function Casting.IsCastingFor(owner)
    return Casting.GetOwner() == owner
end

---The priority nothing weaker may run at while a cast is in progress.
---
---This is the whole reason a cast has a priority. A heal that has committed three seconds of
---cast time is lost if the follow state below it walks off, or if the melee state below it
---sticks to something -- so while this returns a number, the host must starve every state
---weaker than it. It is deliberately raised during preparation as well: a cast waiting to stand
---still has even more to lose from a weaker behavior starting to move again.
---@return number|nil floor nil when nothing is casting
function Casting.GetPriorityFloor()
    local task = Casting._.task
    if task == nil then return nil end
    return task.priority
end

---How a cast ended. Returns nil while it is still running, so a caller can poll the id it was
---handed without tracking anything else.
---
---A result stays available until the next cast finishes, and a late "resisted" or "unaffected"
---line can refine a success into the outcome it really had for a moment afterwards -- so a
---caller that cares about resists should read the result on the frame after it first goes
---terminal rather than acting on the first non-nil answer.
---@param taskId number
---@return string|nil status terminal status, nil while the cast is still running
---@return string|nil outcome
---@return string|nil reason
function Casting.GetResult(taskId)
    local task = Casting._.task
    if task ~= nil and task.id == taskId then return nil, nil, task:Reason() end

    local pending = Casting._.pending
    if pending ~= nil and pending.id == taskId then return nil, nil, "queued" end

    local last = Casting._.last
    if last.id == taskId then return last.status, last.outcome, last.reason end

    return CastStatus.failed, CastOutcome.aborted, "cancelled"
end

---@return string description of what casting is doing, for status output
function Casting.Describe()
    local task = Casting._.task or Casting._.pending
    if task == nil then return "standby" end
    return task:Describe()
end

return Casting
