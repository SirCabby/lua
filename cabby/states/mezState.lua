---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Menu = require("cabby.ui.menu")
local MezStateConfig = require("cabby.configs.mezStateConfig")
local MezStateMenu = require("cabby.ui.states.mezStateMenu")
local Mobs = require("cabby.mobs")
local SlashCmd = require("cabby.commands.slashcmd")
local Spells = require("cabby.actions.spells")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")

---How long something this state just landed is trusted before the world is believed instead. A
---cast reports success the moment the cast bar closes; the mez shows up in the mob's buff list a
---server round-trip later, and for that beat "nothing on it" reads exactly like "it broke". Once
---the window has passed, what the world shows is the answer.
local justLandedMs = 2000

---How long the mobs a break was called on are given to say which of them it was, before every one
---of them is treated as loose.
---
---The awakened line carries a *name*, and a camp usually holds more than one mob wearing it, so
---what the line narrows to is a group. The mobs settle it themselves by moving (`settleSuspicions`,
---and the animation read beside it), and this is how long that is allowed to take: `cabby.mobs`
---samples position and heading four times a second, and a mob handed back its own will faces
---whoever it is about to hit inside one of those samples. Four samples is generous for that, and
---still shorter than the cast a wrong guess would spend.
---
---**An evidence window, not a give-up timer.** What happens at the end of it is not that the work
---is dropped -- it is that every suspect is treated as loose after all, because a break nobody owned
---up to is still a break and a redundant mez is the safe way to be wrong.
local suspicionSettleMs = 1000

---The animations a mob shows while it is standing there doing nothing -- which is what a mezzed
---mob does, and the only thing about a mez that the client will report for a spawn we are not
---looking at.
---
---**Taken from `macros/bots/mez.mac`**, where this same list has been the mez-broke test on this
---server for years. It is worth saying why it is needed at all, since the client also keeps the
---mez itself: `Spawn.CachedBuff` reports what was on the mob when we last looked and counts it
---down honestly, but *nothing tells it about a break*. A mez that a rogue's backstab ended still
---sits in the cache with two minutes left. So the cache answers "how long has it got" and this
---answers "is it still under" -- and it is the second question that a mez state exists for.
local passiveAnimations = {
    [25] = true,   -- tread_water
    [26] = true,   -- stand_animated2
    [32] = true,   -- stand2
    [71] = true,   -- stand1
    [72] = true,   -- stand_animated1
    [110] = true,  -- stand3
    [111] = true,  -- stand_animated3
    [127] = true   -- tread_water2
}

---What a slot in the control list is for, read off the spell and never configured.
local roles = {
    mez = "mez",        -- it mesmerizes: `SPA_ENTHRALL`
    stun = "stun",      -- it stuns: `SPA_STUN`
    soften = "soften"   -- anything else in this list: the debuff that gets a mez to land
}

---How a mez reaches its mob.
local deliveries = {
    single = "single",      -- one mob, targeted
    targeted = "targeted",  -- an AE that goes off around whatever it is aimed at
    centred = "centred"     -- an AE that goes off around us
}

---Holding the fight still: mezzing the adds, keeping them mezzed, and stunning whatever has
---turned around and reached us.
---
---**This is the state the priority chain was drawn for.** A mez that waits its turn behind a
---damage rotation is a mez that lands after the add has already killed somebody, so it sits at
---`Priorities.mez` -- above tanking, above both dps states, below healing and the passive band.
---Everything below it is starved for exactly as long as a mez is in the air and not one frame
---longer, which the casting service's priority floor does without this state having to hold
---anything.
---
---**What is in the fight is not this state's question.** `cabby.mobs` answers it, from four angles
---at once, and this state reads the roster the way the dps states read the engagement. That split
---is deliberate: "which mobs are here" is a fact several jobs need (a puller's leash, a tank's add
---sweep) and exactly the fact a crowd control state must not be quietly guessing at on its own.
---
---**What a slot in the list is for is read off the spell.** A spell that mesmerizes is a mez, one
---that stuns is a stun, and anything else in the list is a softener -- the resist debuff cast at a
---mob so the mez after it takes. Nothing is labelled by hand, for the reason nothing else in cabby
---is: a tash filed as a mez is a page that looks configured and a camp full of loose adds.
---
---**Two questions decide every mob, every pass, and neither is a timer.**
---
---1. *Is it still under?* Four readings, strongest first: our own mez landing a beat ago (which
---    bridges the round trip before the client has been told anything); the world saying it woke up
---    (the awakened line, and the mob doing something other than standing there); and failing both,
---    the client's own cached reading of the mez, which ages by itself. The third of those is the
---    one every other mez script leaves out and the one that matters most -- a cached mez counts
---    down happily through a break it was never told about.
---2. *Is it worth mezzing?* Not what the group is killing, not something already immune to it, not
---    something already hurt past the point of being worth taking out of reach of the damage in the
---    air, and not something out of range or out of sight -- which the casting service answers for
---    us, since a slot's `IsReady` is judged against the mob the cast would be aimed at.
---
---**An add is only an add beside something being killed**, which is why both answers above stop at
---the same place: a *new* mob is chosen only once something has been named first to kill
---(`namedKill` -- the main tank's target, or our own engagement where the tank's cannot be seen --
---and the mob it names is itself never mezzed). Before that there is the pull walking in, which is
---one mob and nobody's add (`isUnfoughtPull`), and there is a pile of mobs with no telling which
---one the tank is about to hit -- and mezzing the wrong one of those is the tank taunting a mob it
---must not break. What this state has *already* mezzed is exempt from both, so a refresh never
---waits on the beat between one target and the next.
---
---Nothing is remembered that the world can be asked about, and the two things that are -- this
---spawn cannot be mezzed, this spawn resisted -- are what the world *said* and are dropped the
---moment it dies, we zone, or the group runs.
---@class MezState : BaseState
local MezState = {
    key = "MezState",
    eventIds = {
        mezzing = "mezzing",
        mezAction = "mezaction",
        awakened = "mezawakened"
    },
    _ = {
        isInit = false,
        castId = nil,
        castName = nil,
        castOn = nil,
        castRole = nil,
        castAtId = nil,      -- the mob a single-target cast was aimed at, for crediting a resist
        castWitnesses = {},
        settled = false,     -- the cast has gone terminal once; the next pass takes the refined answer
        lastResult = nil,
        holdReason = nil,
        landed = {},         -- ["<effect>@<id>"] = trusted until
        mezzedAtMs = {},     -- [id] = when our mez landed on it -- the mark the motion read is against
        immune = {},         -- [id] = name -- this spawn will never take a mez
        resisted = {},       -- [id] = true -- a mez bounced off it; soften before spending another
        awake = {},          -- [id] = true -- the world said this one woke up, whatever the cache says
        suspect = {},        -- [id] = { name, sinceMs } -- one of these woke; which is being settled
        zoneId = 0
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MezState.key, str)
end

---Who this state is when it asks the casting service for something.
---@param targetId number|nil
---@return table request
function MezState.CastRequest(targetId)
    return {
        owner = MezState.key,
        priority = MezState.priority,
        targetId = targetId
    }
end

---------------- What a slot is --------------------

---Which of the three jobs this spell does, or nil when it does none of them.
---
---Each is an exact effect read, and the order is the order they outrank each other in: a mez that
---also stuns is a mez, and a debuff that also stuns is a stun. There is deliberately **no default**
----- a spell with no job here used to fall through to "softener" and be cast at mobs before every
---mez, which is how a slow ended up being cast as though it made mezzes land.
---@param spell any mq spell TLO
---@return string|nil role one of `roles`
local function roleOf(spell)
    if Spells.Mesmerizes(spell) then return roles.mez end
    -- reached only for a spell that has already passed `unusableReason`, so a stun rider on a nuke
    -- never gets this far and the bare effect means what it says here
    if Spells.Stuns(spell) then return roles.stun end
    if Spells.LowersResists(spell) then return roles.soften end
    return nil
end

---Can this spell be in a crowd control list at all?
---
---Three ways of not belonging, each with its own answer worth printing on the row:
---
---**It is cast on a friend**, and holds nothing still.
---
---**It does damage.** Not tidiness: damage is exactly what breaks a mez, so a slot holding a nuke
---works against every other slot in the list. It is also the only thing that tells a stun from a
---nuke -- an enchanter's Anarchy is a two hundred point AE that stuns, and carries the identical
---`SPA_STUN` that Color Shift, which is a stun and nothing else, carries.
---
---**It does none of the three jobs.** A slow, a cripple, a snare, a root and a lull are all useful
---spells that hold nothing still and make no mez land; they belong in the damage rotation, where
---`dps_timing` and `dps_spread` already say when and how widely to cast one. Saying so on the row
---is the point -- a slot that will never fire and does not say why is worse than no slot.
---@param spell any mq spell TLO
---@return string|nil problem in words, nil when the spell belongs here
local function unusableReason(spell)
    if spell.Beneficial() == true then
        return "this is cast on a friend, so it holds nothing still"
    end
    if Spells.Damages(spell) then
        return "this does damage, which is what breaks a mez -- it belongs in the damage rotation"
    end
    if roleOf(spell) == nil then
        return "this holds nothing still and makes no mez land, so there is no job for it here" ..
            " -- a slow, a snare or a root is a damage rotation slot"
    end
    return nil
end

---How this spell reaches what it is cast at.
---
---Read off the spell's own reach rather than off its target type string, because the two answer
---different halves and only together do they say where the blast lands: `AERange` above zero is
---what makes it an AE at all, and whether it needs a target is what says whether the blast is
---centred on the mob or on us.
---@param subject CastSubject
---@param spell any mq spell TLO
---@return string delivery one of `deliveries`
---@return number aeRange 0 for a single-target spell
local function deliveryOf(subject, spell)
    local aeRange = tonumber(spell.AERange()) or 0
    if aeRange <= 0 then return deliveries.single, 0 end
    if subject:NeedsTarget() then return deliveries.targeted, aeRange end
    return deliveries.centred, aeRange
end

---The highest level of mob this spell will hold.
---
---Read off the mesmerize effect's own Max rather than off `Spell.MaxLevel`, which reads the first
---effect slot whatever is in it. Zero is "no limit stated", which is the honest reading of a spell
---that does not carry one -- not a limit of zero.
---@param spell any mq spell TLO
---@return number maxLevel 0 when the spell states none
local function mezMaxLevel(spell)
    local effects = tonumber(spell.NumEffects()) or 12
    for index = 1, effects do
        if (tonumber(spell.Attrib(index)()) or 0) == 31 then
            return tonumber(spell.Max(index)()) or 0
        end
    end
    return 0
end

---------------- What is on a mob --------------------

---@param effect string
---@param id number
---@return string key
local function landedKey(effect, id)
    return effect .. "@" .. tostring(id)
end

---Drop records that have run out, and records about mobs the world has taken back.
---
---An id is only meaningful while its spawn stands: a dead mob's immunity is not a fact about
---anything, and the next spawn to wear that id would inherit it. So everything keyed by one is
---confirmed against the world here rather than left to expire.
local function prune()
    local now = Time.current_time()

    for key, until_ in pairs(MezState._.landed) do
        if now >= until_ then MezState._.landed[key] = nil end
    end

    for _, record in ipairs({
        MezState._.immune, MezState._.resisted, MezState._.awake,
        MezState._.suspect, MezState._.mezzedAtMs
    }) do
        for id in pairs(record) do
            local spawn = mq.TLO.Spawn("id " .. tostring(id))
            if spawn.ID() == nil or spawn.Dead() == true then record[id] = nil end
        end
    end
end

---Settle a break the world reported by name, now that the mobs have had a chance to give
---themselves away.
---
---The line says *a* mob called this woke up; it cannot say which one, and with two of them mezzed
---side by side that is the whole difficulty. So the line is treated as what it actually is -- a
---prompt to look harder -- and the mobs answer it themselves: the one that has moved or turned
---since the mez we put on it is the one that is loose.
---
---**One line accounts for exactly one mob**, so the moment one of a suspected group gives itself
---away the rest are cleared. Two mobs waking is two lines, and the second one suspects whatever is
---still held.
---
---**Nothing is thrown away about a mob while this is unsettled**, which is the other half of it
---being the *right* mob that gets the mez: the group is suspected, not accused, so the trust in a
---mez of ours that landed a beat ago (`landed`) stands until the suspicion lands on that mob. It is
---dropped here, at the moment there is one mob to drop it for.
---
---A suspicion nothing resolves simply stands, and that is correct rather than a leak: past
---`suspicionSettleMs` an unresolved suspect is treated as loose, so the worst it can do is buy that
---mob a mez it may not have needed -- and it is dropped by the mob dying, by a mez of ours landing
---on it, or by a zone.
local function settleSuspicions()
    local resolved = {}

    for id, suspicion in pairs(MezState._.suspect) do
        local lastMoved = Mobs.LastMovedMs(id)
        if lastMoved ~= nil and lastMoved > suspicion.sinceMs then
            resolved[#resolved + 1] = { id = id, name = suspicion.name }
        end
    end

    for _, answer in ipairs(resolved) do
        DebugLog("It was " .. answer.name .. " (" .. tostring(answer.id) .. ") that woke: it moved")
        MezState._.awake[answer.id] = true
        -- now that the line has one mob to belong to, what we thought we had just put on it is
        -- what the world has contradicted
        MezState._.landed[landedKey(roles.mez, answer.id)] = nil

        for id, suspicion in pairs(MezState._.suspect) do
            if suspicion.name == answer.name then MezState._.suspect[id] = nil end
        end
    end
end

---Has this mob moved since the mez we put on it landed?
---
---**The strongest break signal there is, and it needs no window and no threshold.** A mez landed at
---one instant and the mob moved at another; which of those came second is the entire answer. A mob
---held by a mez is *perfectly* still -- not "not running", but the same coordinates and the same
---heading, pulse after pulse -- so anything else is the mez not holding it.
---
---Heading is half of it and the half that catches what position alone misses: a mob handed back its
---own will faces whoever it is about to hit before it takes a step, and one that is rooted or
---snared may never take one at all. `macros/bots/enchanterBot.mac` samples exactly this pair for
---exactly this reason.
---
---False when we have no mark to measure against -- a mez somebody else landed, or one of ours old
---enough to have been forgotten -- because "we cannot say" is not "it broke".
---@param id number
---@return boolean hasMoved
local function movedSinceMez(id)
    local mezzedAt = MezState._.mezzedAtMs[id]
    if mezzedAt == nil then return false end

    local lastMoved = Mobs.LastMovedMs(id)
    if lastMoved == nil then return false end
    return lastMoved > mezzedAt
end

---Is this mob standing there doing nothing?
---
---The animation half of the reading, kept beside the motion one above because
---`macros/bots/mez.mac` is field evidence for this server specifically -- though it is the weaker
---of the two, being a lookup table that can be incomplete where "it is somewhere else now" cannot.
---They err the same way, so either one calling the mob active makes it active.
---
---Silence is read as "standing there" rather than as "loose": a spawn the client will not answer
---about is one we cannot see, and calling every mob we cannot see loose would mean re-mezzing the
---whole camp on the strength of not knowing. Being wrong the other way costs one mez that arrives
---a pass late, which the cached duration would have called for anyway.
---@param spawn any mq spawn TLO
---@return boolean isStill
local function isStandingStill(spawn)
    local animation = tonumber(spawn.Animation())
    if animation == nil then return true end
    return passiveAnimations[animation] == true
end

---How much of a mez is left on this mob, in milliseconds, and how sure we are of it.
---
---The chain, strongest first:
---
---1. **We just landed one.** For the couple of seconds it takes the server to tell the client,
---    what we did is the only record there is.
---2. **The world said it woke up.** The awakened line, or the mob visibly up and doing something.
---    This *overrides the cache*, which is the whole point: nothing tells a cached buff about a
---    break, so a mez ended by a backstab sits there counting down for the two minutes it had left.
---3. **The client's own reading**, `CachedBuff[^mezzed]` -- the same `SPA_ENTHRALL` search the
---    client's `Target.Mezzed` is built on, filled in whenever the mob was last targeted (which for
---    a mob we mez is every time we mez it) and ageing by itself from there, so a stale cache
---    decays into "it needs one" rather than lying about it.
---@param id number
---@param spawn any mq spawn TLO
---@return number remainingMs
local function mezRemainingMs(id, spawn)
    -- Held, and *how long* is deliberately not answered: a mez we just landed lasts whatever it
    -- lasts, and the window is only bridging the beat before the client has been told anything.
    -- Answering with the window's own few seconds instead would read as "nearly out" against the
    -- refresh margin below, and the mob would be mezzed a second time before the first had been
    -- reported. Once the window passes, the cache answers with the real figure.
    local trustedUntil = MezState._.landed[landedKey(roles.mez, id)]
    if trustedUntil ~= nil and Time.current_time() < trustedUntil then
        return math.huge
    end

    -- Never cleared by a reading, only by a mez of our own landing or by the mob dying. A mob that
    -- broke free and has not started swinging yet still looks like it is standing there, so
    -- clearing this on a reading alone would hand the add back during exactly that beat -- and the
    -- two ways of being wrong cost differently: a redundant mez is a gem timer, a loose add is the
    -- fight.
    if MezState._.awake[id] then return 0 end

    -- One of several mobs of this name woke and the world has not yet said which. For the moment it
    -- takes the freed one to give itself away -- it turns to face what it is about to hit before it
    -- takes a step, and the readings below are watching for exactly that -- the suspicion adds
    -- nothing, and every mob of the name is judged on its own evidence like any other.
    --
    -- **This used to answer "all of them are loose", and that answer cost a cast.** With two of a
    -- kind held side by side it is a coin toss, and losing it spends the mez, the gem timer and
    -- three seconds of casting on a mob that was already mezzed -- three seconds during which the
    -- one that actually woke is loose and nothing is being cast at it. Waiting a beat to be told
    -- which is the cheaper bet by every measure.
    local suspicion = MezState._.suspect[id]
    if suspicion ~= nil and Time.current_time() - suspicion.sinceMs >= suspicionSettleMs then
        return 0
    end

    if movedSinceMez(id) then return 0 end
    if not isStandingStill(spawn) then return 0 end

    local cached = spawn.CachedBuff("^mezzed")
    if cached.SpellID() == nil then return 0 end

    -- a permanent's negative is not "expired"; nothing that mezzes is permanent, but the reading
    -- is shared with everything else that sits in a buff slot
    local remaining = tonumber(cached.Duration()) or 0
    if remaining < 0 then return math.huge end
    return remaining
end

---Is this mob held well enough to leave alone?
---
---The margin is the cast plus the configured lead, and it is arithmetic rather than a timer: a mez
---with four seconds left that takes three to cast has to be started *now* or it wears off with the
---caster stood still mid-cast, which is the worst moment of the fight to hand an add back. So "is
---it mezzed" is never the question; "will it still be mezzed when the next one could land" is.
---@param id number
---@param spawn any mq spawn TLO
---@param spell any mq spell TLO the mez that would be recast
---@param subject CastSubject
---@return boolean isHeld
local function isHeld(id, spawn, spell, subject)
    local margin = subject:CastTimeMs() + MezStateConfig.GetRefreshLeadMs()
    return mezRemainingMs(id, spawn) > margin
end

---Is this spell's own effect already on this mob?
---
---The same reading the rotation uses for a debuff, against the same cache: a tash that is on the
---mob has done its whole job, and casting it again spends a gem timer to change nothing. A stun
---asks it too, for a narrower reason -- a stun is short enough that the cache may never carry it,
---and what is really being checked there is our own record, which stops the same stun going out
---twice while the first one is still landing.
---@param spell any mq spell TLO
---@param id number
---@return boolean isWorking
local function alreadyOn(spell, id)
    local name = spell.Name()
    if name == nil then return false end

    local trustedUntil = MezState._.landed[landedKey(name, id)]
    if trustedUntil ~= nil and Time.current_time() < trustedUntil then return true end

    local cached = mq.TLO.Spawn("id " .. tostring(id)).CachedBuff(name)
    if cached.SpellID() ~= nil then return (tonumber(cached.Duration()) or 0) ~= 0 end

    return false
end

---------------- Who is worth acting on --------------------

---What the group is killing first, and how this client came to know it.
---
---**The mob everything else is an add beside.** Crowd control cannot name an add on its own -- an
---add is a mob that is *not* the one being killed -- so this is the fact the whole of the choosing
---below stands on, and nil is a real answer that stops it.
---
---Two sources, and the order between them is the point:
---
---**The main tank's target**, which is the group's own answer and the one that arrives first: the
---tank has picked the mob up before this character has cast anything, and `Combat.GetTankTargetId`
---already knows the three ways it is knowable (we are the tank; the tank's `assist` call; the
---client's assist record). This is what the enchanter waits for.
---
---**Failing that, our own engagement.** Not a nicety -- it is what keeps the rule from being a
---silent off switch. `GetTankTargetId` answers nil for a group that never dragged anybody onto the
---Main Tank role, and for a tank that is neither running cabby nor holding the assist, and a mez
---state that never fires because of a window nobody filled in is worse than one that occasionally
---mezzes early. Our own engagement comes from the assist call or from what turned on us, so it is
---the same fight named a different way.
---@return number|nil id nil when nobody here can say what is being killed
---@return string|nil source in words, for the page and `/cmez`
local function namedKill()
    local tankOn = Combat.GetTankTargetId()
    if tankOn ~= nil then return tankOn, "what the main tank is on" end

    local ours = Combat.GetTargetId()
    if ours > 0 then return ours, "what we are fighting" end

    return nil, nil
end

---@class MezCandidate
---@field id number
---@field name string
---@field spawn any mq spawn TLO, read once and handed on
---@field isKillTarget boolean what is being killed and is never mezzed on purpose -- our own
---engagement, and what the group's main tank has named, which are two answers to one question
---@field isOnMe boolean it is coming for this character -- what a stun is for
---@field canSee boolean whether there is line of sight to it from here, read once per pass and
---shared by every slot -- see `scanCandidates`

---Everything in the fight worth a second look, in the roster's own order.
---
---The filtering here is what is true of a mob whatever we might cast at it. *Range* is still the
---casting service's question and is asked per slot, because a mob out of reach of one mez is in
---reach of another.
---
---**Line of sight is read here rather than per slot**, for two reasons. It is the same answer for
---every spell in the list -- a wall is a wall -- so asking once and sharing it turns a raycast per
---slot per mob into one raycast per mob. And it has to be a fact this state can *decide* on rather
---than only be refused by: an AE mez is worth casting because of how many mobs it will catch, and
---counting one on the far side of a wall toward that is how a blast goes off for two mobs when it
---was judged worth casting for four. Both macros this state is built from filter mez targets the
---same way (`macros/bots/mez.mac`, and RGMercs' `IsValidMezTarget`).
---
---Unreadable is read as visible: `LineOfSight` answering nothing is the client declining to say,
---and the casting service will refuse the cast for real if it turns out to be blocked.
---@param killId number|nil what is first to kill (`namedKill`), read once for the pass
---@return MezCandidate[] candidates
local function scanCandidates(killId)
    local candidates = {}
    local killTargetId = Combat.GetTargetId()

    local onMe = {}
    for _, id in ipairs(Combat.GetUnderAttackIds() or {}) do onMe[id] = true end

    for _, id in ipairs(Mobs.GetIds()) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        -- the roster is as fresh as its own pulse; a corpse hitting the ground between that pulse
        -- and this pass is caught here, where it costs a read of a spawn we were about to judge
        if spawn.ID() ~= nil and not spawn.Dead() then
            candidates[#candidates + 1] = {
                id = id,
                name = spawn.CleanName() or ("spawn " .. tostring(id)),
                spawn = spawn,
                -- our own engagement *and* the tank's, because they are one question -- "is
                -- somebody killing this" -- and a character that has not engaged anything (a
                -- chanter with auto-engage off is the ordinary case) would otherwise read the
                -- mob the tank is holding as just another add and mez it off them
                isKillTarget = id == killTargetId or id == killId,
                isOnMe = onMe[id] == true,
                canSee = spawn.LineOfSight() ~= false
            }
        end
    end

    return candidates
end

---Is the whole fight one mob that nobody has picked up yet?
---
---**A lone mob nothing is fighting is the pull, not an add.** It is walking in on somebody's leash
---with the camp waiting for it, and a mez that lands on it stops it dead halfway there: the puller
---stands still for a mob that is never arriving, the tank never gets to pick it up, and the first
---person to hit it breaks the mez anyway. A mez is for the *second* mob and everything after it.
---
---A question about the fight rather than about the mob, because being the only one in it is not a
---property of a mob -- and the moment anything else joins, both of them are worth holding: two on
---the way in is the ordinary pull a group keeps crowd control for.
---
---**`IsEngaged` rather than "is it what we are killing"**, and the difference is the beat between
---two mobs of one fight -- exactly when the roster is down to one and the mez on the survivor is
---coming up for a refresh. Combat holds the fight open across that beat (`IsSeeking`), so what
---this asks is "has a fight not started", never "is this the moment between targets".
---@param candidates MezCandidate[] everything in the fight this pass
---@return boolean isPull
local function isUnfoughtPull(candidates)
    return #candidates == 1 and not Combat.IsEngaged()
end

---Is this mob one a mez should be spent on at all?
---
---`stop_pct` is the one that reads backwards until you have watched it go wrong: a mob *below* the
---health line is left alone. It is not too healthy to mez, it is too nearly dead -- somebody has
---been killing it, there is damage in the air aimed at it, and a mez that lands takes it out of
---reach of all of that so the group can start again on a full-health add instead.
---
---**Nothing new is mezzed until something has been named as first to kill** (`namedKill`, which is
---the tank's target where it can be seen). An add is only an add relative to something being
---killed, so with two mobs standing there and nobody on either, choosing one is a coin toss that
---loses half the time -- mez the one the tank was walking towards and the fight opens with the tank
---taunting a mob it must not hit while the group's damage sits on a mez about to break. The
---question is never "which of these looks like the add" but "has anybody said which one is first",
---and until somebody has, this state picks nothing.
---
---**A mob we have already mezzed is exempt, and that is what stops the rule blinking.** What is
---first to kill is unknown for a beat every time one mob dies before the next is picked up --
---exactly when the adds already held come up for a refresh -- and a mob we put a mez on was judged
---an add at the moment we did it. The rule governs *choosing* a target; that one was chosen.
---@param candidate MezCandidate
---@param candidates MezCandidate[] the fight it is in, for the lone-pull reading above
---@param killId number|nil what is first to kill (`namedKill`); nil when nobody here can say
---@return boolean isWorth
local function isWorthMezzing(candidate, candidates, killId)
    if candidate.isKillTarget then return false end
    if MezState._.immune[candidate.id] then return false end

    -- Both of these are about picking a *new* mob to hold, so neither is asked of one this state
    -- is already holding: a mez of ours on it is the record of having decided, and the fight going
    -- quiet for a beat does not hand it back.
    if MezState._.mezzedAtMs[candidate.id] == nil then
        -- the mob being brought in is nobody's add until there is something else here
        if isUnfoughtPull(candidates) then return false end
        -- and with several here, no telling the add from the one the group is about to kill
        if killId == nil then return false end
    end
    -- nothing in this list reaches through a wall, so a mob we cannot see is not a mob to plan
    -- around: it is neither mezzed, nor counted toward an AE being worth casting, nor waited for.
    -- It comes back the pass it comes into sight
    if not candidate.canSee then return false end

    local pct = Status.HealthPct(candidate.spawn)
    if pct ~= nil and pct < MezStateConfig.GetStopPct() then return false end

    return true
end

---@param spell any mq spell TLO
---@param candidate MezCandidate
---@return boolean canHold whether this mez is strong enough for this mob
local function withinMezLevel(spell, candidate)
    local maxLevel = mezMaxLevel(spell)
    if maxLevel <= 0 then return true end

    local level = tonumber(candidate.spawn.Level())
    -- an unreadable level is not a reason to refuse: the cast is the cheapest way to find out, and
    -- the answer comes back as the immune line, which is remembered
    if level == nil then return true end
    return level <= maxLevel
end

---------------- Choosing what to cast --------------------

---@class MezPick
---@field action ActionType
---@field targetId number|nil
---@field on string who or what it is being aimed at, for status
---@field role string one of `roles`
---@field atId number|nil the one mob a single-target cast was aimed at, for crediting a resist
---@field witnesses table what to remember once it lands

---@param effect string
---@param id number
---@param ms number
---@return table witness
local function witnessFor(effect, id, ms)
    return { key = landedKey(effect, id), ms = ms }
end

---The mob this stun is for.
---
---**A stun is what buys the mez.** A mez is a long cast, and a mob that has turned around and
---reached this character interrupts it -- so the mob swinging at us is stunned first and mezzed
---during the seconds that buys. That is the whole reason a stun is in this list rather than in the
---damage rotation: it is not damage and it is not crowd control on its own, it is the thing that
---makes the crowd control castable at all.
---
---**And a mezzed mob is never stunned**, because a stun landing on one breaks the mez.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@param candidates MezCandidate[]
---@return MezPick? pick
local function pickStun(slot, action, spell, candidates)
    local when = MezStateConfig.GetStunWhen(slot)
    local subject = action:Subject()

    for _, candidate in ipairs(candidates) do
        local wants = false
        if when == MezStateConfig.stunWhen.OnMe.value then
            wants = candidate.isOnMe
        elseif when == MezStateConfig.stunWhen.Casting.value then
            wants = candidate.spawn.Casting.ID() ~= nil
        else
            wants = candidate.isOnMe or candidate.spawn.Casting.ID() ~= nil
        end

        -- a stun does not reach through a wall either, and a mob out of sight is not the one
        -- interrupting our casts. `isWorthMezzing` is not asked here -- a stun is aimed at what is
        -- beating on us whatever its health, and at the mob the group is killing if that is what
        -- has turned on us -- so line of sight has to be asked on its own
        if wants and candidate.canSee and not MezState._.immune[candidate.id] then
            -- **A mezzed mob is never stunned, because a stun landing on one breaks the mez.**
            -- Not "there is nothing to add": the cast would actively undo the thing this state
            -- spent three seconds putting there, and hand back the add it was holding.
            local remaining = mezRemainingMs(candidate.id, candidate.spawn)
            if remaining <= 0 and not alreadyOn(spell, candidate.id) then
                if action:IsReady(MezState.CastRequest(candidate.id)) then
                    return {
                        action = action,
                        targetId = subject:NeedsTarget() and candidate.id or nil,
                        on = candidate.name,
                        role = roles.stun,
                        atId = candidate.id,
                        -- a stun is short and unreadable from a cache; the record is only there to
                        -- stop the same stun going out twice while the first is still landing
                        witnesses = { witnessFor(spell.Name(), candidate.id, justLandedMs) }
                    }
                end
            end
        end
    end

    return nil
end

---The mob this softener is for.
---
---*Once it resists* is the default and it is the honest reading of "sometimes we have to tash it
---first": we find out that a mob resists by having a mez bounce off it, and the record of that is
---what the world told us rather than something guessed. *Before every mez* is the zone where they
---all resist, and is a real answer -- it just costs a cast and a gem timer per add to find out
---nothing, which is not the one to ship.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@param candidates MezCandidate[]
---@param killId number|nil
---@return MezPick? pick
local function pickSoften(slot, action, spell, candidates, killId)
    local always = MezStateConfig.GetSoftenWhen(slot) == MezStateConfig.softenWhen.Always.value
    local subject = action:Subject()

    for _, candidate in ipairs(candidates) do
        if isWorthMezzing(candidate, candidates, killId)
            and (always or MezState._.resisted[candidate.id]) then
            if not alreadyOn(spell, candidate.id) then
                if action:IsReady(MezState.CastRequest(candidate.id)) then
                    return {
                        action = action,
                        targetId = subject:NeedsTarget() and candidate.id or nil,
                        on = candidate.name,
                        role = roles.soften,
                        atId = candidate.id,
                        witnesses = { witnessFor(spell.Name(), candidate.id, justLandedMs) }
                    }
                end
            end
        end
    end

    return nil
end

---Everything a mez should be going on right now, in the roster's order.
---
---A mob that has resisted and is waiting on a softener is left out entirely, which is the one
---piece of coordination between the slots in this list -- and it is worth the exception: without
---it, a mez slot above the tash keeps choosing the mob we already know it bounces off, and the
---softener below it never gets a turn. The deferral only holds while a softener that could
---actually act on the mob is enabled and in the list, so a character with no tash configured goes
---on trying the mez, which is the only thing it has.
---@param spell any mq spell TLO
---@param subject CastSubject
---@param candidates MezCandidate[]
---@param deferred table set of ids waiting on a softener
---@param killId number|nil
---@return MezCandidate[] loose
local function looseFor(spell, subject, candidates, deferred, killId)
    local loose = {}
    for _, candidate in ipairs(candidates) do
        if isWorthMezzing(candidate, candidates, killId) and not deferred[candidate.id]
            and withinMezLevel(spell, candidate)
            and not isHeld(candidate.id, candidate.spawn, spell, subject) then
            loose[#loose + 1] = candidate
        end
    end

    -- **Whoever is provably loose goes first**, and it is what makes an unsettled break cost
    -- nothing. A chat line naming one of two identical mobs leaves both treated as loose, but only
    -- one mez can be in the air at a time -- so the order the list is walked in *is* which mob gets
    -- the cast, and the one that has actually moved since we mezzed it is the one that needs it.
    -- By the time that cast finishes the other has been cleared, so the second mez is never spent.
    --
    -- A stable sort, because the roster's order is meaningful underneath this (what we are killing
    -- first, then the fight around it) and re-ordering equals every pass would mean choosing a
    -- different mob every pass for no reason.
    local rank = {}
    for index, candidate in ipairs(loose) do
        rank[candidate.id] = (MezState._.awake[candidate.id] or movedSinceMez(candidate.id))
            and index or (index + #loose)
    end
    table.sort(loose, function(left, right) return rank[left.id] < rank[right.id] end)

    return loose
end

---@param a MezCandidate
---@param b MezCandidate
---@return number distance
local function between(a, b)
    return Geometry.Distance3D(
        tonumber(a.spawn.Y()) or 0, tonumber(a.spawn.X()) or 0, tonumber(a.spawn.Z()) or 0,
        tonumber(b.spawn.Y()) or 0, tonumber(b.spawn.X()) or 0, tonumber(b.spawn.Z()) or 0)
end

---Where an AE mez is worth going off, and what it would catch.
---
---The blast is worth its aggro when it covers enough loose mobs at once, which is the whole reason
---an AE mez exists -- one cast instead of four, at the moment four is more than the gem timer can
---keep up with. Below that count a single-target mez covers the same ground without waking
---anything that was not already in the fight.
---
---**A blast is only aimed where every mob in it is one the client has been told about**, when the
---safety switch is on. The roster's own sweep can see a mob in combat stance without being able to
---say it is in combat with *us*, and an AE aimed into a group of those is the classic way a camp
---pulls the room -- so the mobs that make an AE worth casting have to be ones something actually
---told us about. The mobs it *also* catches are not filtered, because a blast catches what it
---catches; what is being decided here is only where to point it.
---@param loose MezCandidate[]
---@param aeRange number
---@param delivery string
---@return MezCandidate|nil centre nil for a blast centred on us
---@return MezCandidate[] caught
---@return number count how many loose mobs it would cover
local function aeBlast(loose, aeRange, delivery)
    local confirmedOnly = MezStateConfig.GetAeConfirmedOnly()

    ---@param centre MezCandidate|nil
    ---@return MezCandidate[] caught
    local function coveredBy(centre)
        local caught = {}
        for _, candidate in ipairs(loose) do
            local distance
            if centre == nil then
                distance = tonumber(candidate.spawn.Distance3D()) or math.huge
            else
                distance = between(centre, candidate)
            end
            if distance <= aeRange then caught[#caught + 1] = candidate end
        end
        return caught
    end

    if delivery == deliveries.centred then
        local caught = coveredBy(nil)
        return nil, caught, #caught
    end

    local best, bestCaught, bestCount = nil, {}, 0
    for _, centre in ipairs(loose) do
        if not confirmedOnly or Mobs.IsConfirmed(centre.id) then
            local caught = coveredBy(centre)
            local count = 0
            for _, candidate in ipairs(caught) do
                if not confirmedOnly or Mobs.IsConfirmed(candidate.id) then count = count + 1 end
            end
            if count > bestCount then
                best, bestCaught, bestCount = centre, caught, count
            end
        end
    end

    return best, bestCaught, bestCount
end

---What this mez slot has to do right now.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@param candidates MezCandidate[]
---@param deferred table
---@param killId number|nil
---@return MezPick? pick
local function pickMez(slot, action, spell, candidates, deferred, killId)
    local subject = action:Subject()
    local delivery, aeRange = deliveryOf(subject, spell)
    local loose = looseFor(spell, subject, candidates, deferred, killId)
    if #loose == 0 then return nil end

    local function witnessesFor(caught)
        local witnesses = {}
        for _, candidate in ipairs(caught) do
            witnesses[#witnesses + 1] = witnessFor(roles.mez, candidate.id, justLandedMs)
        end
        return witnesses
    end

    if delivery == deliveries.single then
        for _, candidate in ipairs(loose) do
            if action:IsReady(MezState.CastRequest(candidate.id)) then
                return {
                    action = action,
                    targetId = candidate.id,
                    on = candidate.name,
                    role = roles.mez,
                    atId = candidate.id,
                    witnesses = witnessesFor({ candidate })
                }
            end
            -- out of range or out of sight says nothing about the next mob, and the next pass asks
            -- again anyway, so keep walking rather than dropping the slot
        end
        return nil
    end

    local centre, caught, count = aeBlast(loose, aeRange, delivery)
    if count < MezStateConfig.GetAeMin() then return nil end

    local targetId = centre ~= nil and centre.id or nil
    if not action:IsReady(MezState.CastRequest(targetId)) then return nil end

    return {
        action = action,
        targetId = targetId,
        on = centre ~= nil
            and (tostring(count) .. " around " .. centre.name)
            or (tostring(count) .. " around me"),
        role = roles.mez,
        -- an AE's immune and resist lines cannot be pinned on any one mob in the blast, so nothing
        -- is credited from one; the mobs it failed on show up loose on the next pass, which is the
        -- honest answer and costs a pass
        atId = nil,
        witnesses = witnessesFor(caught)
    }
end

---Which mobs are waiting on a softener rather than on a mez.
---
---Only ever mobs a softener in this list could actually act on -- a resist recorded against a
---character with nothing to soften with is a fact with nothing to do about it, and deferring on it
---would mean never mezzing the mob again.
---@param candidates MezCandidate[]
---@return table deferred set of ids
local function deferredForSoftening(candidates)
    local deferred = {}

    for _, slot in ipairs(MezStateConfig.GetActions()) do
        if Action.IsEnabled(slot) then
            local action = Action.GetActionType(slot)
            if action ~= nil and action.Subject ~= nil then
                local spell = action:Subject():Spelldata()
                if spell ~= nil and unusableReason(spell) == nil and roleOf(spell) == roles.soften then
                    local always = MezStateConfig.GetSoftenWhen(slot) == MezStateConfig.softenWhen.Always.value
                    for _, candidate in ipairs(candidates) do
                        if (always or MezState._.resisted[candidate.id])
                            and not alreadyOn(spell, candidate.id) then
                            deferred[candidate.id] = true
                        end
                    end
                end
            end
        end
    end

    return deferred
end

---The first slot in the control list with something to do.
---@param candidates MezCandidate[]
---@param killId number|nil
---@return MezPick? pick
local function choosePick(candidates, killId)
    local deferred = deferredForSoftening(candidates)

    for _, slot in ipairs(MezStateConfig.GetActions()) do
        if Action.IsEnabled(slot) then
            local action = Action.GetActionType(slot)
            -- casts only: this state polls the cast it started, which a skill or a discipline has
            -- no equivalent of. Only casts are offered on the page; this is for a config edited by
            -- hand
            if action ~= nil and action.Subject ~= nil then
                local spell = action:Subject():Spelldata()
                -- Left unfiltered, anything that is not a mez or a stun falls through to
                -- "softener" and gets cast at a mob -- so a nuke picked from behind the "show
                -- every spell" switch would be fired at the very mobs this list is holding still.
                -- The page says so on the row; this is the half that stops it happening.
                if spell ~= nil and unusableReason(spell) == nil and Action.GetLuaResult(slot) then
                    local role = roleOf(spell)
                    local pick
                    if role == roles.mez then
                        pick = pickMez(slot, action, spell, candidates, deferred, killId)
                    elseif role == roles.stun then
                        pick = pickStun(slot, action, spell, candidates)
                    else
                        pick = pickSoften(slot, action, spell, candidates, killId)
                    end
                    if pick ~= nil then return pick end
                end
            end
        end
    end

    return nil
end

---------------- Reasons to hold everything --------------------

---@return string|nil code
---@return string|nil reason in words
local function holdReason()
    if Status.IsFleeing() then return "fleeing", "the group is running" end

    local myState = mq.TLO.Me.State()
    if myState == "DEAD" or myState == "HOVER" then return "dead", "we are dead" end

    if #Mobs.GetIds() == 0 then return "noFight", "nothing in the fight" end

    local manaFloor = MezStateConfig.GetManaFloor()
    if manaFloor > 0 and (tonumber(mq.TLO.Me.PctMana()) or 0) < manaFloor then
        return "lowMana", "saving mana below " .. tostring(manaFloor) .. "%"
    end

    return nil, nil
end

---------------- The state itself --------------------

---@return string description of what this state is doing, for the page and /state
function MezState.Describe()
    if MezState._.castId ~= nil then
        return "casting " .. tostring(MezState._.castName) ..
            (MezState._.castOn ~= nil and (" on " .. MezState._.castOn) or "")
    end
    if MezState._.holdReason ~= nil then
        return "holding: " .. MezState._.holdReason
    end
    return "watching"
end

---@return string|nil result what the last cast did
function MezState.GetLastResult()
    return MezState._.lastResult
end

---What is first to kill, in words: the fact that decides whether anything new is mezzed at all.
---
---A read of services and the world and nothing else, so the page can ask it every frame -- and it
---has to be asked somewhere, because a state holding off for a perfectly good reason and saying
---nothing about it is indistinguishable from a broken one.
---@return string description
function MezState.DescribeKill()
    local killId, killSource = namedKill()
    if killId == nil then return "nobody has picked one -- nothing new will be mezzed" end

    local name = mq.TLO.Spawn("id " .. tostring(killId)).CleanName()
        or ("spawn " .. tostring(killId))
    return name .. " (id " .. tostring(killId) .. ") -- " .. tostring(killSource)
end

---What this state believes about every mob in the fight, for the page and `/cmez`.
---
---Worked out on demand rather than kept, because it is the same reading `Go` makes and keeping a
---second copy of it is how a page comes to disagree with the state it is describing.
---@return table rows { id, name, status, note }
function MezState.DescribeMobs()
    local rows = {}
    local killTargetId = Combat.GetTargetId()
    local killId, killSource = namedKill()
    local ids = Mobs.GetIds()
    -- the same reading `isUnfoughtPull` makes, taken off the roster rather than off a pass's
    -- candidates: a page that leaves the one mob in the fight sitting at *loose* while nothing is
    -- cast at it is a page that looks broken
    local isPull = #ids == 1 and not Combat.IsEngaged()

    for _, id in ipairs(ids) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        if spawn.ID() ~= nil then
            local status, note
            if MezState._.immune[id] then
                status, note = "immune", "it cannot be mesmerized"
            elseif id == killTargetId then
                status, note = "killing", "what we are fighting"
            elseif id == killId then
                status, note = "killing", killSource
            elseif isPull and MezState._.mezzedAtMs[id] == nil then
                status, note = "incoming", "the only mob in the fight and nobody is on it -- the pull"
            elseif killId == nil and MezState._.mezzedAtMs[id] == nil then
                -- the one that would otherwise read as a state doing nothing for no reason
                status, note = "waiting", "nothing is first to kill yet -- no telling this from it"
            elseif spawn.LineOfSight() == false then
                -- said out loud rather than left off: a mob missing from the page with no reason
                -- given is the same puzzle as a slot that never fires
                status, note = "unseen", "no line of sight to it"
            else
                local remaining = mezRemainingMs(id, spawn)
                if remaining <= 0 then
                    status = "loose"
                    if MezState._.resisted[id] then
                        note = "it resisted a mez"
                    elseif MezState._.awake[id] then
                        note = "it woke up"
                    elseif MezState._.suspect[id] ~= nil then
                        note = "something called this woke and none of them owned up"
                    elseif movedSinceMez(id) then
                        note = "it has moved since we mezzed it"
                    end
                elseif remaining == math.huge then
                    status, note = "mezzed", "no timer on it"
                else
                    status = "mezzed"
                    note = string.format("%.0fs left", remaining / 1000)
                end

                -- said on a mob that still reads held, because that is the whole of the pause:
                -- something of this name woke and this one has not given itself away, so it is
                -- being left alone rather than mezzed on a guess
                if MezState._.suspect[id] ~= nil and remaining > 0 then
                    note = (note or "") .. " -- watching: one of these woke"
                end
            end

            rows[#rows + 1] = {
                id = id,
                name = spawn.CleanName() or ("spawn " .. tostring(id)),
                status = status,
                note = note,
                sources = Mobs.DescribeSources(id)
            }
        end
    end

    return rows
end

function MezState.Reset()
    MezState._.castId = nil
    MezState._.castName = nil
    MezState._.castOn = nil
    MezState._.castRole = nil
    MezState._.castAtId = nil
    MezState._.castWitnesses = {}
    MezState._.settled = false
end

---@class MezSlotFacts
---@field role string one of `roles`
---@field roleText string what that means, in words
---@field delivery string one of `deliveries`
---@field softenable boolean whether *when to soften* is a question this slot can be asked
---@field stunnable boolean whether *when to stun* is a question this slot can be asked
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user. Everything is read off
---the spell, so this is also the answer to "why is this one not firing" -- otherwise a silent
---puzzle.
---@param slot Action
---@return MezSlotFacts facts
function MezState.DescribeSlot(slot)
    local facts = {
        role = roles.soften,
        roleText = "cast before a mez so it lands",
        delivery = deliveries.single,
        softenable = true,
        stunnable = false,
        problem = nil
    }

    if slot.name == nil or slot.name == "" then
        facts.softenable = false
        return facts
    end

    local action = Action.GetActionType(slot)
    if action == nil then
        facts.softenable = false
        facts.problem = "this character does not have it"
        return facts
    end
    if action.Subject == nil then
        facts.softenable = false
        facts.problem = "only spells, clickies and AAs can be cast"
        return facts
    end

    local subject = action:Subject()
    local spell = subject:Spelldata()
    if spell == nil then
        facts.softenable = false
        facts.problem = "no spell data"
        return facts
    end

    local unusable = unusableReason(spell)
    if unusable ~= nil then
        facts.softenable = false
        facts.problem = unusable
        return facts
    end

    facts.role = roleOf(spell)
    facts.delivery = select(1, deliveryOf(subject, spell))
    facts.softenable = facts.role == roles.soften
    facts.stunnable = facts.role == roles.stun

    if facts.role == roles.mez then
        local maxLevel = mezMaxLevel(spell)
        local reach = ({
            [deliveries.single] = "mez, one mob at a time",
            [deliveries.targeted] = "mez, everything around the mob it is aimed at",
            [deliveries.centred] = "mez, everything around me"
        })[facts.delivery]
        facts.roleText = reach .. (maxLevel > 0 and (" -- up to level " .. tostring(maxLevel)) or "")
    elseif facts.role == roles.stun then
        facts.roleText = "stun, to buy a cast"
    end

    return facts
end

---@diagnostic disable-next-line: duplicate-set-field
function MezState.Init()
    if MezState._.isInit then return end

    MezStateConfig.Init()

    Menu.RegisterState(MezState)

    ToggleCommand.Register({
        key = MezState.key,
        phrase = MezState.eventIds.mezzing,
        summary = "Turns crowd control on or off for listener(s)",
        about = {
            "Off calls off the cast in progress and stops starting new ones. What is already",
            "mezzed stays mezzed until it wears off.",
            "The fight itself is not called off -- (attack off) does that."
        },
        get = MezStateConfig.IsEnabled,
        set = MezState.SetEnabled
    })

    ActionCommand.Register({
        key = MezState.key,
        phrase = MezState.eventIds.mezAction,
        summary = "Switches one of the configured crowd control actions on or off",
        where = "Mez page",
        getActionLists = MezStateConfig.GetActionLists
    })

    -- The one thing the world says about a mez that no reading can replace: it arrives at the
    -- instant of the break, before the mob has physically done anything about it. What it cannot
    -- say is *which* mob -- it carries a name, and two of a kind mezzed side by side is the
    -- ordinary case in a camp. So the line narrows it to a name and the mobs settle the rest by
    -- moving, which is what `settleSuspicions` is for.
    local awakenedDocs = ChelpDocs.new(function() return {
        "(mezawakened) Notices a mez being broken and works out which mob it was",
        " -- The client's cached reading of a mez counts down happily through a break nobody told",
        "    it about, so this line is the only thing that can contradict it.",
        " -- It names the mob and not its id. With one mob of that name held, that settles it.",
        " -- With several, none of them is re-mezzed on a guess: they are watched for a moment,",
        "    and the one that moves or turns is the one that woke -- the rest are then cleared,",
        "    since one line is one mob. Mezzing the coin toss instead spends the cast and the gem",
        "    timer on a mob that was already held, and leaves the one that woke loose meanwhile.",
        " -- If nobody owns up in that moment, every mob of the name is treated as loose after",
        "    all: a break nobody claimed is still a break, and a redundant mez is the safe way to",
        "    be wrong."
    } end )
    local function event_Awakened(_, name)
        if name == nil then return end
        name = tostring(name)

        -- only mobs we believe we are holding: a line about something nobody here mezzed is
        -- somebody else's business, and a mob already known loose needs no further telling
        local candidates = {}
        for _, id in ipairs(Mobs.GetIds()) do
            local spawn = mq.TLO.Spawn("id " .. tostring(id))
            if spawn.CleanName() == name and not MezState._.awake[id]
                and MezState._.mezzedAtMs[id] ~= nil then
                candidates[#candidates + 1] = id
            end
        end

        if #candidates == 0 then return end

        if #candidates == 1 then
            DebugLog(name .. " (" .. tostring(candidates[1]) .. ") woke up; nothing else is called that")
            MezState._.awake[candidates[1]] = true
            MezState._.landed[landedKey(roles.mez, candidates[1])] = nil
            return
        end

        DebugLog("One of " .. tostring(#candidates) .. " mobs called " .. name ..
            " woke up; watching to see which")
        local now = Time.current_time()
        for _, id in ipairs(candidates) do
            -- suspected, not accused: what this state believes about each of them is left exactly
            -- as it was -- above all the trust in a mez of ours that landed a beat ago, since
            -- throwing that away for every mob of the name is the same thing as calling them all
            -- loose, and the whole point of watching is that only one of them is
            MezState._.suspect[id] = { name = name, sinceMs = now }
        end
    end
    Commands.RegisterEvent(Event.new(MezState.eventIds.awakened,
        "#1# has been awakened by #2#.", event_Awakened, awakenedDocs))

    local cmezDocs = ChelpDocs.new(function() return {
        "(/cmez) Reports what crowd control is doing and what it believes about every mob",
        " -- Usage: /cmez",
        " -- Usage (call off the cast in progress): /cmez off",
        " -- What is in the fight comes from the mob roster (/cmobs); this says what is held,",
        "    what is loose, and what will never take a mez.",
        " -- Nothing new is mezzed until something is named first to kill: an add is only an add",
        "    beside something being killed, so until then there is no telling which is which. What",
        "    is already mezzed goes on being refreshed regardless. Rows say *waiting* while that is",
        "    the case, and what is first to kill is named above them.",
        " -- That is the main tank's target where this client can see it (the tank being us, its",
        "    (assist) call, or the client's assist record -- /croles says which), and our own",
        "    engagement where it cannot, so a group that never named a Main Tank still mezzes."
    } end )
    local function Bind_CMez(...)
        local args = { ... }
        if args[1] ~= nil and tostring(args[1]):lower() == "off" then
            Casting.StopFor(MezState.key)
            MezState.Reset()
            print("Called off the mez in progress")
            return
        end

        print("Mez: " .. MezState.Describe())
        print(" -- crowd control (" .. MezState.eventIds.mezzing .. "): " ..
            (MezStateConfig.IsEnabled() and "on" or "off"))
        print(" -- last cast: " .. (MezState.GetLastResult() or "<none yet>"))

        -- the answer that decides whether anything new is mezzed at all, said before the rows so a
        -- page of *waiting* has its reason at the top of it
        print(" -- first to kill: " .. MezState.DescribeKill())

        local rows = MezState.DescribeMobs()
        if #rows == 0 then
            print(" -- no mobs in the fight")
        end
        for _, row in ipairs(rows) do
            print(" -- " .. row.name .. " (id " .. tostring(row.id) .. "): " .. row.status ..
                (row.note ~= nil and (" -- " .. row.note) or "") ..
                " [" .. row.sources .. "]")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cmez", Bind_CMez, cmezDocs))

    MezState.Reset()
    MezState._.isInit = true
end

---Look at the fight, decide what should be holding it still, start that, and release.
---
---The same shape as every other state: no "I am mezzing" mode to be stuck in, nothing waited on
---inside the pass, and every answer re-derived from the roster and the world. A mez that cannot get
---started is looked at again on the very next pass, and dropped the moment the mob stops being
---worth one.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function MezState.Go()
    -- Ids do not survive a zone line, so everything keyed by one goes with it: an immunity
    -- remembered across a zone is a fact about nothing, and the fresh spawn that inherits the id
    -- would inherit the immunity with it.
    local zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    if zoneId ~= 0 and zoneId ~= MezState._.zoneId then
        MezState._.zoneId = zoneId
        MezState._.landed = {}
        MezState._.mezzedAtMs = {}
        MezState._.immune = {}
        MezState._.resisted = {}
        MezState._.awake = {}
        MezState._.suspect = {}
    end

    -- Before anything else, and before the hold: a break reported while we had nothing to do is
    -- still a break, and the mob that gave itself away by moving did so whether or not this state
    -- was in a position to act on it.
    settleSuspicions()

    local code, hold = holdReason()
    MezState._.holdReason = hold

    local castId = MezState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        if status == nil then
            -- the one hold worth calling a cast off for: there is no fight left to control, so a
            -- mez landing three seconds from now lands on nothing
            if code == "fleeing" or code == "noFight" then
                DebugLog("Calling off the cast: " .. tostring(hold))
                MezState._.lastResult = tostring(MezState._.castName) .. ": called off, " .. tostring(hold)
                Casting.StopFor(MezState.key)
            end
            return true
        end

        -- **A resist arrives after the cast bar has closed.** The casting service reports the cast
        -- a success the moment the bar shuts and refines that a beat later when the line turns up,
        -- which is why its own contract says a caller that cares about resists reads the result on
        -- the frame *after* it first goes terminal. That beat is the whole of the softening
        -- feature: "it resisted" is the only way this state ever learns that a mob needs a tash
        -- before a mez will stick, and consuming the first answer would mean never hearing one.
        --
        -- So the first terminal pass writes down what we think landed -- which is what stops the
        -- pass after it casting a second mez at the same mob -- and takes the answer on the next.
        -- One pass, not a clock: the line is in the same burst of packets as the cast ending, and
        -- `mq.doevents` at the top of the next frame is where it gets read.
        if not MezState._.settled then
            MezState._.settled = true
            if status == Casting.status.succeeded and outcome == Casting.outcomes.succeeded then
                local now = Time.current_time()
                for _, witness in ipairs(MezState._.castWitnesses) do
                    MezState._.landed[witness.key] = now + witness.ms
                end
            end
            return true
        end

        local what = tostring(MezState._.castName) ..
            (MezState._.castOn ~= nil and (" on " .. MezState._.castOn) or "")
        local atId = MezState._.castAtId

        if status == Casting.status.succeeded and outcome == Casting.outcomes.succeeded then
            MezState._.lastResult = what .. ": landed"
            if MezState._.castRole == roles.mez then
                -- The mark the motion read measures against, written for every mob the cast
                -- covered -- an AE's whole blast, not just its centre. From here on "has it moved
                -- since we mezzed it" has something to compare to, which is the strongest thing
                -- this state ever knows about whether a mez is still holding.
                local now = Time.current_time()
                for _, witness in ipairs(MezState._.castWitnesses) do
                    local id = tonumber(tostring(witness.key):match("@(%d+)$"))
                    if id ~= nil then
                        MezState._.mezzedAtMs[id] = now
                        -- it took, so whatever we knew about it waking is out of date
                        MezState._.awake[id] = nil
                        MezState._.suspect[id] = nil
                    end
                end
            end

            if atId ~= nil then
                if MezState._.castRole == roles.mez then
                    MezState._.resisted[atId] = nil
                elseif MezState._.castRole == roles.soften then
                    -- softened: the next mez is worth trying again on its own merits
                    MezState._.resisted[atId] = nil
                end
            end
        else
            MezState._.lastResult = what .. ": " .. tostring(reason)

            -- The optimism above was wrong, so it is taken back rather than left to run out: a mob
            -- recorded as mezzed when the mez was refused is a mob left loose for the length of
            -- the window, which is exactly the two seconds an add needs to reach the healer.
            for _, witness in ipairs(MezState._.castWitnesses) do
                MezState._.landed[witness.key] = nil
            end

            -- What the world said about this mob, which is the only way either of these is ever
            -- knowable. Credited only to a cast aimed at one mob: an AE's lines cannot be pinned
            -- on any of the several it went off around.
            if atId ~= nil and MezState._.castRole == roles.mez then
                if outcome == Casting.outcomes.immune then
                    local name = mq.TLO.Spawn("id " .. tostring(atId)).CleanName() or tostring(atId)
                    DebugLog(name .. " cannot be mesmerized; leaving it alone")
                    MezState._.immune[atId] = name
                elseif outcome == Casting.outcomes.resisted then
                    DebugLog("Mez resisted on " .. tostring(atId) .. "; softening it first")
                    MezState._.resisted[atId] = true
                end
            end
        end

        DebugLog("Cast finished: " .. tostring(MezState._.lastResult))
        MezState.Reset()
        return true
    end

    if hold ~= nil then return false end

    prune()

    -- read once for the pass: what is first to kill answers both which mob is never mezzed and
    -- whether an add can be told apart from it at all
    local killId = namedKill()

    local pick = choosePick(scanCandidates(killId), killId)
    if pick == nil then return false end

    local newCastId, refused = Casting.Cast(pick.action:Subject(), MezState.CastRequest(pick.targetId))
    if newCastId == nil then
        DebugLog("Cast of [" .. pick.action:Name() .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Casting [" .. pick.action:Name() .. "] on " .. tostring(pick.on))
    MezState._.castId = newCastId
    MezState._.castName = pick.action:Name()
    MezState._.castOn = pick.on
    MezState._.castRole = pick.role
    MezState._.castAtId = pick.atId
    MezState._.castWitnesses = pick.witnesses
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
MezState.IsEnabled = function()
    return MezStateConfig.IsEnabled()
end

---Switching it off calls off the cast in the air: it is the casting service's now, and it would
---hold the chain back for a job we were just told to stop doing. What is already mezzed is left
---mezzed -- there is no un-mezzing, and it wears off on its own.
---@diagnostic disable-next-line: duplicate-set-field
MezState.SetEnabled = function(isEnabled)
    MezStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        Casting.StopFor(MezState.key)
        MezState.Reset()
    end
end

function MezState.BuildMenu()
    MezStateMenu.BuildMenu(MezState)
end

return MezState
