local mq = require("mq")

---Why a cast ended, and the client lines that say so.
---
---Two sources decide a cast's fate and neither is enough on its own. The TLOs say *whether* we
---are still casting (`Me.Casting`); only the chat lines say *why* it stopped -- a fizzle, a
---resist and a stun all look identical from the outside. So the casting service watches
---`Me.Casting` for the shape of the cast and these events for the reason, exactly as MQ2Cast
---does, because EQ offers nothing better.
---
---Outcomes fall into three groups, and the group is what a caller acts on:
---
---- **refused** -- the cast never left the ground. Nothing was spent, and it is a real answer
---  rather than a "not yet": the waits (standing still, getting on target, memorizing) have no
---  outcome because they never give up.
---- **broken** -- the cast started and was lost. Mana is gone and the gem is on its recast. A
---  fizzle is decided at the *server's* end of the cast, so these can arrive a round trip after
---  our own cast bar has closed -- which is why a completed cast is held open waiting for one
---  rather than called a success on the spot.
---- **late** -- the cast completed and the spell landed without doing anything (resisted,
---  immune, blocked by a better buff). These lines arrive *after* the cast bar closes, which
---  is why they refine a result that has already been reported rather than producing one.
---@class CastOutcome
local CastOutcome = {
    succeeded = "succeeded",

    -- refused: nothing was spent
    notAvailable = "notAvailable",
    notReady = "notReady",
    notMemorized = "notMemorized",
    outOfMana = "outOfMana",
    missingComponents = "missingComponents",
    noTarget = "noTarget",
    wrongTarget = "wrongTarget",
    outOfRange = "outOfRange",
    cannotSee = "cannotSee",
    notStanding = "notStanding",
    silenced = "silenced",
    feared = "feared",
    stunned = "stunned",
    distracted = "distracted",
    wrongPlace = "wrongPlace",
    didNotStart = "didNotStart",

    -- broken: started and lost
    fizzled = "fizzled",
    interrupted = "interrupted",
    collapsed = "collapsed",
    aborted = "aborted",
    preempted = "preempted",
    timedOut = "timedOut",

    -- late: landed without effect
    resisted = "resisted",
    immune = "immune",
    didNotTakeHold = "didNotTakeHold"
}

local descriptions = {
    succeeded = "the cast completed",
    notAvailable = "we do not have it",
    notReady = "it is not ready yet",
    notMemorized = "it could not be memorized",
    outOfMana = "not enough mana",
    missingComponents = "missing a required component",
    noTarget = "no target",
    wrongTarget = "wrong kind of target",
    outOfRange = "target out of range",
    cannotSee = "cannot see the target",
    notStanding = "not standing",
    silenced = "silenced",
    feared = "feared",
    stunned = "stunned",
    distracted = "too distracted to cast",
    wrongPlace = "the spell does not work here",
    didNotStart = "the cast never started",
    fizzled = "fizzled",
    interrupted = "interrupted",
    collapsed = "the gate collapsed",
    aborted = "cancelled",
    preempted = "dropped for something more important",
    timedOut = "timed out",
    resisted = "resisted",
    immune = "the target was unaffected",
    didNotTakeHold = "the spell did not take hold"
}

---The lines EQ prints when a cast goes wrong, in Blech pattern form (`#*#` is a wildcard).
---
---`late = true` marks a line that arrives *after* the cast bar closes: the spell went off and
---did nothing. Everything else ends the cast where it stands -- which for the broken lines is a
---beat after the bar has already gone down, since our cast bar and the server's do not end
---together.
---
---This list is deliberately not exhaustive over every spell-specific refusal EQ has. An
---outcome we have no line for still terminates -- the cast either never starts (`didNotStart`)
---or the cast bar closes and we call it a success -- so a missing line costs us the reason,
---not the bookkeeping.
local outcomeLines = {
    -- refused
    { "Insufficient Mana to cast this spell#*#",                   CastOutcome.outOfMana },
    { "You do not have enough mana to cast this spell#*#",          CastOutcome.outOfMana },
    { "Your target is out of range, get closer#*#",                 CastOutcome.outOfRange },
    { "You cannot see your target#*#",                              CastOutcome.cannotSee },
    { "You must first select a target for this spell#*#",           CastOutcome.noTarget },
    { "You must first target a group member#*#",                    CastOutcome.noTarget },
    { "This spell only works on#*#",                                CastOutcome.wrongTarget },
    { "Spell recast time not yet met#*#",                           CastOutcome.notReady },
    { "Spell recovery time not yet met#*#",                         CastOutcome.notReady },
    { "You haven't recovered yet#*#",                               CastOutcome.notReady },
    { "You must be standing to cast a spell#*#",                    CastOutcome.notStanding },
    { "You can't cast spells while stunned#*#",                     CastOutcome.stunned },
    { "You are too distracted to cast a spell now#*#",              CastOutcome.distracted },
    { "You can't cast spells while invulnerable#*#",                CastOutcome.distracted },
    { "You *CANNOT* cast spells, you have been silenced#*#",        CastOutcome.silenced },
    { "You are missing some required components#*#",                CastOutcome.missingComponents },
    { "You need to play a#*#instrument for this song#*#",           CastOutcome.missingComponents },
    { "This spell does not work here#*#",                           CastOutcome.wrongPlace },
    { "You can only cast this spell in the outdoors#*#",            CastOutcome.wrongPlace },

    -- broken mid-cast
    { "Your spell fizzles#*#",                                      CastOutcome.fizzled },
    { "Your #*# spell fizzles#*#",                                  CastOutcome.fizzled },
    { "You miss a note, bringing your song to a close#*#",          CastOutcome.fizzled },
    { "Your spell is interrupted#*#",                               CastOutcome.interrupted },
    { "Your #*# spell is interrupted#*#",                           CastOutcome.interrupted },
    { "Your casting has been interrupted#*#",                       CastOutcome.interrupted },
    { "Your gate is too unstable, and collapses#*#",                CastOutcome.collapsed },

    -- landed without effect, reported after the cast bar closes
    { "Your target resisted the#*#spell#*#",                        CastOutcome.resisted, true },
    { "Your target looks unaffected#*#",                            CastOutcome.immune, true },
    { "Your target has no mana to affect#*#",                       CastOutcome.immune, true },
    { "Your target cannot be mesmerized#*#",                        CastOutcome.immune, true },
    { "Your target is immune to changes in its attack speed#*#",    CastOutcome.immune, true },
    { "Your target is immune to changes in its run speed#*#",       CastOutcome.immune, true },
    { "Your target is immune to snare spells#*#",                   CastOutcome.immune, true },
    { "Your spell did not take hold#*#",                            CastOutcome.didNotTakeHold, true },
    { "Your spell would not have taken hold#*#",                    CastOutcome.didNotTakeHold, true },
    { "Your spell is too powerful for your intended target#*#",     CastOutcome.didNotTakeHold, true },
    { "#*# spell did not take hold on#*#",                          CastOutcome.didNotTakeHold, true }
}

---@param outcome string
---@return string description in words, for status output and chat
function CastOutcome.Describe(outcome)
    return descriptions[outcome] or tostring(outcome)
end

---@param outcome string
---@return boolean isLate true for outcomes that only arrive after the cast bar has closed
function CastOutcome.IsLate(outcome)
    return outcome == CastOutcome.resisted or outcome == CastOutcome.immune or
        outcome == CastOutcome.didNotTakeHold
end

---Whether the cast started and was lost: the mana is gone, the gem is on its recast, and nothing
---landed on anybody.
---
---This is the group a *success* cannot be told apart from by looking, because the cast bar closes
---the same way for both -- which is why a completed cast waits to be contradicted before it is
---called a success (see `CastTask`).
---@param outcome string
---@return boolean wasBroken
function CastOutcome.WasBroken(outcome)
    return outcome == CastOutcome.fizzled or outcome == CastOutcome.interrupted or
        outcome == CastOutcome.collapsed or outcome == CastOutcome.timedOut
end

---Whether the cast was refused before anything was spent, so retrying costs nothing but the
---frame it takes to ask again.
---@param outcome string
---@return boolean wasRefused
function CastOutcome.WasRefused(outcome)
    return outcome ~= CastOutcome.succeeded and not CastOutcome.IsLate(outcome) and
        not CastOutcome.WasBroken(outcome)
end

---Register an mq.event per line above.
---
---Called once, from the casting service's Init rather than at require time, so requiring this
---module has no side effects on the client. The handler is called with the outcome and whether
---it is a late line; deciding whether a cast is even in flight is the service's business, not
---this module's.
---@param onOutcome fun(outcome: string, isLate: boolean, line: string)
function CastOutcome.RegisterEvents(onOutcome)
    for index, entry in ipairs(outcomeLines) do
        local pattern, outcome, isLate = entry[1], entry[2], entry[3] == true
        mq.event("cabbyCastOutcome" .. tostring(index), pattern, function(line)
            onOutcome(outcome, isLate, line)
        end)
    end
end

---@return number count of registered outcome lines, for tests
function CastOutcome.LineCount()
    return #outcomeLines
end

return CastOutcome
