---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Menu = require("cabby.ui.menu")
local Priorities = require("cabby.classes.priorities")
local SlashCmd = require("cabby.commands.slashcmd")
local ToggleCommand = require("cabby.commands.toggleCommand")
local TradeskillJobConfig = require("cabby.configs.tradeskillJobConfig")
local TradeskillJobMenu = require("cabby.ui.jobs.tradeskillJobMenu")

---Making the same combine over and over: fill the container, press Combine, put the results away,
---again, until something says stop.
---
---**The container is the whole of it.** A tradeskill container -- a bag in inventory, or a forge
---or brew barrel standing in the world with its window open -- takes one item per slot, and the
---server matches the recipe by *which slots hold what*, not by how deep a stack in one of them is
---(`ZoneDatabase::GetTradeRecipe` counts occupied slots). It then **deletes everything in the
---container** before working out whether the combine succeeded. Both halves matter here:
---
---- two of something means two slots, so `count` on a material row is how many slots it takes,
---  and each one is picked up **one at a time** (`/ctrlkey` on the pick-up, which is what the
---  client reads as "one off this stack" -- `PickupItem`, `moveItem.count = isCtrl and 1 or 0`).
---  Dropping a whole stack of twenty flasks in would combine once and destroy the other nineteen;
---- the container emptying is therefore the world telling us the combine **happened**. A refused
---  combine -- no such recipe, not skilled enough, wrong class, a recipe that must be learnt --
---  leaves the container exactly as it was, and each of those refusals is a different sentence,
---  several of them composed by the server rather than sent as a string id. So this job does not
---  try to recognize them. It fires one `/combine`, watches the container, and reads whichever
---  refusal it did happen to hear only to *explain* a stop it had already decided on.
---
---**Everything else is read the same way**: the cursor holding the item is what says the pick-up
---took, the container's own count is what says the material went in, and the cursor going empty is
---what says the products are away. The only clocks are evidence windows on commands this job
---fired, plus a pace on re-firing them -- a command that produced no visible change at all did not
---take, and there is nothing else the client will say about it.
---
---**Stopping.** Four things end a run and every one of them is the world or the player, not a
---clock: a limit the player set (a skill level reached, a number of combines made, the recipe
---going trivial), the materials running out, the container being closed, and the Stop button.
---Closing the container is deliberately an instruction rather than a fault -- the job opens a bag
---once when it starts and never again, because reopening the thing somebody just closed is
---fighting the player.
---
---Where it sits: it is a **job**, not a state (`cabby/jobs/job.lua`). While it runs it holds the
---whole chain at `Priorities.job`, so nothing follows, sits, buffs or fights while the character
---is standing at a forge, and it takes the character's feet from the movement service on the way
---in for the same reason.
---@class TradeskillJob : Job
local TradeskillJob = {
    key = "TradeskillJob",
    eventIds = {
        somethingNew = "tradeskillSomethingNew",
        alternate = "tradeskillAlternate",
        unexpected = "tradeskillUnexpected",
        failed = "tradeskillFailed",
        trivial = "tradeskillTrivial",
        noCombine = "tradeskillNoCombine",
        missing = "tradeskillMissing",
        unskilled = "tradeskillUnskilled",
        handsFull = "tradeskillHandsFull",
        betterAt = "tradeskillBetterAt"
    },
    _ = {
        isInit = false
    }
}

---The Combine button on the client's own container window (`EQUI_Container.xml`). The client only
---draws it on a container that can combine, which is what makes it the reading for "is this
---actually a tradeskill container": there is no TLO for the item's container type.
local combineButton = "Container_Combine"

---What the client calls the container standing in the world -- one at a time, whatever it is.
---`/combine enviro`, `/itemnotify enviro<n>`, `Window[enviro]` and `InvSlot[enviro]` all take it.
local worldWindow = "enviro"

---How many slots a world container can have (`AddSlotArray(enviro, 10, 4000)`).
local worldSlots = 10

---How long each fired command gets to show up in the world before it is called a fault. Evidence
---windows, not give-ups: they only ever run while nothing at all has happened.
local openEvidenceMs = 2500
local checkEvidenceMs = 1500
local pickUpEvidenceMs = 2000
local placeEvidenceMs = 2000
local combineEvidenceMs = 4000
local collectEvidenceMs = 3000

---How often an unanswered command is issued again. Re-issuing *is* the retry; there is nothing
---else to try, and the evidence window above is what ends it.
local retryIntervalMs = 750

---How often the cursor is emptied. Faster than the rest, because nothing is being waited on:
---putting an item away is a local client action, and a combine handing back several of them puts
---them on the cursor one after another.
local handsIntervalMs = 250

---How long a reading about the cursor has to hold before it is acted on.
---
---Two readings need it. **A cursor that reads empty** after a combine is not evidence the server's
---queue is empty: it hands the output over one item at a time, describing only the front and
---revealing the next as each is taken (`Client::SendCursorBuffer`), so the next one may still be in
---flight. **A material that reads as in hand** is not evidence the pick-up was accepted: the client
---applies it locally before the server answers, and if the server refused it -- its cursor still
---holding output the client has not seen -- `Client::SwapItemResync` corrects us a round trip
---later. Acting early on either one is what posts the wrong item into the container, and no recipe
---matches it afterwards (2026-08-27, in game).
---
---Both are the same wait: one server round trip. So rather than guess at a number, it is measured.
---See `settleWindow`.

---Bounds on that measured window, and how much slack is put on top of what was observed.
local settleFloorMs = 150
local settleCeilingMs = 800
local settleSafetyFactor = 2

---How long after a stop the cursor is watched for something to put away. A run cut off mid-fill
---leaves a material in the client's hand, and the client gives it back on its own clock.
local stowWindowMs = 3000

---How often the container list behind the page's picker is re-read. Only ever while idle -- a
---walk over every bag is a few dozen reads, and nothing about it changes while a run is going.
local scanIntervalMs = 500

---The skills a combine can raise, in the client's own words (`eqdata/skills.h`). Fishing is left
---out: it is a skill, but not one anything is combined for.
TradeskillJob.tradeskills = {
    "Alchemy", "Baking", "Blacksmithing", "Brewing", "Fletching",
    "Jewelry Making", "Make Poison", "Pottery", "Research", "Tailoring", "Tinkering"
}

---Where a run can be in its cycle. Each one fires at most one command and then reads the world.
local steps = {
    ---a bag that is not open yet: open it, once
    opening = "opening",
    ---is this really a tradeskill container -- does the window show a Combine button
    checking = "checking",
    ---work out the next material the container is short of
    filling = "filling",
    ---get that material onto the cursor, one off the stack
    picking = "picking",
    ---and into the container
    placing = "placing",
    ---press Combine, and wait for the container to empty
    combining = "combining",
    ---put whatever the combine produced away
    collecting = "collecting"
}

---@param str string
local function DebugLog(str)
    Debug.Log(TradeskillJob.key, str)
end

---@return number ping current latency in ms, defaulted when the client has not reported one
local function ping()
    local latency = tonumber(mq.TLO.EverQuest.Ping())
    if latency == nil or latency < 0 then return 100 end
    return math.min(latency, 2000)
end

---------------- Addressing the container --------------------

---@param container table
---@return string name what `/combine`, `Window[]` and `/itemnotify` know it by
local function windowName(container)
    if container.kind == TradeskillJobConfig.kinds.world then return worldWindow end
    return "pack" .. tostring(container.pack)
end

---@param container table
---@return boolean isOpen whether its window is up
local function windowOpen(container)
    return mq.TLO.Window(windowName(container)).Open() == true
end

---@param container table
---@return boolean showsCombine whether the window is drawing a Combine button
local function showsCombine(container)
    return mq.TLO.Window(windowName(container)).Child(combineButton).Open() == true
end

---How many slots the container has -- and whether the client actually told us.
---
---A bag is an item like any other and answers straight away. **The world container does not.**
---`Item.Container` reports slots only for an item typed as a pack (`ITEMTYPE_PACK`, see
---`MQ2ItemType.cpp`), and the one the client builds out of the object it was told to open is not
---typed that way: a brew barrel standing open in the world answered **0** the first time this ran
---in game (2026-08-22), and a zero read as "no room left" on an empty barrel before the first
---material ever went in. MQ has the same blind spot noted in its own `FirstFreeSlot` ("FIXME:
---check with world container").
---
---So the unreadable count is not spent as though it were a real zero. It falls back to the ten
---slots the client itself addresses (`enviro1..enviro10`), and the caller is told the number was a
---fallback so the pre-flight size check can stand aside rather than refuse on it. Nothing is aimed
---at a slot that might not exist by doing this: filling always takes the *lowest empty* slot, so a
---container with fewer than ten is only ever overrun by a recipe that was already too big for it.
---@param container table
---@return number slots
---@return boolean known whether that came from the client or from the fallback
local function containerSlots(container)
    if container.kind == TradeskillJobConfig.kinds.world then
        local read = tonumber(mq.TLO.InvSlot(worldWindow).Item.Container()) or 0
        if read > 0 then return math.min(read, worldSlots), true end
        return worldSlots, false
    end
    return tonumber(mq.TLO.Me.Inventory("pack" .. tostring(container.pack)).Container()) or 0, true
end

---@param container table
---@param slot number 1-based
---@return string|nil name what is in that slot
local function slotName(container, slot)
    if container.kind == TradeskillJobConfig.kinds.world then
        return mq.TLO.InvSlot(worldWindow .. tostring(slot)).Item.Name()
    end
    return mq.TLO.Me.Inventory("pack" .. tostring(container.pack)).Item(slot).Name()
end

---@param container table
---@param slot number 1-based
---@return string command that drops what is on the cursor into that slot
local function dropCommand(container, slot)
    if container.kind == TradeskillJobConfig.kinds.world then
        return "/itemnotify " .. worldWindow .. tostring(slot) .. " leftmouseup"
    end
    return "/itemnotify in pack" .. tostring(container.pack) .. " " .. tostring(slot) .. " leftmouseup"
end

---@param container table
---@param name string
---@return number count how many slots of the container hold this item
local function countIn(container, name)
    local wanted = tostring(name):lower()
    local count = 0
    for slot = 1, containerSlots(container) do
        local held = slotName(container, slot)
        if held ~= nil and tostring(held):lower() == wanted then
            count = count + 1
        end
    end
    return count
end

---@param container table
---@return number used how many slots hold anything at all
local function occupied(container)
    local count = 0
    for slot = 1, containerSlots(container) do
        if slotName(container, slot) ~= nil then count = count + 1 end
    end
    return count
end

---@param container table
---@return number|nil slot the first empty slot, 1-based
local function firstFree(container)
    for slot = 1, containerSlots(container) do
        if slotName(container, slot) == nil then return slot end
    end
    return nil
end

---How many of this material can still be picked up out of inventory.
---
---`FindItemCount` counts stack charges across the whole inventory -- and a bag being used as the
---tradeskill container is *in* the inventory, so what is already staged in it would otherwise be
---counted as still available and the run would think it had one more than it does. A container
---standing in the world is not inventory and needs no such subtraction.
---@param container table
---@param name string
---@return number available
local function available(container, name)
    local held = tonumber(mq.TLO.FindItemCount("=" .. tostring(name))()) or 0
    if container.kind == TradeskillJobConfig.kinds.pack then
        held = held - countIn(container, name)
    end
    return math.max(0, held)
end

---Where one of a material can be picked up from, addressed by the slot it is sitting in.
---
---`/itemnotify "<name>"` would do this in one line, and it is what the world container case could
---safely use -- but when the container is a **bag**, its contents are part of this character's
---inventory, and the client resolving that name walks the whole of it. A recipe wanting two of
---something would then pull the one already staged back out of the container and put it straight
---back in, and the fill would never finish. So the walk is ours and it skips the container.
---
---A material sitting loose in a top-level bag slot rather than inside a bag falls back to the name
---form: that slot cannot be addressed with `/itemnotify` unless the inventory window happens to be
---open, and materials live in bags.
---@param container table
---@param name string
---@return string|nil command that puts exactly one of it on the cursor, nil when there is none to
---take that is not already staged
local function pickUpCommand(container, name)
    local wanted = tostring(name):lower()
    local bags = tonumber(mq.TLO.Me.NumBagSlots()) or 10

    for pack = 1, bags do
        local isTheContainer = container.kind == TradeskillJobConfig.kinds.pack
            and pack == container.pack

        if not isTheContainer then
            local item = mq.TLO.Me.Inventory("pack" .. tostring(pack))
            local slots = tonumber(item.Container()) or 0

            if slots > 0 then
                for slot = 1, slots do
                    local held = item.Item(slot).Name()
                    if held ~= nil and tostring(held):lower() == wanted then
                        -- ctrl is what the client reads as "one off this stack" (`PickupItem`);
                        -- without it the whole stack comes along, fills the one slot the recipe
                        -- wanted, and is destroyed by the combine
                        return "/ctrlkey /itemnotify in pack" .. tostring(pack) .. " " ..
                            tostring(slot) .. " leftmouseup"
                    end
                end
            else
                local held = item.Name()
                if held ~= nil and tostring(held):lower() == wanted then
                    return '/ctrlkey /itemnotify "' .. tostring(name) .. '" leftmouseup'
                end
            end
        end
    end

    return nil
end

---------------- Reading the cursor --------------------

---@return string|nil name what the client is holding
local function cursorName()
    return mq.TLO.Cursor.Name()
end

---@param name string
---@return boolean holdsIt whether the cursor holds this item
local function cursorHolds(name)
    local held = cursorName()
    return held ~= nil and tostring(held):lower() == tostring(name):lower()
end

---@return boolean loaded whether the cursor holds anything at all
local function cursorLoaded()
    return mq.TLO.Cursor.ID() ~= nil
end

---------------- The look, for the page's pickers --------------------

---Every container that could be combined in: the one standing open in the world, and every
---container in a bag slot. Whether a bag is a *tradeskill* container is not readable off the item
----- the client keeps the container type but no TLO hands it over -- so what is reported is the
---one reading that does settle it, the Combine button on its window, and that only exists while
---the bag is open. A closed bag is offered as a candidate all the same, with the answer left
---unknown: the run opens it and checks then.
---@return table candidates
local function scanContainers()
    local found = {}

    if mq.TLO.Window(worldWindow).Open() == true then
        local item = mq.TLO.InvSlot(worldWindow).Item
        found[#found+1] = {
            kind = TradeskillJobConfig.kinds.world,
            name = item.Name() or "Open container",
            -- through the same helper, so the page and the run agree about a count the client will
            -- not give for a world container
            slots = containerSlots({ kind = TradeskillJobConfig.kinds.world }),
            open = true,
            combines = mq.TLO.Window(worldWindow).Child(combineButton).Open() == true
        }
    end

    local bags = tonumber(mq.TLO.Me.NumBagSlots()) or 10
    for pack = 1, bags do
        local item = mq.TLO.Me.Inventory("pack" .. tostring(pack))
        local slots = tonumber(item.Container()) or 0
        if slots > 0 then
            local isOpen = mq.TLO.Window("pack" .. tostring(pack)).Open() == true

            -- nil is "nobody has shown us", and it has to stay distinct from a plain false: a
            -- closed bag has no window to read a button off, and saying "no Combine button" about
            -- one we have never looked at would be spending a reading that was never taken
            local combines = nil
            if isOpen then
                combines = mq.TLO.Window("pack" .. tostring(pack)).Child(combineButton).Open() == true
            end

            found[#found+1] = {
                kind = TradeskillJobConfig.kinds.pack,
                pack = pack,
                name = item.Name() or ("Bag " .. tostring(pack)),
                slots = slots,
                open = isOpen,
                combines = combines
            }
        end
    end

    return found
end

---Everything in inventory, once per name, for the material picker. Read on demand rather than
---kept current: it is a hundred-odd reads, and it only matters while somebody is looking at the
---list of what they could add.
---@return table items array of `{ name, count }`, sorted by name
function TradeskillJob.ScanInventory()
    local names = {}
    local seen = {}

    local function add(item)
        local name = item.Name()
        if name == nil or name == "" then return end
        if seen[name:lower()] then return end
        seen[name:lower()] = true
        names[#names+1] = { name = name, count = tonumber(mq.TLO.FindItemCount("=" .. name)()) or 0 }
    end

    local bags = tonumber(mq.TLO.Me.NumBagSlots()) or 10
    for pack = 1, bags do
        local item = mq.TLO.Me.Inventory("pack" .. tostring(pack))
        local slots = tonumber(item.Container()) or 0
        if slots > 0 then
            for slot = 1, slots do add(item.Item(slot)) end
        elseif item.ID() ~= nil then
            add(item)
        end
    end

    table.sort(names, function(a, b) return a.name:lower() < b.name:lower() end)
    return names
end

---@return table candidates the last look at what could be combined in
function TradeskillJob.GetContainerCandidates()
    return TradeskillJob._.candidates or {}
end

---------------- Running --------------------

---@param step string
---@param evidenceMs number how long this step's fired command has to show up in the world
local function advance(step, evidenceMs)
    local run = TradeskillJob._
    run.step = step
    -- zero rather than "now", so the step's first command goes out on the pass it starts
    run.lastFireMs = 0
    run.deadlineMs = Time.current_time() + evidenceMs + ping()
end

---@return boolean expired whether this step's evidence window has run out
local function expired()
    return Time.current_time() > (TradeskillJob._.deadlineMs or math.huge)
end

---Re-arm the window this step is waiting inside. Called when the world *did* change: an evidence
---window only ever runs while nothing at all is happening.
---@param evidenceMs number
local function extend(evidenceMs)
    TradeskillJob._.deadlineMs = Time.current_time() + evidenceMs + ping()
end

---Diagnostic only -- NOT what sizes the settle, see settleWindow. This is the time from firing
---`/combine` to the macro noticing the container empty, which is the round trip plus this script's
---own polling granularity. Useful for judging whether a window is sane, misleading as the window
---itself.
---@param ms number
---------------- What the server actually has on the cursor --------------------

---How many items the SERVER holds on the cursor, or nil when that cannot be known.
---
---The client keeps no cursor queue -- it renders only the item in hand -- so after a combine that
---hands back more than one item there is a window where the client reads empty and the server does
---not. Everything below about settling exists to wait that window out by inference.
---
---`cursorsync.asi` removes the inference. It counts the server's pushes from the item packets and
---the pops from outgoing OP_MoveItem, and publishes the number. Measured 2026-08-28: exactly
---0 -> 2 -> 0 per combine across ten of them, no drift. When the file is there the wait becomes a
---fact and costs nothing; when it is not -- no mod, older client -- this returns nil and the
---measured settle below is used instead, so the job still works either way.
---@return number|nil depth
local function serverCursorDepth()
    local dir = mq.TLO.EverQuest.Path()
    if dir == nil or dir == "" then return nil end

    local f = io.open(dir .. "\\cursorsync.state", "r")
    if f == nil then return nil end
    local line = f:read("l")
    f:close()

    return tonumber(line)
end

-- forward declaration: recordReveal below reports the window, and settleWindow is defined further
-- down next to the other step helpers
local settleWindow

---Measure a reveal: the gap between putting an item down and the next one showing up in hand.
---That is exactly the window settleWindow has to cover, so it is the honest thing to size from.
---@param ms number
local function recordReveal(ms)
    local run = TradeskillJob._
    if type(ms) ~= "number" or ms < 0 then return end

    -- the worst of the last few, not an all-time high-water mark: one bad sample used to pin the
    -- window at its ceiling for the rest of the run
    run.revealSamples = run.revealSamples or {}
    table.insert(run.revealSamples, ms)
    while #run.revealSamples > 5 do table.remove(run.revealSamples, 1) end

    local worst = 0
    for _, sample in ipairs(run.revealSamples) do
        if sample > worst then worst = sample end
    end
    run.observedRevealMs = worst

    -- unconditional while this is being tuned: the number is the whole point
    print(string.format("CURSORREVEAL took %dms -- settling reads for %dms",
        math.floor(ms), math.floor(settleWindow())))
end

local function recordLatency(ms)
    local run = TradeskillJob._
    if type(ms) ~= "number" or ms < 0 then return end

    -- a high-water mark that decays: one slow pass widens the window at once, and a run of fast
    -- ones narrows it again rather than leaving it stuck at the worst thing ever seen
    local seen = run.observedLatencyMs
    if seen == nil or ms > seen then
        run.observedLatencyMs = ms
    else
        run.observedLatencyMs = (seen * 0.9) + (ms * 0.1)
    end
end

---Whether the readings after this combine need settling at all.
---
---The window exists only because a combine can hand back **more than one** item: the server can
---then hold a second on its cursor that the client has not been shown, and reveals it a round trip
---after the first is taken. A combine that *failed* hands back exactly the recipe's one failure
---item -- nothing queues behind it, the client is told about it because the cursor was empty, and
---the two sides cannot disagree. So a failure needs no wait, and on a recipe well over trivial
---most attempts are failures.
---
---An outcome we have not heard yet settles: the safe answer is the slow one.
---@return boolean needed
local function settleNeeded()
    return TradeskillJob._.combineOutcome ~= "failure"
end

---How long a reading has to hold before it is acted on.
---
---This is the one window that matters: from taking an item off the cursor, to the server's reveal
---of the next one being visible in client memory. The client keeps no queue of its own -- proved
---twice in the trace, where it banked one item and read empty while the server was already sending
---the second -- so that whole path is server pulse + transit + client frame + this script noticing.
---
---Sized off `ping()` it was far too tight (2026-08-28: broke immediately, the cakes went into the
---oven). Sized off "how long until the container read empty", tripled, it was far too generous
---(1.6s of every 2.1s cycle). So measure the actual thing: every reveal that *does* arrive tells us
---what one costs, and the wait for a reveal that never comes is sized from that.
---@return number ms
function settleWindow()
    local seen = TradeskillJob._.observedRevealMs
    if seen == nil then return settleCeilingMs end

    local window = seen * settleSafetyFactor
    if window < settleFloorMs then return settleFloorMs end
    if window > settleCeilingMs then return settleCeilingMs end
    return window
end

---@param command string
---@param intervalMs? number how often this one may be re-issued, when the default pace is wrong
---for it
---@return boolean fired false when this step's pace says not yet
local function fire(command, intervalMs)
    local run = TradeskillJob._
    local now = Time.current_time()
    if now - (run.lastFireMs or 0) < (intervalMs or retryIntervalMs) then return false end

    DebugLog("Running [" .. command .. "]")
    mq.cmd(command)
    run.lastFireMs = now
    return true
end

---End the run, and say why. Fires nothing: this is reachable from an ImGui button, and the one
---thing that may still need doing -- putting back a material left on the cursor -- is left to the
---pulse (see the stow below).
---@param reason string
local function stop(reason)
    local run = TradeskillJob._

    if run.running then
        print("(Tradeskill) Stopped: " .. reason .. " -- " .. tostring(run.combines) .. " combine(s) made")
        DebugLog("Stopping: " .. reason)
    end

    run.running = false
    run.step = nil
    run.pending = nil
    run.deadlineMs = nil
    run.stoppedReason = reason
    -- whatever the client is still holding is ours to put back
    run.stowUntilMs = Time.current_time() + stowWindowMs
end

---Which tradeskill this run is raising.
---
---The page's picker may name one, and then it is simply that. Left on **Auto** it is a thing to be
---learnt rather than configured, and the world says it plainly: a combine that raises a skill
---prints which one ("You have become better at Brewing! (54)"), and nothing else is acting while a
---job holds the chain, so that line during a run is about this recipe. Until one arrives the answer
---is **nil** -- not a guess off the container's name, and not a stale pick from the last run. A
---skill limit with nothing detected yet has simply not come due; the reading that would settle it
---is the same event that could trip it.
---@return string|nil skill
local function watchedSkill()
    local chosen = TradeskillJobConfig.GetSkill()
    if chosen ~= "" then return chosen end
    return TradeskillJob._.detectedSkill
end

---Whichever limit the player set has been reached, or nil.
---@return string|nil reason
local function limitReached()
    local run = TradeskillJob._

    if TradeskillJobConfig.GetStopAfterCombines() and run.combines >= TradeskillJobConfig.GetCombines() then
        return "made " .. tostring(run.combines) .. " combines"
    end

    -- counted apart from the combines, because they are different questions: one is how much
    -- material to spend, the other is how many of the thing to end up with. A combine the server
    -- made and lost is one of the first and none of the second
    if TradeskillJobConfig.GetStopAfterSuccesses() and run.succeeded >= TradeskillJobConfig.GetSuccesses() then
        return "made " .. tostring(run.succeeded) .. " successful combines"
    end

    if TradeskillJobConfig.GetStopAtSkill() then
        local skill = watchedSkill()
        if skill ~= nil then
            local now = tonumber(mq.TLO.Me.Skill(skill)()) or 0
            if now >= TradeskillJobConfig.GetSkillLevel() then
                return "reached " .. skill .. " " .. tostring(now)
            end
        end
    end

    if TradeskillJobConfig.GetStopWhenTrivial() and run.trivialSeen then
        return "the recipe has gone trivial"
    end

    return nil
end

---What the combine that did not go through was refused for, in the client's own words when it gave
---any. Only a line heard *since* the Combine went out counts -- an older one is about an older
---combine and would explain this one wrongly.
---@return string reason
local function refusalReason()
    local run = TradeskillJob._
    if run.refusal ~= nil and (run.refusalAtMs or 0) >= (run.combineFiredAtMs or 0) then
        return run.refusal
    end
    return "the combine did not go through and the container was not emptied"
end

---Put down whatever the client is holding, one `/autoinventory` at a time.
---
---Three steps need this and all three need it for the same reason: **every command this job sends
---means something different with a full cursor.** A pick-up puts the held item down instead, a drop
---picks that slot's item up instead, and the client refuses a combine outright ("You cannot combine
---items when your hands are full!"). So each of them looks at the hands in the frame it fires, and
---this is what they call when the answer is yes.
---
---Each new item reaching the cursor re-arms the window, so the window only ever runs while nothing
---at all is happening -- the same shape as every other evidence window here.
---@param evidenceMs number the window the caller allows for it
local function putHandsDown(evidenceMs)
    local run = TradeskillJob._

    local held = mq.TLO.Cursor.ID()
    if held ~= run.handsSeenId then
        run.handsSeenId = held
        extend(evidenceMs)
    end

    local before = cursorName()
    if fire("/autoinventory", handsIntervalMs) then
        run.bankFiredAtMs = Time.current_time()
        run.bankItemId    = held
        -- PROBE (2026-08-27): read the cursor again in the same frame the command ran in. Nothing
        -- can have come back from the server yet, so if something is already in hand it came out
        -- of the CLIENT's own cursor queue (pLocalPC->LimboBufferItems) -- which would mean the
        -- client knows the whole queue and the settle windows are unnecessary. "then <nothing>"
        -- means it only ever tracks the front and the settles have to stay.
        print("CURSORPROBE put away [" .. tostring(before) .. "] -- same frame, cursor now [" ..
            tostring(cursorName() or "<nothing>") .. "]")
    end
end

---------------- The steps --------------------

---@param container table
local function stepOpening(container)
    if windowOpen(container) then
        advance(steps.checking, checkEvidenceMs)
        return
    end

    if container.kind == TradeskillJobConfig.kinds.world then
        -- there is nothing to open: a world container is opened by walking up to it and clicking
        stop("nothing is open in the world to combine in")
        return
    end

    if expired() then
        stop("could not open " .. TradeskillJobConfig.DescribeContainer(container))
        return
    end

    -- the notify toggles the bag, so it is only ever sent while the window reads closed
    fire("/itemnotify pack" .. tostring(container.pack) .. " rightmouseup")
end

---@param container table
local function stepChecking(container)
    if showsCombine(container) then
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    if expired() then
        stop(TradeskillJobConfig.DescribeContainer(container) ..
            " has no Combine button -- it is not a tradeskill container")
    end
end

---@param container table
local function stepFilling(container)
    -- anything the client is holding goes away first: a pick-up with a full cursor puts the held
    -- item down instead, which would post a material into whatever slot was aimed at
    if cursorLoaded() then
        if expired() then
            stop("could not put " .. tostring(cursorName()) .. " down before filling the container")
            return
        end
        putHandsDown(pickUpEvidenceMs)
        return
    end

    for _, material in ipairs(TradeskillJobConfig.GetItems()) do
        local wanted = math.max(1, math.floor(tonumber(material.count) or 1))
        local staged = countIn(container, material.name)

        if staged < wanted then
            -- what can actually be picked up is the honest reading of "have we got one", and it is
            -- the same walk the pick-up itself is addressed by
            if pickUpCommand(container, material.name) == nil then
                stop("out of " .. tostring(material.name))
                return
            end

            local slot = firstFree(container)
            if slot == nil then
                stop(TradeskillJobConfig.DescribeContainer(container) .. " has no empty slot left" ..
                    " -- one combine needs " .. tostring(TradeskillJobConfig.GetSlotsNeeded()))
                return
            end

            TradeskillJob._.pending = { name = material.name, slot = slot, wanted = staged + 1 }
            advance(steps.picking, pickUpEvidenceMs)
            return
        end
    end

    -- nothing missing: the container is loaded
    TradeskillJob._.combineFiredAtMs = nil
    advance(steps.combining, combineEvidenceMs)
end

---@param container table
local function stepPicking(container)
    local run = TradeskillJob._
    local pending = run.pending
    if pending == nil then
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    if cursorHolds(pending.name) then
        -- No settle here. This reading is the client's expectation -- MacroQuest reads client
        -- memory, and the client applies a pick-up before the server has answered -- so acting on
        -- it early is what once put a combine's product into the container. But the only way the
        -- server refuses a pick-up is if its cursor is still occupied, and the collect step above
        -- has already waited a full settle to establish that it is not. Waiting again here is
        -- belt-and-braces on a thing already proved, and it cost about 340ms of every cycle.
        --
        -- If this turns out to be wrong the trace says so at once -- a desync on a bag -> 33 move
        -- followed by a CONTAINER in of the wrong item -- and the settle goes back. The version
        -- with it is kept alongside this file as tradeskillJob.with-pickup-settle.lua.
        advance(steps.placing, placeEvidenceMs)
        return
    end

    -- something else turned up in the client's hand; the fill step knows how to put it away
    if cursorLoaded() then
        run.pending = nil
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    if expired() then
        stop("could not pick up " .. tostring(pending.name))
        return
    end

    -- worked out again on every fire rather than carried from the fill: slots move as a bag empties
    local command = pickUpCommand(container, pending.name)
    if command == nil then
        stop("out of " .. tostring(pending.name))
        return
    end

    fire(command)
end

---@param container table
local function stepPlacing(container)
    local pending = TradeskillJob._.pending
    if pending == nil then
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    -- the container's own count is the answer, not the slot that was aimed at: the client is free
    -- to land it somewhere else, and it is in either way
    if countIn(container, pending.name) >= pending.wanted then
        TradeskillJob._.pending = nil
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    -- re-firing the drop is only safe while the item is still in hand: the same notify on an empty
    -- cursor picks that slot's item back up
    if not cursorHolds(pending.name) then
        TradeskillJob._.pending = nil
        advance(steps.filling, pickUpEvidenceMs)
        return
    end

    if expired() then
        stop("could not put " .. tostring(pending.name) .. " into " ..
            TradeskillJobConfig.DescribeContainer(container))
        return
    end

    fire(dropCommand(container, pending.slot))
end

---@param container table
local function stepCombining(container)
    local run = TradeskillJob._

    -- the container emptying is the world saying the combine happened -- the server clears every
    -- slot before it works out whether it succeeded, and leaves them all alone when it refuses
    if occupied(container) < 1 and run.combineFiredAtMs ~= nil then
        recordLatency(Time.current_time() - run.combineFiredAtMs)
        DebugLog("Server answered in " .. tostring(math.floor(run.observedLatencyMs or 0)) ..
            "ms -- settling reads for " .. tostring(math.floor(settleWindow())) .. "ms")
        run.combines = run.combines + 1
        DebugLog("Combine " .. tostring(run.combines) .. " went through")
        -- the server is about to put this combine's output on its cursor, so the collect step
        -- starts a fresh settle rather than inheriting whatever the last one concluded
        run.cursorEmptySinceMs = nil
        run.sawOutput = false
        advance(steps.collecting, collectEvidenceMs)
        return
    end

    if run.combineFiredAtMs == nil then
        -- **The hands are looked at in the frame the command goes out.** The client refuses a
        -- combine outright while anything is on the cursor, and the fill step's own look at the
        -- cursor is a whole pass earlier -- wide enough for the *previous* combine's product to
        -- land in, since the server sends that separately from the packet clearing the container
        -- and the collect step moves on the moment the cursor reads empty. That gap is what a long
        -- unattended run finds (2026-08-22, in game), and closing it means testing here rather than
        -- one step earlier: there is no frame between this test and the command under it
        if cursorLoaded() then
            if expired() then
                stop("could not put " .. tostring(cursorName()) .. " away before combining")
                return
            end
            putHandsDown(combineEvidenceMs)
            return
        end

        -- fired exactly once, and never re-fired: unlike a click on a slot, a combine that is
        -- merely slow is not a combine that failed, and a second one is a second combine
        DebugLog("Pressing Combine on " .. windowName(container))
        run.combineOutcome = nil
        mq.cmd("/combine " .. windowName(container))
        run.combineFiredAtMs = Time.current_time()
        return
    end

    if expired() then
        stop(refusalReason())
    end
end

local function stepCollecting()
    local run = TradeskillJob._

    if cursorLoaded() then
        -- whatever comes off the cursor during a run is what the combine made
        run.lastProduct = cursorName() or run.lastProduct
        run.cursorEmptySinceMs = nil
        -- from here the published depth is meaningful: the output has begun arriving
        run.sawOutput = true

        -- A reveal is a DIFFERENT item turning up -- not the one we just tried to put down still
        -- being in hand because the client has not processed the put-away yet. Timing the latter
        -- measures nothing, reads as about 20ms, and drove the window down to its floor so there
        -- was no settle at all (2026-08-28: broke on the second combine).
        if run.bankFiredAtMs ~= nil and mq.TLO.Cursor.ID() ~= run.bankItemId then
            recordReveal(Time.current_time() - run.bankFiredAtMs)
            run.bankFiredAtMs = nil
            run.bankItemId    = nil
        end

        if expired() then
            stop("no room to put " .. tostring(cursorName()) .. " away")
            return
        end
        putHandsDown(collectEvidenceMs)
        return
    end

    -- The published depth answers "is there more?" exactly -- but only once there is something to
    -- count. Straight after a combine it reads 0 because the server has not pushed yet, and 0 then
    -- means "not arrived", not "nothing coming". Taking that as done is what dropped a combine's
    -- output into the container mid-fill (2026-08-28). So the settle covers the wait for the FIRST
    -- item, and the depth takes over from there -- where it is exact, because the server queues a
    -- combine's whole output in one pass.
    local depth = run.sawOutput and serverCursorDepth() or nil
    if depth ~= nil then
        if depth > 0 then
            -- the server still has something queued that the client has not been shown
            extend(collectEvidenceMs)
            return
        end
    elseif settleNeeded() then
        local now = Time.current_time()
        if run.cursorEmptySinceMs == nil then
            run.cursorEmptySinceMs = now
            return
        end
        if now - run.cursorEmptySinceMs < settleWindow() then
            -- still inside the window the next queued item could arrive in
            extend(collectEvidenceMs)
            return
        end
    end

    local reason = limitReached()
    if reason ~= nil then
        stop(reason)
        return
    end
    run.cursorEmptySinceMs = nil
    -- the wait ended with nothing arriving, so there is no reveal to time. Drop the stamp, or the
    -- next item to turn up -- the NEXT combine's output, seconds later -- gets measured as one.
    run.bankFiredAtMs = nil
    run.bankItemId    = nil
    advance(steps.filling, pickUpEvidenceMs)
end

---------------- The pulse --------------------

---Put back whatever a stopped run left in the client's hand. Runs from the pulse rather than from
---the stop, because a stop can come from an ImGui button and because the client gives an item back
---on its own clock.
local function stow()
    local run = TradeskillJob._
    if run.stowUntilMs == nil then return end

    if Time.current_time() > run.stowUntilMs then
        run.stowUntilMs = nil
        return
    end

    if not cursorLoaded() then
        run.stowUntilMs = nil
        return
    end

    fire("/autoinventory")
end

---Service contract: one pass, every frame, whatever the state chain is doing.
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.Pulse()
    local run = TradeskillJob._

    if not run.running then
        stow()

        -- what the page's container picker offers. Only while idle: a walk over every bag is a few
        -- dozen reads, and none of it changes once a run has its container
        local now = Time.current_time()
        if now - (run.lastScanMs or 0) >= scanIntervalMs then
            run.lastScanMs = now
            run.candidates = scanContainers()
        end
        return
    end

    local container = TradeskillJobConfig.GetContainer()
    if container == nil then
        stop("the container is no longer set")
        return
    end

    -- Closing the container is the player saying stop, and it is the same reading for a bag, a
    -- forge, a zone line and a container a combine consumed. Not while opening one, which is the
    -- one moment it is legitimately shut.
    if run.step ~= steps.opening and not windowOpen(container) then
        stop(TradeskillJobConfig.DescribeContainer(container) .. " was closed")
        return
    end

    if run.step == steps.opening then
        stepOpening(container)
    elseif run.step == steps.checking then
        stepChecking(container)
    elseif run.step == steps.filling then
        stepFilling(container)
    elseif run.step == steps.picking then
        stepPicking(container)
    elseif run.step == steps.placing then
        stepPlacing(container)
    elseif run.step == steps.combining then
        stepCombining(container)
    elseif run.step == steps.collecting then
        stepCollecting()
    else
        stop("lost track of what it was doing")
    end
end

---Service contract: called if the state machine pauses this job after repeated failures.
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.Stop()
    stop("the job was paused after repeated failures")
end

---While a run is going, nothing in the state chain runs. See `Priorities.job`.
---@return number|nil floor
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.Hold()
    if not TradeskillJob._.running then return nil end
    return Priorities.job
end

---------------- Starting and stopping --------------------

---Everything that can be answered before a single command goes out.
---@return string|nil refusal why it cannot start, nil when it can
local function refuseStart()
    local container = TradeskillJobConfig.GetContainer()
    if container == nil then
        return "no container chosen"
    end

    if container.kind == TradeskillJobConfig.kinds.world and not windowOpen(container) then
        return "nothing is open in the world to combine in"
    end

    if container.kind == TradeskillJobConfig.kinds.pack and containerSlots(container) < 1 then
        return "there is no container in bag " .. tostring(container.pack) .. " any more"
    end

    local items = TradeskillJobConfig.GetItems()
    if #items < 1 then
        return "no materials chosen"
    end

    -- only judged against a count the client actually gave: a world container's is a fallback, and
    -- refusing to start over a number nobody told us would be the same mistake as the zero this
    -- replaced
    local needed = TradeskillJobConfig.GetSlotsNeeded()
    local slots, slotsKnown = containerSlots(container)
    if slotsKnown and slots > 0 and needed > slots then
        return TradeskillJobConfig.DescribeContainer(container) .. " holds " .. tostring(slots) ..
            ", and one combine needs " .. tostring(needed)
    end

    for _, material in ipairs(items) do
        local wanted = math.max(1, math.floor(tonumber(material.count) or 1))
        -- what is already staged in the container counts: a run stopped mid-fill leaves materials
        -- sitting in there, and refusing to start over them would be refusing over our own doing
        if available(container, material.name) + countIn(container, material.name) < wanted then
            return "not enough " .. tostring(material.name) .. " to make even one"
        end
    end

    -- Auto is not a missing setting, so there is nothing to refuse over: the limit comes due when
    -- the world says which skill this is, which is the same line that could trip it
    local chosen = TradeskillJobConfig.GetSkill()
    if TradeskillJobConfig.GetStopAtSkill() and chosen ~= "" then
        local now = tonumber(mq.TLO.Me.Skill(chosen)()) or 0
        if now >= TradeskillJobConfig.GetSkillLevel() then
            return chosen .. " is already " .. tostring(now)
        end
    end

    return nil
end

---@return boolean isRunning
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.IsEnabled()
    return TradeskillJob._.running == true
end

---Start a run, or end the one going.
---
---Nothing here talks to the client except `Movement.Stop`, which records intent and is answered by
---the movement service's own pulse -- so this is safe from the page's buttons. Stopping movement is
---the job taking the character: a follow task already in flight would otherwise keep walking, since
---the state that started it is starved from here on and never gets the frame to call it off.
---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.SetEnabled(isEnabled)
    local run = TradeskillJob._

    if not isEnabled then
        if run.running then
            stop("stopped by hand")
        end
        return
    end

    if run.running then return end

    local refusal = refuseStart()
    if refusal ~= nil then
        print("(Tradeskill) Cannot start: " .. refusal)
        run.stoppedReason = refusal
        return
    end

    local container = TradeskillJobConfig.GetContainer()

    run.running = true
    run.combines = 0
    run.succeeded = 0
    run.failed = 0
    run.trivialSeen = false
    run.pending = nil
    run.refusal = nil
    run.refusalAtMs = nil
    run.combineFiredAtMs = nil
    run.handsSeenId = nil
    run.lastProduct = nil
    run.cursorEmptySinceMs = nil
    run.observedLatencyMs = nil
    run.observedRevealMs = nil
    run.revealSamples = nil
    run.bankFiredAtMs = nil
    run.bankItemId = nil
    run.combineOutcome = nil
    run.sawOutput = false
    run.stoppedReason = nil
    run.stowUntilMs = nil
    run.detectedSkill = nil
    -- every tradeskill, not just a chosen one: on Auto there is no way to know at the start which
    -- of them this recipe raises, and a baseline taken after the first skill-up is a baseline that
    -- has already missed one. Eleven reads, once
    run.startedSkills = {}
    for _, skill in ipairs(TradeskillJob.tradeskills) do
        run.startedSkills[skill] = tonumber(mq.TLO.Me.Skill(skill)()) or 0
    end

    Movement.Stop()
    advance(steps.opening, openEvidenceMs)

    print("(Tradeskill) Combining in " .. TradeskillJobConfig.DescribeContainer(container))
end

function TradeskillJob.Reset()
    TradeskillJob._.running = false
    TradeskillJob._.step = nil
    TradeskillJob._.pending = nil
    TradeskillJob._.deadlineMs = nil
    TradeskillJob._.lastFireMs = 0
    TradeskillJob._.lastScanMs = 0
    TradeskillJob._.candidates = {}
    TradeskillJob._.combines = 0
    TradeskillJob._.succeeded = 0
    TradeskillJob._.failed = 0
    TradeskillJob._.trivialSeen = false
    TradeskillJob._.refusal = nil
    TradeskillJob._.refusalAtMs = nil
    TradeskillJob._.combineFiredAtMs = nil
    TradeskillJob._.handsSeenId = nil
    TradeskillJob._.lastProduct = nil
    TradeskillJob._.cursorEmptySinceMs = nil
    TradeskillJob._.observedLatencyMs = nil
    TradeskillJob._.observedRevealMs = nil
    TradeskillJob._.revealSamples = nil
    TradeskillJob._.bankFiredAtMs = nil
    TradeskillJob._.bankItemId = nil
    TradeskillJob._.combineOutcome = nil
    TradeskillJob._.sawOutput = false
    TradeskillJob._.stoppedReason = nil
    TradeskillJob._.stowUntilMs = nil
    TradeskillJob._.startedSkills = {}
    TradeskillJob._.detectedSkill = nil
end

---------------- Status --------------------

---@return string standing what this job is doing right now
---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.Describe()
    local run = TradeskillJob._

    if not run.running then
        if run.stoppedReason ~= nil then
            return "stopped: " .. run.stoppedReason
        end
        return "standing by"
    end

    local container = TradeskillJobConfig.GetContainer()
    local where = container ~= nil and TradeskillJobConfig.DescribeContainer(container) or "the container"

    if run.step == steps.opening then return "opening " .. where end
    if run.step == steps.checking then return "checking " .. where end
    if run.step == steps.picking and run.pending ~= nil then
        return "picking up " .. tostring(run.pending.name)
    end
    if run.step == steps.placing and run.pending ~= nil then
        return "putting " .. tostring(run.pending.name) .. " into " .. where
    end
    if run.step == steps.filling then return "filling " .. where end
    if run.step == steps.combining then return "combining in " .. where end
    if run.step == steps.collecting then
        return "putting away " .. tostring(run.lastProduct or "what it made")
    end

    return "combining in " .. where
end

---@return number combines made this run
function TradeskillJob.GetCombines() return TradeskillJob._.combines or 0 end

---@return number succeeded
function TradeskillJob.GetSucceeded() return TradeskillJob._.succeeded or 0 end

---@return number failed
function TradeskillJob.GetFailed() return TradeskillJob._.failed or 0 end

---@return string|nil product the last thing a combine handed back
function TradeskillJob.GetLastProduct() return TradeskillJob._.lastProduct end

---@return boolean trivialSeen whether the server has said the recipe is trivial this run
function TradeskillJob.IsTrivial() return TradeskillJob._.trivialSeen == true end

---@return string|nil skill which tradeskill this run is raising -- the one that was picked, or the
---one the world named. nil while a run on Auto has not been told yet
function TradeskillJob.GetWatchedSkill() return watchedSkill() end

---@return boolean detected whether that answer came from the world rather than from the page
function TradeskillJob.IsSkillDetected()
    return TradeskillJobConfig.GetSkill() == "" and TradeskillJob._.detectedSkill ~= nil
end

---@return number|nil startedSkill what the watched skill read when this run began
function TradeskillJob.GetStartedSkill()
    local skill = watchedSkill()
    if skill == nil then return nil end
    return (TradeskillJob._.startedSkills or {})[skill]
end

---@return string|nil reason why the last run ended
function TradeskillJob.GetStoppedReason() return TradeskillJob._.stoppedReason end

---@return string|nil refusal what the server last said about a combine it would not make
function TradeskillJob.GetRefusal() return TradeskillJob._.refusal end

---------------- Init --------------------

---@param id string
---@param pattern string
---@param summary string
---@param handler function
local function listen(id, pattern, summary, handler)
    local docs = ChelpDocs.new(function() return {
        "(" .. id .. ") " .. summary,
        " -- Heard while the tradeskill job is combining; ignored otherwise."
    } end )
    Commands.RegisterEvent(Event.new(id, pattern, handler, docs))
end

---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.Init()
    if TradeskillJob._.isInit then return end

    local ftkey = Global.tracing.open("TradeskillJob Setup")

    TradeskillJobConfig.Init()
    TradeskillJob.Reset()

    Menu.RegisterJob(TradeskillJob)

    ---What a combine handed back. Three sentences for the same event -- the recipe's own product,
    ---an alternate one, and an unexpected one -- and nothing here cares which.
    local function event_Made(_, product)
        local run = TradeskillJob._
        if not run.running then return end
        run.succeeded = run.succeeded + 1
        run.combineOutcome = "success"
        if product ~= nil then run.lastProduct = tostring(product) end
        DebugLog("Made " .. tostring(product))
    end
    listen(TradeskillJob.eventIds.somethingNew,
        "You have fashioned the items together to create something new: #1#.",
        "Counts a successful combine", event_Made)
    listen(TradeskillJob.eventIds.alternate,
        "You have fashioned the items together to create an alternate product: #1#.",
        "Counts a successful combine that made the alternate product", event_Made)
    listen(TradeskillJob.eventIds.unexpected,
        "You have fashioned the items together to create an unexpected product: #1#.",
        "Counts a successful combine that made an unexpected product", event_Made)

    listen(TradeskillJob.eventIds.failed,
        "You lacked the skills to fashion the items together.",
        "Counts a combine that consumed the materials and made nothing", function()
            local run = TradeskillJob._
            if not run.running then return end
            run.failed = run.failed + 1
            -- a failure hands back exactly the recipe's failure item, so nothing ever queues
            -- behind it and there is no window to wait out. See settleNeeded
            run.combineOutcome = "failure"
        end)

    -- The server says this on every combine that is over trivial, before it rolls. It is only ever
    -- a reason to stop if the player asked for one -- a run making things to sell does not care
    listen(TradeskillJob.eventIds.trivial,
        "You can no longer advance your skill from making this item.",
        "Notices the recipe going trivial, which can be a reason to stop", function()
            if not TradeskillJob._.running then return end
            TradeskillJob._.trivialSeen = true
        end)

    ---Why a combine was refused, for the stop that the container not emptying has already decided
    ---on. There are more of these sentences than are worth matching -- several are composed by the
    ---server rather than sent as a string id -- so these are the three a repeating run actually
    ---runs into, and an unmatched one simply leaves the generic reason standing.
    local function event_Refused(line)
        local run = TradeskillJob._
        if not run.running then return end
        run.refusal = StringUtils.TrimFront(tostring(line or "")):gsub("^%[.-%]%s*", "")
        run.refusalAtMs = Time.current_time()
    end
    listen(TradeskillJob.eventIds.noCombine,
        "You cannot combine these items in this container type!",
        "Explains a combine the server would not make", event_Refused)
    listen(TradeskillJob.eventIds.missing,
        "You are missing some required components.",
        "Explains a combine the server would not make", event_Refused)
    listen(TradeskillJob.eventIds.unskilled,
        "You are not skilled enough.",
        "Explains a combine the server would not make", event_Refused)

    ---The one refusal that is worth *recovering* from rather than explaining. It is the client's
    ---own, thrown before the packet ever leaves: the container is untouched and no combine
    ---happened, so the right answer is to put the hands down and press it again, not to end the
    ---run. The step already tests the cursor in the frame it fires, so this should never be heard
    ---— it is here because a run that finds a gap at three in the morning should come back from it
    ---rather than stop with an hour of materials left.
    ---
    ---Written out in full, exactly as the client's own string table has it (RoF2 `eqstr_us.txt`,
    ---12024) -- **including the two spaces after the `!`**, which is the sort of thing a hand-typed
    ---pattern silently gets wrong. Nothing is substituted into this line, so the literal is what is
    ---rendered, and a literal is the one pattern shape there is no doubt about.
    listen(TradeskillJob.eventIds.handsFull,
        "You cannot combine items when your hands are full!  Your cursor must be free of items " ..
        "and money before you can combine items together in a special container.",
        "Puts the cursor down and presses Combine again, rather than ending the run", function(line)
            local run = TradeskillJob._
            if not run.running or run.step ~= steps.combining then return end

            -- and only while the materials are demonstrably still sitting there. A combine that
            -- *did* go through empties the container, and un-firing one of those would have the
            -- step count the same combine twice off the emptiness it had already read
            local container = TradeskillJobConfig.GetContainer()
            if container == nil or occupied(container) < 1 then return end

            DebugLog("The combine was refused for full hands -- putting them down and retrying")
            -- un-fire it: nothing was sent, so the next pass starts the combine over, and its
            -- cursor test is what clears the hands first
            run.combineFiredAtMs = nil
            run.handsSeenId = nil
            extend(combineEvidenceMs)
            event_Refused(line)
        end)

    -- What a skill-up run is here for. The number the client prints is the same one the skill
    -- limit is read against, so this is only worth noticing for the page's running total
    -- What tells a run on Auto which skill it is raising, and the only thing that does. Filtered to
    -- the tradeskills on purpose: a run makes things, and a thing that is made can raise something
    -- else about the character -- adopting the first skill name that happens past would be spending
    -- a reading on a question it was not an answer to
    listen(TradeskillJob.eventIds.betterAt,
        "You have become better at #1#! (#2#)",
        "Notices which tradeskill this recipe raises, for a run left on Auto", function(_, skill)
            local run = TradeskillJob._
            if not run.running or skill == nil then return end

            skill = tostring(skill)
            if not TableUtils.ArrayContains(TradeskillJob.tradeskills, skill) then return end

            if run.detectedSkill ~= skill then
                DebugLog("This recipe raises " .. skill)
                run.detectedSkill = skill
            end
        end)

    ToggleCommand.Register({
        key = TradeskillJob.key,
        phrase = "tradeskill",
        summary = "Starts or stops making the combines set up on the Tradeskill job page",
        about = {
            "Fills the chosen container with the chosen materials, presses Combine, puts what it",
            "made away, and does it again. Nothing else this character does runs while it is going.",
            "It stops on whichever limit was set -- a skill level, a number of combines, a number",
            "of successful ones, the recipe going trivial -- and always when the materials run out",
            "or the container is closed."
        },
        get = TradeskillJob.IsEnabled,
        set = TradeskillJob.SetEnabled
    })

    local ctradeskillDocs = ChelpDocs.new(function() return {
        "(/ctradeskill) Report or drive the tradeskill job",
        " -- Usage: /ctradeskill",
        " -- Usage (start combining): /ctradeskill on",
        " -- Usage (stop): /ctradeskill off",
        " -- What to combine in, what to put in it and what stops it are set on the",
        "    Jobs > Tradeskill page of /cmenu.",
        " -- A run never survives a restart: the setup is remembered, the running is not."
    } end )
    local function Bind_CTradeskill(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            ctradeskillDocs:Print()
            return
        end

        if #args > 0 then
            local UserInput = require("cabby.utils.userinput")
            if UserInput.IsTrue(args[1]) then
                TradeskillJob.SetEnabled(true)
                return
            end
            if UserInput.IsFalse(args[1]) then
                TradeskillJob.SetEnabled(false)
                return
            end
            ctradeskillDocs:Print()
            return
        end

        print("Tradeskill: " .. TradeskillJob.Describe())
        print(" -- container: " .. TradeskillJobConfig.DescribeContainer(TradeskillJobConfig.GetContainer()))

        local materials = {}
        for _, material in ipairs(TradeskillJobConfig.GetItems()) do
            materials[#materials+1] = tostring(material.name) ..
                ((tonumber(material.count) or 1) > 1 and (" x" .. tostring(material.count)) or "")
        end
        print(" -- materials: " .. (#materials > 0 and StringUtils.Join(materials, ", ") or "none chosen"))

        print(" -- combines: " .. tostring(TradeskillJob.GetCombines()) ..
            " (" .. tostring(TradeskillJob.GetSucceeded()) .. " made, " ..
            tostring(TradeskillJob.GetFailed()) .. " lost)")

        if TradeskillJobConfig.GetStopAfterCombines() then
            print(" -- stopping after " .. tostring(TradeskillJobConfig.GetCombines()) .. " combines")
        end
        if TradeskillJobConfig.GetStopAfterSuccesses() then
            print(" -- stopping after " .. tostring(TradeskillJobConfig.GetSuccesses()) .. " successes")
        end

        if TradeskillJobConfig.GetStopAtSkill() then
            local skill = watchedSkill()
            if skill == nil then
                print(" -- skill limit: on Auto, waiting for a skill-up to say which skill")
            else
                print(" -- " .. skill .. ": " .. tostring(tonumber(mq.TLO.Me.Skill(skill)()) or 0) ..
                    " of " .. tostring(TradeskillJobConfig.GetSkillLevel()) ..
                    (TradeskillJob.IsSkillDetected() and " (detected)" or ""))
            end
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("ctradeskill", Bind_CTradeskill, ctradeskillDocs))

    TradeskillJob._.isInit = true
    Global.tracing.close(ftkey)
end

---@diagnostic disable-next-line: duplicate-set-field
function TradeskillJob.BuildMenu()
    TradeskillJobMenu.BuildMenu(TradeskillJob)
end

return TradeskillJob
