---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Giving = require("utils.Giving.Giving")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
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

---How long a pet has to have been gone before it is replaced.
---
---A pet vanishes for two reasons and the world does not say which: it died, or somebody let it
---go. This is the grace that keeps `/pet get lost` from being undone on the next frame -- the same
---courtesy the rest state pays a player who stood up by hand. It is deliberately short, because
---the common case is a pet that died and a character that would rather have another one; anybody
---who means to play without a pet has the switch.
local resummonGraceMs = 5000

---How long an order to summon waits for a gem before it stops being an order. A pet asked for
---half a minute ago and summoned now is a surprise rather than an answer; the standing switch is
---what covers "whenever you can".
local summonOrderTtlMs = 15000

---How long an order to gear the pet waits with nothing happening before it is treated as
---finished. Gearing a pet is not one cast, it is "give it everything on the list", so it ends
---when a run of casts and hand-offs goes quiet rather than on the first pass that finds nothing
---to start -- which is also what a recovering gem looks like.
local gearOrderIdleMs = 15000

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
        ---the hand-off we asked the giving service for
        giveId = nil,
        giveSlot = nil,
        giveItemName = nil,
        givePetId = nil,
        giveRecord = nil,
        ---somebody else's pet we were asked to kit out (`petgear`), in the same shape our own
        ---pet's record has plus who asked and when the ask stops standing
        request = nil,
        ---the pet we are looking after: { id, name, gearing, given, summoned }
        pet = nil,
        ---the pet that was already standing here when the script started, which is never geared
        ---on a guess: see `refreshPet`
        startupPetId = nil,
        ---a summon of ours landed, so the next pet to appear is one we made
        ourPetComing = false,
        ---when we first noticed there was no pet, for the grace above
        goneSinceMs = nil,
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

---Who the pet is, re-derived every pass.
---
---A pet is its spawn id, and a new id is a new pet however alike the two look -- so the record of
---what has been handed over lives and dies with that id, and nothing else needs clearing.
---@return table|nil pet
local function refreshPet()
    local id = tonumber(mq.TLO.Me.Pet.ID())

    if id == nil or id < 1 then
        if PetSetupState._.pet ~= nil then
            DebugLog("The pet is gone")
            PetSetupState._.pet = nil
        end
        if PetSetupState._.goneSinceMs == nil then
            PetSetupState._.goneSinceMs = Time.current_time()
        end
        return nil
    end

    PetSetupState._.goneSinceMs = nil

    local pet = PetSetupState._.pet
    if pet ~= nil and pet.id == id then return pet end

    local ours = PetSetupState._.ourPetComing
    PetSetupState._.ourPetComing = false

    -- the pet that was standing here when the script started is left exactly as we found it, and
    -- the empty-hands guess is not even asked. A reload is not a reason to re-arm a pet that has
    -- been fighting all evening: what it was handed is remembered nowhere the client can be asked
    -- about (`Equipment` is a weapon model and says nothing about anything a pet does not wield),
    -- so a script that has just started knows nothing about this pet and the honest answer to
    -- "does it need gear" is "ask me". `gearpet` and the page's button are that ask.
    --
    -- Any *other* unsummoned pet is one that turned up while we were watching -- the player cast
    -- it by hand -- and that one is plainly new, so the hands are worth reading.
    local wasHereAtStartup = id == PetSetupState._.startupPetId

    pet = {
        id = id,
        name = mq.TLO.Me.Pet.CleanName() or "my pet",
        gearing = ours or (not wasHereAtStartup and handsAreEmpty()),
        adopted = not ours,
        wasHereAtStartup = wasHereAtStartup,
        given = {},
        summoned = {}
    }
    PetSetupState._.pet = pet

    DebugLog("Looking after [" .. pet.name .. "] (" .. tostring(pet.id) .. ")" ..
        (pet.gearing and "" or (wasHereAtStartup and " -- already here when the script started, leaving it as it is"
            or " -- already equipped, leaving it as it is")))
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
---@return table|nil pick { action, slot }
local function chooseSummon()
    for _, slot in ipairs(PetSetupStateConfig.GetActions()) do
        if Action.IsEnabled(slot) and dueNow(slot) then
            local action, spell = readSlot(slot)
            if action ~= nil and Spells.SummonsPet(spell) and Action.GetLuaResult(slot) then
                -- a pet spell aims itself, so it is cast at nobody: EQ puts the pet beside us
                -- with nothing targeted, and targeting for one would drop whatever we were
                -- looking at to no purpose
                if action:IsReady(PetSetupState.CastRequest(nil)) then
                    return { action = action, slot = slot }
                end
            end
        end
    end

    return nil
end

---The first gear slot this pet is short of, and what to do about it: hand over one we are
---carrying, or conjure one first.
---
---A slot that is short but cannot be acted on right now -- nothing carried and the gem still
---recovering -- says nothing about the next slot down, so the walk carries on rather than
---stopping on it.
---@param pet table
---@return table|nil job { slot, action, itemId, carried }
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
                        return { slot = slot, action = action, itemId = itemId, carried = true }
                    end

                    -- never conjure more of a thing than this pet is owed. The cast succeeding
                    -- and the item not turning up is the one failure no retry can fix, and this
                    -- is what bounds it: the pet is owed two daggers, so two are ever summoned
                    -- for it, and the row says what happened to them
                    if (pet.summoned[key] or 0) < wanted and action:IsReady(PetSetupState.CastRequest(nil)) then
                        return { slot = slot, action = action, itemId = itemId, carried = false }
                    end
                end
            end
        end
    end

    return nil
end

---------------- Starting things --------------------

---@param pick table from chooseSummon
---@return boolean isBusy
local function startSummon(pick)
    local castId, refused = Casting.Cast(pick.action:Subject(), PetSetupState.CastRequest(nil))

    if castId == nil then
        DebugLog("Summon of [" .. pick.action:Name() .. "] was refused: " .. tostring(refused))
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
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandon(code)
    if code == "fighting" then return "a fight started" end
    if code == "dead" then return "we died" end
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
local function requestPass()
    local request = PetSetupState._.request
    if request == nil then return false end

    local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
    if spawn.ID() == nil or spawn.Dead() then
        print("(petgear) " .. request.speaker .. "'s pet is gone")
        PetSetupState._.request = nil
        return false
    end

    local job = chooseGear(request)
    if job == nil then return false end

    local started
    if job.carried then
        started = startGive(request, job)
    else
        started = startGearCast(job, request)
    end

    if not started then return false end

    -- the ask stands for as long as it is still producing work
    request.expires = Time.current_time() + gearOrderIdleMs
    return true
end

---------------- Orders --------------------

---Summon a pet now: the switch and the grace are the state's own judgment, and somebody asking
---outranks both. It waits for a gem for as long as an order is still an order.
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
        " -- An order, so it does not wait out the grace a pet that was let go is given, and it",
        "    stands for fifteen seconds while a gem recovers before it lapses."
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
            local abandon = reasonToAbandon(code)
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
    if requestPass() then return true end

    if pet == nil then
        local ordered = PetSetupState._.summonOrder ~= nil

        if PetSetupStateConfig.GetSummoning() or ordered then
            -- a pet that vanished may have been let go on purpose, so give the player a moment
            -- before replacing it. An order says the moment is not needed
            local goneSince = PetSetupState._.goneSinceMs or Time.current_time()
            if ordered or Time.current_time() - goneSince >= resummonGraceMs then
                local pick = chooseSummon()
                if pick ~= nil and startSummon(pick) then return true end
            end
        end

        PetSetupState._.nextLookMs = Time.current_time() + idleLookIntervalMs
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
        local job = chooseGear(pet)
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
