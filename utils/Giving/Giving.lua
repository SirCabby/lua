---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local GiveStatus = require("utils.Giving.GiveStatus")
local GiveTask = require("utils.Giving.GiveTask")

---The giving service: one hand-off at a time, pulsed once per frame.
---
---This is to handing an item over what `utils/Casting` is to casting, and it exists for the same
---reason. A give is four commands and three waits -- pick the item up, get on them, click, answer
---the window -- and the waits are on the client rather than on us. A caller that walked that
---sequence inline would have to block for it; a caller that walked it from a state's `Go()` would
---leave a give window open with an item in it the first time something above that state took the
---frame away mid-sequence. So callers **request** a hand-off and poll the result by id, and the
---sequence itself runs on the service's pulse whatever the state chain is doing.
---
---Two rules make it safe to share:
---
---1. **One hand-off at a time, and the one in flight keeps it.** A second request is refused
---   rather than queued -- there is no priority to arbitrate by here, and an item halfway into a
---   window is not something to interrupt for somebody else's item. `StopFor(owner)` is how the
---   caller that owns it takes it back.
---2. **Requests never touch the client; only `Pulse()` does.** Every game command -- the
---   pick-up, the targeting, the click, the notify -- is issued from the pulse, so a hand-off can
---   be asked for from an ImGui button or a chat handler without running EQ commands mid-frame,
---   which is a crash-to-desktop hazard.
---
---What it deliberately does not do: decide *whether* to hand something over, or remember that it
---did. Whether the pet already has one of these is the caller's question and the caller's record
---(see `cabby/states/petSetupState.lua`); this service knows only about one item and one spawn.
---@class Giving
local Giving = {
    author = "judged",
    key = "Giving",
    status = GiveStatus,
    ---Overridable through `Configure`, the way the casting service's timings are.
    settings = {
        ---how close we have to be to hand something over. The client is the real judge; this only
        ---buys a readable refusal instead of a silent wait
        reach = 20
    },
    _ = {
        isInit = false,
        task = nil,
        nextId = 1,
        ---an item a failed hand-off left in our hands, to be put away once the client gives it
        ---back: { id, name, untilMs }
        stow = nil,
        last = {
            id = nil,
            status = nil,
            reason = nil,
            owner = nil,
            describe = nil,
            finishedMs = 0
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Giving.key, str)
end

function Giving.Init(options)
    if Giving._.isInit then return end

    Giving.Configure(options or {})
    Giving._.isInit = true
end

---Change settings at runtime. Only the keys present are touched, so a config page can push one
---without knowing about the others.
---@param settings table
function Giving.Configure(settings)
    for key, value in pairs(settings or {}) do
        if Giving.settings[key] ~= nil then
            Giving.settings[key] = value
        end
    end
end

---@param task GiveTask
local function recordFinished(task)
    local last = Giving._.last
    last.id = task.id
    last.status = task:Status()
    last.reason = task:Reason()
    last.owner = task.owner
    last.describe = task:Describe()
    last.finishedMs = Time.current_time()

    if task.onDone ~= nil then
        -- pcall'd on purpose: a caller's bad callback should not take this service down with it,
        -- and the host would otherwise pause giving for a fault that is not ours
        local ok, err = pcall(task.onDone, last.status, last.reason)
        if not ok then
            print("(Giving) Error in the completion callback for " .. tostring(last.describe) .. ": " .. tostring(err))
        end
    end
end

---Ask for an item to be handed to somebody.
---@param item table `{ name = string|nil, id = number|nil }` -- either will do; an id names the
---item exactly, which is what a summoned item is known by before it exists
---@param options? table
--- owner: string, which behavior this belongs to -- used to stop it again later
--- spawnId: number, who to hand it to
--- onDone: fun(status, reason), called from the pulse once the hand-off is terminal
---@return number|nil taskId poll it with `GetResult`; nil when the request was refused
---@return string|nil refusedReason why, when it was refused
function Giving.Hand(item, options)
    options = options or {}

    local active = Giving._.task
    if active ~= nil then
        return nil, "already " .. active:Describe()
    end

    local task = GiveTask.new(item, {
        owner = options.owner,
        spawnId = options.spawnId,
        reach = Giving.settings.reach,
        onDone = options.onDone
    })

    task.id = Giving._.nextId
    Giving._.nextId = Giving._.nextId + 1
    Giving._.task = task

    DebugLog("Give requested [" .. tostring(task.id) .. "]: " .. task:Describe())
    return task.id, nil
end

---How long the cursor is watched for an item a failed hand-off should have given back. A cancelled
---give window returns the item on the client's own clock, a frame or two after the cancel goes
---out, so the stow cannot be fired in the same frame -- and if it never comes back there is
---nothing to put away.
local stowWindowMs = 3000

---@param stow table
---@return boolean holding whether the cursor is holding what we meant to put away
local function cursorHolds(stow)
    local cursorId = tonumber(mq.TLO.Cursor.ID())
    if cursorId == nil then return false end
    if stow.id ~= nil then return cursorId == stow.id end

    local name = mq.TLO.Cursor.Name()
    return name ~= nil and tostring(name):lower() == tostring(stow.name):lower()
end

---Put away what a failed hand-off left us holding. Only ever the item that hand-off picked up,
---and only for a moment afterwards: an item on the cursor blocks looting and every other
---hand-off, and leaving one there is the mess a cancelled give would otherwise be.
local function progressStow()
    local stow = Giving._.stow
    if stow == nil then return end

    if cursorHolds(stow) then
        DebugLog("Putting [" .. tostring(stow.name) .. "] away again")
        mq.cmd("/autoinventory")
        Giving._.stow = nil
        return
    end

    if Time.current_time() > stow.untilMs then
        Giving._.stow = nil
    end
end

---One frame of giving. **Call this every frame from the host's main loop, and from nowhere
---else** -- everything that talks to the client happens here.
---@return string status
function Giving.Pulse()
    local task = Giving._.task
    if task == nil then
        progressStow()
        return GiveStatus.idle
    end

    local status = task:Pulse()

    if GiveStatus.IsTerminal(status) then
        if status == GiveStatus.failed then
            Giving._.stow = {
                id = task:StowItemId(),
                name = task:ItemName(),
                untilMs = Time.current_time() + stowWindowMs
            }
        end
        recordFinished(task)
        Giving._.task = nil
    end

    return status
end

---Ask for the hand-off in progress to stop. The request is recorded and carried out on the next
---pulse, so this is safe from an ImGui callback.
---@return boolean stopped false when there was nothing to stop
function Giving.Interrupt()
    local task = Giving._.task
    if task == nil then return false end
    task:RequestStop()
    return true
end

---Stop the hand-off in progress only if it belongs to this owner. A caller cleaning up after
---itself must not cancel somebody else's give -- which is what an unconditional `Stop` would do
---by the time the frame comes round.
---@param owner string
---@return boolean stopped
function Giving.StopFor(owner)
    local task = Giving._.task
    if task == nil or task.owner ~= owner then return false end
    task:RequestStop()
    return true
end

---Stop whatever is in progress, unconditionally. Also what the host calls if this service is
---auto-paused for repeated failures.
function Giving.Stop()
    local task = Giving._.task
    if task == nil then return end

    task:Abandon("stopped")
    Giving._.stow = {
        id = task:StowItemId(),
        name = task:ItemName(),
        untilMs = Time.current_time() + stowWindowMs
    }
    recordFinished(task)
    Giving._.task = nil
end

---@return boolean isActive true while a hand-off is being prepared or is in the window
function Giving.IsActive()
    return Giving._.task ~= nil
end

---@return string status
function Giving.GetStatus()
    local task = Giving._.task
    if task == nil then return GiveStatus.idle end
    return task:Status()
end

---@return string|nil reason what giving is waiting on right now
function Giving.GetReason()
    local task = Giving._.task
    if task == nil then return nil end
    return task:Reason()
end

---@return string|nil owner of the hand-off in progress
function Giving.GetOwner()
    local task = Giving._.task
    if task == nil then return nil end
    return task.owner
end

---How a hand-off ended. Returns nil while it is still running, so a caller can poll the id it
---was handed without tracking anything else. A result stays available until the next one
---finishes.
---@param taskId number
---@return string|nil status terminal status, nil while the hand-off is still running
---@return string|nil reason
function Giving.GetResult(taskId)
    local task = Giving._.task
    if task ~= nil and task.id == taskId then return nil, task:Reason() end

    local last = Giving._.last
    if last.id == taskId then return last.status, last.reason end

    return GiveStatus.failed, "cancelled"
end

---@return string description of what giving is doing, for status output
function Giving.Describe()
    local task = Giving._.task
    if task == nil then return "standby" end
    return task:Describe()
end

return Giving
