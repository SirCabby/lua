---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local CommandQueue = require("cabby.commandQueue")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local Pet = require("cabby.pet")
local PetDpsStateConfig = require("cabby.configs.petDpsStateConfig")
local PetDpsStateMenu = require("cabby.ui.states.petDpsStateMenu")
local Roles = require("cabby.roles")
local SlashCmd = require("cabby.commands.slashcmd")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How long an unanswered `/pet attack` is left before it is said again.
---
---Pacing, not giving up: the answer to the order is the pet turning round, which is a server round
---trip away, and the same order sent every frame in the meantime is nothing but spam. The order is
---repeated for as long as the pet is not on what the fight says it should be on -- there is no
---count and no window after which this state stops asking.
local sendRetryMs = 1500

---The same, for `/pet back off`.
local backOffRetryMs = 1500

---How long a posture flip is left before the same switch is flipped again. Long enough that a
---client which has not caught up yet is not flipped back and forth by us.
local postureRetryMs = 3000

---How long a pet is left alone before its switches are touched. A pet that has only just appeared
---has a window the client has not finished filling in, and a flip sent into that reads back as no
---answer at all.
local postureSettleMs = 1000

---How long a switch flipped by hand is left standing before the configured answer wins again.
---
---The grace this doctrine pays anything the player did deliberately -- the same courtesy the rest
---state pays somebody who sat down by hand. It is a grace and not a surrender: a dial set to on or
---off is a standing order, and the way to stop this state having an opinion about a switch is to
---set that dial to "leave alone", which is what it ships as.
local handGraceMs = 15000

---How long an order to send the pet in waits for something to send it at before it stops being an
---order. A pet sent at whatever turned up half a minute later is a surprise rather than an answer.
local orderTtlMs = 15000

---Fighting with the pet: sending it in, keeping it on what we are on, and calling it back.
---
---The other half of a pet, and the half that belongs in the fight. `PetSetupState` summons one and
---arms it a band above buffing, out of combat, where a long cast and a hand-off are affordable;
---this one says four words to it and reads the answers, which is all using a pet amounts to.
---
---**It sits above the rotations** (`Priorities.dps - 2`) for the reason everything above the melee
---state sits there: the melee state reports busy for as long as it is engaged, so anything below it
---is starved for the whole fight. Above it, this state takes a frame only on the pass where it
---actually says something -- an order, a flip -- and yields every other pass, so a magician's nukes
---and a beastlord's swings are one frame behind a pet order at worst.
---
---**What we are fighting is `cabby.combat`'s answer, not this state's.** It engages nothing, drops
---nothing and holds no opinion about what should be fought: `attack <id>`, the tank's assist call
---and auto-engage all mean the same thing to the pet as they do to the swing, because they are read
---from the same place. What this state adds is the pet's side of it.
---
---**The pet is sent by id.** `/pet attack <spawnid>` is MacroQuest's own extension (see
---`cabby.pet`), so nothing here touches the client's target -- which matters more than it sounds:
---the bare client command sends the pet at whatever we happen to be looking at, and a heal cast on
---somebody at the wrong moment would send the pet at a group member.
---
---**It only ever calls the pet off what this fight put it on.** A pet that has moved on to
---something else has picked that up for itself -- an add on the healer, something that turned on
---the pet while we were busy -- and calling it off that is calling it off a fight nobody else is
---having. So the record kept between passes is one number, what the fight last put the pet on, and
---it is dropped the moment the pet is not on it.
---
---**A pet can be given a different job.** The dial ships as "fight what we fight", which is all of
---the above. Set to "protect me first", one thing outranks the fight: a mob actually coming for this
---character is taken off it, by sending the pet at that mob with taunt on, and the pet goes back to
---the fight when nothing is on us any more. The whole cycle is re-derived from
---`Combat.GetUnderAttackIds` every pass -- a mob the pet has pulled off us stops being one we are
---most hated by, so it drops out of that list on its own and the pet moves to the next one or back
---to the fight. Nothing is timed and no peel is remembered: see `protectTarget`.
---
---**Taunt is the one switch that can be handed over rather than set.** The other three are a
---player's standing preference about how their pet fights; taunt is a question about the group --
---is anybody else holding what the pet is on -- and its right answer changes inside a single fight.
---A dial set to `Automatic` is answered every pass from the main tank role and what that tank is on
---(`autoTaunt` below), and the answer is enforced through exactly the same reading, flipping and
---hand-grace as a dial set by hand. It ships as "leave alone" like the rest.
---
---**Not every pet is listening, and that is read rather than assumed.** An enchanter's animation is
---a pet in every way except the one this state is made of: it takes no orders at all, and the only
---thing that changes that is the `Animation Empathy` alternate ability, whose ranks say which words
---it will hear. A *charmed* pet is the opposite -- a mob on a leash, and an ordinary pet as far as
---the commands go -- which is why an enchanter with one is a character this state can fight with.
---`cabby.pet` answers both questions (`Pet.TakesOrders`), and this state simply says nothing it
---cannot be heard saying: no order, no flip, no peel, and a page that says why instead of showing
---dials that do nothing. Nothing is concluded from silence and no attempt is counted -- what the
---client says about the pet and about this character's abilities is the whole of it.
---
---What it deliberately leaves out: an action list. A pet is not a rotation -- the pet AAs and discs
---a class fires *at* a fight (Companion's Fury and its neighbours) are ordinary damage, and the
---spell dps rotation already casts anything aimed at the mob or at the pet.
---@class PetDpsState : BaseState
local PetDpsState = {
    key = "PetDpsState",
    eventIds = {
        attack = "petattack"
    },
    _ = {
        isInit = false,
        ---the pet we are looking after, and when it turned up
        petId = nil,
        petSince = nil,
        ---what the fight last put the pet on, and when we last said so
        sentTargetId = nil,
        sentAtMs = nil,
        calledAtMs = nil,
        ---{ [switch] = when it was flipped }, the evidence window on a flip
        postureAt = {},
        ---{ [switch] = when the configured answer wins again }, the grace above
        handAt = {},
        ---{ [switch] = true } for a switch seen standing where it was asked to. What makes the
        ---next disagreement somebody's hand rather than a pet that arrived that way
        agreed = {},
        ---{ [switch] = the last answer this state gave for it, whatever produced that answer }.
        ---What lets this state tell its own mind changing from somebody's hand, and what a dial
        ---with nothing to judge from holds on to
        lastWant = {},
        ---{ [switch] = where it stood before the protect job borrowed it }, for the switches this
        ---state was told to leave alone and takes anyway while something is on us
        borrowed = {},
        ---what is on us that the pet should be taking off us, worked out once a pass
        protectId = nil,
        ---an order to send the pet in now, held as the time it stops standing
        attackOrder = nil,
        lastResult = nil,
        holdReason = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(PetDpsState.key, str)
end

---@param at number|nil when the last one was said
---@param delayMs number
---@return boolean isDue
local function due(at, delayMs)
    return at == nil or Time.current_time() - at >= delayMs
end

---------------- The pet --------------------

---Everything held between passes is about one pet, and a new one is a new pet however alike the
---two look.
local function forget()
    PetDpsState._.sentTargetId = nil
    PetDpsState._.sentAtMs = nil
    PetDpsState._.calledAtMs = nil
    PetDpsState._.postureAt = {}
    PetDpsState._.handAt = {}
    PetDpsState._.agreed = {}
    -- the answer itself is about the group and would still be true, but it is the thing that says
    -- whether the marks above mean anything, and they are gone: kept, it would read the first
    -- disagreement of a new pet as this state changing its mind about one that no longer exists
    PetDpsState._.lastWant = {}
    -- and there is nothing left to put back: a new pet arrives with all four switches off whatever
    -- the last one was set to, so what the job borrowed died with the pet it borrowed it from
    PetDpsState._.borrowed = {}
end

---@return number|nil id who the pet is, re-read every pass
local function refreshPet()
    local id = Pet.GetId()
    if id == PetDpsState._.petId then return id end

    forget()
    PetDpsState._.petId = id
    PetDpsState._.petSince = Time.current_time()

    if id == nil then
        DebugLog("The pet is gone")
    else
        DebugLog("Fighting with [" .. Pet.GetName() .. "] (" .. tostring(id) .. ")")
    end
    return id
end

---------------- Sending it in, and calling it back --------------------

---@param targetId number what to send the pet at
---@param why string what put the pet on it, in words
---@param urgent boolean whether the health gate is skipped: an order, or a mob already on us
---@return boolean isBusy
local function sendIn(targetId, why, urgent)
    local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
    if spawn.ID() == nil or spawn.Dead() then return false end

    -- aggro management, and the only setting this state has about *this* fight: a pet in before
    -- the tank has a hold of the mob is a pet with the mob on it. It answers one question -- when
    -- to join a fight the group is having -- so anything that is not that skips it: somebody
    -- asking outranks this state's judgment, and a mob already beating on us has no aggro left to
    -- manage
    if not urgent then
        local sendPct = PetDpsStateConfig.GetSendPct()
        local pct = tonumber(spawn.PctHPs())
        if pct ~= nil and pct > sendPct then
            PetDpsState._.holdReason = "waiting for it to drop below " .. tostring(sendPct) .. "%"
            return false
        end
    end

    if PetDpsState._.sentTargetId == targetId and not due(PetDpsState._.sentAtMs, sendRetryMs) then
        return false
    end

    Pet.Attack(targetId, why)
    PetDpsState._.sentTargetId = targetId
    PetDpsState._.sentAtMs = Time.current_time()
    PetDpsState._.calledAtMs = nil
    PetDpsState._.attackOrder = nil
    PetDpsState._.lastResult = "sent it at " .. (spawn.CleanName() or tostring(targetId)) ..
        " -- " .. why
    return true
end

---@param takes PetOrders what this pet is listening for
---@return boolean isBusy
local function callOff(takes)
    local sent = PetDpsState._.sentTargetId
    if sent == nil then return false end

    -- off it already: either the order took, or the pet has moved on to something of its own,
    -- and either way this fight has nothing more to say about where it is
    if Pet.GetTargetId() ~= sent then
        PetDpsState._.sentTargetId = nil
        PetDpsState._.calledAtMs = nil
        return false
    end

    -- a pet that will not take this word is left to finish what it is on: the record above is
    -- still true and still ours, and saying it anyway would be a command a second and a half
    -- forever at something that is not listening
    if not takes.backOff then return false end

    if not due(PetDpsState._.calledAtMs, backOffRetryMs) then return false end

    Pet.BackOff("the fight is over")
    PetDpsState._.calledAtMs = Time.current_time()
    PetDpsState._.lastResult = "called it off"
    return true
end

---------------- Taking things off us --------------------

---What is on us that the pet should be taking off us, or nil when there is nothing to take.
---
---The whole of the protect job, worked out from the world every pass and remembered nowhere. It
---reads `Combat.GetUnderAttackIds` -- everything at the top of whose hate list we are, which is the
---client's own answer to "this one is coming for *you*" -- and the *leaving* of that list is what
---says a peel took: a mob the pet has pulled off us is a mob we are no longer the most hated by, so
---it drops out on the next scan and the pet is free. Nothing is timed, nothing is assumed, and a
---mob that comes back to us is news again the moment it does.
---
---Three rules decide which, and they are all about not making things worse:
---
---- **The one the pet already has, while it is still on us.** Moving a pet between two mobs that
---  are both on us throws away the aggro it just built and leaves us with both.
---- **Anything the group is not already on, first.** The mob nobody else is answering is the one
---  worth a pet; what the fight is on has a group killing it.
---- **What the fight is on, only if that is all that is on us.** Then the pet is already there and
---  the peel is the taunt, which the posture below turns on.
---@return number|nil id
local function protectTarget()
    if not PetDpsStateConfig.IsProtecting() then return nil end

    local ids = Combat.GetUnderAttackIds()
    if ids == nil then return nil end

    local on = Pet.GetTargetId()
    local fightId = Combat.GetTargetId()
    local firstLive, fightIsOnUs = nil, false

    for _, id in ipairs(ids) do
        -- the window is a beat behind a corpse hitting the ground, and sending a pet at one is an
        -- order the world will not answer
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        if spawn.ID() ~= nil and not spawn.Dead() then
            if id == on then return id end
            if id == fightId then
                fightIsOnUs = true
            elseif firstLive == nil then
                firstLive = id
            end
        end
    end

    if firstLive ~= nil then return firstLive end
    return fightIsOnUs and fightId or nil
end

---------------- One pass of what the pet should be on --------------------

---@param takes PetOrders what this pet is listening for
---@return boolean isBusy
local function fightPass(takes)
    if PetDpsState._.attackOrder ~= nil and Time.current_time() > PetDpsState._.attackOrder then
        print("(pet) Nothing to send the pet at")
        PetDpsState._.attackOrder = nil
    end

    -- Something on us outranks what we are fighting, and does not wait on there being a fight at
    -- all: with auto-engage off a beating is a beating nobody agreed to, and the pet is the answer
    -- to it this state has. It is still *our* pet in *our* fight either way, so what it was sent at
    -- is recorded the same way and called off the same way.
    local protectId = PetDpsState._.protectId
    if protectId ~= nil then
        if Pet.GetTargetId() == protectId then
            PetDpsState._.sentTargetId = protectId
            PetDpsState._.calledAtMs = nil
            return false
        end
        return sendIn(protectId, "it is on us", true)
    end

    if not Combat.IsEngaged() then
        PetDpsState._.holdReason = "nothing to fight"
        return callOff(takes)
    end

    local targetId = Combat.GetTargetId()
    -- the beat between two mobs of one fight, while Combat looks for the successor. A pet still
    -- swinging at what it was sent at is exactly right for it, and there is nothing to send it at
    if targetId == 0 then return false end

    -- on it: what we said is the world's own fact now, and a pet that went in on its own is in
    -- this fight the same as one we sent -- which is what makes it ours to call off afterwards
    if Pet.GetTargetId() == targetId then
        PetDpsState._.sentTargetId = targetId
        PetDpsState._.calledAtMs = nil
        PetDpsState._.attackOrder = nil
        return false
    end

    -- a pet that will not take the order is left where it is: it is still in this fight if it went
    -- in on its own, which the read above has already recorded, and the only thing left to do about
    -- it is say so on the page
    if not takes.attack then
        PetDpsState._.holdReason = takes.why
        return false
    end

    local ordered = PetDpsState._.attackOrder ~= nil
    return sendIn(targetId, ordered and "ordered in" or "what we are fighting", ordered)
end

---------------- How it is set up to fight --------------------

---Whether the pet should be holding aggro on what it is on, answered from the group rather than
---set by hand.
---
---One question, and it is about the fight rather than about the pet: **is anybody else tanking the
---thing the pet is on?** A taunting pet standing next to a warrior is a pet pulling the mob off the
---character built to hold it; a pet that never taunts on a mob nobody else is on is a pet handing
---that mob to whoever is softest, which is usually the character whose pet it is. A dial cannot
---answer that once and be right, because it changes inside one fight -- the add the pet was sent to
---hold becomes the tank's the moment the tank picks it up, and cabby's own `defend` machinery is
---built to make that happen.
---
---**Not knowing reads as "the tank has it".** A group with a tank named in it whose target this
---client cannot see (see `Combat.GetTankTargetId`) is the case where the two ways of being wrong
---cost differently: a pet that rips a mob off a warrior is how a group wipes, and a pet that fails
---to hold an add is what the defend report and the tank's pickup already answer.
---
---**Nothing to judge is not an answer.** Mid-fight between two mobs the last answer stands rather
---than falling back to the resting one: taunt off in the beat between two mobs of one fight and on
---again afterwards is two commands that changed nothing. Out of a fight there is nothing to hold
---and the group alone decides it.
---@return boolean|nil wanted nil when there is nothing to judge and the last answer stands
---@return string why in words, for the page and /cpetdps
local function autoTaunt()
    if Roles.GetMainTank() == nil then
        return true, "no main tank in the group -- the pet holds what it is on"
    end

    -- what the pet is on, or what it is about to be on: the first swing is aggro as much as the
    -- tenth, and a pet held back by the health dial is one pass from being sent
    local mob = Pet.IsFighting() and Pet.GetTargetId() or Combat.GetTargetId()

    if mob == 0 then
        if Combat.IsEngaged() then return nil, "between targets" end
        return false, "no fight to judge -- the group has a main tank"
    end

    local tankOn = Combat.GetTankTargetId()
    if tankOn == nil then
        return false, "the main tank's target cannot be seen from here -- assuming it has this one"
    end

    if tankOn == mob then return false, "the main tank is on it" end
    return true, "the main tank is on something else"
end

---The switches an `Automatic` dial can actually be answered for, by name. `PetDpsStateConfig`
---decides which dials may offer the position; this is what answers them.
local autoAnswers = {
    taunt = autoTaunt
}

---How a pet peeling something off its owner has to be set up, whatever the dials say.
---
---**Taunt on** is the job: taunt is the only thing a pet does that takes a mob off somebody, and a
---peel by a pet that will not hold what it takes is a mob walking straight back to us. **Focus off**
---because focus is a standing order to stay on what it was sent at and ignore everything else, which
---is precisely the switching this job is made of -- whether it also refuses a direct order is a
---client question nobody here can answer, and off is the side of it that cannot break the job.
---
---Hold and greater hold are deliberately not in this table. They gate what a pet picks up *unbidden*
---and every target in this job is bidden, so flipping them would be flipping a switch for a reason
---this state cannot name -- which is the one thing the doctrine says never to do to something the
---player set.
local protectPosture = {
    taunt = true,
    focus = false
}

---This state's own answer moving is not somebody's hand: drop the marks that would otherwise read
---the next disagreement as a deliberate flip and grace it for fifteen seconds.
---
---A switch that agreed with "off" and now wants "on" -- because the tank moved, because something
---is on us, because the dial itself was turned -- has not been touched by anybody. Left standing,
---those marks are a pet not taunting the add it was just sent to hold.
---@param name string one of `Pet.toggles`
---@param wanted boolean the answer now
local function answerMoved(name, wanted)
    if wanted == PetDpsState._.lastWant[name] then return end

    PetDpsState._.agreed[name] = nil
    PetDpsState._.handAt[name] = nil
    PetDpsState._.postureAt[name] = nil
    PetDpsState._.lastWant[name] = wanted
end

---What a switch's dial resolves to on this pass, and why.
---
---Four answers in order, and only the first that applies: **the protect job**, which outranks every
---dial while something is on us; **putting back** a switch that job borrowed; the **automatic**
---answer; and the dial itself. A switch left alone with none of the above answers nothing at all,
---which is different from answering "off".
---@param name string one of `Pet.toggles`
---@param dial string one of PetDpsStateConfig.postures values
---@param remember boolean whether to write down what it worked out -- false for a caller that is
---only looking (the page, drawn every frame), so that reading the state cannot change it
---@return boolean|nil wanted nil when nothing has an opinion, or an automatic dial has nothing yet
---@return string|nil why in words, for whatever is showing this to a user
local function wantedFor(name, dial, remember)
    local wanted, why = nil, nil
    local override = protectPosture[name]

    -- A loan is only ever taken out against a switch this state was told to leave alone. A dial
    -- that has an opinion again outranks it and settles it: putting a switch back where it was
    -- found and then immediately flipping it to what the dial now says is two commands and one
    -- confusing page.
    local borrowed = PetDpsState._.borrowed[name]
    if borrowed ~= nil and dial ~= PetDpsStateConfig.postures.Leave.value then
        if remember then PetDpsState._.borrowed[name] = nil end
        borrowed = nil
    end

    if PetDpsState._.protectId ~= nil and override ~= nil then
        wanted, why = override, "protecting"

        -- A switch this state was told to leave alone is *borrowed*, not taken: where it stood is
        -- written down so the job can put it back when it is done. Without that, "leave alone"
        -- would mean "leave alone until the first add", since nothing would ever have an opinion
        -- about it again -- and a switch changed once and never changed back is exactly the way to
        -- break somebody's pet without them ever seeing it happen.
        if remember and dial == PetDpsStateConfig.postures.Leave.value
            and PetDpsState._.borrowed[name] == nil then
            local is = Pet.GetToggle(name)
            if is ~= nil and is ~= override then
                PetDpsState._.borrowed[name] = is
                DebugLog("[" .. name .. "] borrowed for protecting; it was " .. (is and "on" or "off"))
            end
        end
    elseif borrowed ~= nil then
        if Pet.GetToggle(name) == borrowed then
            -- back where the job found it, and the loan is settled
            if remember then PetDpsState._.borrowed[name] = nil end
        else
            wanted, why = borrowed, "putting it back where the protect job found it"
        end
    elseif dial == PetDpsStateConfig.postures.Auto.value then
        -- the config says which dials may offer Automatic and this says which can be answered: two
        -- lists, so the one that would act is the one that refuses when they disagree
        local answers = autoAnswers[name]
        if answers ~= nil then
            wanted, why = answers()
            -- nothing to judge from: the last answer stands, and a switch with no last answer is
            -- left alone rather than flipped on a guess
            if wanted == nil then wanted = PetDpsState._.lastWant[name] end
        end
    elseif dial ~= PetDpsStateConfig.postures.Leave.value then
        wanted = dial == PetDpsStateConfig.postures.On.value
    end

    if remember and wanted ~= nil then answerMoved(name, wanted) end
    return wanted, why
end

---One pass of the four switches: read where each one stands, flip the first that disagrees with
---the dial, and say nothing about the ones set to "leave alone".
---@param takes PetOrders what this pet is listening for
---@return boolean isBusy
local function posturePass(takes)
    -- a pet that does not take the toggles is a pet whose switches say what they say: flipping one
    -- would be a command into the void, and the read would go on disagreeing forever
    if not takes.postures then return false end

    local now = Time.current_time()
    if PetDpsState._.petSince ~= nil and now - PetDpsState._.petSince < postureSettleMs then
        return false
    end

    for _, name in ipairs(Pet.toggleOrder) do
        local dial = PetDpsStateConfig.GetPosture(name)
        local wanted, why = wantedFor(name, dial, true)

        if wanted == nil then
            -- Nothing has an opinion about this switch. For a dial set to leave alone that means
            -- forgetting it too: a switch this state stops managing must not carry a grace or an
            -- "it agreed once" into the next thing it is told. An automatic dial with nothing to
            -- answer from yet is a different silence and keeps what it has.
            if dial == PetDpsStateConfig.postures.Leave.value then
                PetDpsState._.agreed[name] = nil
                PetDpsState._.handAt[name] = nil
                PetDpsState._.postureAt[name] = nil
                PetDpsState._.lastWant[name] = nil
            end
        else
            local is = Pet.GetToggle(name)

            if is == wanted then
                PetDpsState._.agreed[name] = true
                PetDpsState._.handAt[name] = nil
                PetDpsState._.postureAt[name] = nil
            elseif is ~= nil and due(PetDpsState._.postureAt[name], postureRetryMs) then
                local handAt = PetDpsState._.handAt[name]

                if PetDpsState._.agreed[name] and handAt == nil then
                    -- it stood where it was asked to and does not any more, and the flip was not
                    -- ours: somebody did that on purpose, and a deliberate act is owed a moment
                    PetDpsState._.handAt[name] = now + handGraceMs
                    DebugLog("[" .. name .. "] was flipped by hand -- leaving it for a moment")
                elseif handAt == nil or now >= handAt then
                    Pet.FlipToggle(name, why or ("the pet page says " .. (wanted and "on" or "off")))
                    PetDpsState._.postureAt[name] = now
                    PetDpsState._.handAt[name] = nil
                    PetDpsState._.agreed[name] = nil
                    PetDpsState._.lastResult = Pet.toggles[name].display:lower() .. " " ..
                        (wanted and "on" or "off") .. (why ~= nil and (" -- " .. why) or "")
                    return true
                end
            end
        end
    end

    return false
end

---------------- Orders --------------------

---Send the pet in now, whatever the health the dial holds: somebody asking outranks this state's
---own judgment about when a pet should go in. It waits for something to send it at for as long as
---an order is still an order.
function PetDpsState.OrderAttack()
    -- an order to a pet that takes none is answered here rather than held for fifteen seconds and
    -- then reported as "nothing to send it at", which is a different and untrue thing to say. This
    -- is a read and not a command, so it is safe from the page's button
    local takes = Pet.TakesOrders()
    if not takes.attack then
        print("(pet) " .. tostring(takes.why))
        return
    end

    PetDpsState._.attackOrder = Time.current_time() + orderTtlMs
    DebugLog("The pet was ordered in")
end

---Let go of the pet: call it off what this fight put it on, and forget the order waiting its turn.
---
---The command is queued rather than run, because this is reachable from the Enabled checkbox and a
---game command from inside a render callback is the crash `CommandQueue` exists to prevent.
function PetDpsState.CallOff()
    PetDpsState._.attackOrder = nil
    -- the peel goes with it: it is worked out fresh on every pass this state gets, so a stale one
    -- left here is only something for the page to lie with while nothing is running
    PetDpsState._.protectId = nil

    local sent = PetDpsState._.sentTargetId
    PetDpsState._.sentTargetId = nil

    if sent ~= nil and Pet.TakesOrders().backOff and Pet.GetTargetId() == sent then
        CommandQueue.Push(Pet.BackOffLine())
        PetDpsState._.lastResult = "called it off"
    end
end

---------------- Status --------------------

---@return string description of what this state is doing, for /cpetdps and the menu
function PetDpsState.Describe()
    if PetDpsState._.petId == nil then return "no pet" end

    -- what a pet that is not listening is doing is its own business, and saying "the pet is on a
    -- rat" here would read as this state having put it there
    local takes = Pet.TakesOrders()
    if not takes.anything then return tostring(takes.why) end

    local protectId = PetDpsState._.protectId
    local on = Pet.GetTargetName()

    if protectId ~= nil then
        local name = mq.TLO.Spawn("id " .. tostring(protectId)).CleanName() or ("spawn " .. tostring(protectId))
        if Pet.GetTargetId() == protectId then
            return "taking " .. name .. " off us"
        end
        return "sending it at " .. name .. ", which is on us"
    end

    if on ~= nil then return "the pet is on " .. on end

    if PetDpsState._.holdReason ~= nil then
        return "holding: " .. PetDpsState._.holdReason
    end

    return "watching"
end

---@return string|nil result the last thing this state said to the pet
function PetDpsState.GetLastResult()
    return PetDpsState._.lastResult
end

---@class PetToggleFacts
---@field display string what the switch is called
---@field about string what it does, for the page
---@field want string the dial, one of PetDpsStateConfig.postures values
---@field is boolean|nil where it actually stands; nil when there is no pet to read
---@field graced boolean whether it was flipped by hand and is being left alone for a moment
---@field wanted boolean|nil where this state wants it right now, whatever decided that; nil when
---nothing has an opinion about it
---@field why string|nil what decided it, in words, when something other than the dial did
---@field taken boolean whether the protect job is overriding the dial on this switch
---@field borrowed boolean|nil where the protect job found a left-alone switch, and will put it back

---Where each of the four switches stands against its dial, for whatever is showing it to a user.
---
---**It only looks.** The answers are worked out again here rather than read off what the last pass
---decided, because the page is drawn on frames this state never gets -- a disabled state, a frame
---spent by something above it -- and a page showing a stale answer is worse than one that costs a
---few reads. Nothing it works out is written down: reading the state must not change it.
---
---The one thing it does take from the last pass is which mob the pet is peeling, which is worked
---out once a pass and would be twenty spawn reads a frame to ask again here. It is dropped when
---this state is switched off, so the page cannot show a peel that nothing is running.
---@return table facts one PetToggleFacts per switch, in `Pet.toggleOrder`
function PetDpsState.DescribeToggles()
    local facts = {}
    local taking = PetDpsState._.protectId ~= nil

    for _, name in ipairs(Pet.toggleOrder) do
        local handAt = PetDpsState._.handAt[name]
        local want = PetDpsStateConfig.GetPosture(name)
        local wanted, why = wantedFor(name, want, false)

        facts[#facts+1] = {
            key = name,
            display = Pet.toggles[name].display,
            about = Pet.toggles[name].about,
            want = want,
            is = Pet.GetToggle(name),
            graced = handAt ~= nil and Time.current_time() < handAt,
            wanted = wanted,
            why = why,
            taken = taking and protectPosture[name] ~= nil,
            borrowed = PetDpsState._.borrowed[name]
        }
    end

    return facts
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function PetDpsState.Init()
    if PetDpsState._.isInit then return end

    -- our own config, so a class that does not register this state gets no pet dials written
    PetDpsStateConfig.Init()

    Menu.RegisterState(PetDpsState)

    ToggleCommand.Register({
        key = PetDpsState.key,
        phrase = PetDpsState.eventIds.attack,
        summary = "Turns fighting with the pet on or off for listener(s)",
        about = {
            "On, the pet is sent at whatever this character is fighting and called back off it",
            "when the fight ends.",
            "Off calls the pet off what it was sent at and stops sending it -- which is also how",
            "to get the pet back mid-fight without calling the fight off."
        },
        get = PetDpsStateConfig.IsEnabled,
        set = PetDpsState.SetEnabled
    })

    local cpetdpsDocs = ChelpDocs.new(function() return {
        "(/cpetdps) Report what the pet is fighting, and how it is set up to fight",
        " -- Usage: /cpetdps",
        " -- Usage (send the pet in now, whatever the health dial says): /cpetdps in",
        " -- Usage (call the pet off and stop sending it): /cpetdps off",
        " -- Usage (what the pet is for): /cpetdps job fight|protect",
        " -- `protect` puts anything actually coming for this character above the fight: the pet",
        "    is sent at it with taunt on, and goes back to the fight once nothing is on us."
    } end )
    local function Bind_CPetDps(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cpetdpsDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            PetDpsState.SetEnabled(false)
            return
        end

        if #args > 0 and UserInput.IsTrue(args[1]) then
            PetDpsState.SetEnabled(true)
            return
        end

        if #args > 0 and args[1]:lower() == "in" then
            PetDpsState.OrderAttack()
            print("Pet: sending it in")
            return
        end

        if #args > 0 and args[1]:lower() == "job" then
            local asked = #args > 1 and args[2]:lower() or nil
            for _, known in pairs(PetDpsStateConfig.jobs) do
                if known.value == asked then
                    PetDpsStateConfig.SetJob(known.value)
                    return
                end
            end
            print("(pet) Usage: /cpetdps job fight|protect -- it is currently [" ..
                PetDpsStateConfig.GetJob() .. "]")
            return
        end

        print("Pet dps: " .. PetDpsState.Describe() .. (PetDpsState.IsEnabled() and "" or " (disabled)"))

        local result = PetDpsState.GetLastResult()
        if result ~= nil then
            print(" -- last: " .. result)
        end

        -- what kind of pet this is, and what it will hear: the first question about anything below
        -- and the one nothing else on this page answers
        local kind = Pet.DescribeKind()
        if kind ~= nil then
            print(" -- " .. Pet.GetName() .. " is " .. kind)
        end

        print(" -- job: " .. PetDpsStateConfig.GetJobDisplay(PetDpsStateConfig.GetJob()) ..
            (PetDpsStateConfig.IsProtecting()
                and " -- anything actually coming for me is taken off me first"
                or " -- the pet stays on what this character is fighting"))

        local sendPct = PetDpsStateConfig.GetSendPct()
        if sendPct >= 100 then
            print(" -- sent in as soon as there is a fight")
        else
            print(" -- sent in once what we are fighting is at or below " .. tostring(sendPct) .. "%")
        end

        for _, facts in ipairs(PetDpsState.DescribeToggles()) do
            local dial = PetDpsStateConfig.GetPostureDisplay(facts.want)
            if facts.want == PetDpsStateConfig.postures.Auto.value or facts.taken
                or facts.borrowed ~= nil then
                dial = dial .. " (" ..
                    (facts.wanted == nil and "nothing to judge yet" or (facts.wanted and "on" or "off")) ..
                    (facts.why ~= nil and (": " .. facts.why) or "") .. ")"
            end
            print(" -- " .. facts.display .. ": " .. dial ..
                ", now " .. (facts.is == nil and "no pet" or (facts.is and "on" or "off")) ..
                (facts.graced and " -- flipped by hand, leaving it for a moment" or "") ..
                (facts.borrowed ~= nil and (" -- borrowed by the protect job, and goes back to " ..
                    (facts.borrowed and "on" or "off")) or ""))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cpetdps", Bind_CPetDps, cpetdpsDocs))

    PetDpsState._.isInit = true
end

---Read where the pet is and where it should be, say at most one thing, release.
---
---There is no "the pet is fighting" mode to be stuck in: every pass re-reads who the pet is, what
---is on us, what the fight is on and what the pet is on, and the answer follows from those four.
---What is held between passes is what the world cannot say -- which mob this fight put the pet on --
---and it is dropped the moment the pet is not on it.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function PetDpsState.Go()
    local petId = refreshPet()

    local state = mq.TLO.Me.State()
    if state == "DEAD" or state == "HOVER" then
        PetDpsState._.holdReason = "dead"
        PetDpsState._.protectId = nil
        return false
    end

    if petId == nil then
        PetDpsState._.holdReason = "no pet"
        PetDpsState._.protectId = nil
        return false
    end

    PetDpsState._.holdReason = nil

    -- What this pet is listening for, before anything is said to it. An enchanter's animation is a
    -- pet in every way except the one this state is made of -- it takes no orders -- so there is
    -- nothing here to do about one, and a state with nothing to do yields the frame rather than
    -- spending it saying words nobody hears
    local takes = Pet.TakesOrders()
    if not takes.anything then
        PetDpsState._.holdReason = takes.why
        PetDpsState._.protectId = nil
        return false
    end

    -- Worked out once and read twice, by the fight and then by the switches: they have to agree
    -- about whether the pet is peeling, and a fact read twice in one pass is a fact that can
    -- disagree with itself. It is a within-pass answer and nothing carries it forward -- the next
    -- pass asks the world again. A peel is a pet *sent* somewhere, so a pet that cannot be sent has
    -- no peel to work out.
    PetDpsState._.protectId = takes.attack and protectTarget() or nil

    -- the fight first: a switch that is one pass late costs nothing, and an order that is one pass
    -- late is a pet arriving after the mob has picked somebody
    if fightPass(takes) then return true end

    return posturePass(takes)
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
PetDpsState.IsEnabled = function()
    return PetDpsStateConfig.IsEnabled()
end

---Switching this off has to let go of the pet as well as stop asking for turns: the order we gave
---it is standing, and a pet left chewing on something after being told to stop fighting with it is
---the same mistake as a stick left chasing the mob the melee state was called off.
---
---What it does *not* do is call off the fight -- `attack off` does that, and a character told to
---stop using its pet is still fighting.
---@diagnostic disable-next-line: duplicate-set-field
PetDpsState.SetEnabled = function(isEnabled)
    PetDpsStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        PetDpsState.CallOff()
    end
end

function PetDpsState.BuildMenu()
    PetDpsStateMenu.BuildMenu(PetDpsState)
end

return PetDpsState
