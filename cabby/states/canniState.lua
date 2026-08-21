---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local CanniStateConfig = require("cabby.configs.canniStateConfig")
local CanniStateMenu = require("cabby.ui.states.canniStateMenu")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local Spells = require("cabby.actions.spells")
local ToggleCommand = require("cabby.commands.toggleCommand")

---How long something this state just landed is trusted to still be on us before the buff bar is
---believed instead. A cast reports success the moment the bar closes and the effect turns up a
---server round-trip later, and for that beat "not on us yet" reads exactly like "already faded" --
---which for a slot on a duration would fire it again straight away. The same evidence window the
---dps rotation keeps, for the same reason and against the same bar.
local justLandedMs = 2000

---How long a use we have fired stays charged against the pools before the bars are believed
---instead.
---
---The evidence window for a click nobody validates. The server applies the trade the moment the
---click reaches it and pushes both numbers straight back -- mana on the change itself rather than
---on its own slow beat -- so a use is either visible within a round trip or it was never taken,
---and after that what the bars say is simply the truth. Nothing is held open by this and nothing
---is retried because of it: it only decides how long a use we have committed keeps counting
---toward the floor and the ceiling before the world's own answer takes over.
local inFlightWindowMs = 200

---The floor under two uses of ours, and it is the server's number rather than one of ours.
---
---The server arms a ten millisecond guard at the end of every cast and refuses whatever arrives
---inside it -- silently, for a click that draws no bar, so a burst fired faster than that is a
---burst with holes in it. A pass is longer than this at any frame rate anyone plays at, which is
---the point: it costs nothing at sixty frames a second and it is still there if the simulation is
---ever fast enough to fit two passes inside the guard. Set anything above a frame time and the
---burst runs at half rate for no reason.
local minUseIntervalMs = 10

---A gap this long between uses means the last burst is over, so the next one is worth a line in
---the log. Firing is a per-pass event here and a burst is dozens of them: logged one for one it
---would bury everything else in the file. The same interval covers a refusal that is still the
---same refusal -- "already casting" is worth reading once, not sixty times a second.
local burstQuietMs = 1000

---Trading health for mana.
---
---One job with four faces and no reason to treat them as four: a shaman's cannibalize line and the
---Cannibalization AA, the modulation rods a magician summons and hands round, a manastone, a
---necromancer's Death Bloom. Every one of them is the same sentence -- take hit points off, put
---mana on -- so every one of them is a slot in one list, and what a character actually owns is read
---out of the client (`Spells.ConvertsToMana` off the effects, plus whatever AAs and clickies the
---registries found) rather than declared anywhere.
---
---**Where it sits is the design.** `Priorities.canni` is above the damage rotations and below every
---job that is the fight itself. Above the rotations because mana is what they are spent out of: a
---caster that nukes to empty and then stands there has lost more casts than the beat this costs,
---and a rotation left below this band gets its frames back the moment the bar is full. Below the
---fight because a heal, a mez or a taunt is somebody dying if it waits, and no amount of mana is
---worth that. It also has to be above the melee state, which reports busy for the whole of an
---engagement -- anything under that never sees a mid-fight frame at all, and mid-fight is exactly
---when this is worth doing.
---
---**It is bounded at both ends** (see `CanniStateConfig`): no health to spend below the floor,
---nothing worth spending it on above the mana ceiling. That is what makes a state this strong safe
---to have -- it is self-limiting in a way a rotation is not, and the ceiling is what hands the
---frames back.
---
---**The health end is a latch and not a line**, and that is the one piece of remembered state here.
---A single threshold cannot work, because the trade is what moves health across the line it is
---being judged against: trade to the floor, sit down, take one regen tick back over it, stand up
---and spend that tick, sit again -- a stand and a sit per tick, and the out-of-combat regen bonus
---that makes sitting worth anything never applies for long enough to matter. So the floor is where
---trading *stops* and `resume_hp_pct` is where it *starts again*, with the state latched in between:
---`_.recovering` goes on the pass health falls under the floor and off the pass it reaches the
---resume point. Both edges are read from the world every pass and neither is timed, so it is a
---reading rather than a mode -- there is nothing here that can go stale, and nothing that needs
---rescuing if it does. What it buys is a burst of trading followed by a rest worth sitting through.
---
---**The gap is skipped where there is no rest to protect**, which is: on our feet, in a fight or
---out of one. The floor is the safety number and is asked whatever else is true; the gap above it
---is an efficiency device for medding and nothing else, and the thing it actually buys is that
---this state never *fragments* a rest -- stand up, spend a tick's worth of trade, sit back down,
---and the sitting bonus never applies for long enough to matter. A trade taken while the character
---is already standing fragments nothing: the sit that follows it is one sit and a longer one, not
---two. So the trade belongs on the way *into* a rest rather than in the middle of one, and the
---wait is owed to a sit that is happening rather than to one that might.
---
---Standing in a fight that means the floor is the only line and the character trades down to it,
---takes a heal, and trades down again -- canni-dancing, and the job this state exists for.
---Standing *after* one it means the latch that dance left behind is not cashed in as a long med:
---the character comes out of the fight at 92% health with an empty bar, and the trade it has every
---reason to take before it sits down is taken then, rather than waited out and lost to the regen
---that was going to happen anyway. Leaving a fight is only where that shows up most -- a run to
---the next pull, a zone line, the player standing the character up are all the same fact. Sitting,
---the wait is owed whatever else is true, including a fight being medded through (`restcombat`
---allows exactly that). See `restIsWorthWaitingFor`.
---
---**The floor is where trading stops, not a budget for each use.** It is asked before the use and
---not after it, which is the only reading that leaves the expensive half of the family usable: the
---Cannibalization AA takes a third to a half of a shaman's health in one click, so a floor read as
---"and where would that leave me" refuses it at every setting anyone would actually pick. A trade
---is meant to hurt; the floor says how far down the character is willing to go before it stops
---going further, and health comes back afterwards -- from a regen, from a heal, from the group's
---healer -- which is the whole shape of canni-dancing.
---
---What a use costs is still read off the spell (`Spells.HealthCost`), and it is read for two
---things: it is on the page, so the floor is set by somebody who can see that this slot costs six
---thousand hit points and that one costs fifty; and **nothing is fired that costs more health than
---the character has**. That last one is not a policy and has no dial -- a manastone has no
---safeguard of its own and the classic way to die to one is to click it once too often.
---
---**Some of these cannot be used while anything is fighting us.** A manastone is the example: its
---click carries `can_cast_in_combat = false` in the spell data, and the server refuses it whenever
---this character's *aggro count* is anything but zero -- which is neither our engagement nor the
---group's fight, but the `Auto Hater` list on the extended target window, so a manastone is fine in
---a pitched battle nothing has noticed us in and barred the moment one add turns round.
---
---The flag is asked of the spell (`Spells.CombatRestriction`) and the slot is skipped before
---anything is spent. On a client whose `Spell` TLO does not carry it -- it was not exposed until
---the members were added to `MQ2SpellType` -- the reading comes back nil, and the fallback is the
---server saying so out loud (`CastOutcome.inCombat`): one refused click per thing, remembered
---because it is a property of the thing rather than a state of ours. Either way the slot is
---**passed over rather than ending the walk**, so a barred manastone is no reason not to reach the
---cannibalize under it, and it goes on being used normally whenever nothing is on us.
---
---**A slot that leaves something on the bar is not fired again while it is there.** Death Bloom
---converts over a duration rather than on the spot, and the difference is a duration read rather
---than a different kind of slot: read off the spell, confirmed against our own buff bar every pass,
---and bridged by the evidence window above for the beat between the cast landing and the bar
---catching up. Nothing else about it is special-cased.
---
---**Nothing waits to be told a click worked.** A conversion that draws no bar cannot be interrupted
---and cannot be taken away, so there is no cast to watch -- and the cast task's own way of ending an
---instant use, giving the client a beat to complain and calling silence a yes, costs a large
---fraction of a second per click. That is the wrong price here more than anywhere else, because
---this is the one job measured in *dozens* of uses: a manastone trades sixty health for twenty mana,
---so filling a bar is fifty clicks, and a fifth of a second each is a minute of standing still.
---
---So the instant half of the family is fired straight (`Casting.Use`), one use per pass, and the
---**bars are the verification** -- which they were always going to be, since mana arriving is the
---thing this was fired for and no chat line says it better. What that costs is that the client is a
---round trip behind: fire fifty clicks at a bar that has not moved yet and the character is dead
---long before the first packet lands. So every use is **charged the moment it goes out** and the
---floor, the ceiling and the affordability check are all read against where the character *will* be
---(`_.inFlight`, `updateInFlight`). A use stops being charged when the mana it promised turns up --
---live, from the bar, usually inside a round trip -- or when the window over it runs out, which is
---the answer for a click the server never took.
---
---There is still no plan and no count: "how many clicks to reach the ceiling" is never asked,
---because it is answered one pass at a time by the reading that started the job. The burst is the
---same single decision, re-made every frame, and it ends the moment that decision changes.
---
---What this state deliberately does *not* do is keep a lich up. The necromancer and shadow knight
---lines that drain health for mana over ten minutes are buffs by every measure that matters --
---cast once, kept, wanted at full mana as much as at empty -- and the buff state is where a buff
---belongs. This is the on-demand half of the family: fired because the bar is low, and stopped
---because it is not.
---@class CanniState : BaseState
local CanniState = {
    key = "CanniState",
    eventIds = {
        -- no registered phrase may be a prefix of another, so the combat switch is not `canni`
        -- with something after it
        canni = "canni",
        canniCombat = "cannicombat",
        canniAction = "canniaction"
    },
    _ = {
        isInit = false,
        castId = nil,
        castName = nil,
        castEffect = nil, -- what to remember once it lands, for a slot on a duration
        -- the health latch: on below the floor, off at the resume point, and nowhere in between.
        -- The one thing here the world cannot answer on its own -- health sitting at 90% is "on the
        -- way down, carry on" or "on the way back up, not yet" depending only on which edge was
        -- crossed last -- and both of its edges are re-read every pass
        recovering = false,
        lastResult = nil,
        holdReason = nil,
        landed = {}, -- ["<effect>"] = trusted until
        -- Uses fired and not yet seen in the bars, oldest first, each remembering what it is
        -- worth: `{ mana = <gain>, hp = <cost> }`. This is what makes firing without waiting
        -- safe -- every use is charged against health and credited to mana the instant it goes
        -- out, so the floor and the ceiling are read against where the character *will* be
        -- rather than where the client has caught up to. Without it a burst empties the health
        -- bar past the floor before the first packet comes back
        inFlight = {},
        ---mana the bar had when the oldest unconfirmed use went out, which is what arrivals are
        ---measured against
        inFlightSeenMana = 0,
        inFlightUntilMs = 0,
        lastUseMs = 0,
        ---the refusal we last said out loud, and when, so a standing one is not repeated per pass
        lastRefusal = nil,
        lastRefusalMs = 0,
        ---whether anything at all has come back from the burst in progress
        sawArrival = false,
        ---set when a whole burst went out and the bars never moved: the next use is watched
        ---instead of fired blind, which is how the reason surfaces
        doubted = false,
        ---slots the server has refused for combat: `["<action name>"] = true`.
        ---
        ---A property of the thing rather than a state of ours, which is why it is remembered and
        ---never expires: the flag is in the spell data, it is the same on every use, and no
        ---amount of re-reading the world will produce it -- the client keeps it
        ---(`eqlib`'s `SPELL::CanCastInCombat`) and exposes no TLO for it, so the server saying so
        ---out loud is the only way to find out. Learned once, at the cost of one refused click
        ---(see `CastOutcome.inCombat`), and spent only against the same fact the server checks
        combatBarred = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CanniState.key, str)
end

---Who this state is when it asks the casting service for something.
---
---Every one of these is cast at nobody: they are self spells to the last one, so nothing is
---targeted and whatever we were fighting stays targeted.
---@return table request
function CanniState.CastRequest()
    return {
        owner = CanniState.key,
        priority = CanniState.priority,
        targetId = nil
    }
end

---------------- What the pools say --------------------

---@return number ms round trip to the server, defaulted when the client has not reported one
local function ping()
    local latency = tonumber(mq.TLO.EverQuest.Ping())
    if latency == nil or latency < 0 then return 100 end
    return math.min(latency, 2000)
end

---@return number mana absolute, 0 when it cannot be read
local function currentMana()
    return tonumber(mq.TLO.Me.CurrentMana()) or 0
end

---What everything we have fired and not yet seen is worth.
---@return number mana that will arrive, number hp that will be taken
local function committed()
    local mana, hp = 0, 0
    for _, use in ipairs(CanniState._.inFlight) do
        mana = mana + use.mana
        hp = hp + use.hp
    end
    return mana, hp
end

---Drop the uses the world has caught up with.
---
---Two ways one stops being in flight, and the first is the one that does the work: **the mana
---arrived**. That is the fact it was fired for, the client is sent it live, and each use is worth a
---known amount of it -- so a bar risen by two uses' worth is two uses confirmed, dropped in the
---same pass the packet lands rather than at the end of some window. The second is the window
---running out, which is the answer for a use the server never took: nothing arrived, so nothing is
---owed, and the bars as they stand are what this state works from. Neither is a give-up -- there is
---nothing here to give up on, only a question of whose number to believe.
---
---A regen tick between passes can flatter the first one, but only by a fraction of a use, and a use
---worth less than a regen tick is not a use this state has any business firing.
local function updateInFlight()
    local flight = CanniState._.inFlight
    if #flight == 0 then return end

    -- oldest first, and each one taken off the front as the mana it promised turns up
    local arrived = currentMana() - CanniState._.inFlightSeenMana
    while #flight > 0 and flight[1].mana > 0 and arrived >= flight[1].mana do
        arrived = arrived - flight[1].mana
        CanniState._.inFlightSeenMana = CanniState._.inFlightSeenMana + flight[1].mana
        table.remove(flight, 1)
        CanniState._.sawArrival = true
    end

    if #flight > 0 and Time.current_time() >= CanniState._.inFlightUntilMs then
        -- A whole burst went out and *nothing* came back. Firing without watching is a trade for
        -- a reading we can take instead, and here there was no reading -- so the trade is off:
        -- the next use goes through the cast task, which waits to be told why. That is not this
        -- state giving up (it fires again on the very next pass) and not a timer deciding
        -- anything (the next use decides, and clears this the moment one works). It is the one
        -- answer the bars can give that the bars cannot explain: a click the server ignored,
        -- because we were stunned, or standing in the wrong place, or holding the wrong target.
        if not CanniState._.sawArrival then
            DebugLog("Fired " .. tostring(#flight) .. " use(s) and the bars never moved -- " ..
                "watching the next one instead of firing blind")
            CanniState._.doubted = true
        end
        CanniState._.inFlight = {}
    end
end

---Where health is once everything we have fired has been paid for.
---
---Not the bar as it stands, and the difference is the whole of what makes a burst safe: a use costs
---its health the moment it is fired, whatever the client has been told yet, so a floor read off the
---raw bar is a floor that a burst walks straight through while the packets are still in the air.
---@return number pct health, as a percentage
local function hpPct()
    local pct = tonumber(mq.TLO.Me.PctHPs()) or 100

    local _, hp = committed()
    if hp <= 0 then return pct end

    local maxHp = tonumber(mq.TLO.Me.MaxHPs()) or 0
    if maxHp <= 0 then return pct end

    return math.max(0, pct - hp * 100 / maxHp)
end

---Health as the client shows it, with nothing of ours charged against it.
---
---The other half of `hpPct`, and the two are for different jobs. The projection is for decisions
---about the *next use* -- it is what keeps a burst from walking through the floor while its packets
---are still in the air, and being wrong there costs a click. This one is for deciding where health
---actually is, and being wrong there costs a rest: a use that was fired and never landed is charged
---against the projection until the window clears, and anything that latched on it stays latched
---long after the bar says otherwise.
---@return number pct health, as the client has it
local function settledHpPct()
    return tonumber(mq.TLO.Me.PctHPs()) or 100
end

---Where mana is once everything we have fired has arrived. The ceiling's side of the same reading:
---trading stops when the bar is *going* to be full, not a round trip after it already was.
---@return number pct mana, as a percentage
local function manaPct()
    local pct = tonumber(mq.TLO.Me.PctMana()) or 100

    local mana = committed()
    if mana <= 0 then return pct end

    local maxMana = tonumber(mq.TLO.Me.MaxMana()) or 0
    if maxMana <= 0 then return pct end

    return math.min(100, pct + mana * 100 / maxMana)
end

---Is there enough health in the bar to pay for one use of this?
---
---Not the floor -- the floor is a percentage the user chose and is asked separately. This is the
---one thing underneath it that is not a preference: a trade that costs more health than the
---character is carrying is a trade that kills it. A manastone is why this is here and has no dial
---next to it; it carries no safeguard of its own, and clicking one once too often is the classic
---way to die to it.
---
---An unreadable cost or an unreadable pool answers yes, which leaves the floor above as the only
---thing in the way -- the same answer this state gave before the cost could be read at all.
---@param spell any mq spell TLO
---@return boolean canAfford
local function canAfford(spell)
    local cost = Spells.HealthCost(spell)
    if cost <= 0 then return true end

    local currentHp = tonumber(mq.TLO.Me.CurrentHPs())
    if currentHp == nil then return true end

    -- what is left after the uses already in the air, for the reason this check exists at all:
    -- during a burst the bar the client is showing is several uses behind what the character has
    -- already spent
    local _, owed = committed()
    return currentHp - owed > cost
end

---Read both edges of the health latch.
---
---A Schmitt trigger and nothing cleverer: below the floor it goes on, at the resume point it goes
---off, and between the two it holds whatever it was. Run every pass, ahead of every other reading,
---so the latch cannot drift out of step with a health bar that moved while something else was
---holding the job back.
---
---**Read off the settled bar and never off the projection**, which is the one thing here that is
---easy to get wrong and expensive when it is. A use is charged against health the instant it is
---fired, before the server has agreed to it -- and a use can fail to land for reasons that have
---nothing to do with our health: refused, preempted by a stronger cast, lost to a zone. Latching on
---that reading turns a burst that was *interrupted* into a burst that spent health it never spent:
---the ledger clears a moment later, the bar reads exactly where it always did, and the job sits
---there waiting to climb to a resume point it never fell from. The projection is for deciding
---whether to fire the next use; where health *is* is a question only the bar can answer.
---
---The two edges cannot both be true at once, because the config keeps the resume point at or above
---the floor -- read the other way round this would latch on and never let go.
local function updateRecovery()
    local hp = settledHpPct()

    if hp < CanniStateConfig.GetMinHpPct() then
        if not CanniState._.recovering then
            DebugLog("Health is under the floor -- resting it back up before the next trade")
        end
        CanniState._.recovering = true
    elseif hp >= CanniStateConfig.GetResumeHpPct() then
        if CanniState._.recovering then
            DebugLog("Health is back -- trading again")
        end
        CanniState._.recovering = false
    end
end

---Is anything fighting us right now?
---
---The server's own question, asked the server's own way. A spell that carries
---`can_cast_in_combat = false` is refused against the caster's **aggro count** -- how many NPCs
---hold this character on their hate list -- which is neither our engagement nor the group's fight:
---a shaman standing untouched in the middle of a pitched battle has an aggro count of zero and can
---click its manastone all it likes, and one add peeling onto it stops that dead.
---
---`Combat.GetHaterIds` is the client's side of exactly that number: the whole `Auto Hater` list on
---the extended target window, rather than the subset coming for us *most*. Reading anything else
---here would bar the click through fights where it works, or fire it through fights where it does
---not.
---@return boolean anyHaters
local function underAttackNow()
    local haters = Combat.GetHaterIds()
    return haters ~= nil and #haters > 0
end

---Is this slot barred by the server right now for what is, or is not, fighting us?
---
---**Asked of the spell first**, which is the answer worth having: the two flags are in the spell
---data, the client keeps them, and a build whose `Spell` TLO exposes them turns this into a plain
---read -- nothing is fired, nothing is refused, and the slot is skipped before it costs anything.
---
---**Falls back to what the server has already said out loud** when the client will not answer,
---which is every MQ build before the members were added. There the only reading available is a
---refusal we have been given (`CastOutcome.inCombat`), so the first use in a fight is spent finding
---out and the rest are not. Both paths end in the same place; one of them costs a click.
---
---Either way it is spent against `underAttackNow` -- the fact the server checks -- so a slot barred
---for combat is used freely in a fight nothing has noticed us in.
---@param action ActionType
---@param spell any mq spell TLO
---@return boolean isBarred
local function barredNow(action, spell)
    local inCombat, outOfCombat = Spells.CombatRestriction(spell)

    if inCombat ~= nil then
        if inCombat then return underAttackNow() end
        if outOfCombat then return not underAttackNow() end
        return false
    end

    return CanniState._.combatBarred[action:Name()] == true and underAttackNow()
end

---Is the wait up to the resume point worth anything right now?
---
---The gap between the floor and the resume point buys exactly one thing: a sit long enough for the
---out-of-combat regen bonus to be worth having. **It is not a safety margin** -- the floor is the
---safety number and is checked whatever this answers -- so the only thing the gap can ever protect
---is a rest that is actually under way, and the posture is the whole of that reading.
---
---**On our feet it is not owed, in a fight or out of one.** What the gap stops is this state
---*fragmenting* a rest: stand up, spend a tick's worth of trade, sit down again, and the sitting
---bonus never applies for long enough to be worth having. A trade taken by a character that is
---already standing fragments nothing -- the sit after it is one sit and a longer one, not two --
---so the trade belongs on the way into the rest rather than in the middle of it.
---
---Read the other way round, that is the bug this answers: the latch is set by the trading itself
---and does not care where the character was standing when it happened, so a dance through a fight
---leaves one behind, and the moment the fight ends it turns into a long med nobody chose. The
---character stands there at 92% health with an empty bar waiting to reach a resume point for the
---sake of a rest it has not started -- and the trade it should have taken on the way into that
---rest is spent on regen instead. Leaving a fight is where it shows up most and it is not the only
---place: a run to the next pull, a zone line, the player standing the character up are the same
---fact, and all of them are read here as the one thing they have in common.
---
---**Sitting, the wait is owed whatever else is true**, which includes a fight this character has
---not joined and is legitimately medding through (`restcombat` allows exactly that). A rest that is
---really happening is worth protecting whether or not somebody nearby is swinging, and standing out
---of one is the cost the gap exists to refuse.
---
---The reading is the client's and is taken fresh every pass, both edges, with nothing remembered
---and nothing timed: the wait is owed while the character is sitting and stops being owed the frame
---it is not. Whose sit it is, and whether anybody means to keep it, is neither asked nor this
---state's business -- a character that is sitting is a character getting the bonus, and that is the
---whole of the fact in play.
---@return boolean worthWaiting
local function restIsWorthWaitingFor()
    return tostring(mq.TLO.Me.State() or "") == "SIT"
end

---Reasons to hold everything, in the order they are worth reporting.
---
---All of them are read from the world every pass and none of them is timed: health comes back, mana
---is spent, a fight ends. The moment one stops being true the trade resumes, which is why there is
---nothing here to reset and nothing to time out. The health one reads the latch `updateRecovery`
---keeps rather than the bar directly -- see there for why one line cannot do it.
---@return string|nil reason in words, nil when there is trading to be done
local function holdReason()
    -- a character with no mana bar has nothing to convert to, and the reading that says so is the
    -- maximum rather than the percentage: read the other way round, a warrior with a manastone
    -- would sit at 0% mana forever and trade its health away for nothing
    if (tonumber(mq.TLO.Me.MaxMana()) or 0) <= 0 then
        return "this character has no mana"
    end

    local ceiling = CanniStateConfig.GetMaxManaPct()
    if manaPct() >= ceiling then
        return "mana is above " .. tostring(ceiling) .. "%"
    end

    -- The floor, and it is asked unconditionally because it is the only number on this page that is
    -- about safety. Nothing below it is traded whatever else is true.
    local floor = CanniStateConfig.GetMinHpPct()
    if hpPct() < floor then
        return "health is below " .. tostring(floor) .. "%"
    end

    -- The gap above the floor is a different question and is deliberately *not* unconditional: it
    -- is an efficiency device for medding, not caution, so it is skipped wherever there is no rest
    -- for it to protect. The two waits are worth telling apart in the words as well -- under the
    -- floor is "that trade cost what it cost", and here is "and now sit still long enough for it to
    -- be worth something"
    if CanniState._.recovering and restIsWorthWaitingFor() then
        return "letting health come back to " .. tostring(CanniStateConfig.GetResumeHpPct()) .. "%"
    end

    -- The group's fight rather than our own engagement, and the difference is the whole point on
    -- the character this setting is for: a healer holds no target for the length of a fight it is
    -- standing in the middle of, so a gate on `IsEngaged` would read "no fight here" and quietly
    -- never fire.
    if not CanniStateConfig.GetInCombat() and Combat.IsGroupFighting() then
        return "we are in a fight"
    end

    return nil
end

---------------- What is already running --------------------

---How long this spell's effect lasts on us. Zero is a conversion that happens on the spot, which
---is most of them.
---@param spell any mq spell TLO
---@return number ms
local function durationMs(spell)
    return Spells.DurationMs(spell)
end

---Is this slot's effect already running on us?
---
---Only ever asked of something with a duration -- a conversion that lands on the spot has nothing
---to still be doing, and asking would answer "not on the bar" forever. Our own bar is the readable
---one (unlike another player's, which is why the buff state has a whole model for it), so this is a
---plain read every pass with one window over it: the beat between a cast reporting success and the
---effect appearing.
---@param spell any mq spell TLO
---@return boolean isRunning
local function alreadyRunning(spell)
    if spell == nil or durationMs(spell) <= 0 then return false end

    local name = spell.Name()
    if name == nil then return false end

    local trustedUntil = CanniState._.landed[name]
    if trustedUntil ~= nil and Time.current_time() < trustedUntil then return true end

    -- a readable zero is the effect having run out; ticking down, a permanent's negative, or
    -- unreadable are all still on us
    local buff = mq.TLO.Me.Buff(name)
    if buff.ID() ~= nil then return tonumber(buff.Duration()) ~= 0 end
    -- a short one sits in the song window instead, and is no less on us for it
    local song = mq.TLO.Me.Song(name)
    if song.ID() ~= nil then return tonumber(song.Duration()) ~= 0 end

    return false
end

---Drop what we remembered about an effect we have stopped seeing, so the table cannot grow for the
---length of a session.
local function prune()
    local now = Time.current_time()
    for name, until_ in pairs(CanniState._.landed) do
        if now >= until_ then CanniState._.landed[name] = nil end
    end
end

---------------- Choosing what to use --------------------

---@class CanniPick
---@field action ActionType
---@field effect string|nil what to remember once it lands, for a slot on a duration
---@field manaEach number what one use puts in the mana bar
---@field hpEach number what one use takes out of the health bar
---@field burst boolean whether this one can be fired without waiting to be told it worked

---The first slot in the list worth using right now.
---
---Walked top to bottom like every other action list, and a slot the character cannot pay for is
---*passed over* rather than ending the walk: the expensive AA at the top and the cheap spell under
---it are exactly the pairing this list is usually filled with, and with too little health for the
---first one the right answer is the second rather than nothing.
---@return CanniPick|nil pick
local function choosePick()
    for _, slot in ipairs(CanniStateConfig.GetActions()) do
        if Action.IsEnabled(slot) then
            local action = Action.GetActionType(slot)
            -- casts only: this state polls the cast it started, which a skill or a discipline has
            -- no equivalent of. Only casts are offered on the page; this is for a config that was
            -- edited by hand
            if action ~= nil and action.Subject ~= nil then
                local spell = action:Subject():Spelldata()
                if spell ~= nil and Action.GetLuaResult(slot) then
                    -- something the server will not take right now. Passed over rather than
                    -- ending the walk, exactly like one we cannot pay for: a manastone barred for
                    -- the fight is no reason not to reach the cannibalize under it, which is the
                    -- whole point of the list being ordered
                    if not barredNow(action, spell)
                        and canAfford(spell)
                        and not alreadyRunning(spell)
                        and action:IsReady(CanniState.CastRequest())
                    then
                        local manaEach = Spells.ManaGain(spell)
                        local hpEach = Spells.HealthCost(spell)
                        return {
                            action = action,
                            effect = durationMs(spell) > 0 and spell.Name() or nil,
                            manaEach = manaEach,
                            hpEach = hpEach,
                            -- Three things make a use safe to fire and forget, and all three are
                            -- read rather than declared. **No bar**, so there is nothing that can
                            -- be taken away between firing it and it going off, and nothing worth
                            -- watching for. **A readable gain**, because that is what tells us we
                            -- are done -- both the ceiling to stop at and the arrival that
                            -- confirms each use. **A readable cost**, because a burst is only
                            -- kept off the floor by charging every use the moment it goes out,
                            -- and a cost of nothing readable is indistinguishable from a cost of
                            -- nothing at all -- which on a manastone is the difference between
                            -- stopping at the floor and clicking the character to death.
                            --
                            -- Anything short of all three still fires, one at a time, through the
                            -- cast task that watches it. Slower, and correct for the same reason.
                            burst = action:Subject():IsInstant() and manaEach > 0 and hpEach > 0
                        }
                    end
                end
            end
        end
    end

    return nil
end

---Say a refusal out loud once, rather than once per pass.
---
---A refusal here is usually something standing -- a cast in the air, an item timer -- and asking
---again next pass is the whole of the response to it, so it repeats at the frame rate. Worth
---reading when it starts and when it changes; noise every time after that.
---@param name string
---@param reason string|nil
local function noteRefusal(name, reason)
    local said = "Use of [" .. name .. "] was refused: " .. tostring(reason)
    local now = Time.current_time()

    if said ~= CanniState._.lastRefusal or now - CanniState._.lastRefusalMs >= burstQuietMs then
        DebugLog(said)
        CanniState._.lastRefusal = said
    end
    CanniState._.lastRefusalMs = now
end

---Fire one use of something instant and charge it against the pools straight away.
---
---**One per pass, and the pass is the pace.** There is no loop here and nothing waits: the burst is
---simply this, run again on the next pass, for as many passes as the projected bars still say there
---is trading to be done. That is what makes a burst re-arbitrated like everything else -- a heal, a
---mez, an order over chat, all of them get their frame between two clicks, and the burst stops the
---moment the reason for it stops rather than at the end of some planned count.
---
---And it is why nothing here counts uses. The question "how many clicks to reach the ceiling" never
---has to be asked, because it is answered one click at a time by the same reading that started the
---job: fire, charge it, ask again. The count falls out, and it cannot go stale the way a plan can.
---@param pick CanniPick
---@return boolean isBusy
local function useOnce(pick)
    local now = Time.current_time()

    -- only just fired: this is still our burst and still our job, so the pass is spent holding it
    -- rather than handing it down and picking the whole thing up again
    if now - CanniState._.lastUseMs < minUseIntervalMs then return true end

    local startingBurst = now - CanniState._.lastUseMs >= burstQuietMs

    local fired, refused = Casting.Use(pick.action:Subject(), { owner = CanniState.key })
    if not fired then
        noteRefusal(pick.action:Name(), refused)
        return false
    end

    if #CanniState._.inFlight == 0 then
        CanniState._.inFlightSeenMana = currentMana()
        CanniState._.sawArrival = false
    end
    table.insert(CanniState._.inFlight, { mana = pick.manaEach, hp = pick.hpEach })
    CanniState._.inFlightUntilMs = now + ping() + inFlightWindowMs
    CanniState._.lastUseMs = now
    CanniState._.lastResult = tostring(pick.action:Name()) .. ": used"

    -- a slot on a duration is still not fired again while it is running, and firing is all the
    -- notice we get of it now that nothing waits to be told the use landed
    if pick.effect ~= nil then
        CanniState._.landed[pick.effect] = now + justLandedMs
    end

    if startingBurst then
        DebugLog("Trading health for mana with [" .. pick.action:Name() .. "]")
    end

    return true
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
function CanniState.Describe()
    if CanniState._.castId ~= nil then
        return "using " .. tostring(CanniState._.castName)
    end
    local inFlight = #CanniState._.inFlight
    if inFlight > 0 then
        return "trading (" .. tostring(inFlight) .. " in flight)"
    end
    if CanniState._.holdReason ~= nil then
        return "holding: " .. CanniState._.holdReason
    end
    return "watching"
end

---@return string|nil result what the last use did
function CanniState.GetLastResult()
    return CanniState._.lastResult
end

---@return string|nil reason why it is not trading, in words
function CanniState.GetHoldReason()
    return CanniState._.holdReason
end

---@class CanniSlotFacts
---@field cost number health one use takes, 0 when it cannot be read
---@field gain number mana one use gives, 0 when it cannot be read
---@field lasting boolean whether it converts over a duration rather than on the spot
---@field affordable boolean whether there is enough health in the bar to pay for one use
---@field combatBarred boolean whether the server has refused this one for combat, so it is only
---used while nothing is fighting us
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user.
---
---Everything here is read off the spell rather than configured, so it is also the answer to "why
---is this one not firing" -- which is otherwise a silent puzzle, and the expensive slots on this
---page are the ones most likely to sit quiet.
---@param slot Action
---@return CanniSlotFacts facts
function CanniState.DescribeSlot(slot)
    local facts = {
        cost = 0,
        gain = 0,
        lasting = false,
        affordable = true,
        combatBarred = false,
        problem = nil
    }

    -- a row being filled in has nothing to report yet
    if slot.name == nil or slot.name == "" then return facts end

    local action = Action.GetActionType(slot)
    if action == nil then
        facts.problem = "this character does not have it"
        return facts
    end
    if action.Subject == nil then
        facts.problem = "only spells, clickies and AAs can be cast"
        return facts
    end

    local spell = action:Subject():Spelldata()
    if spell == nil then
        facts.problem = "no spell data"
        return facts
    end

    facts.cost = Spells.HealthCost(spell)
    facts.gain = Spells.ManaGain(spell)
    facts.lasting = durationMs(spell) > 0
    facts.affordable = canAfford(spell)
    -- the spell's own flag where the client will give it, and what the server has told us
    -- otherwise: the page should say so before a click has been spent finding out, on a build
    -- that can
    local restrictedInCombat = Spells.CombatRestriction(spell)
    if restrictedInCombat ~= nil then
        facts.combatBarred = restrictedInCombat
    else
        facts.combatBarred = CanniState._.combatBarred[tostring(slot.name)] == true
    end

    if not Spells.ConvertsToMana(spell) then
        facts.problem = "this does not trade health for mana, so nothing here will fire it"
    end

    return facts
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function CanniState.Init()
    if CanniState._.isInit then return end

    -- our own config, so a class that does not register this state gets no list written
    CanniStateConfig.Init()

    Menu.RegisterState(CanniState)

    ToggleCommand.Register({
        key = CanniState.key,
        phrase = CanniState.eventIds.canni,
        summary = "Turns trading health for mana on or off for listener(s)",
        about = {
            "Off calls off whatever is in the air and stops starting more. The health floor and",
            "the mana ceiling on the Canni State page are what stop it the rest of the time."
        },
        get = CanniStateConfig.IsEnabled,
        set = CanniState.SetEnabled
    })

    ToggleCommand.Register({
        key = CanniState.key,
        phrase = CanniState.eventIds.canniCombat,
        summary = "Turns trading health for mana during a fight on or off",
        about = {
            "On is the case this is worth most in -- a fight is when the mana is being spent.",
            "It covers the group's fight, not only one this character has engaged."
        },
        get = CanniStateConfig.GetInCombat,
        set = CanniStateConfig.SetInCombat
    })

    ActionCommand.Register({
        key = CanniState.key,
        phrase = CanniState.eventIds.canniAction,
        summary = "Switches one of the configured health-for-mana actions on or off",
        where = "Canni State page",
        getActionLists = CanniStateConfig.GetActionLists
    })

    local ccanniDocs = ChelpDocs.new(function() return {
        "(/ccanni) Report whether this character is trading health for mana, and what it is waiting on",
        " -- Usage: /ccanni"
    } end )
    local function Bind_CCanni(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            ccanniDocs:Print()
            return
        end

        print("Canni: " .. CanniState.Describe() .. (CanniState.IsEnabled() and "" or " (disabled)"))
        print(" -- trades down to " .. tostring(CanniStateConfig.GetMinHpPct()) .. "% health and " ..
            "starts again at " .. tostring(CanniStateConfig.GetResumeHpPct()) .. "% (now " ..
            tostring(math.floor(hpPct())) .. "%), while mana is under " ..
            tostring(CanniStateConfig.GetMaxManaPct()) .. "% (now " .. tostring(math.floor(manaPct())) .. "%)" ..
            (CanniStateConfig.GetInCombat() and ", during a fight as well" or ", never during a fight"))
        for _, slot in ipairs(CanniStateConfig.GetActions()) do
            local facts = CanniState.DescribeSlot(slot)
            local note = facts.problem
            if note == nil and facts.cost > 0 then
                note = tostring(facts.cost) .. " health for " .. tostring(facts.gain) .. " mana" ..
                    (facts.affordable and "" or " -- more health than we have") ..
                    (facts.combatBarred and " -- not while anything is fighting us" or "")
            end
            print(" -- " .. tostring(slot.name) .. (Action.IsEnabled(slot) and "" or " (off)") ..
                (note ~= nil and (": " .. note) or ""))
        end
        print(" -- Last use: " .. (CanniState.GetLastResult() or "<none yet>") ..
            (#CanniState._.inFlight > 0
                and (" (" .. tostring(#CanniState._.inFlight) .. " fired, waiting on the bars)")
                or ""))
    end
    Commands.RegisterSlashCommand(SlashCmd.new("ccanni", Bind_CCanni, ccanniDocs))

    CanniState.Reset()
    CanniState._.isInit = true
end

function CanniState.Reset()
    CanniState._.castId = nil
    CanniState._.castName = nil
    CanniState._.castEffect = nil
end

---One pass: settle up what we have already fired, read the two pools, poll anything in the air, and
---use the first thing in the list that is worth using.
---
---Same shape as every other state. There is no "I am cannibalizing" mode to be stuck in: each pass
---re-reads where health and mana are and answers afresh, so a use that cannot get started is
---reconsidered on the very next one and a bar that fills up ends the job with nothing to unwind.
---A burst is not an exception to that -- it is this pass, repeated, for as long as the answer keeps
---coming back the same.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function CanniState.Go()
    -- first of all, because every reading under it is taken against the projected bars rather than
    -- the drawn ones: what has been fired and not yet seen is what the pools already owe
    updateInFlight()

    -- ahead of the holds: the latch is about where health has *been* since it was last full, so a
    -- pass spent held back by the mana ceiling still has to watch it
    updateRecovery()

    local hold = holdReason()
    CanniState._.holdReason = hold

    local castId = CanniState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        -- Still going. The pass ends here and the next one starts at the top of the chain, so
        -- everything stronger is re-asked immediately -- which is what makes holding it safe. It is
        -- deliberately not called off for a hold: every one of them is a reason not to *start*, and
        -- a cast already in the air is health that has been committed either way
        if status == nil then return true end

        if status == Casting.status.succeeded and outcome == Casting.outcomes.succeeded then
            -- watched, and it worked: whatever was eating the last burst is over
            CanniState._.doubted = false
            CanniState._.lastResult = tostring(CanniState._.castName) .. ": landed"
            local effect = CanniState._.castEffect
            if effect ~= nil then
                CanniState._.landed[effect] = Time.current_time() + justLandedMs
            end
        else
            -- The one refusal worth remembering, because it is the only one that is a fact about
            -- the *thing* rather than about this moment: a spell flagged against combat is flagged
            -- against it on every use, and nothing readable says so beforehand. Everything else
            -- here -- out of mana, not ready, out of range -- is a moment that has already changed
            -- by the next pass, and is asked again then.
            if outcome == Casting.outcomes.inCombat then
                local name = tostring(CanniState._.castName)
                if not CanniState._.combatBarred[name] then
                    DebugLog("[" .. name .. "] cannot be used while anything is fighting us -- " ..
                        "it will be skipped while something is on us and used the rest of the time")
                end
                CanniState._.combatBarred[name] = true
            end
            CanniState._.lastResult = tostring(CanniState._.castName) .. ": " .. tostring(reason)
        end

        DebugLog("Finished: " .. tostring(CanniState._.lastResult))
        CanniState.Reset()
        return true
    end

    if hold ~= nil then return false end

    prune()

    local pick = choosePick()
    if pick == nil then return false end

    if pick.burst and not CanniState._.doubted then return useOnce(pick) end

    local newCastId, refused = Casting.Cast(pick.action:Subject(), CanniState.CastRequest())
    if newCastId == nil then
        DebugLog("Use of [" .. pick.action:Name() .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Trading health for mana with [" .. pick.action:Name() .. "]")
    CanniState._.castId = newCastId
    CanniState._.castName = pick.action:Name()
    CanniState._.castEffect = pick.effect
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
CanniState.IsEnabled = function()
    return CanniStateConfig.IsEnabled()
end

---Switching it off calls off whatever is in the air: it is the casting service's now, and it would
---hold the chain back for a job we were just told to stop doing.
---@diagnostic disable-next-line: duplicate-set-field
CanniState.SetEnabled = function(isEnabled)
    CanniStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        Casting.StopFor(CanniState.key)
        CanniState.Reset()
        -- the latch is about a run of trading, and there is no run now. It is set again on the
        -- first pass after this is switched back on if health is still short, so clearing it can
        -- only lose a wait that was already over.
        --
        -- `combatBarred` is deliberately *not* cleared beside it: it is not a state of this job
        -- but a property of the thing, it costs a refused click to find out, and it is as true
        -- after the switch as it was before
        CanniState._.recovering = false
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function CanniState.BuildMenu()
    CanniStateMenu.BuildMenu(CanniState)
end

return CanniState
