---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")

local CastOutcome = require("utils.Casting.CastOutcome")
local CastStatus = require("utils.Casting.CastStatus")
local Immobilizer = require("utils.Casting.Immobilizer")

---One cast, from the moment someone asks for it to the moment it succeeds or fails.
---
---The sequence is the same one every casting macro since spell_routines.inc has had to walk,
---because EQ imposes it: be able to use the thing, be on the right target, be standing still,
---have it memorized, fire it, and then find out what happened. What is different here is that
---none of it blocks. Each step does one frame of work and says what it is waiting on, so the
---script it lives in keeps running -- which is the whole point of casting from a state machine
---rather than from a macro.
---
---The task never retries. A fizzle, a resist or an interrupt is reported to whoever asked for
---the cast, and that caller decides whether casting again is still the right thing to do -- by
---then the mob may be dead, or the heal no longer needed. MQ2Cast loops internally because a
---macro has nowhere else to put the decision; a state machine does.
---@class CastTask
local CastTask = {
    key = "CastTask"
}
CastTask.__index = CastTask

setmetatable(CastTask, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---Cast times at or below this are instant: no cast bar, nothing to interrupt, so no standing
---still and nothing to watch for.
local instantCastMs = 100

---How often a target that will not take, or a memorize that did not land, is asked for again.
---Re-issuing the command is the retry; there is nothing else to try.
local retryIntervalMs = 2000

---How long the same "waiting for..." can hold before it is worth saying out loud. Not a failure:
---a cast that cannot get started is usually waiting for something that will change, and the one
---thing worse than waiting is waiting silently.
local stuckNoticeMs = 30000

---@param str string
local function DebugLog(str)
    Debug.Log(CastTask.key, str)
end

---@return number ping current latency in ms, defaulted when the client has not reported one
local function ping()
    local latency = tonumber(mq.TLO.EverQuest.Ping())
    if latency == nil or latency < 0 then return 100 end
    return math.min(latency, 2000)
end

---@param subject CastSubject
---@param options? table
--- owner: string, whose cast this is (a state key)
--- priority: number, that owner's place in the priority chain; smaller is stronger
--- targetId: number, target this spawn before casting
--- gem: number, memorize into this gem when the spell is not already memorized
--- settleMs / readyWaitMs / memorizeRetryMs: timings, all defaulted
--- mayStopMovement: fun(priority, movementOwner): boolean -- may this cast cancel the movement
---   task that is running? Defaults to yes; the host installs the real policy.
---@return CastTask
function CastTask.new(subject, options)
    options = options or {}
    local self = setmetatable({}, CastTask)

    self.id = nil
    self.owner = options.owner
    self.priority = options.priority
    ---called by the service once this task is terminal; the task itself never uses it
    self.onDone = options.onDone

---@diagnostic disable-next-line: inject-field
    self._ = {
        subject = subject,
        targetId = options.targetId,
        gem = options.gem,
        settleMs = options.settleMs or 250,
        readyWaitMs = options.readyWaitMs or 1500,
        memorizeRetryMs = options.memorizeRetryMs or 15000,
        mayStopMovement = options.mayStopMovement or function() return true end,

        status = CastStatus.preparing,
        outcome = nil,
        reason = nil,
        step = nil,
        pendingOutcome = nil,
        stopOutcome = nil,

        startedMs = Time.current_time(),
        stepDeadlineMs = nil,
        stuckReason = nil,
        stuckSinceMs = nil,
        stuckReported = false,
        immobilizer = nil,
        -- assumed until validate works out the cast time: a caller asking "may I move" before
        -- the first pulse should be told no, not maybe
        requiresStillness = true,
        targetedAtMs = nil,
        memorizedAtMs = nil,
        firedAtMs = nil,
        castTimeMs = 0
    }

    return self
end

---A step returns whether the task should keep working this frame:
---
---- `advance(next)` -- this step is done, run the next one immediately. Preparing a cast is a
---  chain of cheap checks, and spending a frame apiece on them would put a tenth of a second
---  between "heal now" and the cast starting.
---- `waiting(reason)` -- we are waiting on the client for something, so stop until next frame.
---- `finish(outcome)` -- terminal.
---@param outcome string
---@param reason? string
---@return boolean keepWorking always false
local function finish(self, outcome, reason)
    self._.outcome = outcome
    self._.reason = reason or CastOutcome.Describe(outcome)
    self._.status = outcome == CastOutcome.succeeded and CastStatus.succeeded or CastStatus.failed
    self._.step = nil
    DebugLog("Cast of [" .. self._.subject:Describe() .. "] finished: " .. self._.status ..
        " (" .. self._.reason .. ")")
    return false
end

---@param reason string
---@return boolean keepWorking always false
local function waiting(self, reason)
    self._.reason = reason
    return false
end

---@param nextStep function
---@return boolean keepWorking always true
local function advance(self, nextStep)
    self._.step = nextStep
    self._.reason = nil
    return true
end

---Everything the client can tell us before we commit anything: do we have it, can we afford
---it, is it off cooldown.
---
---Readiness gets a short grace period rather than an outright refusal. The usual reason a gem
---is not ready is the global recovery from the cast before it, which is under a second, and a
---caller that has decided to heal should not have to re-ask every frame until the client
---agrees.
local function validate(self)
    local subject = self._.subject

    if not subject:IsAvailable() then
        return finish(self, CastOutcome.notAvailable)
    end

    if mq.TLO.Me.Silenced() ~= nil and subject:IsSpell() then
        return finish(self, CastOutcome.silenced)
    end

    local manaCost = subject:ManaCost()
    if manaCost > 0 and (tonumber(mq.TLO.Me.CurrentMana()) or 0) < manaCost then
        return finish(self, CastOutcome.outOfMana)
    end

    local missingReagent = subject:MissingReagent()
    if missingReagent ~= nil then
        return finish(self, CastOutcome.missingComponents, "missing " .. missingReagent)
    end

    -- An unmemorized spell is not "not ready", it is a memorize away, and the readiness TLO
    -- cannot tell the difference. Skip the check and let the memorize step deal with it; the
    -- gem timer is checked again at the fire step, by which time it has been memorized.
    if subject:IsMemorized() and not subject:IsReady() then
        if Time.current_time() - self._.startedMs >= self._.readyWaitMs then
            return finish(self, CastOutcome.notReady)
        end
        return waiting(self, "waiting for " .. subject:Name() .. " to be ready")
    end

    self._.castTimeMs = subject:CastTimeMs()
    -- Bards sing on the move, and an instant cast has no bar to lose. Worked out here rather
    -- than at the hold-still step because callers ask whether this cast pins the character down
    -- (`RequiresStillness`) from the moment it is accepted.
    local isBardSong = subject:IsSpell() and mq.TLO.Me.Class.ShortName() == "BRD"
    self._.requiresStillness = not isBardSong and self._.castTimeMs > instantCastMs

    return advance(self, self.AcquireTarget)
end

---Get on the target the caller asked for, and refuse the cast now if the spell cannot be aimed
---at what we ended up with. EQ would refuse it anyway -- the point of checking first is that a
---refusal here costs nothing, while one from the client costs a gem timer.
local function acquireTarget(self)
    local subject = self._.subject
    local targetId = self._.targetId

    if targetId ~= nil and tonumber(mq.TLO.Target.ID()) ~= targetId then
        if mq.TLO.Spawn("id " .. tostring(targetId)).ID() == nil then
            return finish(self, CastOutcome.noTarget, "spawn " .. tostring(targetId) .. " is not here")
        end

        -- Ask again on a timer rather than giving up. The spawn is here (checked above), so the
        -- target either took and the client has not caught up, or something transient ate it;
        -- both are answered by asking again, and neither is answered by failing.
        local now = Time.current_time()
        if self._.targetedAtMs == nil or now - self._.targetedAtMs >= retryIntervalMs + ping() then
            self._.targetedAtMs = now
            DebugLog("Targeting spawn " .. tostring(targetId) .. " to cast " .. subject:Describe())
            mq.cmdf("/mqtarget id %d", targetId)
        end

        return waiting(self, "targeting spawn " .. tostring(targetId))
    end

    if subject:NeedsTarget() then
        local currentTargetId = tonumber(mq.TLO.Target.ID())
        if currentTargetId == nil or currentTargetId < 1 then
            return finish(self, CastOutcome.noTarget)
        end

        local range = subject:Range()
        local distance = tonumber(mq.TLO.Target.Distance())
        if range > 0 and distance ~= nil and distance > range then
            return finish(self, CastOutcome.outOfRange,
                "target is " .. tostring(math.floor(distance)) .. " away, range is " .. tostring(math.floor(range)))
        end

        if mq.TLO.Target.LineOfSight() == false then
            return finish(self, CastOutcome.cannotSee)
        end
    end

    return advance(self, self.HoldStill)
end

---Stand still long enough that the cast will survive being started.
---
---Bards are exempt for songs, which is what bards are: they sing on the move, and the movement
---service knows it too (its pause gate lets a bard keep walking mid-cast). Instant casts are
---exempt because there is no cast bar to lose.
local function holdStill(self)
    local subject = self._.subject

    if not self._.requiresStillness then
        return advance(self, self.Memorize)
    end

    -- Cancel the movement that is running, if this cast outranks whoever asked for it. A task
    -- we may not cancel is not fatal: a follow that has caught up is holding position with the
    -- keys released, which is standing still, so the check below can still succeed.
    if Movement.IsActive() and self._.mayStopMovement(self.priority, Movement.GetOwner(), self.owner) then
        DebugLog("Stopping movement owned by [" .. tostring(Movement.GetOwner()) .. "] to cast")
        Movement.Stop()
    end

    if self._.immobilizer == nil then
        self._.immobilizer = Immobilizer.new({ settleMs = self._.settleMs })
    end

    if self._.immobilizer:Pulse() == Immobilizer.results.settled then
        return advance(self, self.Memorize)
    end

    return waiting(self, self._.immobilizer:Reason() or "waiting to stand still")
end

---Memorize the spell if it is not in a gem. Items and AAs skip straight through.
local function memorize(self)
    local subject = self._.subject

    if subject:IsMemorized() then
        return advance(self, self.Fire)
    end

    local gem = self._.gem
    if gem == nil or gem < 1 then
        return finish(self, CastOutcome.notMemorized, "no gem to memorize into")
    end

    -- Memorizing is slow and can be refused outright (moving, or a spellbook that will not open),
    -- and the client says nothing either way. Ask again rather than failing: the reasons it did
    -- not take are the reasons that pass.
    local now = Time.current_time()
    if self._.memorizedAtMs == nil or now - self._.memorizedAtMs >= self._.memorizeRetryMs then
        self._.memorizedAtMs = now
        DebugLog("Memorizing " .. subject:Name() .. " into gem " .. tostring(gem))
        subject:Memorize(gem)
    end

    return waiting(self, "memorizing " .. subject:Name())
end

---Commit. Nothing after this point is free.
local function fire(self)
    local subject = self._.subject

    if mq.TLO.Me.Stunned() then
        return finish(self, CastOutcome.stunned)
    end

    -- Something is already casting and it is not us, since we have not fired yet: a hand cast,
    -- or the cast this one is replacing still winding down from its /stopcast. Wait for it. The
    -- alternative is failing on a cast that is about to end anyway, and being told to start over
    -- -- back through targeting and standing still -- for the sake of a second's impatience.
    if mq.TLO.Me.Casting.ID() ~= nil then
        return waiting(self, "waiting for the cast in progress to end")
    end

    if not subject:IsReady() then
        -- the gem timer moved under us between validate and here, most likely a recovery from
        -- something else that went off in the meantime
        return finish(self, CastOutcome.notReady)
    end

    -- Standing still was settled before the memorize, and memorizing takes seconds. Rather than
    -- fire into a character that started moving in the meantime, go back and settle again; the
    -- preparation budget is what stops that from going round forever.
    if self._.requiresStillness and mq.TLO.Me.Moving() then
        self._.immobilizer = nil
        return advance(self, self.HoldStill)
    end

    if not subject:Fire() then
        return finish(self, CastOutcome.notAvailable, "could not work out how to cast it")
    end

    local now = Time.current_time()
    self._.firedAtMs = now
    self._.status = CastStatus.casting
    self._.step = self.ConfirmStart
    self._.stepDeadlineMs = now + 1500 + ping() * 2
    -- stop here for the frame: the client has only just been handed the command, so nothing it
    -- says about casting yet means anything
    return waiting(self, "casting " .. subject:Name())
end

---Wait for the client to show the cast, which is what tells us the command took.
---
---An instant cast never shows one, so for those the absence of a complaint *is* the result: we
---give the client a beat to say no and call it done if it does not.
local function confirmStart(self)
    local now = Time.current_time()

    if mq.TLO.Me.Casting.ID() ~= nil then
        self._.step = self.InFlight
        self._.stepDeadlineMs = now + self._.castTimeMs + 3000 + ping() * 2
        return waiting(self, "casting " .. self._.subject:Name())
    end

    if self._.castTimeMs <= instantCastMs then
        if now - (self._.firedAtMs or now) >= 400 + ping() then
            return finish(self, CastOutcome.succeeded)
        end
        return waiting(self, "using " .. self._.subject:Name())
    end

    if now > (self._.stepDeadlineMs or 0) then
        return finish(self, CastOutcome.didNotStart)
    end

    return waiting(self, "casting " .. self._.subject:Name())
end

---The cast is up. It ends when the client stops showing it, and the reason it ended has either
---already arrived as a chat line (handled before we get here) or there was no reason, which
---means it went off.
local function inFlight(self)
    if mq.TLO.Me.Casting.ID() == nil then
        return finish(self, CastOutcome.succeeded)
    end

    if Time.current_time() > (self._.stepDeadlineMs or 0) then
        return finish(self, CastOutcome.timedOut)
    end

    local remaining = tonumber(mq.TLO.Me.CastTimeLeft())
    if remaining ~= nil and remaining > 0 then
        return waiting(self, "casting " .. self._.subject:Name() .. " (" ..
            tostring(math.floor(remaining / 100) / 10) .. "s left)")
    end

    return waiting(self, "casting " .. self._.subject:Name())
end

-- Steps are held as methods so each one can name the next by identity, the way the cabby
-- states name their action functions
CastTask.Validate = validate
CastTask.AcquireTarget = acquireTarget
CastTask.HoldStill = holdStill
CastTask.Memorize = memorize
CastTask.Fire = fire
CastTask.ConfirmStart = confirmStart
CastTask.InFlight = inFlight

---A cast that keeps waiting on the same thing is not failing, but it is worth mentioning.
---
---Nothing here gives up: waiting to stand still, waiting to get on target and waiting on a
---memorize are all waits for something that changes, and the caller re-asking would only throw
---away the waiting already done. The cost is that a genuinely stuck cast holds its priority floor
---quietly, so it says so once instead.
---@param self CastTask
local function noticeIfStuck(self)
    if CastStatus.IsTerminal(self._.status) then return end

    local reason = self._.reason
    if reason ~= self._.stuckReason then
        self._.stuckReason = reason
        self._.stuckSinceMs = Time.current_time()
        self._.stuckReported = false
        return
    end

    if reason == nil or self._.stuckReported then return end
    if Time.current_time() - (self._.stuckSinceMs or 0) < stuckNoticeMs then return end

    self._.stuckReported = true
    print("(Casting) Still " .. tostring(reason) .. " for " .. self._.subject:Describe() ..
        " -- it will keep trying; /ccast off to call it off")
end

---One frame of the cast. **Main loop only** -- this is where every game command is issued.
---@return string status one of CastStatus
function CastTask:Pulse()
    if CastStatus.IsTerminal(self._.status) then return self._.status end

    if self._.step == nil then
        self._.step = CastTask.Validate
    end

    -- A stop asked for from anywhere (a menu button, a chat order, a stronger cast) is carried
    -- out here rather than where it was asked for, so nothing outside the main loop ever runs a
    -- game command. Same rule the movement service works under.
    if self._.stopOutcome ~= nil then
        local outcome = self._.stopOutcome
        self._.stopOutcome = nil
        self:Abandon(outcome)
        return self._.status
    end

    -- A line from the client outranks anything we can work out from the TLOs: it is the only
    -- thing that says *why*. Checked before the step so a fizzle is reported as a fizzle rather
    -- than as the cast bar closing, which is what a success looks like.
    if self._.pendingOutcome ~= nil then
        local outcome = self._.pendingOutcome
        self._.pendingOutcome = nil
        finish(self, outcome)
        return self._.status
    end

    -- Run steps until one says it is waiting on the client. The guard is a runaway backstop and
    -- nothing more: there are seven steps and each one only ever names a later one.
    local guard = 0
    while self._.step ~= nil and guard < 10 do
        guard = guard + 1
        if not self._.step(self) then break end
    end

    noticeIfStuck(self)
    return self._.status
end

---Feed in an outcome the client just announced. Recorded rather than acted on, so it is applied
---on the next pulse alongside everything else.
---@param outcome string
function CastTask:RecordOutcome(outcome)
    if CastStatus.IsTerminal(self._.status) then return end
    self._.pendingOutcome = outcome
end

---Ask for this cast to end. Interrupting a committed cast happens on the next pulse, which is
---what makes this safe to call from an ImGui callback or a chat event handler.
---@param outcome? string defaults to aborted
function CastTask:RequestStop(outcome)
    if CastStatus.IsTerminal(self._.status) then return end
    self._.stopOutcome = outcome or CastOutcome.aborted
end

---End this cast now, interrupting the client if it has already committed. **Main loop only** --
---`RequestStop` is the safe form. Ducking is how a cast is cancelled in EQ, and a mount has to
---come off first or the duck does nothing.
---@param outcome? string defaults to aborted
---@return string status
function CastTask:Abandon(outcome)
    outcome = outcome or CastOutcome.aborted
    if CastStatus.IsTerminal(self._.status) then return self._.status end

    if CastStatus.IsCommitted(self._.status) then
        if mq.TLO.Me.Mount.ID() ~= nil then
            mq.cmd("/dismount")
        end
        mq.cmd("/stopcast")
    end

    finish(self, outcome)
    return self._.status
end

---@return string status
function CastTask:Status()
    return self._.status
end

---@return string|nil outcome set once the task is terminal
function CastTask:Outcome()
    return self._.outcome
end

---@return string|nil reason what it is waiting on, or why it ended
function CastTask:Reason()
    return self._.reason
end

---Whether this cast pins the character down. False for bard songs and instant casts, which can
---be run on the move, and for a cast that is already over.
---@return boolean requiresStillness
function CastTask:RequiresStillness()
    if CastStatus.IsTerminal(self._.status) then return false end
    return self._.requiresStillness
end

---@return CastSubject subject
function CastTask:Subject()
    return self._.subject
end

---@return number|nil targetId the cast was asked to aim at
function CastTask:TargetId()
    return self._.targetId
end

---@return string description for status output
function CastTask:Describe()
    local description = self._.subject:Describe()
    if self._.targetId ~= nil then
        description = description .. " on " .. (mq.TLO.Spawn("id " .. tostring(self._.targetId)).CleanName() or
            ("spawn " .. tostring(self._.targetId)))
    end
    if self.owner ~= nil then
        description = description .. " for " .. tostring(self.owner)
    end
    return description
end

return CastTask
