---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Giving = require("utils.Giving.Giving")
local Swapping = require("utils.Swapping.Swapping")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Items = require("cabby.actions.items")
local Menu = require("cabby.ui.menu")
local Pet = require("cabby.pet")
local PetSetupStateConfig = require("cabby.configs.petSetupStateConfig")
local PetSetupStateMenu = require("cabby.ui.states.petSetupStateMenu")
local SlashCmd = require("cabby.commands.slashcmd")
local Spells = require("cabby.actions.spells")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How long to leave it before looking again, once a pass has found nothing to do. Everything
---this state watches -- is there a pet, has it been handed what it is owed -- changes at the
---speed of a summon, and it sits below every job that matters. Cleared the moment anything *is*
---started, so a pet being kitted out from nothing is kitted out at the speed of the casts.
local idleLookIntervalMs = 1000

---How long before a slot is tried again after a cast or a hand-off that did not take. Refusals
---cost nothing, so this is only here to stop the same hopeless attempt being made every pass.
local retryAfterFailureMs = 5000

---How long a pet that walked through a zone line with us is presumed to still be arriving.
---
---**The only wait a missing pet gets, and it is not a courtesy -- it is a reading that cannot be
---taken yet.** We are put back into the world a beat before the pet is, so for a stretch after the
---loading screen lifts "there is no pet" means *not yet* rather than *no*, and the first pass to
---believe it summons a second pet over the one still walking through. Armed at the line, and only
---when there was a pet to walk through it; ended the moment the pet turns up, which is the evidence
---this is waiting on rather than a duration anybody chose.
---
---A pet that vanishes **without** a zone line is not waited on at all. It died or it was let go,
---and either way the standing order to keep a pet up is the more explicit statement of the two --
---anybody who means to play without one has the switch, and turning that off is a decision that
---sticks, where a grace only delays this state fighting the same player a few seconds later.
local zonedPetSettleMs = 5000

---How long a pet we did not summon is left unjudged after it turns up.
---
---An evidence window, and the one thing standing between this state and re-arming a pet that is
---already armed: the client puts a spawn into the world before it dresses it, so a pet asked what
---it is holding on the frame it appears answers "nothing at all" whatever it is carrying -- and
---"nothing at all" is the answer that says kit it out. A beat later the answer is the true one.
---Nothing is withheld from a pet we summoned ourselves, which arrived with empty hands and needs
---no reading to say so.
local handsSettleMs = 2000

---How long an order to summon waits for a gem before it stops being an order. A pet asked for
---half a minute ago and summoned now is a surprise rather than an answer; the standing switch is
---what covers "whenever you can".
local summonOrderTtlMs = 15000

---How long an order to gear the pet waits with nothing happening before it is treated as
---finished. Gearing a pet is not one cast, it is "give it everything on the list", so it ends
---when a run of casts and hand-offs goes quiet rather than on the first pass that finds nothing
---to start -- which is also what a recovering gem looks like.
local gearOrderIdleMs = 15000

---How long the pet focus stays on with no summon of ours in the air.
---
---**An evidence window, and the only clock the focus swap has.** The gear goes on so that one
---cast can be made, and the pass that makes it is the very next one this state is given -- so a
---stretch with the focus on and no summon of ours anywhere is the world saying that cast is not
---going to happen: refused every time it was tried, or this state starved out of the chain by
---something that started in the beat between the swap and the summon. Either way the swap has
---bought nothing, and the player is standing there with their own gear in a bag, which is the one
---outcome worth a clock.
---
---Re-armed by every pass that still means to cast, so it only ever runs while nothing at all is
---happening; and the worst it can do when it is wrong is take the focus off and put it back on.
---Nothing about the *restore* is timed: that is the swapping service's standing obligation and it
---is discharged whether this state ever runs again or not.
local focusCastWindowMs = 8000

---Keeping the pet: summoning it, conjuring what it should be holding, and handing that over.
---
---One job in three steps, and the order between them is the whole of the logic: there is no
---point conjuring a weapon for a pet that is not here, and no point handing one to a pet that is
---about to be replaced. So every pass asks, in order, *is there a pet* and then *has this pet
---been given what the list says it should have*, and starts at most one thing.
---
---**What a slot is for is read off the spell.** A pet slot summons a pet because the spell
---carries the effect that summons one; a gear slot conjures an item because the spell carries the
---effect that makes one, and that effect names the item's own id -- so nothing here has to be
---told which item a spell makes, or trusted to have been told correctly. The one thing no spell
---can answer, and so the one dial a gear slot carries, is how many of that item this pet should
---end up with: one for a hand, two for a pet that dual wields.
---
---**What has been handed over is remembered, because nothing else can say.** A pet's inventory
---is not readable -- the client will say what it is *wielding* and nothing more -- so a record of
---what we handed to *this* pet is the only answer there is. That record is progress through a
---procedure the world cannot describe, which is the one kind of held state this design allows,
---and it is kept honest the only way such a record can be: it belongs to one pet, by spawn id,
---and a pet that is replaced takes it with it. The new one is kitted out from nothing.
---
---**A zone line renumbers the pet, it does not replace it.** Spawn ids are a zone's own numbering
---and crossing a line re-deals every one of them, so the pet that walks through with us comes out
---the far side wearing a number it did not have -- which is the only thing about it that changed.
---Read as a new pet it is a fully armed pet re-armed from nothing on every zone, so the record is
---carried across the line and re-attached by the one thing a line does not touch, which is the
---pet's own name. See `noticeZoneLine` and `refreshPet`.
---
---**A pet we did not summon is left as we found it.** Coming up beside a pet that is already
---standing there there is no record and no way to build one, so the question is which way to be
---wrong -- and the answer depends on which kind of "already standing there" it is.
---
---The pet that was here **when the script started** is left alone, full stop: it may have been
---fighting all evening with everything it is owed, the client cannot say (`Equipment` is a weapon
---model, and silent about anything a pet does not wield), and re-arming one on every reload is
---mana and items spent on nothing. A pet that turns up unsummoned **while we are watching** is one
---the player just cast by hand, so it is plainly new and the hands are worth reading: holding
---something, it is left alone, since a second weapon into a full pair of hands is mana for no
---visible end; holding nothing at all, it is kitted out. `gearpet` is the order that overrules
---either way of being wrong, and the page has the same button.
---
---**What the pet is made of includes what we were wearing.** A magician's pet focus -- the
---"Minion of Air" and "Enhanced Minion" lines -- is not on the summon, it is on a piece of gear,
---and the client reads it off the character at the moment the pet is made. So an item carrying one
---is worth *putting on for one cast and taking off again*, which is what the focus list is: the
---gear goes on before the summon is started, the summon is cast, and the gear comes off. A pet
---made a rank stronger is a pet that lasts the whole camp; a focus put on afterwards did nothing
---at all, which is why the order here is not negotiable.
---
---**Taking it off again is not this state's promise to keep.** This state sits at `buff - 1` and
---is starved by nearly everything: a fight, a follow, a heal. A restore this state owned would put
---somebody's own gear in a bag and leave it there the first time one of those took the frame away.
---So `utils/Swapping` owns both halves -- what went on, what it displaced, and the putting back --
---and discharges the second on its own pulse, which runs whether or not this state ever gets
---another frame. All this state hands over is the *reason*: `KeepFocusWorn`, a question the
---service asks every pulse, answered from the summon in the air rather than from a clock.
---
---**Handing an item over is not this state's own work.** It is four commands and three waits on
---the client, and a state that walked them itself would leave a give window standing open with an
---item in it the first time a fight took the frame away mid-sequence. `utils/Giving` owns the
---sequence and runs it on the service pulse; this state asks for one hand-off and polls it.
---
---**A charmed pet is not a pet this state keeps.** It is a mob held by a spell rather than one this
---character made, and everything here is about making one: there is nothing to summon while it is
---standing there (the client allows one pet, and a charm is that pet), and what it is handed leaves
---with it the moment the charm breaks -- a conjured weapon walking off on a mob that has just gone
---back to being a mob. So the gear list is not walked for one and `gearpet` says so rather than
---going quiet. `cabby.pet` is what answers "is this one charmed"; keeping and *using* a charmed pet
---is the pet dps state's half.
---
---**Somebody else's pet is the same work with a different hand held out.** `petgear` asks whoever
---is carrying a gear list to walk it once for the asker's pet -- the magician's trade, since every
---other class's pet arrives bare and only a magician has the spell that fixes it. The record kept
---for it is the same shape our own pet's is and for the same reason, it belongs to one spawn id,
---and it is a *request* rather than a switch: it ends when there is nothing left to hand over and
---the pet is forgotten again, because arming somebody's warder is a favour asked for once and not
---a standing arrangement with every pet in the group.
---
---What it deliberately leaves out: telling the pet what to do -- sending it in, calling it off and
---how it is set up to fight -- which is the other half of a pet and belongs in the fight, where
---`PetDpsState` does it at the dps band. This is the half that happens between fights, which is
---why the two are two states rather than one: a summon is a long cast and a hand-off needs the pet
---standing next to us, and neither is a thing to be doing while something is being killed. Also
---left out: summoning anything for anybody who is not the pet.
---@class PetSetupState : BaseState
local PetSetupState = {
    key = "PetSetupState",
    eventIds = {
        -- verbs first, so no phrase here is a prefix of another one: `petsummoning` would swallow
        -- a `petsummon`, which is why the orders read the other way round
        summon = "summonpet",
        gear = "gearpet",
        keeping = "petkeeping",
        summoning = "petsummoning",
        gearing = "petgearing",
        combat = "petsetupcombat",
        focus = "petfocus",
        action = "petaction",
        -- the one exception to that rule, and it is deliberate: `petgear` sits inside
        -- `petgearing`, so it hears every line the switch does. It is the word the group would
        -- actually say to a magician, so the collision is handled at the handler instead -- see
        -- `event_PetGear`, which drops any line with a word carrying on where its phrase ended
        request = "petgear"
    },
    _ = {
        isInit = false,
        ---the cast we started, and what it was for
        castId = nil,
        castSlot = nil,
        castJob = nil,      -- "summon" or "gear"
        castItemId = nil,   -- for a gear cast, the item it should conjure
        castName = nil,
        ---whose gear list the cast in the air is for: our own pet's record, or a request's
        castRecord = nil,
        ---the swap that puts the pet focus on, while it is being made
        focusSwapId = nil,
        ---while this stands, the focus is still wanted: the summon it went on for has either not
        ---been started yet or is in the air. What `KeepFocusWorn` answers out of
        focusWaitingUntilMs = nil,
        ---why the focus could not be put on, when it could not. The row that failed says it, since
        ---a page where everything looks picked and the pet comes out weak is otherwise silent
        focusProblem = nil,
        ---when a swap that would not go through is worth trying again. Pacing and nothing more:
        ---the summon is cast either way, and this only stops a full bag being answered by a swap
        ---attempt on every single pass
        focusRetryAtMs = nil,
        ---the hand-off we asked the giving service for
        giveId = nil,
        giveSlot = nil,
        giveItemName = nil,
        givePetId = nil,
        giveRecord = nil,
        ---somebody else's pet we were asked to kit out (`petgear`), in the same shape our own
        ---pet's record has plus who asked and when the ask stops standing
        request = nil,
        ---the pet we are looking after: { id, name, zoneId, gearing, judged, given, summoned }
        pet = nil,
        ---that same record while the pet itself is out of sight, which across a zone line is for
        ---the whole of a loading screen: what it says about the gear the pet is already carrying
        ---is true again the moment the pet is back. See `refreshPet`
        lastPet = nil,
        ---the zone the last pass was in, for noticing a line being crossed
        zoneId = nil,
        ---the pet that was already standing here when the script started, which is never geared
        ---on a guess: see `refreshPet`
        startupPetId = nil,
        ---a summon of ours landed, so the next pet to appear is one we made
        ourPetComing = false,
        ---while this stands, a pet we cannot see is one still arriving rather than one to replace
        petExpectedUntilMs = nil,
        ---orders, both held as the time they stop standing: `summonpet` lapses if nothing was
        ---ready to cast, `gearpet` ends once the casts and hand-offs go quiet
        summonOrder = nil,
        gearOrder = nil,
        ---{ [slot key] = when that slot is worth trying again }
        tryAgainAt = {},
        ---{ [slot key] = why the last attempt on that slot did not take }. The world's own answer,
        ---kept so the row that failed can say it -- a summon refused for a missing reagent is
        ---otherwise a page where everything looks configured and nothing happens
        slotProblem = {},
        ---item names we have resolved, so status output can name what a slot conjures even
        ---while we are not carrying one
        itemNames = {},
        nextLookMs = 0,
        lastResult = nil,
        holdReason = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(PetSetupState.key, str)
end

---------------- Slots --------------------

---@param slot Action
---@return string key naming this slot for the records and the retry windows
local function slotKey(slot)
    return tostring(slot.actionType) .. ":" .. tostring(slot.name)
end

---@param slot Action
---@return boolean isDue whether this slot is worth trying again yet
local function dueNow(slot)
    local at = PetSetupState._.tryAgainAt[slotKey(slot)]
    return at == nil or Time.current_time() >= at
end

---@param slot Action|nil
---@param delayMs number
local function holdOff(slot, delayMs)
    if slot == nil then return end
    PetSetupState._.tryAgainAt[slotKey(slot)] = Time.current_time() + delayMs
end

---Remember why a slot's last attempt did not take, so the row can say it. Cleared by an attempt
---that works, since by then it is a story about a spell we no longer have a problem with.
---@param slot Action|nil
---@param problem string|nil
local function recordProblem(slot, problem)
    if slot == nil then return end
    PetSetupState._.slotProblem[slotKey(slot)] = problem
end

---Drop retry windows that have run out. They are the only thing this state accumulates.
local function prune()
    local now = Time.current_time()
    for key, at in pairs(PetSetupState._.tryAgainAt) do
        if now >= at then
            PetSetupState._.tryAgainAt[key] = nil
        end
    end
end

---@param slot Action
---@return CastAction|nil action
---@return any|nil spell mq spell TLO for whatever the slot holds
local function readSlot(slot)
    local action = Action.GetActionType(slot)
    -- casts only: this state polls what it started, which a skill or a discipline has no
    -- equivalent of. Only casts are offered on the page; this is for a config edited by hand
    if action == nil or action.Subject == nil then return nil, nil end
    return action, action:Subject():Spelldata()
end

---@param itemId number
---@return string name what the item is called, remembered once seen
local function itemName(itemId)
    local known = PetSetupState._.itemNames[itemId]
    if known ~= nil then return known end

    local name = mq.TLO.FindItem(itemId).Name()
    if name == nil then return "item " .. tostring(itemId) end

    PetSetupState._.itemNames[itemId] = name
    return name
end

---@param itemId number
---@return boolean carried whether we have one to hand over
local function carrying(itemId)
    return (tonumber(mq.TLO.FindItemCount(itemId)()) or 0) > 0
end

---------------- The pet --------------------

---Is the pet holding anything at all?
---
---The one thing the client will say about a pet's gear: what it is wielding, as the weapon models
---in its equipment slots. It cannot name the item and it says nothing about anything a pet was
---handed that it does not wield -- so this answers exactly one question, and it is only ever
---asked about a pet we did not summon.
---@return boolean empty
local function handsAreEmpty()
    local pet = mq.TLO.Me.Pet
    return (tonumber(pet.Equipment("primary")()) or 0) == 0
        and (tonumber(pet.Equipment("offhand")()) or 0) == 0
end

---Notice a zone line, and say what crossing one means for the pet.
---
---Two things follow from a line, and both of them are things this state would otherwise get wrong.
---
---The pet is **renumbered rather than replaced**, so its record is carried across and re-attached
---on the far side rather than dropped with the id it was keyed by -- `refreshPet` does the
---attaching, by name.
---
---And the pet is **behind us**: it is put back into the world a beat after we are, so the stretch
---where the client says there is no pet begins on arrival rather than back at the door. That is what
---`zonedPetSettleMs` is armed for here, and why it is armed at the line rather than at the door: a
---window that started back at the loading screen has already run out by the time the screen lifts,
---and the first pass in the new zone summons a second pet over the one still walking through.
---@return number|nil zoneId the zone we are in, nil while the client will not say
local function noticeZoneLine()
    local zoneId = tonumber(mq.TLO.Zone.ID())
    if zoneId == nil or zoneId < 1 then return PetSetupState._.zoneId end
    if zoneId == PetSetupState._.zoneId then return zoneId end

    -- the first zone we ever see is not one we crossed into
    if PetSetupState._.zoneId ~= nil then
        DebugLog("A zone line was crossed into zone " .. tostring(zoneId))
        -- only if there was a pet to come through with us: an arrival with no pet behind it has
        -- nothing to wait for, and waiting anyway is this state pretending to know something
        if PetSetupState._.pet ~= nil or PetSetupState._.lastPet ~= nil then
            PetSetupState._.petExpectedUntilMs = Time.current_time() + zonedPetSettleMs
        end
        -- whatever a summon of ours was going to produce, it produced it on the other side of the
        -- line: the pet standing here now is one that walked through, not one we just cast. Left
        -- set, it is what tells the pet below that it is brand new and owed everything
        PetSetupState._.ourPetComing = false
    end
    PetSetupState._.zoneId = zoneId

    return zoneId
end

---What a pet we did not summon is owed, asked once the client has had its beat to answer.
---
---Until then the pet is left alone, which is the answer that costs nothing when it is wrong: a
---pet wrongly left is one `gearpet` fixes, and a pet wrongly kitted out is a bar of mana and a
---string of trade windows spent on a pet that was already carrying everything.
---@param pet table
local function judgeAdopted(pet)
    if pet.judged then return end
    if Time.current_time() - pet.seenAtMs < handsSettleMs then return end

    pet.judged = true
    pet.gearing = not pet.wasHereAtStartup and handsAreEmpty()

    DebugLog("[" .. pet.name .. "] " .. (pet.gearing and "is holding nothing -- kitting it out" or
        (pet.wasHereAtStartup and "was already here when the script started, leaving it as it is"
            or "is already holding something, leaving it as it is")))
end

---Who the pet is, re-derived every pass.
---
---A pet is its spawn id, and a new id is a new pet however alike the two look -- so the record of
---what has been handed over lives and dies with that id, and nothing else needs clearing. The one
---exception is the one the world forces: a zone line re-deals every id in it, and the pet that
---walks through with us is the same pet on the far side. So an id that changes **across a line**
---is matched back to its record by name, and only across a line -- a pet replaced without one is a
---new pet whatever it happens to be called.
---@return table|nil pet
local function refreshPet()
    local zoneId = noticeZoneLine()
    local id = tonumber(mq.TLO.Me.Pet.ID())

    if id == nil or id < 1 then
        if PetSetupState._.pet ~= nil then
            DebugLog("The pet is out of sight")
            -- set aside rather than thrown away: a pet crossing a zone line is out of sight for
            -- the whole of a loading screen, and this record is the only thing that knows it is
            -- already carrying its gear
            PetSetupState._.lastPet = PetSetupState._.pet
            PetSetupState._.pet = nil
            -- The interval below was set on a pass that found nothing to do, and something has
            -- just happened: looking again "in a second" is the answer to a question that has been
            -- overtaken. Every order in this state clears it for the same reason, and without this
            -- the state sleeps through most of a second before it even asks whether to summon.
            PetSetupState._.nextLookMs = 0
        end
        return nil
    end

    -- it is here, so it is not still coming
    PetSetupState._.petExpectedUntilMs = nil

    local pet = PetSetupState._.pet
    if pet ~= nil and pet.id == id then
        pet.zoneId = zoneId
        judgeAdopted(pet)
        return pet
    end

    local ours = PetSetupState._.ourPetComing
    PetSetupState._.ourPetComing = false

    local name = mq.TLO.Me.Pet.CleanName() or "my pet"

    -- The pet that came through the line with us, wearing its new number. A name is what a zone
    -- line leaves alone, and the zone the record was last seen in is what makes it a *line* being
    -- crossed rather than a pet being replaced -- without that check, a pet resummoned in one zone
    -- would inherit a dead pet's record on the strength of a shared name.
    --
    -- The record may still be in hand (the chain never gave us a pass while the pet was away) or
    -- set aside above; either is the same record.
    local previous = pet or PetSetupState._.lastPet
    PetSetupState._.lastPet = nil

    if not ours and previous ~= nil and previous.name == name and previous.zoneId ~= zoneId then
        previous.id = id
        previous.zoneId = zoneId
        -- a pet still being looked over when the line came is looked over again on this side of it
        if not previous.judged then previous.seenAtMs = Time.current_time() end
        PetSetupState._.pet = previous

        DebugLog("[" .. name .. "] came through the zone line (" .. tostring(id) ..
            ") -- it keeps everything it has been given")
        return previous
    end

    -- the pet that was standing here when the script started is left exactly as we found it, and
    -- the empty-hands guess is not even asked. A reload is not a reason to re-arm a pet that has
    -- been fighting all evening: what it was handed is remembered nowhere the client can be asked
    -- about (`Equipment` is a weapon model and says nothing about anything a pet does not wield),
    -- so a script that has just started knows nothing about this pet and the honest answer to
    -- "does it need gear" is "ask me". `gearpet` and the page's button are that ask.
    --
    -- Any *other* unsummoned pet is one that turned up while we were watching -- the player cast
    -- it by hand -- and that one is plainly new, so the hands are worth reading, a beat from now.
    local wasHereAtStartup = id == PetSetupState._.startupPetId

    pet = {
        id = id,
        name = name,
        zoneId = zoneId,
        -- a pet we summoned needs no reading at all: it arrived with nothing. Anything else is
        -- judged on what it is holding, and not on the frame it turns up -- see `judgeAdopted`
        gearing = ours,
        judged = ours,
        seenAtMs = Time.current_time(),
        adopted = not ours,
        wasHereAtStartup = wasHereAtStartup,
        given = {},
        summoned = {}
    }
    PetSetupState._.pet = pet

    DebugLog("Looking after [" .. pet.name .. "] (" .. tostring(pet.id) .. ")")
    return pet
end

---------------- Choosing what to do --------------------

---Who this state is when it asks the casting service for something.
---@param targetId number|nil
---@return table request
function PetSetupState.CastRequest(targetId)
    return {
        owner = PetSetupState.key,
        priority = PetSetupState.priority,
        targetId = targetId
    }
end

---The first pet slot worth casting right now. List order is the whole priority: which pet this
---character would rather have is the order the user already gave us.
---
---Which is why the walk stops at that slot rather than carrying on past it. A gem still
---recovering, or a mana bar a hundred short, is a moment -- and carrying on past it would mean
---summoning the second-choice pet for the rest of the camp because the first choice was a moment
---away. Both of those come back on their own, so the answer is to come back next pass; the second
---return is how the caller knows that is what happened.
---@return table|nil pick { action, slot }
---@return boolean isNeeded a slot that would summon the pet we want is owed, pick or no pick
local function chooseSummon()
    for _, slot in ipairs(PetSetupStateConfig.GetActions()) do
        if Action.IsEnabled(slot) and dueNow(slot) then
            local action, spell = readSlot(slot)
            if action ~= nil and Spells.SummonsPet(spell) and Action.GetLuaResult(slot) then
                -- a pet spell aims itself, so it is cast at nobody: EQ puts the pet beside us
                -- with nothing targeted, and targeting for one would drop whatever we were
                -- looking at to no purpose
                if action:IsReady(PetSetupState.CastRequest(nil)) then
                    return { action = action, slot = slot }, true
                end

                return nil, true
            end
        end
    end

    return nil, false
end

---The first gear slot this pet is short of, and what to do about it: hand over one we are
---carrying, or conjure one first.
---
---The walk stops on a slot the pet is short of and waits, rather than carrying on down the list,
---whenever the only thing in the way is ours: the gem recovering from the conjure we just made,
---or the mana for the next one. Both come back on their own in a moment, and going down the list
---in the meantime is what turns a full spell bar into two conjures taking turns in one gem --
---each memorized over the other, neither ever handed to the pet. One kind of gear, finished, then
---the next.
---
---What does *not* stop the walk is a slot that has had everything out of it it will ever get: the
---cap below is the end of that slot's work whether the pet is holding the items or lost them, and
---nothing about waiting here brings one back.
---@param pet table
---@return table|nil job { slot, action, itemId, carried }
---@return boolean isNeeded the pet is short of a slot that could still deliver, job or no job
local function chooseGear(pet)
    for _, slot in ipairs(PetSetupStateConfig.GetGearActions()) do
        if Action.IsEnabled(slot) and dueNow(slot) then
            local action, spell = readSlot(slot)
            local itemId = action ~= nil and Spells.SummonedItemId(spell) or nil

            if itemId ~= nil and Action.GetLuaResult(slot) then
                local key = slotKey(slot)
                local wanted = PetSetupStateConfig.GetGearCount(slot)

                if (pet.given[key] or 0) < wanted then
                    if carrying(itemId) then
                        return { slot = slot, action = action, itemId = itemId, carried = true }, true
                    end

                    -- never conjure more of a thing than this pet is owed. The cast succeeding
                    -- and the item not turning up is the one failure no retry can fix, and this
                    -- is what bounds it: the pet is owed two daggers, so two are ever summoned
                    -- for it, and the row says what happened to them
                    if (pet.summoned[key] or 0) < wanted then
                        if action:IsReady(PetSetupState.CastRequest(nil)) then
                            return { slot = slot, action = action, itemId = itemId, carried = false }, true
                        end

                        return nil, true
                    end
                end
            end
        end
    end

    return nil, false
end

---------------- The pet focus --------------------

---Is the pet focus still wanted?
---
---**The whole of what this state tells the swapping service about when to take the gear off**, and
---it is asked on the service's pulse rather than reported from a pass of ours, which is the point:
---at `buff - 1` this state can be starved for the length of a fight, and a promise to say "you can
---take it off now" is a promise a starved state cannot keep. A question the service asks itself
---always gets an answer.
---
---The answer is the summon: while the cast it went on for is in the air, the focus is doing its
---job. Before the cast has been started, the window above stands in -- see `focusCastWindowMs` for
---why that one clock is here and why it is the only one.
---@return boolean keepIt
function PetSetupState.KeepFocusWorn()
    local castId = PetSetupState._.castId
    if castId ~= nil and PetSetupState._.castJob == "summon" then
        return Casting.GetResult(castId) == nil
    end

    local until_ = PetSetupState._.focusWaitingUntilMs
    return until_ ~= nil and Time.current_time() < until_
end

---Get the focus onto the character, for the summon this pass is about to make.
---
---Called only once a summon has been picked and found ready, because that is the only moment
---putting gear on is worth anything: the effect is read off the character when the pet is made,
---so it goes on *before* the cast starts and comes off when the cast ends.
---
---**A focus that will not go on is not a reason to skip the summon.** A full bag, an item left in
---the bank, a slot the client will not answer for -- each of those makes the next pet a rank
---weaker, and none of them makes it better to have no pet at all. So every ending here except
---"still moving gear" says the cast may go ahead, with the reason kept for the row to show.
---@return boolean isBusy gear is being moved right now
---@return boolean isReady the focus is on, or there is none to put on
local function focusPass()
    if not PetSetupStateConfig.GetFocusSwapping() then return false, true end

    local wanted = PetSetupStateConfig.GetActiveFocusItems()
    if #wanted < 1 then return false, true end

    -- **Whether the focus is on is read off the character rather than off how the swap went**, so
    -- there is no result to still be holding when this is asked. Either the swapping service is
    -- holding it for us -- which is also what a partly successful swap looks like, one item on and
    -- one still in the bank -- or the player simply wears it, which is nothing we will ever owe
    -- back. In both cases this pass is the one that casts, so the reason to be wearing it is
    -- renewed right here
    if Swapping.IsHolding(PetSetupState.key) or Swapping.AllWorn(wanted) then
        PetSetupState._.focusWaitingUntilMs = Time.current_time() + focusCastWindowMs
        return false, true
    end

    local retryAt = PetSetupState._.focusRetryAtMs
    if retryAt ~= nil and Time.current_time() < retryAt then return false, true end

    -- armed before the request, because the service asks the question from the pulse and the
    -- first one it asks comes before this state's next pass
    PetSetupState._.focusWaitingUntilMs = Time.current_time() + focusCastWindowMs

    local id, refused = Swapping.Wear(wanted, {
        owner = PetSetupState.key,
        label = "the pet focus",
        keepWhile = PetSetupState.KeepFocusWorn
    })

    if id == nil then
        PetSetupState._.focusWaitingUntilMs = nil
        PetSetupState._.focusProblem = tostring(refused)
        PetSetupState._.focusRetryAtMs = Time.current_time() + retryAfterFailureMs
        DebugLog("Nothing of the pet focus could be put on: " .. tostring(refused))
        return false, true
    end

    PetSetupState._.focusProblem = nil
    PetSetupState._.focusSwapId = id
    PetSetupState._.nextLookMs = 0
    return true, false
end

---@param status string
---@param reason string|nil
local function recordFocusSwapFinished(status, reason)
    PetSetupState._.focusSwapId = nil

    if status == Swapping.status.succeeded then
        PetSetupState._.focusProblem = nil
        PetSetupState._.focusRetryAtMs = nil
        PetSetupState._.lastResult = "put the pet focus on"
    else
        PetSetupState._.focusProblem = tostring(reason)
        -- a swap that would not go through is not a reason to skip the summon -- a pet a rank
        -- weaker is still a pet -- but it is a reason not to try the same thing on the next pass
        PetSetupState._.focusRetryAtMs = Time.current_time() + retryAfterFailureMs
        PetSetupState._.lastResult = "the pet focus did not go on: " .. tostring(reason)
    end

    DebugLog("Focus swap finished: " .. tostring(PetSetupState._.lastResult))
    PetSetupState._.nextLookMs = 0
end

---------------- Starting things --------------------

---@param pick table from chooseSummon
---@return boolean isBusy
local function startSummon(pick)
    local castId, refused = Casting.Cast(pick.action:Subject(), PetSetupState.CastRequest(nil))

    if castId == nil then
        DebugLog("Summon of [" .. pick.action:Name() .. "] was refused: " .. tostring(refused))
        recordProblem(pick.slot, tostring(refused))
        -- Held off rather than tried again next pass, which matters more since the focus swap:
        -- a slot the casting service keeps refusing would otherwise have this state putting the
        -- focus on, failing to cast, letting the window run out, taking it off and starting again
        holdOff(pick.slot, retryAfterFailureMs)
        return false
    end

    DebugLog("Summoning a pet with [" .. pick.action:Name() .. "]")
    PetSetupState._.castId = castId
    PetSetupState._.castSlot = pick.slot
    PetSetupState._.castJob = "summon"
    PetSetupState._.castItemId = nil
    PetSetupState._.castName = pick.action:Name()
    PetSetupState._.summonOrder = nil
    return true
end

---@param job table from chooseGear
---@param record table whose gear list this is: our own pet, or a `petgear` request
---@return boolean isBusy
local function startGearCast(job, record)
    local castId, refused = Casting.Cast(job.action:Subject(), PetSetupState.CastRequest(nil))

    if castId == nil then
        DebugLog("Summon of [" .. job.action:Name() .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Conjuring [" .. job.action:Name() .. "] for [" .. tostring(record.name) .. "]")
    PetSetupState._.castId = castId
    PetSetupState._.castSlot = job.slot
    PetSetupState._.castJob = "gear"
    PetSetupState._.castItemId = job.itemId
    PetSetupState._.castName = job.action:Name()
    -- what this cast is being made for, so the count lands on the right record: a conjure for
    -- somebody else's pet must not be credited against our own
    PetSetupState._.castRecord = record
    return true
end

---@param pet table our own pet's record, or a `petgear` request's
---@param job table from chooseGear
---@return boolean isBusy
local function startGive(pet, job)
    local name = itemName(job.itemId)

    local giveId, refused = Giving.Hand({ id = job.itemId, name = name }, {
        owner = PetSetupState.key,
        spawnId = pet.id
    })

    if giveId == nil then
        DebugLog("Hand-off of [" .. name .. "] was refused: " .. tostring(refused))
        holdOff(job.slot, retryAfterFailureMs)
        return false
    end

    DebugLog("Handing [" .. name .. "] to [" .. pet.name .. "]")
    PetSetupState._.giveId = giveId
    PetSetupState._.giveSlot = job.slot
    PetSetupState._.giveItemName = name
    PetSetupState._.givePetId = pet.id
    PetSetupState._.giveRecord = pet
    return true
end

---------------- Finishing things --------------------

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordCastFinished(status, outcome, reason)
    local job = PetSetupState._.castJob
    local slot = PetSetupState._.castSlot
    local name = PetSetupState._.castName or "it"

    if status == Casting.status.succeeded then
        recordProblem(slot, nil)

        if job == "summon" then
            -- the pet arrives a beat behind the cast; whichever one turns up next is ours, and
            -- ours are the ones kitted out from nothing
            PetSetupState._.ourPetComing = true
            PetSetupState._.lastResult = "summoned with " .. name
        else
            PetSetupState._.lastResult = "conjured " .. name
            -- against whichever gear list asked for it, which is not always our own pet's
            local record = PetSetupState._.castRecord
            if record ~= nil and slot ~= nil then
                local key = slotKey(slot)
                record.summoned[key] = (record.summoned[key] or 0) + 1
            end
        end
    else
        PetSetupState._.lastResult = name .. " failed: " .. tostring(reason)
        recordProblem(slot, tostring(reason))
        holdOff(slot, retryAfterFailureMs)
    end

    if job == "summon" then
        -- What the focus went on for is over, whichever way it went, so it comes off now rather
        -- than when the window above runs out. Nothing is moved here: this only ends the reason,
        -- and the swapping service does the putting back on its own pulse
        PetSetupState._.focusWaitingUntilMs = nil
        Swapping.Release(PetSetupState.key)
    end

    DebugLog("Cast finished: " .. tostring(PetSetupState._.lastResult))
    PetSetupState._.castId = nil
    PetSetupState._.castSlot = nil
    PetSetupState._.castJob = nil
    PetSetupState._.castItemId = nil
    PetSetupState._.castName = nil
    PetSetupState._.castRecord = nil
    -- something changed, so the next pass is worth taking rather than waiting out the idle window
    PetSetupState._.nextLookMs = 0
end

---@param status string
---@param reason string|nil
local function recordGiveFinished(status, reason)
    local slot = PetSetupState._.giveSlot
    local name = PetSetupState._.giveItemName or "it"
    local record = PetSetupState._.giveRecord

    if status == Giving.status.succeeded then
        recordProblem(slot, nil)
        PetSetupState._.lastResult = "gave " .. name .. " to " .. (record ~= nil and record.name or "the pet")
        -- credited to the pet it was actually handed to: a pet that died mid-hand-off is not the
        -- one standing here now, and the new one has been given nothing
        if record ~= nil and slot ~= nil and record.id == PetSetupState._.givePetId then
            local key = slotKey(slot)
            record.given[key] = (record.given[key] or 0) + 1
        end
    else
        PetSetupState._.lastResult = name .. " was not handed over: " .. tostring(reason)
        recordProblem(slot, tostring(reason))
        holdOff(slot, retryAfterFailureMs)
    end

    DebugLog("Hand-off finished: " .. tostring(PetSetupState._.lastResult))
    PetSetupState._.giveId = nil
    PetSetupState._.giveSlot = nil
    PetSetupState._.giveItemName = nil
    PetSetupState._.givePetId = nil
    PetSetupState._.giveRecord = nil
    PetSetupState._.nextLookMs = 0
end

---------------- Holding back --------------------

---Reasons to hold everything, in the order they are worth reporting.
---@return string|nil code
---@return string|nil reason in words
local function holdReason()
    -- The world is being taken down and put back up, and it answers nothing worth hearing while
    -- that is happening -- least of all "there is no pet", which is what it says for the whole of a
    -- loading screen about a pet walking through the line alongside us. Asked positively: a client
    -- that will not say where it is is not one to hold everything on, and the zone line itself is
    -- noticed separately either way (see `noticeZoneLine`).
    local gameState = mq.TLO.EverQuest.GameState()
    if gameState ~= nil and gameState ~= "INGAME" then
        return "zoning", "waiting for the zone"
    end

    local state = mq.TLO.Me.State()
    if state == "DEAD" or state == "HOVER" then
        return "dead", "dead"
    end

    if Combat.IsEngaged() and not PetSetupStateConfig.GetInCombat() then
        return "fighting", "not while we are fighting"
    end

    -- a summon is a long cast that has to be stood still for, and an item cannot be handed to a
    -- pet trailing along behind us. This is a state that can afford to ask again in a moment
    if mq.TLO.Me.Moving() then
        return "moving", "waiting until we stop moving"
    end

    return nil, nil
end

---Is what is in the air still worth finishing?
---@param code string|nil the hold code this pass, if any
---@param isCast? boolean whether what is in the air is a cast rather than a hand-off
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandon(code, isCast)
    if code == "fighting" then return "a fight started" end
    if code == "dead" then return "we died" end
    -- nothing survives a zone line: a cast is interrupted by the door and a hand-off is a trade
    -- window with the other half of it in a zone we have left
    if code == "zoning" then return "we zoned" end

    -- The group has moved off with a cast up that cannot survive it -- the same thing the hold
    -- above says about starting one, said about the one already going. A summon waiting out a run
    -- for the stillness it needs is a summon that pins the character and starves the bands below
    -- it while the group leaves, and it is no more castable at the end of the wait than it was at
    -- the start. Only a cast: a hand-off is its own sequence, with a window open and an item on the
    -- cursor, and calling one off is not the same conversation.
    if isCast and code == "moving" and Casting.IsHoldingStill() then return "we started moving" end

    return nil
end

---Push the pending orders' clocks along while everything is held.
---
---Every one of these windows means "this ask has stopped meaning anything", and being in a fight
---is not that -- so they only run across passes where the work could have been started. Without
---this a `gearpet` said at the start of a fight is quietly dropped fifteen seconds later, and the
---first pass after the fight reports it as finished having done nothing.
local function holdOrders()
    local now = Time.current_time()

    if PetSetupState._.summonOrder ~= nil then
        PetSetupState._.summonOrder = now + summonOrderTtlMs
    end
    if PetSetupState._.gearOrder ~= nil then
        PetSetupState._.gearOrder = now + gearOrderIdleMs
    end
    if PetSetupState._.request ~= nil then
        PetSetupState._.request.expires = now + gearOrderIdleMs
    end
end

---------------- Somebody else's pet --------------------

---One pass of a `petgear` request: the same walk down the same gear list, aimed at the pet of
---whoever asked.
---
---Nothing here is different from kitting out our own pet except who holds out their hand, which is
---why the record has the same shape and `chooseGear` never learns there are two kinds. The request
---ends the way `gearpet` does -- when the casts and hand-offs go quiet -- or the moment the pet it
---was for is not there any more, which is a thing worth saying out loud rather than timing out
---over: a warder that died mid-favour is one nobody is waiting on.
---@return boolean isBusy
---@return boolean isHolding nothing started, but the ask is one gem away from its next hand-off
local function requestPass()
    local request = PetSetupState._.request
    if request == nil then return false, false end

    local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
    if spawn.ID() == nil or spawn.Dead() then
        print("(petgear) " .. request.speaker .. "'s pet is gone")
        PetSetupState._.request = nil
        return false, false
    end

    local job, isNeeded = chooseGear(request)
    -- an ask that is owed something and only waiting on our own gem keeps the pass: our own pet's
    -- list is the thing below it, and letting that in is what would conjure over the gem this one
    -- is coming back to
    if job == nil then return false, isNeeded end

    local started
    if job.carried then
        started = startGive(request, job)
    else
        started = startGearCast(job, request)
    end

    if not started then return false, true end

    -- the ask stands for as long as it is still producing work
    request.expires = Time.current_time() + gearOrderIdleMs
    return true, false
end

---------------- Orders --------------------

---Summon a pet now: the switch and the wait for a pet still crossing a zone line are the state's
---own judgment, and somebody asking outranks both. It waits for a gem for as long as an order is
---still an order.
function PetSetupState.OrderSummon()
    PetSetupState._.summonOrder = Time.current_time() + summonOrderTtlMs
    PetSetupState._.nextLookMs = 0
    DebugLog("A pet was ordered")
end

---Hand this pet everything the gear list says it should have, from scratch: what it was given
---before is forgotten, and a pet we had decided to leave alone is kitted out after all. Ends when
---there is nothing left to hand over.
function PetSetupState.OrderGear()
    -- the one ask this state will not carry out: see the charm gate in `Go`. Answered here so that
    -- somebody who asks gets told rather than watching nothing happen for fifteen seconds
    if Pet.IsCharmed() then
        print("(gearpet) " .. Pet.GetName() .. " is charmed -- what a charmed pet is handed leaves with it")
        return
    end

    PetSetupState._.gearOrder = Time.current_time() + gearOrderIdleMs
    PetSetupState._.tryAgainAt = {}
    PetSetupState._.nextLookMs = 0

    local pet = PetSetupState._.pet
    if pet ~= nil then
        pet.gearing = true
        -- somebody asking outranks whatever the pet's hands were going to say, so the reading is
        -- not taken afterwards to argue with them
        pet.judged = true
        pet.given = {}
        pet.summoned = {}
    end

    DebugLog("Gearing the pet was ordered")
end

---Kit out somebody else's pet from this character's own gear list.
---
---The one thing this state does for a person rather than for itself, and it is the magician's
---trade: everybody else's pet arrives bare, and a magician is carrying the spell that fixes it. It
---is a *request* rather than a switch -- it stands until there is nothing left to hand over and
---then stops -- because handing somebody a weapon is a favour asked for once, not a standing
---arrangement, and a magician that tracked every pet in the group forever would be conjuring for
---pets that have died and been replaced twice over.
---
---The record is the same shape our own pet's is, and for the same reason: what a pet has been
---handed is readable nowhere, so what we handed *this* pet is the only answer there is. It belongs
---to one spawn id and dies with the request.
---@param petId number the asker's pet
---@param petName string
---@param speaker string who asked, for the report
function PetSetupState.OrderGearFor(petId, petName, speaker)
    PetSetupState._.request = {
        id = petId,
        name = petName,
        speaker = speaker,
        given = {},
        summoned = {},
        expires = Time.current_time() + gearOrderIdleMs
    }
    -- a slot held off after a failure for our own pet says nothing about this one
    PetSetupState._.tryAgainAt = {}
    PetSetupState._.nextLookMs = 0

    DebugLog("Gearing [" .. petName .. "] was asked for by [" .. speaker .. "]")
end

---Call off whatever is in the air right now, and forget any order waiting for its turn.
function PetSetupState.CallOff()
    PetSetupState._.summonOrder = nil
    PetSetupState._.gearOrder = nil
    PetSetupState._.request = nil

    if PetSetupState._.castId ~= nil then
        Casting.StopFor(PetSetupState.key)
    end
    if PetSetupState._.giveId ~= nil then
        Giving.StopFor(PetSetupState.key)
    end

    -- the focus is a different kind of thing to call off: stopping the swap is only half of it,
    -- and the half that matters is that the gear still owes a trip back to the slots it came out
    -- of. `StopFor` says both
    PetSetupState._.focusWaitingUntilMs = nil
    Swapping.StopFor(PetSetupState.key)
end

---------------- Status --------------------

---Whose pet a piece of work is for, named the way it should read in a report.
---@param record table|nil
---@return string
local function whose(record)
    if record == nil then return "the pet" end
    if record.speaker ~= nil then return record.speaker .. "'s " .. record.name end
    return record.name
end

---@return string description of what this state is doing, for /cpet and the menu
function PetSetupState.Describe()
    -- gear of ours actually in motion, either way round. Only while a swap is running: the focus
    -- merely sitting on the character is what "summoning a pet with ..." below already means
    if Swapping.IsBusyFor(PetSetupState.key) then
        return Swapping.Describe()
    end

    if PetSetupState._.castId ~= nil then
        if PetSetupState._.castJob == "summon" then
            return "summoning a pet with " .. tostring(PetSetupState._.castName)
        end
        return "conjuring " .. tostring(PetSetupState._.castName) .. " for " ..
            whose(PetSetupState._.castRecord)
    end

    if PetSetupState._.giveId ~= nil then
        return "handing " .. tostring(PetSetupState._.giveItemName) .. " to " ..
            whose(PetSetupState._.giveRecord or PetSetupState._.pet)
    end

    if PetSetupState._.holdReason ~= nil then
        return "holding: " .. PetSetupState._.holdReason
    end

    local request = PetSetupState._.request
    if request ~= nil then return "gearing " .. whose(request) end

    if PetSetupState._.pet == nil then return "no pet" end
    return "looking after " .. PetSetupState._.pet.name
end

---@return table|nil request the pet somebody asked us to kit out, as last read
function PetSetupState.GetRequest()
    return PetSetupState._.request
end

---@return string|nil result how the last thing this state started went
function PetSetupState.GetLastResult()
    return PetSetupState._.lastResult
end

---@return table|nil pet the pet being looked after, as last read
function PetSetupState.GetPet()
    return PetSetupState._.pet
end

---@class PetSlotFacts
---@field summonsPet boolean whether this slot puts a pet beside us
---@field itemId number|nil the item this slot conjures, for a gear slot
---@field itemName string|nil what that item is called, once we have seen one
---@field given number how many of it this pet has been handed
---@field wanted number how many of it this pet should end up with
---@field problem string|nil why this slot will never fire, when it will not
---@field lastProblem string|nil why its last attempt did not take, when one did not

---What a configured slot amounts to, for whatever is showing it to a user. Everything here is
---read off the spell rather than configured, so it is also the answer to "why is this one not
---firing" -- which is otherwise a silent puzzle.
---
---Two different questions live in the two problem fields, and both are worth showing. `problem`
---is about the slot as configured -- a spell that summons nothing will never work whatever the
---world does. `lastProblem` is what the *world* said the last time this slot was tried: no mana,
---a missing reagent (which is what stops a magician's elemental until there is malachite in the
---bags), a pet that would not take what it was handed. The second is the one that comes back
---from a page where everything looks right and nothing happens.
---@param slot Action
---@param isGear boolean whether this is a slot from the gear list
---@return PetSlotFacts facts
function PetSetupState.DescribeSlot(slot, isGear)
    local facts = { summonsPet = false, itemId = nil, itemName = nil, given = 0, wanted = 0,
        problem = nil, lastProblem = nil }

    -- a row being filled in has nothing to report yet, and "this character does not have it" is a
    -- strange thing to say about a spell nobody has picked
    if slot.name == nil or slot.name == "" then return facts end

    facts.lastProblem = PetSetupState._.slotProblem[slotKey(slot)]

    local action = Action.GetActionType(slot)
    if action == nil then
        facts.problem = "this character does not have it"
        return facts
    end
    if action.Subject == nil then
        facts.problem = "only spells, clickies and AAs can summon"
        return facts
    end

    local spell = action:Subject():Spelldata()
    if spell == nil then
        facts.problem = "no spell data"
        return facts
    end

    if not isGear then
        facts.summonsPet = Spells.SummonsPet(spell)
        if not facts.summonsPet then
            facts.problem = "this does not summon a pet"
        end
        return facts
    end

    facts.itemId = Spells.SummonedItemId(spell)
    if facts.itemId == nil then
        facts.problem = "this does not conjure an item"
        return facts
    end

    -- remembered once seen, because this is drawn every frame the page is open and a name we
    -- are not carrying one of cannot be read at all
    facts.itemName = PetSetupState._.itemNames[facts.itemId]
    if facts.itemName == nil then
        local name = mq.TLO.FindItem(facts.itemId).Name()
        if name ~= nil then
            PetSetupState._.itemNames[facts.itemId] = name
            facts.itemName = name
        end
    end

    facts.wanted = PetSetupStateConfig.GetGearCount(slot)

    local pet = PetSetupState._.pet
    if pet ~= nil then
        facts.given = pet.given[slotKey(slot)] or 0
    end

    return facts
end

---@class PetFocusFacts
---@field focus string|nil what the focus effect on it is called, once we can see the item
---@field carried boolean whether it is on us or in our bags at all
---@field worn string|nil the slot it is in right now, when it is on
---@field problem string|nil why this row will do nothing

---What a configured focus item amounts to, for whatever is showing it to a user.
---
---Read live rather than out of the registry a picker was filled from: that list is rebuilt when
---the bags change, and a row can name something bought, banked or destroyed since. The focus
---itself is the thing worth reporting -- a row naming an item with no pet focus on it is a swap
---that will happen and buy nothing, which is worse than one that plainly cannot happen.
---@param entry table a row from the focus list
---@return PetFocusFacts facts
function PetSetupState.DescribeFocusItem(entry)
    local facts = { focus = nil, carried = false, worn = nil, problem = nil }

    -- a row being filled in has nothing to report yet
    if entry.name == nil or entry.name == "" then return facts end

    local item = mq.TLO.FindItem("=" .. tostring(entry.name))
    if item.ID() == nil then
        facts.problem = "not on us or in our bags"
        return facts
    end

    facts.carried = true
    facts.worn = Swapping.WornSlotOf(tonumber(item.ID()))
    facts.focus = Items.PetFocusName(item)

    if facts.focus == nil then
        facts.problem = "no pet focus on it"
    end

    return facts
end

---@return boolean isWorn whether the swapping service is holding the focus on for us right now
function PetSetupState.IsFocusWorn()
    return Swapping.IsHolding(PetSetupState.key)
end

---@return string|nil problem why the focus could not be put on, the last time it could not
function PetSetupState.GetFocusProblem()
    return PetSetupState._.focusProblem
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function PetSetupState.Init()
    if PetSetupState._.isInit then return end

    -- our own config, so a class that does not register this state has no pet slots written
    PetSetupStateConfig.Init()

    -- the pet that is standing here before this script has done anything is one this script knows
    -- nothing about, and it stays that way: see `refreshPet`
    PetSetupState._.startupPetId = tonumber(mq.TLO.Me.Pet.ID())
    if PetSetupState._.startupPetId ~= nil then
        DebugLog("A pet was already here at startup (" .. tostring(PetSetupState._.startupPetId) ..
            ") -- it will not be geared unless asked")
    end

    Menu.RegisterState(PetSetupState)

    local summonDocs = ChelpDocs.new(function() return {
        "(summonpet) Tells listener(s) to summon a pet now",
        " -- The first pet on the Pet Setup page that is ready is the one cast.",
        " -- An order, so it does not even wait for a pet that may still be crossing a zone line,",
        "    and it stands for fifteen seconds while a gem recovers before it lapses."
    } end )
    local function event_SummonPet(_, speaker)
        if not Commands.GetCommandOwners(PetSetupState.eventIds.summon):HasPermission(speaker) then
            DebugLog("Ignoring summonpet speaker [" .. speaker .. "]")
            return
        end
        PetSetupState.OrderSummon()
    end
    Commands.RegisterCommEvent(Command.new(PetSetupState.eventIds.summon, event_SummonPet, summonDocs))

    local gearDocs = ChelpDocs.new(function() return {
        "(gearpet) Tells listener(s) to hand their pet everything on its gear list",
        " -- What the pet was already given is forgotten, so this is also how a pet that was",
        "    already standing here -- one this script did not summon -- gets equipped."
    } end )
    local function event_GearPet(_, speaker)
        if not Commands.GetCommandOwners(PetSetupState.eventIds.gear):HasPermission(speaker) then
            DebugLog("Ignoring gearpet speaker [" .. speaker .. "]")
            return
        end
        PetSetupState.OrderGear()
    end
    Commands.RegisterCommEvent(Command.new(PetSetupState.eventIds.gear, event_GearPet, gearDocs))

    local requestDocs = ChelpDocs.new(function() return {
        "(petgear) Asks listener(s) to hand YOUR pet everything on their own gear list",
        " -- The magician's trade: every other class's pet arrives bare, and a magician is the one",
        "    carrying the spell that fixes it. Say it once; only a character with something on its",
        "    gear list answers, so a group of six is not six characters conjuring daggers.",
        " -- Stand next to the magician with your pet out: an item is handed over in person.",
        " -- It ends when there is nothing left to hand over, and your pet is forgotten again --",
        "    a pet that dies afterwards is not re-armed until you ask again."
    } end )
    local function event_PetGear(_, speaker, args)
        -- `petgearing on` arrives here as this phrase plus "ing on", because a registered phrase
        -- matches every longer line that starts with it. A word carrying straight on from ours is
        -- somebody else's command, and this one never takes arguments to lose by saying so
        if args ~= nil and args ~= "" and args:sub(1, 1) ~= " " then return end

        if not Commands.GetCommandOwners(PetSetupState.eventIds.request):HasPermission(speaker) then
            DebugLog("Ignoring petgear speaker [" .. speaker .. "]")
            return
        end

        -- silence is the answer for a character with nothing to hand over. Every pet class hears
        -- this and only the one with a gear list was being asked; a shadow knight explaining that
        -- it has no daggers is chat nobody wanted
        if #PetSetupStateConfig.GetGearActions() < 1 then
            DebugLog("Ignoring petgear from [" .. speaker .. "] -- nothing on the gear list")
            return
        end

        local spawn = mq.TLO.Spawn("pc radius 300 " .. speaker)
        if spawn.ID() == nil then
            Commands.GetCommandSpeak(PetSetupState.eventIds.request)
                :speak("Cannot see [" .. speaker .. "] to gear their pet")
            return
        end

        local petId = tonumber(spawn.Pet.ID())
        if petId == nil or petId < 1 then
            Commands.GetCommandSpeak(PetSetupState.eventIds.request)
                :speak("[" .. speaker .. "] has no pet to gear")
            return
        end

        PetSetupState.OrderGearFor(petId, spawn.Pet.CleanName() or (speaker .. "'s pet"), speaker)
    end
    Commands.RegisterCommEvent(Command.new(PetSetupState.eventIds.request, event_PetGear, requestDocs)
        :ActsOnSpeaker())

    ToggleCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.keeping,
        summary = "Turns looking after the pet on or off for listener(s)",
        about = { "Off calls off a summon or a hand-off in progress as well as stopping new ones." },
        get = PetSetupStateConfig.IsEnabled,
        set = PetSetupState.SetEnabled
    })

    ToggleCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.summoning,
        summary = "Turns replacing a missing pet on or off",
        about = {
            "Off, a pet that dies or is let go stays gone until `summonpet` says otherwise.",
            "On, the first ready entry on the pet list is cast a few seconds after the pet goes."
        },
        get = PetSetupStateConfig.GetSummoning,
        set = PetSetupStateConfig.SetSummoning
    })

    ToggleCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.gearing,
        summary = "Turns conjuring and handing over the pet's gear on or off",
        about = { "Off, nothing is conjured for the pet and nothing is handed to it." },
        get = PetSetupStateConfig.GetGearing,
        set = PetSetupStateConfig.SetGearing
    })

    ToggleCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.combat,
        summary = "Turns summoning and gearing the pet during a fight on or off",
        about = {
            "Off by default: a summon is a long cast and a bar of mana, and an item cannot be",
            "handed to a pet that is off fighting something.",
            "Off also calls off what is in the air when a fight starts.",
            "Nothing to do with using the pet in a fight, which is (petattack) and its own page."
        },
        get = PetSetupStateConfig.GetInCombat,
        set = PetSetupStateConfig.SetInCombat
    })

    ToggleCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.focus,
        summary = "Turns wearing the pet focus for a summon on or off",
        about = {
            "On, everything on the Focus tab goes on just before the summon is cast and comes",
            "back off when it lands -- what it displaced goes back in its slot.",
            "A magician's pet focus is read off the character at the moment the pet is made, so",
            "it has to be worn for the cast and is worth nothing put on afterwards.",
            "Off, the summon is cast with whatever is already on."
        },
        get = PetSetupStateConfig.GetFocusSwapping,
        set = PetSetupStateConfig.SetFocusSwapping
    })

    ActionCommand.Register({
        key = PetSetupState.key,
        phrase = PetSetupState.eventIds.action,
        summary = "Switches one of the configured pets or pieces of pet gear on or off",
        where = "Pet Setup page",
        getActionLists = PetSetupStateConfig.GetActionLists
    })

    local cpetDocs = ChelpDocs.new(function() return {
        "(/cpet) Report what the pet state is doing, and what the pet has been given",
        " -- Usage: /cpet",
        " -- Usage (call off what is in the air): /cpet off",
        " -- Usage (hand the pet its whole gear list again): /cpet gear",
        " -- Usage (summon a pet now): /cpet summon"
    } end )
    local function Bind_CPet(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cpetDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            PetSetupState.CallOff()
            print("Pet work called off")
            return
        end

        if #args > 0 and args[1]:lower() == "gear" then
            PetSetupState.OrderGear()
            print("Pet: handing over the whole gear list again")
            return
        end

        if #args > 0 and args[1]:lower() == "summon" then
            PetSetupState.OrderSummon()
            print("Pet: summoning")
            return
        end

        print("Pet: " .. PetSetupState.Describe() .. (PetSetupState.IsEnabled() and "" or " (disabled)"))
        local result = PetSetupState.GetLastResult()
        if result ~= nil then
            print(" -- last: " .. result)
        end

        local pet = PetSetupState.GetPet()
        if pet == nil then
            print(" -- no pet")
        elseif Pet.IsCharmed() then
            print(" -- " .. pet.name .. " is charmed: nothing is conjured for it and nothing is handed to it")
        elseif not pet.judged then
            print(" -- " .. pet.name .. " has only just turned up; looking at what it is holding")
        elseif not pet.gearing then
            if pet.wasHereAtStartup then
                print(" -- " .. pet.name .. " was already here when the script started, so it is left as it is; `gearpet` to kit it out anyway")
            else
                print(" -- " .. pet.name .. " was already equipped when we found it; `gearpet` to kit it out anyway")
            end
        end

        local request = PetSetupState.GetRequest()
        if request ~= nil then
            print(" -- asked by " .. request.speaker .. " to gear " .. request.name)
        end

        for _, slot in ipairs(PetSetupStateConfig.GetActions()) do
            local facts = PetSetupState.DescribeSlot(slot, false)
            local line = " -- pet: " .. tostring(slot.name)
            if not Action.IsEnabled(slot) then
                line = line .. " (switched off)"
            elseif facts.problem ~= nil then
                line = line .. " -- " .. facts.problem
            elseif facts.lastProblem ~= nil then
                line = line .. " -- last try: " .. facts.lastProblem
            end
            print(line)
        end

        for _, slot in ipairs(PetSetupStateConfig.GetGearActions()) do
            local facts = PetSetupState.DescribeSlot(slot, true)
            local label = facts.itemName or tostring(slot.name)
            if facts.problem ~= nil then
                print(" -- gear: " .. tostring(slot.name) .. " -- " .. facts.problem)
            else
                print(" -- gear: " .. label .. ": " .. tostring(facts.given) .. " of " .. tostring(facts.wanted) ..
                    " handed over" .. (facts.lastProblem ~= nil and (" -- last try: " .. facts.lastProblem) or ""))
            end
        end

        for _, entry in ipairs(PetSetupStateConfig.GetFocusItems()) do
            local facts = PetSetupState.DescribeFocusItem(entry)
            local line = " -- focus: " .. tostring(entry.name)

            if not PetSetupStateConfig.IsFocusItemEnabled(entry) then
                line = line .. " (switched off)"
            elseif not PetSetupStateConfig.GetFocusSwapping() then
                line = line .. " (not worn for summons -- `petfocus on`)"
            elseif facts.problem ~= nil then
                line = line .. " -- " .. facts.problem
            else
                line = line .. " -- " .. tostring(facts.focus) ..
                    (facts.worn ~= nil and (", on now (" .. facts.worn .. ")") or ", in a bag")
            end

            print(line)
        end

        local focusProblem = PetSetupState.GetFocusProblem()
        if focusProblem ~= nil then
            print(" -- focus: last swap -- " .. focusProblem)
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cpet", Bind_CPet, cpetDocs))

    PetSetupState._.isInit = true
end

---Read what is here, start one thing, release.
---
---There is no "I am summoning" mode to be stuck in. Every pass that looks re-reads whether there
---is a pet and which pet it is, and asks the same two questions in the same order. What is held
---between passes is what the world cannot say: the cast or the hand-off we started, and what this
---pet has been handed -- and both are dropped the moment they stop being true.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function PetSetupState.Go()
    local code, hold = holdReason()
    PetSetupState._.holdReason = hold

    -- who the pet is, before anything reads it: a pet that has been replaced takes its record
    -- with it, and the new one starts from nothing
    local pet = refreshPet()

    local castId = PetSetupState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        if status == nil then
            local abandon = reasonToAbandon(code, true)
            if abandon ~= nil then
                DebugLog("Calling off the cast: " .. abandon)
                PetSetupState._.lastResult = "called off: " .. abandon
                Casting.StopFor(PetSetupState.key)
            end
            return true
        end

        recordCastFinished(status, outcome, reason)
        return true
    end

    local giveId = PetSetupState._.giveId
    if giveId ~= nil then
        local status, reason = Giving.GetResult(giveId)

        if status == nil then
            local abandon = reasonToAbandon(code)
            if abandon == nil and (pet == nil or pet.id ~= PetSetupState._.givePetId) then
                abandon = "the pet is gone"
            end
            if abandon ~= nil then
                DebugLog("Calling off the hand-off: " .. abandon)
                PetSetupState._.lastResult = "called off: " .. abandon
                Giving.StopFor(PetSetupState.key)
            end
            -- busy while it runs: the sequence holds the target and the cursor, and anything
            -- below that targets somebody else would take them out from under it
            return true
        end

        recordGiveFinished(status, reason)
        return true
    end

    -- The pet focus going on. Busy while it runs, because the cursor and a worn slot are the
    -- character's hands, and called off for the same reasons a cast is -- a swap half made when a
    -- fight starts is one the swapping service unwinds for us.
    local swapId = PetSetupState._.focusSwapId
    if swapId ~= nil then
        local status, reason = Swapping.GetResult(swapId)

        if status == nil then
            local abandon = reasonToAbandon(code)
            if abandon ~= nil then
                DebugLog("Calling off the focus swap: " .. abandon)
                PetSetupState._.lastResult = "the pet focus was called off: " .. abandon
                PetSetupState._.focusWaitingUntilMs = nil
                Swapping.StopFor(PetSetupState.key)
            end
            return true
        end

        -- Deliberately no `return` here, unlike the cast and the hand-off above. The pass that
        -- finishes putting the focus on has to be the pass that fires the summon: the window the
        -- gear is worn against is armed by that pass, and a spare pass in between is a pass in
        -- which the swapping service can decide nobody wants it any more and take it off again
        recordFocusSwapFinished(status, reason)
    end

    -- the focus coming back off. Busy while it actually runs and never called off: it is what we
    -- owe rather than what we wanted, and the swapping service finishes it on its own pulse
    -- whether this state is given another frame or not
    if Swapping.IsBusyFor(PetSetupState.key) then return true end

    if hold ~= nil then
        -- an order does not go stale while we are held: what a TTL is for is an ask that has
        -- stopped meaning anything, and "we were in a fight for twenty seconds" is not that. The
        -- clock on all three runs only across the passes where the work could have been started
        holdOrders()
        return false
    end

    if Time.current_time() < PetSetupState._.nextLookMs then return false end

    prune()

    if PetSetupState._.summonOrder ~= nil and Time.current_time() > PetSetupState._.summonOrder then
        print("(summonpet) Nothing was ready to summon a pet with")
        PetSetupState._.summonOrder = nil
    end

    -- an order to gear the pet ends when the casts and hand-offs go quiet, not on the first pass
    -- that starts nothing: "no slot picked this pass" is also what a recovering gem looks like
    if PetSetupState._.gearOrder ~= nil and Time.current_time() > PetSetupState._.gearOrder then
        print("(gearpet) Nothing left to hand over")
        PetSetupState._.gearOrder = nil
    end

    local request = PetSetupState._.request
    if request ~= nil and Time.current_time() > request.expires then
        print("(petgear) Nothing left to hand " .. request.speaker .. "'s pet")
        PetSetupState._.request = nil
    end

    -- somebody else's pet, ahead of our own: it is an ask from a person, and this character's own
    -- pet is a job that will still be there in a moment
    local requestBusy, requestHolding = requestPass()
    if requestBusy then return true end
    -- the ask is owed something and waiting on a gem: end the pass on it rather than stamping the
    -- idle interval over a decision already made, and without letting the lists below it in
    if requestHolding then return false end

    if pet == nil then
        local ordered = PetSetupState._.summonOrder ~= nil
        local expected = PetSetupState._.petExpectedUntilMs

        if PetSetupStateConfig.GetSummoning() or ordered then
            -- a pet still walking through a zone line behind us is not a pet to replace. Anything
            -- else missing is replaced on the pass that finds it missing; an order says even the
            -- zone line is not worth waiting out
            if ordered or expected == nil or Time.current_time() >= expected then
                local pick, isNeeded = chooseSummon()

                if pick ~= nil then
                    -- The focus goes on first, and only now that there is a summon ready to cast:
                    -- what makes the pet stronger is read off the character at the moment the pet
                    -- is made, so a focus put on afterwards is a focus that did nothing, and one
                    -- put on for a summon that was never ready is gear moved for no reason
                    local swapping, ready = focusPass()
                    if swapping then return true end
                    if ready and startSummon(pick) then return true end
                end

                if isNeeded then return false end
            end
        end

        -- Never idle past a moment already being waited on. The interval is for "nothing to do,
        -- ask again in a while", and a pet expected off a zone line is not nothing to do -- it is
        -- something to do at a time we already know. Sleeping through it and finding out a second
        -- late is the same mistake either way round.
        local nextLook = Time.current_time() + idleLookIntervalMs
        if expected ~= nil and expected < nextLook then nextLook = expected end
        PetSetupState._.nextLookMs = nextLook
        return false
    end

    -- A charmed pet is a mob on a leash rather than a pet this character made, and what it is
    -- handed leaves with it: the charm breaks, the mob goes back to being a mob, and the weapon it
    -- was given goes with it. So the gear list is for pets we summoned, and this one is left as it
    -- was found. It is asked here rather than written into the pet's record because a pet that has
    -- only just appeared reads as ours for a beat while the client fills its buffs in.
    if Pet.IsCharmed() then
        PetSetupState._.holdReason = "nothing is conjured for a charmed pet, and nothing handed to it"
        PetSetupState._.nextLookMs = Time.current_time() + idleLookIntervalMs
        return false
    end

    local ordered = PetSetupState._.gearOrder ~= nil
    if (PetSetupStateConfig.GetGearing() or ordered) and (pet.gearing or ordered) then
        local job, isNeeded = chooseGear(pet)
        if job ~= nil then
            local started
            if job.carried then
                started = startGive(pet, job)
            else
                started = startGearCast(job, pet)
            end

            if started then
                -- an order stands for as long as it is still producing work
                if ordered then PetSetupState._.gearOrder = Time.current_time() + gearOrderIdleMs end
                return true
            end
        end

        -- the pet is short of something this list can still deliver, and the gem it takes is on
        -- its way back: look again next pass rather than idling on it
        if isNeeded then return false end
    end

    PetSetupState._.nextLookMs = Time.current_time() + idleLookIntervalMs
    return false
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
PetSetupState.IsEnabled = function()
    return PetSetupStateConfig.IsEnabled()
end

---Switching this off has to call off what is in the air as well: a cast is the casting service's
---now and would go on holding the chain back, and a hand-off would leave a window open.
---@diagnostic disable-next-line: duplicate-set-field
PetSetupState.SetEnabled = function(isEnabled)
    PetSetupStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        PetSetupState.CallOff()
    end
end

function PetSetupState.BuildMenu()
    PetSetupStateMenu.BuildMenu(PetSetupState)
end

return PetSetupState
