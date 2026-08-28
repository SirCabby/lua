---@diagnostic disable: undefined-field
local mq = require("mq")

local Bags = require("utils.Bags.Bags")
local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local SwapStatus = require("utils.Swapping.SwapStatus")

---One walk down a list of moves, where a move is "this worn slot should end up holding this".
---
---EQ has no command that equips anything. What it has is a cursor and a set of slots you can
---click, so putting a ring on is three commands with a wait on the client after each: pick the
---ring up, click the finger -- which drops the ring in and hands whatever was there back to the
---cursor -- and put that back in a bag. There is no way to say "swap these" in one line, and
---there is no reply to any of the three: the world simply looks different a frame or two later,
---or it does not.
---
---**So every step is answered by the world rather than by a delay.** The cursor either holds the
---item or it does not, the slot either holds it or it does not, the cursor is either clear or it
---is not. What each step keeps is an *evidence window*: a command that produced no visible change
---in a second and a half did not take, and there is nothing else the client will say about it.
---Those windows are the only clocks in here, and none of them runs while something is happening.
---
---**A move is three steps and the same three whichever direction it is going.** Filling a slot
---and emptying one differ only in whether there is anything to pick up first: emptying is "pick
---up nothing, click the slot, stow what comes back", which is the identical Place and Stow with
---the Pick skipped. That is why putting the focus item on and taking it off again are one
---sequencer rather than two.
---
---**A move records what it displaced, in the move itself.** The list handed in is the same table
---the service keeps as its obligation, so what this task learns as it goes -- which slot it
---actually used, what was sitting in it -- is written where the restore will read it, from the
---first frame rather than at the end. A swap abandoned halfway therefore leaves behind an exact
---account of what it moved, which is the only thing that makes putting it back possible.
---
---**A move that cannot be made does not stop the ones after it.** Two focus items where one is
---in the bank is one focus item worn and one row with a reason on it, not a swap that did
---nothing. Each move carries its own `problem`, and the task's status is the roll-up.
---@class SwapTask
local SwapTask = {
    key = "SwapTask"
}
SwapTask.__index = SwapTask

setmetatable(SwapTask, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---How long each command gets to show up in the world before it is called a fault. Evidence
---windows and not give-ups: they only ever run while nothing at all has happened, and the thing
---they answer -- a command the client silently dropped -- has no other answer.
local pickEvidenceMs = 1500
local placeEvidenceMs = 1500
local stowEvidenceMs = 2000
local openBagEvidenceMs = 2500

---@param str string
local function DebugLog(str)
    Debug.Log(SwapTask.key, str)
end

---Issue one client command, with a line either side of it.
---
---**The pair is the point, not the message.** Moving gear is the only thing this codebase does
---that clicks the client's own inventory windows, and a command that faults in there does not come
---back as a lua error -- it is a C++ fault that unwinds straight past every `pcall` in the script
---and stops it dead, leaving nothing in the crash log because the crash barrier never sees it. A
---single line before the command cannot tell "this one killed us" from "we never got here"; a line
---on each side can, because the missing one names the command exactly. That is the only
---instrument there is for this class of fault, and it costs nothing with the toggle off.
---@param what string what the command is for, in words
---@param command string
local function fire(what, command)
    DebugLog(what .. " -> " .. command)
    mq.cmd(command)
    DebugLog(what .. " <- returned")
end

---@return number ping current latency in ms, defaulted when the client has not reported one
local function ping()
    local latency = tonumber(mq.TLO.EverQuest.Ping())
    if latency == nil or latency < 0 then return 100 end
    return math.min(latency, 2000)
end

---@param moves table array of move records -- see `Swapping.PlanWear` for the shape. **Held by
---reference**: this task writes what it finds into them, and the service reads it back out
---@param options? table
--- owner: string, which behavior this swap belongs to -- used to stop it again later
--- what: string, "wear" or "restore", for the status line only
--- onDone: fun(status, reason), called from the pulse once the swap is terminal
---@return SwapTask
function SwapTask.new(moves, options)
    options = options or {}
    local self = setmetatable({}, SwapTask)

    self.id = nil
    self.owner = options.owner
    ---called by the service once this task is terminal; the task itself never uses it
    self.onDone = options.onDone

---@diagnostic disable-next-line: inject-field
    self._ = {
        moves = moves,
        what = options.what or "swap",
        index = 0,

        status = SwapStatus.preparing,
        reason = nil,
        step = nil,
        stopRequested = false,

        startedMs = Time.current_time(),
        stepDeadlineMs = nil,
        openedAtMs = nil,
        pickedAtMs = nil,
        placedAtMs = nil,
        stowedAtMs = nil,
        ---{ [pack number] = true } for bags this task opened, to be closed again at the end. Only
        ---ones it opened: a bag the player already had open is theirs and is left alone
        openedPacks = {},
        ---how many moves ended with the slot the way the move wanted it, and how many could not
        landed = 0,
        refused = 0,
        cleaned = false
    }

    return self
end

---------------- Reading the world --------------------

---@param slotName string
---@return number|nil itemId what is worn there, nil for an empty slot
local function wornIn(slotName)
    local id = tonumber(mq.TLO.Me.Inventory(slotName).ID())
    if id == nil or id < 1 then return nil end
    return id
end

---@param slotName string
---@return string|nil name
local function wornNameIn(slotName)
    return mq.TLO.Me.Inventory(slotName).Name()
end

---@return number|nil itemId what the cursor is holding
local function onCursor()
    local id = tonumber(mq.TLO.Cursor.ID())
    if id == nil or id < 1 then return nil end
    return id
end

---@param itemId number
---@return boolean carried whether one of these is anywhere in our inventory
local function carried(itemId)
    return (tonumber(mq.TLO.FindItemCount(itemId)()) or 0) > 0
end

---------------- Step plumbing --------------------

---A step returns whether the task should keep working this frame, exactly as a give's does:
---`advance` chains straight into the next one, `waiting` stops until the next frame, and the two
---move-level endings hand the walk on to the move after this one.

---@param status string
---@param reason string
---@return boolean keepWorking always false
local function finish(self, status, reason)
    self._.status = status
    self._.reason = reason
    self._.step = nil
    DebugLog(self._.what .. " finished: " .. status .. " (" .. tostring(reason) .. ")")
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

---@return table|nil move the one being worked on
local function current(self)
    return self._.moves[self._.index]
end

---This move is as far as it is going to get. Recorded on the move itself and the walk carries on:
---one slot that cannot be reached is not a reason to leave the others alone.
---@param problem string|nil nil when the move simply had nothing left to do
---@return boolean keepWorking always true -- the next move starts this same frame
local function moveDone(self, problem)
    local move = current(self)

    if move ~= nil then
        move.problem = problem
        if problem == nil then
            move.done = true
            self._.landed = self._.landed + 1
        else
            self._.refused = self._.refused + 1
            DebugLog("[" .. tostring(move.slotName) .. "] " .. problem)
        end
    end

    self._.openedAtMs = nil
    self._.pickedAtMs = nil
    self._.placedAtMs = nil
    self._.stowedAtMs = nil
    return advance(self, SwapTask.NextMove)
end

---------------- Steps --------------------

---Take up the next move, and answer the questions that can be answered before anything is
---touched: has this slot moved on without us, is it already the way the move wants it, and are we
---actually carrying the thing.
local function nextMove(self)
    self._.index = self._.index + 1
    local move = current(self)

    if move == nil then
        -- the roll-up: a plan where nothing could be done is a failure, and one where anything
        -- landed is a success with the rest reported on the moves themselves
        if self._.refused > 0 and self._.landed < 1 then
            return finish(self, SwapStatus.failed, "nothing could be moved")
        end
        if self._.refused > 0 then
            return finish(self, SwapStatus.succeeded,
                tostring(self._.landed) .. " moved, " .. tostring(self._.refused) .. " could not be")
        end
        return finish(self, SwapStatus.succeeded, "done")
    end

    local holding = wornIn(move.slotName)

    -- The player has put something else in this slot since. Whatever this move was going to do
    -- there, they have made a more recent statement about it than we have, and putting a slot
    -- back that somebody has since filled by hand is fighting them over their own gear. Only a
    -- *positive* reading counts: an empty slot is not somebody's decision, it is a slot to fill.
    if move.onlyIfHolds ~= nil and holding ~= nil and holding ~= move.onlyIfHolds then
        move.skipped = true
        DebugLog("[" .. tostring(move.slotName) .. "] holds something else now -- leaving it alone")
        return moveDone(self, nil)
    end

    if holding == move.wantId then
        -- already the way the move wants it. Nothing was pushed out to make room, so this move
        -- leaves nothing owed -- which for a wear is the difference between a focus item the
        -- player was already wearing and one we put on them
        move.displacedId = nil
        move.displacedName = nil
        move.preexisting = true
        return moveDone(self, nil)
    end

    -- what this move is about to push out, read now rather than trusted from the plan: the plan
    -- was made a frame or more ago and this is the reading the restore will be built on
    move.displacedId = holding
    move.displacedName = holding ~= nil and wornNameIn(move.slotName) or nil
    move.preexisting = false

    if move.wantId == nil then
        -- emptying the slot: nothing to pick up, the click itself is what lifts it out
        return advance(self, SwapTask.Place, placeEvidenceMs)
    end

    if not carried(move.wantId) then
        return moveDone(self, "we are not carrying " .. tostring(move.wantName or move.wantId))
    end

    -- The pick-up is made **by name** (see `pick`), so a move that has only an id is a move that
    -- cannot be made until the name is looked up. Read here rather than at the moment of use so
    -- there is one place it can fail, and only from a record that arrived without one -- a plan
    -- built this session always carries it.
    if move.wantName == nil then
        move.wantName = mq.TLO.FindItem(move.wantId).Name()
        if move.wantName == nil then
            return moveDone(self, "cannot tell what item " .. tostring(move.wantId) .. " is called")
        end
    end

    return advance(self, SwapTask.OpenBag, openBagEvidenceMs)
end

---Open the bag the item is sitting in, if it is in one and it is closed.
---
---**This is not a convenience, it is the only way the pick-up works at all.** Told to pick up an
---item, the client looks for that item's own inventory-slot *window* and clicks it; only when it
---cannot find one does it fall back to moving the item directly -- and on this client that
---fallback takes the whole script down, silently, in a way no `pcall` can catch (see `fire`).
---A bag that is open has slot windows. So the bag is opened first, and the click that follows is
---the same kind of click that puts gear into a worn slot, which is the one that provably works.
---
---Verified by hand on 2026-08-24: the identical pick-up command works with the bag open and kills
---the script with it closed.
---
---Only bags this task opened are closed again afterwards -- see `finishUp`. One the player had
---open is theirs.
local function openBag(self)
    local move = current(self)
    local pack = Bags.PackHolding(mq.TLO.FindItem(move.wantId))
    local action = Bags.Progress(pack, self._.openedAtMs)

    if action == "ready" then
        return advance(self, SwapTask.Pick, pickEvidenceMs)
    end

    if action == "open" and self._.openedAtMs == nil then
        self._.openedAtMs = Time.current_time()
        self._.openedPacks[pack] = true
        fire("open pack" .. tostring(pack) .. " to reach " .. tostring(move.wantName),
            Bags.ToggleCommand(pack))
    end

    if expired(self) then
        return moveDone(self, "could not open the bag holding " .. tostring(move.wantName))
    end

    return waiting(self, "opening pack" .. tostring(pack))
end

---Get what the slot should end up holding onto the cursor, which is the only place the client
---will put anything into a slot from.
local function pick(self)
    local move = current(self)
    local cursor = onCursor()

    if cursor == move.wantId then
        return advance(self, SwapTask.Place, placeEvidenceMs)
    end

    -- what the player put on the cursor is theirs. Stowing it to make room would be undoing
    -- something they did by hand, and it may be the thing they are in the middle of doing
    if cursor ~= nil then
        return moveDone(self, "something else is on the cursor")
    end

    if self._.pickedAtMs == nil then
        self._.pickedAtMs = Time.current_time()
        -- **Reached only with the item's bag open** -- see `openBag`, which is the step that makes
        -- this line safe rather than fatal. The addressing form is not what matters (both `#<id>`
        -- and the quoted name killed the script with the bag shut, and the quoted name works with
        -- it open); what matters is whether the client can find a slot *window* to click.
        --
        -- By name rather than by id because that is the form `utils/Giving` has used in production
        -- all along, and nothing is lost by it: two items of one name are interchangeable for
        -- filling a slot, and the verification still goes by id -- `place` waits for the slot to
        -- read back `wantId` -- so a pick-up that brought the wrong thing does not pass.
        --
        -- `/nomodkey`, because a modifier key the player happens to be holding turns a pick-up
        -- into a stack split or a link.
        fire("pick up " .. tostring(move.wantName),
            string.format('/nomodkey /itemnotify "%s" leftmouseup', move.wantName))
    end

    if expired(self) then
        return moveDone(self, "could not get " .. tostring(move.wantName or move.wantId) .. " onto the cursor")
    end

    return waiting(self, "picking up " .. tostring(move.wantName or move.wantId))
end

---Click the slot. With something on the cursor this drops it in and hands back whatever was
---there; with an empty cursor it lifts out what was there. Both are the same command.
local function place(self)
    local move = current(self)

    if wornIn(move.slotName) == move.wantId then
        self._.status = SwapStatus.swapping
        return advance(self, SwapTask.Stow, stowEvidenceMs)
    end

    if self._.placedAtMs == nil then
        self._.placedAtMs = Time.current_time()
        fire("put " .. tostring(move.wantName or "nothing") .. " in " .. tostring(move.slotName),
            string.format("/nomodkey /itemnotify %s leftmouseup", move.slotName))
    end

    if expired(self) then
        -- The one failure with a cause worth naming *in the message*. Addressing a worn slot by
        -- name goes through the client's own inventory slot windows, and a slot whose window the
        -- UI has never built cannot be clicked at all -- so the fix is a thing to go and look at
        -- rather than anything to change here, and the command that looks is named
        return moveDone(self, "the " .. tostring(move.slotName) ..
            " slot would not take it (/itemslots lists the slots the UI can click)")
    end

    return waiting(self, "putting it in " .. tostring(move.slotName))
end

---Put away whatever the slot handed back. An item left on the cursor blocks looting, every
---hand-off and the next move, so this is part of the move rather than tidying afterwards.
local function stow(self)
    local move = current(self)

    if onCursor() == nil then
        return moveDone(self, nil)
    end

    if self._.stowedAtMs == nil then
        self._.stowedAtMs = Time.current_time()
        fire("stow " .. tostring(move.displacedName or "what came back"), "/autoinventory")
    end

    if expired(self) then
        -- the slot took the item, so the move itself worked; what is left is an item on the
        -- cursor with nowhere to go, which is a full bag and worth saying in those words
        return moveDone(self, "no room to put " .. tostring(move.displacedName or "what came back") .. " away")
    end

    return waiting(self, "putting away " .. tostring(move.displacedName or "what came back"))
end

-- Steps are held as methods so each one can name the next by identity, the way the give
-- sequencer and the cabby states name theirs
SwapTask.NextMove = nextMove
SwapTask.OpenBag = openBag
SwapTask.Pick = pick
SwapTask.Place = place
SwapTask.Stow = stow

---Put the client back the way we found it: nothing of ours left on the cursor, and no bag left
---open that we opened.
---
---**The cursor half** only ever clears an item *this plan moved* -- checked against every move's
---two ids rather than against the move we happened to stop on, since the walk carries on past a
---move that failed and the item it stranded is two moves back by the time we get here. A cursor
---holding anything else is the player's, which is also what makes `pick` give up in the first
---place. Fired straight away rather than watched for: unlike a cancelled give window there is
---nothing on its way back, the item is already in our hand.
---
---**The bag half** closes only what `openBag` opened, and only while it is still open -- a player
---who has since closed it themselves, or opened one we never touched, is left alone. Fired and
---forgotten: a bag that will not close is an open bag, which is untidy rather than wrong, and
---there is nothing to be gained by holding the task open over it.
local function finishUp(self)
    if self._.cleaned then return end
    self._.cleaned = true

    local cursor = onCursor()
    if cursor ~= nil then
        for _, move in ipairs(self._.moves) do
            if cursor == move.wantId or cursor == move.displacedId then
                fire("clear the cursor of " .. tostring(mq.TLO.Cursor.Name()), "/autoinventory")
                break
            end
        end
    end

    for pack in pairs(self._.openedPacks) do
        if Bags.IsOpen(pack) then
            fire("close pack" .. tostring(pack) .. " again", Bags.ToggleCommand(pack))
        end
    end
    self._.openedPacks = {}
end

---One frame of the swap. **Main loop only** -- this is where every game command is issued.
---@return string status
function SwapTask:Pulse()
    if SwapStatus.IsTerminal(self._.status) then return self._.status end

    if self._.step == nil then
        self._.step = SwapTask.NextMove
        self._.stepDeadlineMs = nil
    end

    -- a stop asked for from anywhere (a menu button, a chat order, the state changing its mind)
    -- is carried out here rather than where it was asked for, so nothing outside the main loop
    -- ever runs a game command. Same rule the casting, movement and giving services work under.
    if self._.stopRequested then
        self._.stopRequested = false
        return self:Abandon("cancelled")
    end

    -- run steps until one says it is waiting on the client. The guard is a runaway backstop: each
    -- move is at most four steps, and a plan of a dozen slots settled in one frame is still a
    -- frame's work rather than a loop
    local guard = 0
    while self._.step ~= nil and guard < 64 do
        guard = guard + 1
        if not self._.step(self) then break end
    end

    -- A move that gave up between picking an item up and getting it into a slot leaves that item
    -- **on the cursor**, and a loaded cursor blocks looting, every hand-off and the next swap. The
    -- steps themselves cannot tidy it -- each one hands the walk straight on to the next move --
    -- so it is done here, on whichever ending got us out of the loop. Same rule the give
    -- sequencer works under, and the same reason.
    if SwapStatus.IsTerminal(self._.status) then
        finishUp(self)
    end

    return self._.status
end

---Ask for this swap to end. Carried out on the next pulse, which is what makes it safe to call
---from an ImGui callback or a chat event handler.
function SwapTask:RequestStop()
    if SwapStatus.IsTerminal(self._.status) then return end
    self._.stopRequested = true
end

---End it now, putting back whatever is on the cursor. **Main loop only** -- `RequestStop` is the
---safe form.
---
---What this does *not* undo is the slots already changed: those are the service's standing
---obligation and it discharges them with a swap of its own, because putting them back is the same
---three commands and needs the same frames.
---@param reason? string
---@return string status
function SwapTask:Abandon(reason)
    if SwapStatus.IsTerminal(self._.status) then return self._.status end
    finishUp(self)
    finish(self, SwapStatus.failed, reason or "cancelled")
    return self._.status
end

---@return string status
function SwapTask:Status()
    return self._.status
end

---@return string|nil reason what it is waiting on, or why it ended
function SwapTask:Reason()
    return self._.reason
end

---@return table moves the list handed in, with what this task found written into it
function SwapTask:Moves()
    return self._.moves
end

---@return string what "wear" or "restore"
function SwapTask:What()
    return self._.what
end

---@return string description for status output
function SwapTask:Describe()
    local move = current(self)
    if move == nil then
        return self._.what .. "ing gear"
    end
    if move.wantId == nil then
        return self._.what .. ": clearing " .. tostring(move.slotName)
    end
    return self._.what .. ": " .. tostring(move.wantName or move.wantId) .. " to " .. tostring(move.slotName)
end

return SwapTask
