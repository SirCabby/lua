---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

---What the client will say about this character's pet, and the words it takes back.
---
---Not a service and not a state: it owns no frames and decides nothing. It is the one place that
---knows how the *client* talks about a pet, so that the two callers who need that -- the pet dps
---state, which fights with the pet, and the flee state, which has to drop it while the whole dps
---band is starved -- are not each carrying their own copy of the verbs.
---
---**Not every pet is listening.** An enchanter's animation hears none of the words below, and a
---charmed pet hears all of them, so "what kind of pet is this" has to be answered before anything
---is said to one -- see `Pet.GetKind` and `Pet.TakesOrders`. That answer is the one thing here
---held between passes, because it is a fact about *one* pet that cannot change while that pet
---lives: a mob does not stop being charmed and stay our pet, and an animation does not become an
---elemental. It is keyed by spawn id and dies with the pet it is about.
---
---**Sending the pet is the one order that names its target.** `/pet attack <spawnid>` is
---MacroQuest's own extension of the client's command (see `MQCommands.cpp`, `PetCmd`), and it is
---the reason this state needs no target of its own: the client's bare `/pet attack` sends the pet
---at whatever *we* are looking at, so without the id a pet order would have to snap the target
---first and would fight the heal state for it. Everything else here is the client's own.
---
---**The postures are toggles, not settings.** This client's pet command list (`ePetCommandType`
---in eqlib) carries `PCT_ToggleTaunt`, `PCT_ToggleHold`, `PCT_ToggleGHold` and `PCT_ToggleFocus`
---and no on/off forms at all -- so there is no way to *say* "taunt off", only to flip it and read
---back what happened. That is why every caller here reads first and flips second, and why the
---reads matter as much as the commands.
---@class Pet
local Pet = {
    key = "Pet",
    ---The four per-pet switches this script has anything to say about, each with the word the
    ---client answers to and the read that says where it stands. They are per *pet*: a new one
    ---arrives with all of them off, whatever the last one was set to.
    toggles = {
        taunt = {
            key = "taunt",
            display = "Taunt",
            command = "taunt",
            about = "The pet tries to hold aggro on what it is fighting. Off is what a pet fighting alongside a tank wants.",
            read = function() return mq.TLO.Me.Pet.Taunt() end
        },
        hold = {
            key = "hold",
            display = "Hold",
            command = "hold",
            about = "The pet attacks nothing until it is sent, and does not pick up what turns on us. It still obeys an order to attack, which is what makes it the switch for a pet that is told where to go.",
            read = function() return mq.TLO.Me.Pet.Hold() end
        },
        ghold = {
            key = "ghold",
            display = "Greater hold",
            command = "ghold",
            about = "Hold that survives the pet being hit: it will not fight back on its own even while something is beating on it.",
            read = function() return mq.TLO.Me.Pet.GHold() end
        },
        focus = {
            key = "focus",
            display = "Focus",
            command = "focus",
            about = "The pet stays on what it was sent at and ignores everything else, adds included.",
            read = function() return mq.TLO.Me.Pet.Focus() end
        }
    },
    _ = {
        ---the pet the answer below is about, when it turned up, and when we last asked
        petId = nil,
        since = nil,
        lookedAt = nil,
        ---what kind of pet it is, once that is settled
        kind = nil
    }
}

---The order the toggles are shown and walked in: the two that decide whether the pet fights at
---all, then the two that decide what it fights.
Pet.toggleOrder = { "hold", "ghold", "taunt", "focus" }

---The kinds of pet a character can end up standing next to. Two of them take every word in this
---file and the third takes none of them, which is the whole reason this exists.
---
---**An animation is an enchanter's summoned pet, and it does not take orders.** It is a pet in
---every other way -- it fights, it follows, the client keeps a pet window and four switches for it
----- but the words below are not among the things it answers to. The one thing that changes that
---is `Animation Empathy`, an alternate ability whose entire purpose is buying an enchanter the
---right to talk to one, and whose ranks say exactly which words: guard and follow at one, attack at
---two, back off and the toggles at three (see `animationEmpathy`).
---
---**A charmed pet is a mob on a leash, and it takes everything.** It is somebody else's monster
---held by a spell, so it arrives with a level, a name and a class of its own -- but as far as the
---pet commands go it is an ordinary pet, which is why an enchanter with one is a character this
---script can actually fight with.
---
---**Everything else is summoned**: an elemental, a warder, a skeleton, a familiar. The pet the rest
---of this script was written for.
Pet.kinds = {
    summoned = { key = "summoned", display = "summoned" },
    animation = { key = "animation", display = "an animation" },
    charmed = { key = "charmed", display = "charmed" }
}

---What holds a charmed pet, as EverQuest's own effect number (`SPA_CHARM`, 22, out of `eqlib`'s
---`Spells.h`). Read off the pet's own buffs rather than guessed at from a name or a level, because
---the spell holding it *is* what makes a charmed pet charmed -- and because the client will show us
---a pet's buffs in full, which it will not do for anything else in the zone.
local charmSPA = 22

---How many buff slots to walk. The pet window's own count is not readable from here, so this is the
---client's maximum; empty slots read as nothing and cost one call each.
local petBuffSlots = 30

---How long a new pet is given to have its buff list filled in before "nothing is holding it" is
---taken as the answer.
---
---An evidence window and not a give-up timer: the client is a beat behind a pet appearing, and a
---charm read in that beat would answer "not charmed" about a pet that plainly is. Nothing is
---withheld while it runs -- the answer during it is the one a pet of ours would have, which is what
---this almost always is -- it only stops that answer being *written down* until the world has had
---its say.
local charmSettleMs = 1000

---How often the charm question is asked again while it is still open. Thirty reads is cheap once
---and silly forty times a second.
local charmLookMs = 250

---The ranks of `Animation Empathy` and what each one buys, which is the client's own answer to
---which of these words an animation is listening for. Rank 1 is guard and follow -- neither of
---which this script ever says -- so it is not in the table: as far as cabby is concerned it changes
---nothing.
local animationEmpathy = {
    name = "Animation Empathy",
    attack = 2,
    backOff = 3,
    postures = 3
}

---@param str string
local function DebugLog(str)
    Debug.Log(Pet.key, str)
end

---------------- What the client says --------------------

---@return number|nil id nil when there is no pet
function Pet.GetId()
    local id = tonumber(mq.TLO.Me.Pet.ID())
    if id == nil or id < 1 then return nil end
    return id
end

---@return string name what to call it, for status output
function Pet.GetName()
    return mq.TLO.Me.Pet.CleanName() or "my pet"
end

---What the pet is on. The client keeps this as the pet's "who it is following", which is the same
---thing for a pet: what it is chasing is what it is hitting.
---@return number targetId 0 when it is on nothing
function Pet.GetTargetId()
    local id = tonumber(mq.TLO.Me.Pet.Target.ID())
    if id == nil or id < 1 then return 0 end
    return id
end

---@return string|nil name what it is on, for status output
function Pet.GetTargetName()
    return mq.TLO.Me.Pet.Target.CleanName()
end

---Is the pet on something right now?
---
---The client answers this out of the same field the target above is read from, so "on us" -- a pet
---trailing its owner around -- would read as a fight if it ever landed there. Excluded here rather
---than at every caller, because a pet that is following us is the one thing certainly not worth
---calling off.
---@return boolean isFighting
function Pet.IsFighting()
    if mq.TLO.Me.Pet.Combat() ~= true then return false end

    local id = Pet.GetTargetId()
    return id > 0 and id ~= (tonumber(mq.TLO.Me.ID()) or 0)
end

---------------- What kind of pet --------------------

---Is there a charm holding it?
---@return boolean seen
local function charmSeen()
    for slot = 1, petBuffSlots do
        local buff = mq.TLO.Me.Pet.Buff(slot)
        if buff() ~= nil and buff.HasSPA(charmSPA)() == true then return true end
    end
    return false
end

---What a pet of *ours* is, which is a question about this character rather than about the pet: an
---enchanter summons animations and nobody else summons one.
---@return string|nil kind nil while the client will not say what class this character is, so that
---a pet is never filed as something it might not be
local function ourKind()
    local class = mq.TLO.Me.Class.ShortName()
    if class == nil then return nil end
    return class == "ENC" and Pet.kinds.animation.key or Pet.kinds.summoned.key
end

---What kind of pet is standing here.
---
---One reading and one fact about this character, in that order: **a charm on it** says charmed
---whatever class we are, and everything else is ours and follows from the class. The reading comes
---first because it is the only one that can be *wrong* in the direction that matters -- an
---enchanter's charmed pet mistaken for an animation is a pet this script would refuse to fight
---with -- and it is positive evidence either way round: nothing here concludes "charmed" from the
---absence of something.
---
---Answered once per pet and then remembered, because a pet does not change kind: a charm that
---breaks does not leave us a summoned pet, it leaves us no pet at all, and the id goes with it.
---@return string|nil kind one of `Pet.kinds` keys; nil when there is no pet
function Pet.GetKind()
    local id = Pet.GetId()

    if id ~= Pet._.petId then
        Pet._.petId = id
        Pet._.since = Time.current_time()
        Pet._.lookedAt = nil
        Pet._.kind = nil
    end

    if id == nil then return nil end
    if Pet._.kind ~= nil then return Pet._.kind end

    local now = Time.current_time()
    if Pet._.lookedAt == nil or now - Pet._.lookedAt >= charmLookMs then
        Pet._.lookedAt = now
        if charmSeen() then
            Pet._.kind = Pet.kinds.charmed.key
            DebugLog("[" .. Pet.GetName() .. "] is charmed")
            return Pet._.kind
        end
    end

    local ours = ourKind()
    if ours == nil then return nil end

    -- nothing holding it, and the client has had its moment to say otherwise: it is one of ours,
    -- and which of ours is not a thing that needs asking again
    if now - (Pet._.since or now) >= charmSettleMs then
        Pet._.kind = ours
        DebugLog("[" .. Pet.GetName() .. "] is " .. ours)
    end

    return ours
end

---@return boolean isCharmed whether this pet is a mob held by a charm rather than one we made
function Pet.IsCharmed()
    return Pet.GetKind() == Pet.kinds.charmed.key
end

---@return number rank of `Animation Empathy`, 0 when this character does not have it
local function empathyRank()
    local aa = mq.TLO.Me.AltAbility(animationEmpathy.name)
    if aa.ID() == nil then return 0 end
    return tonumber(aa.Rank()) or 0
end

---@class PetOrders
---@field attack boolean whether `/pet attack <id>` means anything to this pet
---@field backOff boolean whether `/pet back off` does
---@field postures boolean whether the four switches do
---@field anything boolean whether any of the three does
---@field why string|nil what is not being heard and what would fix it, in words

---Which of the words in this file this pet is listening for.
---
---Everything but an animation hears all of them. An animation hears whatever its owner has bought
---the right to say -- so this is a read of the world (the AA and its rank) rather than a rule about
---enchanters, and an enchanter who trains the ability mid-session is being obeyed on the next pass
---without anything having to notice.
---
---**Nothing is concluded from silence.** There is no counting of orders that went unanswered and no
---window after which a pet is written off as deaf: the client says what kind of pet this is and
---what this character can say to one, and that is the whole of it.
---@return PetOrders takes
function Pet.TakesOrders()
    local kind = Pet.GetKind()

    if kind == nil then
        -- two different silences: no pet at all, and a client that has not yet said enough about
        -- this one to know what it is. Neither is a pet to be saying things to
        return { attack = false, backOff = false, postures = false, anything = false,
            why = Pet.GetId() == nil and "there is no pet"
                or "what kind of pet this is cannot be read yet" }
    end

    if kind ~= Pet.kinds.animation.key then
        return { attack = true, backOff = true, postures = true, anything = true }
    end

    local rank = empathyRank()
    local takes = {
        attack = rank >= animationEmpathy.attack,
        backOff = rank >= animationEmpathy.backOff,
        postures = rank >= animationEmpathy.postures
    }
    takes.anything = takes.attack or takes.backOff or takes.postures

    if not takes.attack then
        takes.why = "it takes no orders without Animation Empathy" ..
            (rank > 0 and (" -- rank " .. tostring(rank) ..
                " buys guard and follow, which is nothing this script says") or "")
    elseif not takes.postures then
        takes.why = "Animation Empathy rank " .. tostring(rank) ..
            " sends it in; calling it off and the four switches want rank " ..
            tostring(animationEmpathy.postures)
    end

    return takes
end

---What this pet is and what it will hear, in words, for a page or a report.
---@return string|nil sentence nil when there is no pet
function Pet.DescribeKind()
    local kind = Pet.GetKind()
    if kind == nil then return nil end

    local said = Pet.kinds[kind].display
    local why = Pet.TakesOrders().why
    return why ~= nil and (said .. " -- " .. why) or said
end

---Where one of the four switches stands.
---@param name string one of `Pet.toggles`
---@return boolean|nil isOn nil when there is no pet, or the client will not say
function Pet.GetToggle(name)
    local toggle = Pet.toggles[name]
    if toggle == nil then return nil end
    if Pet.GetId() == nil then return nil end

    local value = toggle.read()
    if type(value) ~= "boolean" then return nil end
    return value
end

---------------- The words --------------------

---The command lines, as text. For a caller that must not run one itself -- anything drawn in
---ImGui, where a game command is the crash-to-desktop hazard `CommandQueue` exists for -- these
---are what gets pushed onto the queue instead.

---@param id number spawn id of what the pet should attack
---@return string line
function Pet.AttackLine(id)
    return "/pet attack " .. tostring(id)
end

---@return string line
function Pet.BackOffLine()
    return "/pet back off"
end

---@param name string one of `Pet.toggles`
---@return string|nil line
function Pet.ToggleLine(name)
    local toggle = Pet.toggles[name]
    if toggle == nil then return nil end
    return "/pet " .. toggle.command
end

---------------- Saying them --------------------

---These run game commands, so the render-callback rule applies: states and services only, never
---from ImGui. Each one only ever *says* something -- what the pet then does is read back off the
---client by whoever asked, on a later pass.

---@param line string
---@param why string for the debug log, so a pet's orders read in words
local function say(line, why)
    DebugLog(line .. " -- " .. why)
    mq.cmd(line)
end

---Send the pet at something, by spawn id, whatever this character is targeting.
---@param id number
---@param why string
function Pet.Attack(id, why)
    say(Pet.AttackLine(id), why)
end

---@param why string
function Pet.BackOff(why)
    say(Pet.BackOffLine(), why)
end

---Flip one of the four switches. There is no way to set one: read it first, and only flip what
---disagrees.
---@param name string one of `Pet.toggles`
---@param why string
function Pet.FlipToggle(name, why)
    local line = Pet.ToggleLine(name)
    if line == nil then return end
    say(line, why)
end

return Pet
