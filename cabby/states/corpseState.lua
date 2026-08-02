---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CorpseStateConfig = require("cabby.configs.corpseStateConfig")
local CorpseStateMenu = require("cabby.ui.states.corpseStateMenu")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")
local UserInput = require("cabby.utils.userinput")

---How far away a corpse of ours may be for the order to act on it.
---
---**The order loots what is already in reach and walks nobody anywhere.** Getting the group back
---to where it died is the player's job today (a corpse-walk state is the neighbour this one is
---waiting for), so 50 is "we are standing on the pile" with room for a group spread out around
---it. Anything further away is not a corpse this order is about, and saying so is better than
---quietly standing there: the answer comes back the moment the order is given.
---
---The corpse comes the rest of the way itself: every corpse this order acts on is pulled to our
---feet with `/corpse` before it is opened, and the server allows that out to 100 -- twice this --
---so the radius is what this order is *about*, not how far a pull can reach.
local corpseRadius = 50

---How long between commands of ours. Targeting, opening and looting are each answered by the
---server when it gets round to them, and firing again forty times a second in between is noise
---rather than speed.
local commandPaceMs = 400

---How long a `/click right target` has to produce a loot window before the world has said no.
---
---Too far to reach it, a corpse somebody else is already looting, or a corpse the name search
---matched but that is not ours: the client says every one of those in chat and none of them in a
---TLO, so a window that never opens is the only reading we get. An evidence window on an action we
---fired, not a give-up timer -- what it ends is this corpse, and only because the world answered.
local openAckMs = 3000

---The same, for one item: how long a loot has to clear the slot it was fired at. Bags full, a lore
---item already carried, a confirmation box nobody has answered -- the item simply stays put.
local lootAckMs = 3000

---The same, for the Done button.
local closeAckMs = 3000

---Slots the loot window draws (`LW_LootSlot0`..`LW_LootSlot33` in EQUI_LootWnd.xml). `Corpse.Items`
---counts what is on the corpse rather than how far up the slots go, and a corpse being emptied has
---holes in it, so the slots are walked instead of counted.
local lootSlots = 34

---Getting our own gear back off the ground, on the order that says to.
---
---This is the death-recovery half of looting: `lootcorpse` said to a group of characters standing
---on their own corpses, and every one of them empties its own. It holds nothing but the order --
---no habit, no watching for deaths, nothing that happens on its own -- because looting is the one
---job where acting unasked is how a script loots the wrong corpse.
---
---**The order is a job, and it ends when the job does.** Every corpse of ours in reach is emptied,
---one after another, and when there is no corpse left that this order has not finished with, the
---order is over. It is not a mode to be turned off later and not a standing intent to loot:
---`lootcorpse` again is how it happens again.
---
---**What it keeps is progress, not decisions** (see `cabby.states.baseState`): which corpse is
---being worked, that a click has gone out and is waiting on a window, which item was last asked
---for. None of that can be re-read from the world -- a loot window is either open or not, and it
---cannot say who opened it or what was asked of it a moment ago -- and every piece of it is
---confirmed or dropped on the next pass.
---
---**Every corpse is targeted, pulled over and then opened**, in that order and one command per
---pass: `/mqtarget id`, `/corpse` to bring it to our feet, `/click right target` to open what is
---now standing on top of us.
---
---**Three actions and three answers.** Opening a corpse, looting an item, closing the window: each
---is fired once and then watched for its evidence, because the client refuses in chat and the
---refusals are not readable anywhere else. A corpse that will not open is left; an item that will
---not come off is left; a window that will not close ends the order. That is what stops a job at
---this band from wedging the chain below it, and none of it is a clock deciding to stop trying --
---the world is answering, and the answer is no. The pull is the one command with no answer of its
---own, and it needs none: it is allowed further than this order ever looks.
---
---**A loot window on somebody else's corpse is somebody else's.** It is neither emptied nor
---closed, and ours waits behind it -- there is only ever one loot window, and taking it away from
---whoever is using it is exactly what the "don't fight the player" rule exists for. A window
---already open on a corpse *of ours* is the opposite case and is taken over: it is the very thing
---the order named, and who clicked it changes nothing about that.
---
---Where it sits (`Priorities.loot + 5`) does the rest: below the fighting bands, so nothing is
---looted mid-fight; below AdvLootState, whose one click clears a roll the whole group is waiting
---on; and above follow, anchor and rest, so a character that has been told to loot does that
---rather than trotting off after the group with its gear still on the floor.
---@class CorpseState : BaseState
local CorpseState = {
    key = "CorpseState",
    eventIds = {
        lootCorpse = "lootcorpse"
    },
    _ = {
        isInit = false,
        ---the standing order: who asked, on what line, in which zone. nil when nothing was asked
        order = nil,
        ---corpses this order is finished with -- emptied, or done refusing us
        done = {},
        ---the corpse being worked, and how far into it we are
        corpseId = nil,
        ---the corpse already pulled to our feet, so `/corpse` goes out once per corpse
        draggedId = nil,
        openFiredMs = nil,
        closeFiredMs = nil,
        ---the loot we last fired: which slot, and what was sitting in it when we fired
        pending = nil,
        ---slots on the corpse being worked that would not come off it
        refused = {},
        ---the loot window we are standing behind, so the waiting is said once and not per frame
        waitingOn = nil,
        lastCommandMs = 0,
        ---when `Go` last ran, for `/ccorpse` and nothing else: an order that stands while the
        ---chain never hands the frame down looks exactly like one being worked on, and this is the
        ---only way to tell them apart. Never read by a decision -- scheduler time does not belong
        ---in one (see baseState)
        lastPassMs = nil,
        ---what this order has come to so far, for the report it ends with
        lootedCount = 0,
        leftCount = 0,
        unopenedCount = 0,
        corpseCount = 0,
        standing = "standing by",
        outcome = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CorpseState.key, str)
end

---------------- Reading the world --------------------

---Whether a spawn's name is *this character's* rather than one ours is the front of.
---
---The spawn search matches a name in part, so `Cabby` finds `Cabbyx`'s corpse as well as ours.
---What follows the name settles it: a corpse is `<name>'s corpse`, and nothing else can start with
---our whole name and carry on with an apostrophe.
---@param name string spawn name, lowercased
---@param myName string our clean name, lowercased
---@return boolean isOurs
local function nameIsOurs(name, myName)
    if name:sub(1, #myName) ~= myName then return false end
    local rest = name:sub(#myName + 1)
    return rest == "" or rest:sub(1, 1) == "'"
end

---The spawn search for corpses in reach, optionally narrowed to a name.
---
---**`corpse` rather than `pccorpse`**, which looks like the obvious filter and is a trap here:
---MacroQuest tells a player corpse from an NPC one by whether the spawn carries a *deity*
---(`SpawnMatchesSearch` in MQ2Utilities.cpp), and there is no promise this emu server sends one on
---a corpse. A `pccorpse` search that comes back empty is indistinguishable from having no corpse,
---which is a silent nothing rather than a bug anybody can see. `cabby.travel` reads a follow
---target's death with the same plain `corpse <name>` search and has always worked. The name is
---what makes it ours anyway (`nameIsOurs`), and no NPC is named after this character.
---@param name string? clean name to narrow to, lowercased; nil for every corpse in reach
---@return string search
local function corpseSearch(name)
    return "corpse radius " .. tostring(corpseRadius) .. (name ~= nil and (" " .. name) or "")
end

---Our nearest corpse in reach that this order has not finished with.
---@return number|nil corpseId
---@return number|nil distance
local function nextCorpse()
    local myName = (mq.TLO.Me.CleanName() or ""):lower()
    if myName == "" then return nil, nil end

    local search = corpseSearch(myName)
    local count = tonumber(mq.TLO.SpawnCount(search)()) or 0

    for index = 1, count do
        local spawn = mq.TLO.NearestSpawn(index, search)
        local id = tonumber(spawn.ID())
        if id ~= nil and id > 0 and not CorpseState._.done[id]
            and nameIsOurs((spawn.CleanName() or ""):lower(), myName) then
            return id, tonumber(spawn.Distance())
        end
    end

    return nil, nil
end

---The corpse the client has open, if any -- and nothing about who opened it, which is why this
---state keeps that itself.
---
---**The window is asked first, and it is the one that decides.** `${Corpse}` is the client's
---active-corpse pointer (`pActiveCorpse` in MQ2CorpseType.cpp), and a pointer left over from a
---loot that has already ended reads exactly like one in progress -- which would park this state in
---"waiting on a window somebody else opened" for the rest of the session, silently, since waiting
---is the one thing it does without saying anything. `LootWnd` being shown is unambiguous.
---@return number|nil corpseId
local function openCorpseId()
    if mq.TLO.Window("LootWnd").Open() ~= true then return nil end
    if mq.TLO.Corpse.Open() ~= true then return nil end
    return tonumber(mq.TLO.Corpse.ID())
end

---Whether the corpse the client has open is one of ours. What makes a window open by hand ours to
---finish (see `Go`) rather than somebody's business to stay out of.
---@return boolean isOurs
local function openCorpseIsOurs()
    local myName = (mq.TLO.Me.CleanName() or ""):lower()
    if myName == "" then return false end
    return nameIsOurs((mq.TLO.Corpse.CleanName() or ""):lower(), myName)
end

---The first slot on the open corpse holding something we have not already been refused.
---@return number|nil slot
---@return number|nil itemId
---@return string|nil itemName
local function nextItem()
    for slot = 1, lootSlots do
        if not CorpseState._.refused[slot] then
            local item = mq.TLO.Corpse.Item(slot)
            local id = tonumber(item.ID())
            if id ~= nil and id > 0 then
                return slot, id, tostring(item.Name() or "an item")
            end
        end
    end
    return nil, nil, nil
end

---------------- The order --------------------

---Everything about the corpse being worked, dropped. The order itself stands: there may be another
---corpse lying here.
local function clearCorpse()
    CorpseState._.corpseId = nil
    CorpseState._.draggedId = nil
    CorpseState._.openFiredMs = nil
    CorpseState._.closeFiredMs = nil
    CorpseState._.pending = nil
    CorpseState._.refused = {}
    CorpseState._.waitingOn = nil
end

---How the order went, in one sentence.
---@return string report
---@return boolean isClean whether everything it set out to do was done
local function summary()
    local looted = CorpseState._.lootedCount
    local corpses = CorpseState._.corpseCount

    local report = "looted nothing"
    if looted > 0 or corpses > 0 then
        report = "looted " .. tostring(looted) .. " item" .. (looted == 1 and "" or "s") ..
            " off " .. tostring(corpses) .. " corpse" .. (corpses == 1 and "" or "s")
    end

    local isClean = true
    if CorpseState._.leftCount > 0 then
        isClean = false
        report = report .. ", left " .. tostring(CorpseState._.leftCount) ..
            " I could not pick up (bags full?)"
    end
    if CorpseState._.unopenedCount > 0 then
        isClean = false
        report = report .. ", " .. tostring(CorpseState._.unopenedCount) ..
            " I could not open (somebody else looting it?)"
    end

    return report, isClean
end

---End the order and say how it went: back to whoever asked when something was left undone, quietly
---in our own console when it all went as asked. A group of six answering a clean corpse run in the
---channel is six lines nobody needed.
---@param report string
---@param tellThem boolean
local function finish(report, tellThem)
    local order = CorpseState._.order

    DebugLog("Order finished: " .. report)
    if tellThem and order ~= nil and order.line ~= nil then
        Speak.Respond(order.line, order.askedBy, report)
    else
        print("(" .. CorpseState.eventIds.lootCorpse .. ") " .. report)
    end

    CorpseState.Reset()
    CorpseState._.outcome = report
end

---Take the order: loot every corpse of ours lying here, nearest first.
---
---Safe to call from a render callback -- it reads the world and writes this state's own
---bookkeeping, and the commands that make it happen are all issued from `Go()`.
---@param speaker string? who asked, for the answer; defaults to this character
---@param line string? the chat line it was asked on, so the answer goes back where it came from
---@return string? refusal why nothing was started, when nothing was
function CorpseState.StartLooting(speaker, line)
    if not CorpseState.IsEnabled() then
        return "My corpse state is turned off, so I will not loot my corpse"
    end

    local posture = tostring(mq.TLO.Me.State() or "")
    if posture == "HOVER" or posture == "DEAD" then
        return "I am still dead, so I cannot loot anything"
    end

    -- asking again starts over: the order is a job rather than a mode, and somebody saying it
    -- twice means "do it again", not "queue another one"
    CorpseState.Reset()

    -- Answered now rather than left to stand. "There is nothing of mine lying here" is the one
    -- answer waiting cannot change -- this order walks nobody anywhere -- and it is the answer
    -- whoever gave the order most needs to hear.
    if nextCorpse() == nil then
        return "I have no corpse of mine within " .. tostring(corpseRadius)
    end

    CorpseState._.order = {
        askedBy = speaker or (mq.TLO.Me.CleanName() or ""),
        line = line,
        zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    }
    CorpseState._.standing = "looting my corpse"
    CorpseState._.outcome = nil

    -- Said out loud, in our own console, because the alternative is indistinguishable from the
    -- order never arriving: this state's whole job happens over the next few seconds and reports
    -- only at the end, and a character that heard nothing and a character that is about to start
    -- look the same until then. One line per order, and `/ccorpse` has the rest.
    DebugLog("Loot corpse order taken from [" .. tostring(CorpseState._.order.askedBy) .. "]")
    print("(" .. CorpseState.eventIds.lootCorpse .. ") Looting my corpse, asked by " ..
        tostring(CorpseState._.order.askedBy))
    return nil
end

---Call the order off, leaving whatever is open open -- the window is a thing the player can see
---and close, and closing it is a command this must not run (it is what a menu button calls).
---@return boolean stopped false when nothing was standing
function CorpseState.CancelOrder()
    if CorpseState._.order == nil then return false end

    local report = summary()
    CorpseState.Reset()
    CorpseState._.outcome = "called off after it " .. report
    return true
end

---@return boolean isLooting whether an order is standing
function CorpseState.IsLooting()
    return CorpseState._.order ~= nil
end

---------------- One corpse --------------------

---Have done with the corpse being worked: whatever is still on it is staying there, so the window
---goes away and the order moves on to the next corpse lying here.
---@param now number
---@return boolean isBusy
local function closeCorpse(now)
    if now - CorpseState._.lastCommandMs < commandPaceMs then return true end

    local left = tonumber(mq.TLO.Corpse.Items()) or 0
    CorpseState._.leftCount = CorpseState._.leftCount + left
    CorpseState._.corpseCount = CorpseState._.corpseCount + 1
    CorpseState._.done[CorpseState._.corpseId] = true

    DebugLog("Finished with corpse [" .. tostring(CorpseState._.corpseId) .. "], " ..
        tostring(left) .. " left on it")
    CorpseState._.lastCommandMs = now
    CorpseState._.closeFiredMs = now
    CorpseState._.pending = nil
    CorpseState._.standing = "closing the loot window"
    mq.cmd("/notify LootWnd LW_DoneButton leftmouseup")
    return true
end

---One pass with our own corpse open in front of us.
---@param now number
---@return boolean isBusy
local function workWindow(now)
    -- the Done button has gone out and the window is still here
    if CorpseState._.closeFiredMs ~= nil then
        if now - CorpseState._.closeFiredMs < closeAckMs then
            CorpseState._.standing = "closing the loot window"
            return true
        end
        -- Nothing below this state can run while a window we cannot close sits in front of us, so
        -- the order ends rather than holding the chain for a client that is not listening.
        finish("I could not close the loot window", true)
        return false
    end

    -- the client hands nothing over while something is on the cursor, so it goes away first
    if mq.TLO.Cursor.ID() ~= nil then
        if now - CorpseState._.lastCommandMs < commandPaceMs then return true end
        CorpseState._.lastCommandMs = now
        CorpseState._.standing = "putting away what is on the cursor"
        DebugLog("Clearing the cursor before looting")
        mq.cmd("/autoinventory")
        return true
    end

    -- did the last thing we asked for come off the corpse?
    local pending = CorpseState._.pending
    if pending ~= nil then
        local inSlot = tonumber(mq.TLO.Corpse.Item(pending.slot).ID())
        if inSlot ~= pending.itemId then
            CorpseState._.lootedCount = CorpseState._.lootedCount + 1
            CorpseState._.pending = nil
        elseif now - pending.firedMs >= lootAckMs then
            -- the world's only way of saying no to one item
            DebugLog("[" .. pending.name .. "] would not come off the corpse")
            CorpseState._.refused[pending.slot] = true
            CorpseState._.pending = nil
        else
            CorpseState._.standing = "looting " .. pending.name
            return true
        end
    end

    local slot, itemId, itemName = nextItem()
    if slot == nil then
        return closeCorpse(now)
    end

    if now - CorpseState._.lastCommandMs < commandPaceMs then return true end
    CorpseState._.lastCommandMs = now
    CorpseState._.pending = { slot = slot, itemId = itemId, name = itemName, firedMs = now }
    CorpseState._.standing = "looting " .. itemName
    DebugLog("Looting [" .. itemName .. "] from slot " .. tostring(slot))
    mq.cmd("/itemnotify loot" .. tostring(slot) .. " rightmouseup")
    return true
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
function CorpseState.Describe()
    if CorpseState._.order ~= nil then return CorpseState._.standing end
    if CorpseState._.outcome ~= nil then return "last order: " .. CorpseState._.outcome end
    return "standing by"
end

---@return number lootedCount items this order has taken off the ground so far
function CorpseState.GetLootedCount()
    return CorpseState._.lootedCount
end

---@return string|nil askedBy who the standing order came from, nil when none is standing
function CorpseState.GetAskedBy()
    if CorpseState._.order == nil then return nil end
    return CorpseState._.order.askedBy
end

---@return number radius how near a corpse has to be for this state to act on it
function CorpseState.GetRadius()
    return corpseRadius
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function CorpseState.Init()
    if CorpseState._.isInit then return end

    CorpseStateConfig.Init()

    Menu.RegisterState(CorpseState)

    local lootCorpseDocs = ChelpDocs.new(function() return {
        "(" .. CorpseState.eventIds.lootCorpse .. ") Tells listener(s) to loot their own corpse",
        " -- Usage: " .. CorpseState.eventIds.lootCorpse .. ", or " ..
            CorpseState.eventIds.lootCorpse .. " off to call it off",
        " -- Only corpses of ours within " .. tostring(corpseRadius) .. " are looted: this walks",
        "    nobody anywhere, so get the group back to the corpses first",
        " -- Each one is targeted, pulled to our feet with /corpse, and then opened",
        " -- Every corpse of ours in reach is emptied, one after another, and then it is done",
        " -- A loot window open on somebody else's corpse is left alone, and ours waits behind it",
        " -- Anything that will not come off the corpse (bags full, a lore item) is left there",
        "    and reported"
    } end )
    local function event_LootCorpse(line, speaker, args)
        if not Commands.GetCommandOwners(CorpseState.eventIds.lootCorpse):HasPermission(speaker) then
            DebugLog("Ignoring " .. CorpseState.eventIds.lootCorpse .. " of speaker [" .. speaker .. "]")
            return
        end

        local words = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #words > 0 and UserInput.IsFalse(words[1]) then
            if CorpseState.CancelOrder() then
                print("(" .. CorpseState.eventIds.lootCorpse .. ") Called off")
            end
            return
        end

        -- answered back where it was asked: our own console for a button press or /cself, the
        -- channel it was spoken on for an order given to a group of us
        local refusal = CorpseState.StartLooting(speaker, line)
        if refusal ~= nil then
            Speak.Respond(line, speaker, refusal)
        end
    end
    Commands.RegisterCommEvent(Command.new(CorpseState.eventIds.lootCorpse, event_LootCorpse, lootCorpseDocs)
        :WithArgs({
            required = false,
            hint = "off to call it off",
            choices = function() return {
                { label = "Loot my corpse", args = "" },
                { label = "Call it off", args = "off" }
            } end
        }))

    local ccorpseDocs = ChelpDocs.new(function() return {
        "(/ccorpse) Report what this character is doing about its corpse, and what it can see",
        " -- Usage: /ccorpse",
        " -- To loot it here: /" .. Commands.selfCommand .. " " .. CorpseState.eventIds.lootCorpse,
        " -- To tell a group of characters to: /bc " .. CorpseState.eventIds.lootCorpse,
        " -- It lists every corpse within " .. tostring(corpseRadius) .. " and which of them it",
        "    reads as this character's, which is the first thing to check when nothing happens"
    } end )
    local function Bind_CCorpse(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            ccorpseDocs:Print()
            return
        end

        print("Corpse: " .. CorpseState.Describe() .. (CorpseState.IsEnabled() and "" or " (disabled)"))

        local askedBy = CorpseState.GetAskedBy()
        if askedBy ~= nil then
            print(" -- asked for by: " .. askedBy)
            -- Whether this state is getting frames at all. Nothing decides anything by it -- it is
            -- read nowhere but here -- and it is the one question the rest of this report cannot
            -- answer: an order that stands while the chain above never hands the frame down looks
            -- exactly like an order that is being worked on.
            if CorpseState._.lastPassMs == nil then
                print(" -- WARNING: it has not had a single pass -- something above it is holding" ..
                    " the chain (/state, and the flee switch first of all)")
            else
                local ago = Time.current_time() - CorpseState._.lastPassMs
                print(" -- last pass: " .. tostring(ago) .. "ms ago" ..
                    (ago > 2000 and " -- something above it is holding the chain" or ""))
            end
        end

        if mq.TLO.Corpse.Open() == true then
            print(" -- a loot window is open on [" .. tostring(mq.TLO.Corpse.CleanName()) .. "] (" ..
                tostring(mq.TLO.Corpse.ID()) .. "), " .. tostring(mq.TLO.Corpse.Items()) .. " item(s), " ..
                (openCorpseIsOurs() and "mine" or "not mine"))
        end

        -- A fresh look, and the *whole* look: every corpse in reach whoever it belongs to, with
        -- what this state makes of each. "It says there is nothing here" and "it can see it but
        -- does not think it is mine" are different problems, and the name is the difference.
        local myName = (mq.TLO.Me.CleanName() or ""):lower()
        local search = corpseSearch(nil)
        local count = tonumber(mq.TLO.SpawnCount(search)()) or 0
        print(" -- corpses within " .. tostring(corpseRadius) .. ": " .. tostring(count))

        for index = 1, math.min(count, 10) do
            local spawn = mq.TLO.NearestSpawn(index, search)
            local id = tonumber(spawn.ID()) or 0
            local name = tostring(spawn.CleanName() or "?")
            local notes = nameIsOurs(name:lower(), myName) and "mine" or "not mine"
            if CorpseState._.done[id] then
                notes = notes .. ", already finished with"
            end
            print("    [" .. name .. "] (" .. tostring(id) .. ") " ..
                tostring(math.floor(tonumber(spawn.Distance()) or 0)) .. " away -- " .. notes)
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("ccorpse", Bind_CCorpse, ccorpseDocs))

    CorpseState.Reset()
    CorpseState._.isInit = true
end

function CorpseState.Reset()
    CorpseState._.order = nil
    CorpseState._.done = {}
    CorpseState._.lastCommandMs = 0
    -- cleared with the order it belongs to, so the next one's report answers "has this had a
    -- frame yet" about itself rather than about the last one
    CorpseState._.lastPassMs = nil
    CorpseState._.lootedCount = 0
    CorpseState._.leftCount = 0
    CorpseState._.unopenedCount = 0
    CorpseState._.corpseCount = 0
    CorpseState._.standing = "standing by"
    CorpseState._.outcome = nil
    clearCorpse()
end

---One pass: carry the order one step further, or find out it is over.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function CorpseState.Go()
    local order = CorpseState._.order
    if order == nil then return false end

    local now = Time.current_time()
    CorpseState._.lastPassMs = now

    -- Spawn ids mean nothing across a zone line, and neither does an order about what is lying on
    -- the other side of one.
    if (tonumber(mq.TLO.Zone.ID()) or 0) ~= order.zoneId then
        finish("I zoned before I was done -- " .. summary(), true)
        return false
    end

    local posture = tostring(mq.TLO.Me.State() or "")
    if posture == "HOVER" or posture == "DEAD" then
        finish("I died before I was done -- " .. summary(), true)
        return false
    end

    local openId = openCorpseId()
    if openId ~= nil then
        if openId ~= CorpseState._.corpseId then
            -- A window this state did not open. If what is in it is a corpse of ours that this
            -- order has not already finished with, it is the very thing we were told to empty and
            -- who opened it changes nothing -- take it over. Anything else is somebody's business
            -- to stay out of: not ours to empty, not ours to close, and there is only ever one
            -- loot window, so ours waits behind it. The frame goes to whatever is under us while
            -- it does; waiting is not work.
            if CorpseState._.done[openId] or not openCorpseIsOurs() then
                CorpseState._.standing = "waiting: a corpse I did not open is being looted"
                -- Said once, when it starts. This is the only place an order can sit indefinitely
                -- without doing anything, so it is the one place where saying nothing would look
                -- exactly like being broken -- and the answer ("close that window") is the
                -- player's to give.
                if CorpseState._.waitingOn ~= openId then
                    CorpseState._.waitingOn = openId
                    print("(" .. CorpseState.eventIds.lootCorpse .. ") Waiting: a loot window is open on [" ..
                        tostring(mq.TLO.Corpse.CleanName()) .. "], which is not mine to empty or to close")
                end
                return false
            end
            CorpseState._.waitingOn = nil

            DebugLog("Taking over the open corpse [" .. tostring(openId) .. "]")
            clearCorpse()
            CorpseState._.corpseId = openId
        end
        return workWindow(now)
    end

    -- the window went away: either the Done button took, or a corpse we emptied has poofed
    if CorpseState._.closeFiredMs ~= nil then
        clearCorpse()
    end

    -- a click has gone out and no window has come of it yet
    if CorpseState._.openFiredMs ~= nil then
        if now - CorpseState._.openFiredMs < openAckMs then
            CorpseState._.standing = "opening my corpse"
            return true
        end

        DebugLog("No loot window came of opening corpse [" .. tostring(CorpseState._.corpseId) .. "]")
        CorpseState._.done[CorpseState._.corpseId] = true
        CorpseState._.unopenedCount = CorpseState._.unopenedCount + 1
        clearCorpse()
    end

    local corpseId, distance = nextCorpse()
    if corpseId == nil then
        local report, isClean = summary()
        finish(report, not isClean)
        return false
    end

    -- the commands are paced; the decision is not. We have decided to loot, so the frame ends here
    -- either way rather than letting something weaker start in the gaps
    if now - CorpseState._.lastCommandMs < commandPaceMs then return true end

    if (tonumber(mq.TLO.Target.ID()) or 0) ~= corpseId then
        CorpseState._.lastCommandMs = now
        CorpseState._.standing = "targeting my corpse"
        DebugLog("Targeting corpse [" .. tostring(corpseId) .. "] at " ..
            tostring(math.floor(distance or 0)) .. " away")
        mq.cmd("/mqtarget id " .. tostring(corpseId))
        return true
    end

    -- Pulled over before it is opened. `/corpse` acts on the target and moves the corpse to exactly
    -- where we are standing (`OPGMSummon` -> `Corpse::Summon` -> `GMMove`, server side), which is
    -- what makes the click that follows a click on something in arm's reach: finding a corpse
    -- reaches `corpseRadius`, and looting one reaches a great deal less.
    --
    -- Fired once per corpse, and not watched for evidence, because there is nothing here that can
    -- answer no: the server allows the pull out to 100, which is further than this state looks in
    -- the first place, so every corpse of ours it can see is one the pull is allowed on. The corpse
    -- keeps its spawn id across the move (the entity is moved, not remade), which is what lets one
    -- id say the pull has already gone out for this corpse. And if it somehow does not move, the
    -- open below is still fired and still watched, and the corpse ends the way it always did.
    if CorpseState._.draggedId ~= corpseId then
        CorpseState._.draggedId = corpseId
        CorpseState._.lastCommandMs = now
        CorpseState._.standing = "pulling my corpse over"
        DebugLog("Pulling corpse [" .. tostring(corpseId) .. "] over from " ..
            tostring(math.floor(distance or 0)) .. " away")
        mq.cmd("/corpse")
        return true
    end

    CorpseState._.corpseId = corpseId
    CorpseState._.openFiredMs = now
    CorpseState._.lastCommandMs = now
    CorpseState._.standing = "opening my corpse"
    DebugLog("Opening corpse [" .. tostring(corpseId) .. "]")
    mq.cmd("/click right target")
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
CorpseState.IsEnabled = function()
    return CorpseStateConfig.IsEnabled()
end

---Switching it off drops the order with it. Nothing is left in flight to call off -- the loot
---window, if one is open, is a thing the player can see and close, and closing it here would be a
---game command run from wherever the switch was flipped (the menu checkbox is one of those).
---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
CorpseState.SetEnabled = function(isEnabled)
    CorpseStateConfig.SetEnabled(isEnabled)

    if not isEnabled then
        CorpseState.Reset()
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CorpseState.BuildMenu()
    CorpseStateMenu.BuildMenu(CorpseState)
end

return CorpseState
