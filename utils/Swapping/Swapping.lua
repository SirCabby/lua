---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local SwapStatus = require("utils.Swapping.SwapStatus")
local SwapTask = require("utils.Swapping.SwapTask")

---The swapping service: gear put on for a moment and taken off again, pulsed once per frame.
---
---This is to wearing something what `utils/Giving` is to handing something over, and it exists
---for the same reason -- putting a ring on is three commands with a wait on the client after each
---and there is no reply to any of them -- plus one this service has to itself:
---
---**What it puts on, it owes taking off.** A hand-off ends when the item lands. A swap is only
---half over then: the player's own gear is sitting in a bag where they did not put it, and the
---thing that makes this safe to use at all is that putting it back is *not* the caller's job to
---remember. The obligation lives here, in one record, and this service discharges it on its own
---pulse -- which means it happens whether or not the caller ever gets another frame from the
---priority chain, whether or not a fight broke out, and whether or not the caller is still
---interested. A state that owned the restore itself would leave somebody's epic in a bag the
---first time something above it took the frame away, which is precisely the failure `utils/Giving`
---was written to avoid one layer down.
---
---**The hold ends when the reason for it does, and the reason is the caller's to answer.**
---`Wear` takes a `keepWhile` -- a question this service asks on every pulse rather than a duration
---anybody guessed at -- so the gear comes off the moment the thing it went on for is over. Read
---here rather than reported by the caller precisely because the caller may be starved: the pulse
---runs every frame regardless of the chain, and a question asked on the pulse is one the answer
---always reaches. A hold with no `keepWhile` stands until somebody says `Release`, which is what a
---swap made by hand wants.
---
---**A restore never fights the player.** Every restore move carries the item it expects to find
---in the slot, and a slot holding something else is left exactly as it is: the player has made a
---more recent statement about their own gear than we have. The same reading is what makes the
---obligation safe to write down and pick up again after a reload -- see `GetObligation`.
---
---**A restore that cannot be made is not forgotten.** A full bag, a loaded cursor, a slot that
---will not answer: none of those are reasons to stop owing the gear back, so the obligation stands
---and is tried again on a pace until it is discharged or somebody drops it by hand.
---
---What it deliberately does not do: decide *whether* anything is worth wearing. Which items carry
---a focus worth a swap, and what the swap is for, are the caller's questions -- see
---`cabby/states/petSetupState.lua`. This service knows about slots and items.
---@class Swapping
local Swapping = {
    author = "judged",
    key = "Swapping",
    status = SwapStatus,
    ---Overridable through `Configure`, the way the giving service's are.
    settings = {
        ---how long before a restore that could not be made is tried again. Pacing on our own
        ---commands and nothing more: the obligation does not lapse, it just stops being retried
        ---every frame while a bag is full or the player is holding something
        restoreRetryMs = 3000
    },
    _ = {
        isInit = false,
        task = nil,
        nextId = 1,
        ---What is swapped in right now and what it displaced: the standing obligation.
        ---{ owner, label, keep, release, moves, problems, retryAtMs, warned }
        hold = nil,
        ---told whenever the obligation changes, so a host can write it somewhere that survives a
        ---reload. See `GetObligation`
        onHoldChanged = nil,
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

---The worn slots, by the names `/itemnotify`, `Me.Inventory` and `InvSlot` all know them by
---(`szItemSlot` in the client). Slots 23 and up are bags and are not somewhere anything is worn.
local wornSlotNames = {
    [0] = "charm",       [1] = "leftear",     [2] = "head",        [3] = "face",
    [4] = "rightear",    [5] = "neck",        [6] = "shoulder",    [7] = "arms",
    [8] = "back",        [9] = "leftwrist",  [10] = "rightwrist", [11] = "ranged",
    [12] = "hands",     [13] = "mainhand",   [14] = "offhand",    [15] = "leftfinger",
    [16] = "rightfinger", [17] = "chest",    [18] = "legs",       [19] = "feet",
    [20] = "waist",     [21] = "powersource", [22] = "ammo"
}

local firstWornSlot, lastWornSlot = 0, 22

---@param str string
local function DebugLog(str)
    Debug.Log(Swapping.key, str)
end

function Swapping.Init(options)
    if Swapping._.isInit then return end

    Swapping.Configure(options or {})
    Swapping._.isInit = true
end

---Change settings at runtime, plus the one hook this service offers. Only the keys present are
---touched, so a config page can push one without knowing about the others.
---@param settings table
function Swapping.Configure(settings)
    for key, value in pairs(settings or {}) do
        if Swapping.settings[key] ~= nil then
            Swapping.settings[key] = value
        end
    end

    if settings ~= nil and settings.onHoldChanged ~= nil then
        Swapping._.onHoldChanged = settings.onHoldChanged
    end
end

---------------- Reading the world --------------------

---@param itemId number
---@return string|nil slotName where this item is worn right now, nil when it is not
function Swapping.WornSlotOf(itemId)
    if itemId == nil then return nil end

    for slot = firstWornSlot, lastWornSlot do
        local name = wornSlotNames[slot]
        if tonumber(mq.TLO.Me.Inventory(name).ID()) == itemId then return name end
    end

    return nil
end

---Where this item is allowed to go, in the client's own order.
---@param item any mq item TLO
---@return table slots array of { slot = number, name = string }
local function slotsFor(item)
    local slots = {}
    local count = tonumber(item.WornSlots()) or 0

    for index = 1, count do
        local slot = tonumber(item.WornSlot(index)())
        local name = slot ~= nil and wornSlotNames[slot] or nil
        if name ~= nil then
            slots[#slots+1] = { slot = slot, name = name }
        end
    end

    return slots
end

---What the caller named, as something the client can be asked about.
---@param entry table|string `{ name = string }`, `{ id = number }`, or a plain name
---@return any|nil item mq item TLO
---@return string label what to call it in a report
local function findItem(entry)
    if type(entry) == "string" then entry = { name = entry } end

    local id = tonumber(entry.id)
    if id ~= nil then
        local byId = mq.TLO.FindItem(id)
        if byId.ID() ~= nil then return byId, entry.name or byId.Name() or ("item " .. tostring(id)) end
    end

    local name = entry.name
    if name == nil then return nil, "item " .. tostring(entry.id) end

    -- exact first, so a name that is the front of a longer one cannot substitute for it
    local exact = mq.TLO.FindItem("=" .. tostring(name))
    if exact.ID() ~= nil then return exact, name end

    local loose = mq.TLO.FindItem(tostring(name))
    if loose.ID() ~= nil then return loose, name end

    return nil, tostring(name)
end

---Is this already on?
---@param entry table|string
---@return boolean isWorn
---@return string|nil slotName where, when it is
function Swapping.IsWorn(entry)
    local item = findItem(entry)
    if item == nil then return false, nil end

    local id = tonumber(item.ID())
    if id == nil then return false, nil end

    local slotName = Swapping.WornSlotOf(id)
    return slotName ~= nil, slotName
end

---Is every one of these already on? The question a caller asks before there is any reason to
---swap: gear the player is already wearing is gear nothing has to be done about, and nothing that
---has to be put back afterwards.
---@param entries table array of item entries
---@return boolean allWorn true also when the list is empty
function Swapping.AllWorn(entries)
    for _, entry in ipairs(entries or {}) do
        if not Swapping.IsWorn(entry) then return false end
    end
    return true
end

---------------- Planning --------------------

---What it would take to be wearing all of these, and what stands in the way of the ones it would
---not.
---
---Slots are chosen rather than configured, and **an empty one is preferred over an occupied one**:
---a swap that displaces nothing is a swap with nothing to put back, which is the cheapest kind and
---the one least able to go wrong. Failing that it is the first slot the item lists, which is the
---client's own order.
---
---A slot claimed by an earlier item is not offered to a later one. Two focus items that both want
---the ranged slot is a real configuration and the honest answer is that the second one cannot go
---on, said in those words, rather than a swap that quietly takes the first one back off.
---@param entries table array of `{ name = string }`, `{ id = number }` or plain names
---@return table moves array of move records for `SwapTask`
---@return table problems array of `{ name, problem }` for the entries that could not be planned
function Swapping.PlanWear(entries)
    local moves = {}
    local problems = {}
    local claimed = {}

    for _, entry in ipairs(entries or {}) do
        local item, label = findItem(entry)

        if item == nil then
            problems[#problems+1] = { name = label, problem = "not in our bags" }
        else
            local id = tonumber(item.ID())
            local slots = slotsFor(item)

            local wornIn = id ~= nil and Swapping.WornSlotOf(id) or nil

            if id == nil then
                problems[#problems+1] = { name = label, problem = "not in our bags" }
            elseif #slots < 1 then
                -- an augment, or anything else the client will not let out of a bag. It has a
                -- focus on it and no way to wear it, which is worth saying rather than swallowing
                problems[#problems+1] = { name = label, problem = "cannot be worn in any slot" }
            elseif wornIn ~= nil then
                -- already on, and not by us: nothing to do and nothing owed afterwards
                claimed[wornIn] = true
            else
                local pick = nil
                for _, slot in ipairs(slots) do
                    if not claimed[slot.name] then
                        if pick == nil then pick = slot end
                        if tonumber(mq.TLO.Me.Inventory(slot.name).ID()) == nil then
                            pick = slot
                            break
                        end
                    end
                end

                if pick == nil then
                    problems[#problems+1] = { name = label,
                        problem = "every slot it fits is already taken by something else being put on" }
                else
                    claimed[pick.name] = true
                    moves[#moves+1] = {
                        slot = pick.slot,
                        slotName = pick.name,
                        wantId = id,
                        wantName = item.Name() or label,
                        displacedId = tonumber(mq.TLO.Me.Inventory(pick.name).ID()),
                        displacedName = mq.TLO.Me.Inventory(pick.name).Name()
                    }
                end
            end
        end
    end

    return moves, problems
end

---The moves that would put everything back the way it was found.
---
---`onlyIfHolds` is what keeps this honest: each move is conditional on the slot still holding the
---item we put there. A slot the player has since filled themselves is left alone -- their hand is
---the more recent statement about their own gear -- and a slot holding nothing is simply filled
---back in, since an empty slot is not a decision anybody made.
---@param hold table
---@return table moves
local function restoreMoves(hold)
    local moves = {}

    for _, move in ipairs(hold.moves) do
        if not move.preexisting and not move.discharged then
            moves[#moves+1] = {
                slot = move.slot,
                slotName = move.slotName,
                wantId = move.displacedId,
                wantName = move.displacedName,
                onlyIfHolds = move.wantId,
                source = move
            }
        end
    end

    return moves
end

---------------- The obligation --------------------

---What is owed, as plain data: the slots this service has changed, what it put in them and what
---it took out.
---
---Offered so a host can write it down somewhere that outlives the script. A `/lua stop` or a crash
---in the second between the gear going on and the cast finishing would otherwise leave somebody's
---own gear in a bag with nothing left anywhere that knows it belongs in a slot. Handed back to
---`Adopt` on the next run, it is put right -- and safely, because every move is still conditional
---on the slot holding what we left there.
---@return table|nil obligation array of plain records, nil when nothing is owed
function Swapping.GetObligation()
    local hold = Swapping._.hold
    if hold == nil then return nil end

    local owed = {}
    for _, move in ipairs(hold.moves) do
        if not move.preexisting and not move.discharged then
            owed[#owed+1] = {
                slot = move.slot,
                slotName = move.slotName,
                wantId = move.wantId,
                wantName = move.wantName,
                displacedId = move.displacedId,
                displacedName = move.displacedName
            }
        end
    end

    if #owed < 1 then return nil end
    return { owner = hold.owner, label = hold.label, moves = owed, attempts = hold.attempts or 0 }
end

---How many runs may pick up the same obligation before it is left alone.
---
---**This is a crash-loop brake and nothing else.** A record still on disk when a run starts is by
---definition one the previous run did not finish -- a finished restore deletes it -- and if the
---reason it did not finish was that the client killed the script, then adopting it again is that
---same script-ending command reissued a second after every login. Which is a game nobody can log
---in to play. Counted on disk *before* the attempt is made, so a run that dies leaves the higher
---number behind and the one after it can tell.
---
---Two, because a restore has honest reasons to fail that are nobody's bug -- a full bag, a cursor
---the player is holding something on -- and one of those should not be the end of it. Past that,
---the gear is left where it is and said out loud, which is the outcome a person can act on.
local maxAdoptAttempts = 2

local function publish()
    local hook = Swapping._.onHoldChanged
    if hook == nil then return end

    -- pcall'd on purpose: a host's bad callback should not take this service down with it, and
    -- the gear it is holding would then never come off
    local ok, err = pcall(hook, Swapping.GetObligation())
    if not ok then
        print("(Swapping) Error publishing the hold: " .. tostring(err))
    end
end

---Pick up an obligation written down by an earlier run, and put it back.
---
---Adopted holds are released at once: nobody is waiting on this gear -- whatever it was worn for
---finished, or did not, on the other side of a reload -- so the only thing left to do with it is
---take it off. Nothing is forced: a slot the player has since sorted out themselves is left alone
---by the same reading every restore uses.
---@param obligation table as handed out by `GetObligation`
---@return boolean adopted false when there was nothing to adopt, or when it has been tried enough
function Swapping.Adopt(obligation)
    if obligation == nil or obligation.moves == nil or #obligation.moves < 1 then return false end
    if Swapping._.hold ~= nil then return false end

    local attempts = (tonumber(obligation.attempts) or 0) + 1
    if attempts > maxAdoptAttempts then
        -- Said out loud rather than logged, because the gear really is in the wrong slots and
        -- nothing is going to move it now. Refusing is the only safe answer left: whatever stopped
        -- the last two runs finishing this is waiting to stop this one too.
        print("(cswap) Gear from an earlier run is still swapped in and " .. tostring(maxAdoptAttempts) ..
            " runs have failed to put it back -- leaving it alone. Put it back by hand:")
        for _, move in ipairs(obligation.moves) do
            print(" -- " .. tostring(move.slotName) .. " is holding " .. tostring(move.wantName) ..
                "; " .. tostring(move.displacedName or "nothing") .. " belongs there")
        end
        return false
    end

    local moves = {}
    for _, move in ipairs(obligation.moves) do
        if move.slotName ~= nil and move.wantId ~= nil then
            moves[#moves+1] = {
                slot = move.slot,
                slotName = move.slotName,
                wantId = move.wantId,
                wantName = move.wantName,
                displacedId = move.displacedId,
                displacedName = move.displacedName,
                -- it went on last time round, which is the whole reason there is anything to undo
                done = true
            }
        end
    end

    if #moves < 1 then return false end

    Swapping._.hold = {
        owner = obligation.owner,
        label = obligation.label or "gear from an earlier run",
        keep = nil,
        release = true,
        moves = moves,
        problems = {},
        attempts = attempts
    }

    -- **Written down before a single command goes out.** The whole worth of the count is that a
    -- run which never comes back has still left it behind, so it has to reach disk ahead of the
    -- thing that might not come back.
    publish()

    DebugLog("Picked up an obligation from an earlier run (attempt " .. tostring(attempts) .. "): " ..
        tostring(#moves) .. " slot(s) to put back")
    return true
end

---@param hold table
---@return boolean shouldRestore
local function dueToRestore(hold)
    if hold.release then return true end
    if hold.keep == nil then return false end

    local ok, keep = pcall(hold.keep)
    if not ok then
        print("(Swapping) Could not ask whether " .. tostring(hold.label) ..
            " is still wanted; putting it back")
        return true
    end

    return keep ~= true
end

---------------- Tasks --------------------

---@param task SwapTask
local function recordFinished(task)
    local last = Swapping._.last
    last.id = task.id
    last.status = task:Status()
    last.reason = task:Reason()
    last.owner = task.owner
    last.describe = task:Describe()
    last.finishedMs = Time.current_time()

    if task.onDone ~= nil then
        local ok, err = pcall(task.onDone, last.status, last.reason)
        if not ok then
            print("(Swapping) Error in the completion callback for " .. tostring(last.describe) .. ": " .. tostring(err))
        end
    end
end

---What a finished task means for the obligation.
---@param task SwapTask
local function settle(task)
    local hold = Swapping._.hold
    if hold == nil then return end

    if task:What() == "restore" then
        for _, move in ipairs(task:Moves()) do
            if (move.done or move.skipped) and move.source ~= nil then
                move.source.discharged = true
            end
        end

        if Swapping.GetObligation() == nil then
            DebugLog("Everything is back where it was found")
            Swapping._.hold = nil
            publish()
            return
        end

        -- still owed. Not a lapse and not a give-up: a full bag or a loaded cursor is a moment,
        -- and the gear stays owed until it is actually back
        hold.retryAtMs = Time.current_time() + Swapping.settings.restoreRetryMs
        if not hold.warned then
            hold.warned = true
            print("(Swapping) Could not put " .. tostring(hold.label) .. " back: " ..
                tostring(task:Reason()) .. ". Still owed -- /cswap to see it")
        end
        publish()
        return
    end

    -- A wear. Two kinds of move leave nothing owed: one whose item turned out to be on already,
    -- and one that never got as far as changing its slot -- refused, or simply not reached before
    -- the swap was called off. The second is settled by looking rather than by what the task
    -- managed, because a move can fail *after* the slot has taken the item (a full bag with the
    -- displaced item stuck on the cursor is the case), and that one is very much still owed
    for _, move in ipairs(hold.moves) do
        if not move.preexisting and not move.discharged and not move.done then
            if tonumber(mq.TLO.Me.Inventory(move.slotName).ID()) ~= move.wantId then
                move.discharged = true
            end
        end
    end

    if Swapping.GetObligation() == nil then
        Swapping._.hold = nil
    end
    publish()
end

---@param hold table
local function startRestore(hold)
    local moves = restoreMoves(hold)
    if #moves < 1 then
        Swapping._.hold = nil
        publish()
        return
    end

    local task = SwapTask.new(moves, { owner = hold.owner, what = "restore" })
    task.id = Swapping._.nextId
    Swapping._.nextId = Swapping._.nextId + 1
    Swapping._.task = task

    DebugLog("Putting " .. tostring(hold.label) .. " back (" .. tostring(#moves) .. " slot(s))")
end

---------------- Requests --------------------

---Ask for gear to be put on, and taken off again when it is no longer wanted.
---@param items table array of `{ name = string }`, `{ id = number }` or plain item names
---@param options? table
--- owner: string, which behavior this belongs to -- used to stop it again later
--- label: string, what to call the swap in status output
--- keepWhile: fun(): boolean, asked every pulse once the gear is on. The gear comes off the first
---   time it answers false. Left out, the hold stands until `Release`
--- onDone: fun(status, reason), called from the pulse once the *wear* is terminal. The restore is
---   this service's own business and is not reported through it
---@return number|nil taskId poll it with `GetResult`; nil when the request was refused
---@return string|nil refusedReason
---@return table|nil problems the entries that could not be planned, when there were any
function Swapping.Wear(items, options)
    options = options or {}

    local active = Swapping._.task
    if active ~= nil then
        return nil, "already " .. active:Describe()
    end

    if Swapping._.hold ~= nil then
        return nil, tostring(Swapping._.hold.label) .. " is already swapped in for " ..
            tostring(Swapping._.hold.owner)
    end

    local moves, problems = Swapping.PlanWear(items)
    if #moves < 1 then
        local reason = "there was nothing to put on"
        if #problems > 0 then
            reason = tostring(problems[1].name) .. ": " .. tostring(problems[1].problem)
        end
        return nil, reason, problems
    end

    local hold = {
        owner = options.owner,
        label = options.label or "swapped gear",
        keep = options.keepWhile,
        release = false,
        moves = moves,
        problems = problems
    }
    Swapping._.hold = hold
    -- written down before a single command goes out, so a script that dies mid-swap leaves behind
    -- an account of everything it was about to move as well as everything it had
    publish()

    local task = SwapTask.new(moves, {
        owner = options.owner,
        what = "wear",
        onDone = options.onDone
    })

    task.id = Swapping._.nextId
    Swapping._.nextId = Swapping._.nextId + 1
    Swapping._.task = task

    DebugLog("Wear requested [" .. tostring(task.id) .. "]: " .. task:Describe())
    return task.id, nil, problems
end

---Say that whatever the gear went on for is over. The restore itself runs on the pulse.
---@param owner? string only release a hold belonging to this owner, when given
---@return boolean released false when there was nothing held
function Swapping.Release(owner)
    local hold = Swapping._.hold
    if hold == nil then return false end
    if owner ~= nil and hold.owner ~= owner then return false end

    hold.release = true
    hold.retryAtMs = nil
    return true
end

---Stop the swap in progress only if it belongs to this owner, and give back what it has already
---moved. A caller cleaning up after itself must not cancel somebody else's swap.
---@param owner string
---@return boolean stopped
function Swapping.StopFor(owner)
    local hold = Swapping._.hold
    local stopped = false

    local task = Swapping._.task
    if task ~= nil and task.owner == owner then
        task:RequestStop()
        stopped = true
    end

    if hold ~= nil and hold.owner == owner then
        hold.release = true
        hold.retryAtMs = nil
        stopped = true
    end

    return stopped
end

---Stop whatever is in progress, unconditionally, and put back what it moved. Also what the host
---calls if this service is auto-paused for repeated failures.
---
---The obligation is deliberately *not* dropped: the gear is still in the wrong slots, and the
---putting back is what this service is for. A host shutting down for good should read
---`GetObligation` first -- it is what the next run needs to finish the job.
function Swapping.Stop()
    local task = Swapping._.task
    if task ~= nil then
        task:Abandon("stopped")
        settle(task)
        recordFinished(task)
        Swapping._.task = nil
    end

    Swapping.Release()
end

---Drop the obligation without discharging it: the gear stays where it is and this service stops
---owing it back. For the case the world has made the restore impossible -- an item sold,
---destroyed, or left in a bank -- and for a player who has sorted it out by hand.
---@return boolean dropped false when nothing was owed
function Swapping.Forget()
    if Swapping._.hold == nil then return false end
    Swapping._.hold = nil
    publish()
    return true
end

---------------- Pulse --------------------

---One frame of swapping. **Call this every frame from the host's main loop, and from nowhere
---else** -- everything that talks to the client happens here.
---@return string status
function Swapping.Pulse()
    -- The world is being taken down and put back up, and it answers nothing worth hearing while
    -- that is happening: every reading a swap is built on -- what is in a slot, what is on the
    -- cursor -- is empty for the whole of a loading screen. Nothing is *forgotten* over a zone
    -- line, though; the obligation is the same obligation on the far side
    local gameState = mq.TLO.EverQuest.GameState()
    if gameState ~= nil and gameState ~= "INGAME" then
        local zoning = Swapping._.task
        if zoning ~= nil then
            zoning:Abandon("we zoned")
            settle(zoning)
            recordFinished(zoning)
            Swapping._.task = nil
        end
        return SwapStatus.idle
    end

    local task = Swapping._.task
    if task ~= nil then
        local status = task:Pulse()

        if SwapStatus.IsTerminal(status) then
            settle(task)
            recordFinished(task)
            Swapping._.task = nil
        end

        return status
    end

    local hold = Swapping._.hold
    if hold ~= nil and dueToRestore(hold) then
        if hold.retryAtMs == nil or Time.current_time() >= hold.retryAtMs then
            startRestore(hold)
        end
    end

    return SwapStatus.idle
end

---------------- Status --------------------

---@return boolean isActive true while a swap is being made
function Swapping.IsActive()
    return Swapping._.task ~= nil
end

---Is gear swapped in right now, or on its way in?
---@param owner? string only count a hold belonging to this owner, when given
---@return boolean isHolding
function Swapping.IsHolding(owner)
    local hold = Swapping._.hold
    if hold == nil then return false end
    if owner ~= nil and hold.owner ~= owner then return false end
    return true
end

---Is this service moving gear around for this owner right now? What a caller asks to know whether
---the character's hands are its own this frame.
---
---Deliberately false while a restore is only *owed* -- waiting out a full bag or a cursor the
---player has loaded. The putting back happens on this service's pulse and wants no frame from
---anybody, and a caller that reported busy for it would starve everything below it for as long as
---the bag stayed full.
---@param owner string
---@return boolean isBusy
function Swapping.IsBusyFor(owner)
    local task = Swapping._.task
    return task ~= nil and task.owner == owner
end

---@return table|nil hold what is swapped in, as last read
function Swapping.GetHold()
    return Swapping._.hold
end

---@return string status
function Swapping.GetStatus()
    local task = Swapping._.task
    if task == nil then return SwapStatus.idle end
    return task:Status()
end

---@return string|nil reason what swapping is waiting on right now
function Swapping.GetReason()
    local task = Swapping._.task
    if task == nil then return nil end
    return task:Reason()
end

---@return string|nil owner of the swap in progress, or of the gear being held
function Swapping.GetOwner()
    local task = Swapping._.task
    if task ~= nil then return task.owner end
    local hold = Swapping._.hold
    if hold ~= nil then return hold.owner end
    return nil
end

---How a swap ended. Returns nil while it is still running, so a caller can poll the id it was
---handed without tracking anything else. A result stays available until the next one finishes.
---@param taskId number
---@return string|nil status terminal status, nil while the swap is still running
---@return string|nil reason
function Swapping.GetResult(taskId)
    local task = Swapping._.task
    if task ~= nil and task.id == taskId then return nil, task:Reason() end

    local last = Swapping._.last
    if last.id == taskId then return last.status, last.reason end

    return SwapStatus.failed, "cancelled"
end

---@return string description of what swapping is doing, for status output
function Swapping.Describe()
    local task = Swapping._.task
    if task ~= nil then return task:Describe() end

    local hold = Swapping._.hold
    if hold == nil then return "standby" end

    local slots = {}
    for _, move in ipairs(hold.moves) do
        if not move.preexisting and not move.discharged then
            slots[#slots+1] = tostring(move.wantName or move.wantId) .. " in " .. tostring(move.slotName)
        end
    end

    if #slots < 1 then return "standby" end
    return "wearing " .. table.concat(slots, ", ")
end

return Swapping
