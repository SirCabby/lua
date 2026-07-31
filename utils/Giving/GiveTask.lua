---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local GiveStatus = require("utils.Giving.GiveStatus")

---One hand-off: an item out of our inventory into somebody else's hands, from the moment
---somebody asks for it to the moment it lands or fails.
---
---EQ imposes the sequence the way it imposes a cast's: the item has to be on the cursor, we have
---to be on the target, the client has to be told we clicked on them, and the give window that
---opens has to be answered. What is different here is that none of it blocks -- each step issues
---at most one command and then says what it is waiting for, so the script it lives in keeps
---running.
---
---**Every step is answered by the world rather than by a delay.** The cursor either holds the
---item or it does not, the target either took or it did not, the window is either open or it is
---not. What each step keeps is an *evidence window*: a command that produced no visible change in
---a second and a half did not take, and there is nothing else the client will say about it. Those
---windows are the only clocks here -- nothing is abandoned for taking too long once the item is
---actually moving.
---
---**The two shapes of a give are both handled.** Clicking a spawn with an item on the cursor
---opens the give window on this client; a client that instead takes the item straight off the
---cursor is not wrong, it has just finished early, so the offer step reads both -- the window
---opening, or the item simply being gone.
---@class GiveTask
local GiveTask = {
    key = "GiveTask"
}
GiveTask.__index = GiveTask

setmetatable(GiveTask, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---The window a give opens, and the two buttons on it. Both are read off the client's own SIDL
---(`EQUI_GiveWnd.xml`): the Give button hands the item over, the Cancel button puts it back on
---the cursor, and there is nothing else on the window worth pressing.
local giveWindow = "GiveWnd"
local giveButton = "GVW_Give_Button"
local cancelButton = "GVW_Cancel_Button"

---How far away a hand-off can be made. The client is the real judge -- it simply does nothing
---when the click is out of reach -- so this is only here to fail early with a reason a person can
---read, rather than after two seconds of waiting for a window that was never going to open.
local defaultReach = 20

---How long each command gets to show up in the world before it is called a fault. These are
---evidence windows and not give-ups: they only ever run while nothing at all has happened, and
---the thing they answer -- a command the client silently dropped -- has no other answer.
local pickUpEvidenceMs = 1500
local targetEvidenceMs = 2500
local windowEvidenceMs = 2500
local handOverEvidenceMs = 3000

---How often an unanswered `/mqtarget` is issued again. Re-issuing the command *is* the retry;
---there is nothing else to try, and the evidence window above is what ends it.
local retryIntervalMs = 1000

---@param str string
local function DebugLog(str)
    Debug.Log(GiveTask.key, str)
end

---@return number ping current latency in ms, defaulted when the client has not reported one
local function ping()
    local latency = tonumber(mq.TLO.EverQuest.Ping())
    if latency == nil or latency < 0 then return 100 end
    return math.min(latency, 2000)
end

---@param item table `{ name = string, id = number|nil }` what to hand over
---@param options? table
--- owner: string, which behavior this give belongs to -- used to stop it again later
--- spawnId: number, who to hand it to
--- reach: number, how close we have to be
--- onDone: fun(status, reason), called from the pulse once the hand-off is terminal
---@return GiveTask
function GiveTask.new(item, options)
    options = options or {}
    local self = setmetatable({}, GiveTask)

    self.id = nil
    self.owner = options.owner
    ---called by the service once this task is terminal; the task itself never uses it
    self.onDone = options.onDone

---@diagnostic disable-next-line: inject-field
    self._ = {
        itemName = item.name,
        itemId = tonumber(item.id),
        spawnId = tonumber(options.spawnId),
        reach = tonumber(options.reach) or defaultReach,

        status = GiveStatus.preparing,
        reason = nil,
        step = nil,
        stopRequested = false,

        startedMs = Time.current_time(),
        stepDeadlineMs = nil,
        pickedUpAtMs = nil,
        targetedAtMs = nil,
        clickedAtMs = nil,
        notifiedAtMs = nil,
        ---whatever was targeted before we took the target, to be put back afterwards
        restoreId = nil,
        restored = false,
        cleaned = false
    }

    return self
end

---------------- Reading the world --------------------

---@return boolean holdsOurs whether the cursor is holding the item this task is about
local function holdsOurs(self)
    local cursorId = tonumber(mq.TLO.Cursor.ID())
    if cursorId == nil then return false end
    if self._.itemId ~= nil then return cursorId == self._.itemId end

    local name = mq.TLO.Cursor.Name()
    return name ~= nil and tostring(name):lower() == tostring(self._.itemName):lower()
end

---@return boolean holdsAnything whether there is anything on the cursor at all
local function cursorLoaded()
    return mq.TLO.Cursor.ID() ~= nil
end

---@return boolean carried whether the item is in our inventory (or already on the cursor)
local function carried(self)
    if self._.itemId ~= nil then
        return (tonumber(mq.TLO.FindItemCount(self._.itemId)()) or 0) > 0
    end
    -- exact first, so a bag of similarly named summoned gear cannot substitute one for another
    if mq.TLO.FindItem("=" .. tostring(self._.itemName)).ID() ~= nil then return true end
    return mq.TLO.FindItem(tostring(self._.itemName)).ID() ~= nil
end

---@return boolean isOpen whether the give window is up
local function windowOpen()
    return mq.TLO.Window(giveWindow).Open() == true
end

---------------- Steps --------------------

---A step returns whether the task should keep working this frame, exactly as a cast's does:
---`advance` chains straight into the next one, `waiting` stops until the next frame, `finish` is
---terminal.

---A read has no business leaving a mark on the player's target window: whatever was there before
---the swap goes back, unless somebody else has taken the target since, in which case it is theirs
---now. Called once, from the finish below.
local function restoreTarget(self)
    if self._.restored then return end
    self._.restored = true

    local restoreId = self._.restoreId
    if restoreId == nil then return end
    if tonumber(mq.TLO.Target.ID()) ~= self._.spawnId then return end
    if mq.TLO.Spawn("id " .. tostring(restoreId)).ID() == nil then return end

    mq.cmdf("/mqtarget id %d", restoreId)
end

---@param status string
---@param reason string
---@return boolean keepWorking always false
local function finish(self, status, reason)
    self._.status = status
    self._.reason = reason
    self._.step = nil
    restoreTarget(self)
    DebugLog("Give of [" .. tostring(self._.itemName) .. "] finished: " .. status .. " (" .. tostring(reason) .. ")")
    return false
end

---@param reason string
---@return boolean keepWorking always false
local function waiting(self, reason)
    self._.reason = reason
    return false
end

---@param nextStep function
---@param deadlineMs? number how long the next step's evidence window runs for
---@return boolean keepWorking always true
local function advance(self, nextStep, deadlineMs)
    self._.step = nextStep
    self._.reason = nil
    if deadlineMs ~= nil then
        self._.stepDeadlineMs = Time.current_time() + deadlineMs + ping()
    end
    return true
end

---@return boolean expired whether this step's evidence window has run out
local function expired(self)
    return Time.current_time() > (self._.stepDeadlineMs or math.huge)
end

---Everything the client can tell us before anything is picked up or clicked: is there somebody
---there, are we close enough, and do we actually have the thing.
local function validate(self)
    if self._.spawnId == nil then
        return finish(self, GiveStatus.failed, "nobody was named to give it to")
    end

    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if spawn.ID() == nil then
        return finish(self, GiveStatus.failed, "spawn " .. tostring(self._.spawnId) .. " is not here")
    end

    local distance = tonumber(spawn.Distance())
    if distance ~= nil and distance > self._.reach then
        return finish(self, GiveStatus.failed,
            (spawn.CleanName() or "they") .. " is " .. tostring(math.floor(distance)) .. " away, too far to hand it over")
    end

    -- a caller that named the item by id gets its name resolved here, since picking an item up
    -- off the inventory window is done by name
    if self._.itemName == nil and self._.itemId ~= nil then
        self._.itemName = mq.TLO.FindItem(self._.itemId).Name()
    end
    if self._.itemName == nil then
        return finish(self, GiveStatus.failed, "we are not carrying item " .. tostring(self._.itemId))
    end

    self._.restoreId = tonumber(mq.TLO.Target.ID())
    if self._.restoreId == self._.spawnId then self._.restoreId = nil end

    if holdsOurs(self) then
        return advance(self, self.AcquireTarget, targetEvidenceMs)
    end

    -- what the player put on the cursor is theirs. Stowing it to make room would be undoing
    -- something they did by hand, and it may be the thing they are in the middle of doing
    if cursorLoaded() then
        return finish(self, GiveStatus.failed, "something else is on the cursor")
    end

    if not carried(self) then
        return finish(self, GiveStatus.failed, "we are not carrying " .. tostring(self._.itemName))
    end

    return advance(self, self.PickUp, pickUpEvidenceMs)
end

---Get the item onto the cursor, which is the only place the client will give one from.
local function pickUp(self)
    if holdsOurs(self) then
        return advance(self, self.AcquireTarget, targetEvidenceMs)
    end

    if cursorLoaded() then
        return finish(self, GiveStatus.failed, "something else is on the cursor")
    end

    if self._.pickedUpAtMs == nil then
        self._.pickedUpAtMs = Time.current_time()
        DebugLog("Picking up [" .. tostring(self._.itemName) .. "]")
        -- /nomodkey, because a modifier key the player happens to be holding turns a pick-up
        -- into a stack split or a link
        mq.cmdf('/nomodkey /itemnotify "%s" leftmouseup', self._.itemName)
    end

    if expired(self) then
        return finish(self, GiveStatus.failed, "could not get " .. tostring(self._.itemName) .. " onto the cursor")
    end

    return waiting(self, "picking up " .. tostring(self._.itemName))
end

---Be on them. The click that hands an item over is a click on the *target*, so there is no other
---way to say who this is for.
local function acquireTarget(self)
    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    if spawn.ID() == nil then
        return finish(self, GiveStatus.failed, "they left before we could hand it over")
    end

    if tonumber(mq.TLO.Target.ID()) ~= self._.spawnId then
        local now = Time.current_time()
        if self._.targetedAtMs == nil or now - self._.targetedAtMs >= retryIntervalMs + ping() then
            self._.targetedAtMs = now
            mq.cmdf("/mqtarget id %d", self._.spawnId)
        end

        if expired(self) then
            return finish(self, GiveStatus.failed, "could not get on " .. (spawn.CleanName() or "them"))
        end

        return waiting(self, "targeting " .. (spawn.CleanName() or tostring(self._.spawnId)))
    end

    return advance(self, self.Offer, windowEvidenceMs)
end

---Click on them with the item up. Either the give window opens, or this client hands it straight
---over -- both are answers, and the second one is already finished.
local function offer(self)
    if windowOpen() then
        return advance(self, self.Hand, handOverEvidenceMs)
    end

    if not holdsOurs(self) then
        if self._.clickedAtMs ~= nil then
            -- no window, and the item is gone: this client took it off the cursor directly
            return finish(self, GiveStatus.succeeded, "handed over")
        end
        return finish(self, GiveStatus.failed, tostring(self._.itemName) .. " left the cursor")
    end

    if self._.clickedAtMs == nil then
        self._.clickedAtMs = Time.current_time()
        DebugLog("Offering [" .. tostring(self._.itemName) .. "] to spawn " .. tostring(self._.spawnId))
        mq.cmd("/click left target")
    end

    if expired(self) then
        return finish(self, GiveStatus.failed, "the give window never opened")
    end

    return waiting(self, "offering " .. tostring(self._.itemName))
end

---The window is up with our item in it. Press Give, and read what the window does next: it
---closes on a hand-off that took, and the item comes back to the cursor on one that did not.
local function hand(self)
    self._.status = GiveStatus.giving

    if not windowOpen() then
        if holdsOurs(self) then
            return finish(self, GiveStatus.failed, "it came back to the cursor")
        end
        return finish(self, GiveStatus.succeeded, "handed over")
    end

    if self._.notifiedAtMs == nil then
        self._.notifiedAtMs = Time.current_time()
        DebugLog("Giving [" .. tostring(self._.itemName) .. "]")
        mq.cmdf("/notify %s %s leftmouseup", giveWindow, giveButton)
    end

    if expired(self) then
        return finish(self, GiveStatus.failed, "the give window would not close")
    end

    return waiting(self, "handing over " .. tostring(self._.itemName))
end

-- Steps are held as methods so each one can name the next by identity, the way the casting
-- sequencer and the cabby states name theirs
GiveTask.Validate = validate
GiveTask.PickUp = pickUp
GiveTask.AcquireTarget = acquireTarget
GiveTask.Offer = offer
GiveTask.Hand = hand

---Put the client back the way we found it: the window closed. Only ever runs against a window
---this task itself opened -- a cursor the player loaded is what makes `validate` refuse in the
---first place.
---
---Stowing the item is deliberately *not* done here. Cancelling gives it back to the cursor on the
---client's own clock, a frame or two later, so an `/autoinventory` fired into this same frame
---would find the cursor still empty and do nothing at all. That half is a short follow-up the
---service carries out over the frames after this task ends (`StowItemId`).
local function cleanUp(self)
    if self._.cleaned then return end
    self._.cleaned = true

    if windowOpen() then
        mq.cmdf("/notify %s %s leftmouseup", giveWindow, cancelButton)
    end
end

---One frame of the hand-off. **Main loop only** -- this is where every game command is issued.
---@return string status
function GiveTask:Pulse()
    if GiveStatus.IsTerminal(self._.status) then return self._.status end

    if self._.step == nil then
        self._.step = GiveTask.Validate
        self._.stepDeadlineMs = nil
    end

    -- a stop asked for from anywhere (a menu button, a chat order, the state changing its mind)
    -- is carried out here rather than where it was asked for, so nothing outside the main loop
    -- ever runs a game command. Same rule the casting and movement services work under.
    if self._.stopRequested then
        self._.stopRequested = false
        return self:Abandon("cancelled")
    end

    -- run steps until one says it is waiting on the client. The guard is a runaway backstop and
    -- nothing more: there are five steps and each only ever names a later one.
    local guard = 0
    while self._.step ~= nil and guard < 8 do
        guard = guard + 1
        if not self._.step(self) then break end
    end

    -- any ending but a hand-off that landed may have left the window standing open, whichever
    -- step it ended on
    if self._.status == GiveStatus.failed then
        cleanUp(self)
    end

    return self._.status
end

---Ask for this hand-off to end. Carried out on the next pulse, which is what makes it safe to
---call from an ImGui callback or a chat event handler.
function GiveTask:RequestStop()
    if GiveStatus.IsTerminal(self._.status) then return end
    self._.stopRequested = true
end

---End it now, putting back whatever we had moved. **Main loop only** -- `RequestStop` is the
---safe form.
---@param reason? string
---@return string status
function GiveTask:Abandon(reason)
    if GiveStatus.IsTerminal(self._.status) then return self._.status end
    cleanUp(self)
    finish(self, GiveStatus.failed, reason or "cancelled")
    return self._.status
end

---@return string status
function GiveTask:Status()
    return self._.status
end

---The item to tidy off the cursor after this task, if any.
---
---Nil for a hand-off that landed: the item is with them, so anything of that id on the cursor
---afterwards is one the player put there. For every other ending it names what we picked up, so
---the service can stow it once the client has actually given it back -- which is a frame or two
---after a cancelled window, not in the frame the cancel was sent.
---@return number|nil itemId
function GiveTask:StowItemId()
    if self._.status ~= GiveStatus.failed then return nil end
    return self._.itemId
end

---@return string|nil reason what it is waiting on, or why it ended
function GiveTask:Reason()
    return self._.reason
end

---@return string itemName
function GiveTask:ItemName()
    return tostring(self._.itemName)
end

---@return number|nil spawnId
function GiveTask:SpawnId()
    return self._.spawnId
end

---@return string description for status output
function GiveTask:Describe()
    local spawn = mq.TLO.Spawn("id " .. tostring(self._.spawnId))
    local who = spawn.CleanName() or ("spawn " .. tostring(self._.spawnId))
    return "giving " .. tostring(self._.itemName) .. " to " .. who
end

return GiveTask
