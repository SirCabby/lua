---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CureTypes = require("cabby.actions.cureTypes")
local CuringConfig = require("cabby.configs.curingConfig")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")
local Spells = require("cabby.actions.spells")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How often this character's own bar is read for afflictions. Nothing about a DoT changes
---meaningfully inside half a second, and the walk below is the expensive half of this service.
local scanIntervalMs = 500

---How long an affliction has to have left before it is worth anybody's cast.
---
---**The whole of what makes an affliction news.** A cure has to be chosen, aimed, cast and land,
---and a DoT with twenty seconds left will have faded before any of that finishes -- so asking for
---one buys a wasted gem, a wasted global cooldown, and a healer that looked away from a tank to
---spend them. A minute is the line between "this is going to keep hurting" and "this is nearly
---over", and it is read against what is *left* rather than against how long the spell lasts:
---the same three-minute DoT is worth curing in its first two minutes and not worth it in its
---last one.
local worthCuringMs = 60000

---How long before an affliction that is still there is mentioned again.
---
---Not a retry -- the request is already queued and being worked on -- but the one thing that
---keeps the queue honest across everything this client cannot see. A cure that fizzled, a curer
---that zoned, a request that arrived while nobody could answer it: all of them look identical
---from here, and all of them are fixed by the affliction saying it is still there. It is also
---what a curer's request TTL is measured against (see `staleMs`), so the two numbers move
---together.
local reshoutMs = 20000

---How long a request outlives the last time it was heard.
---
---A domain TTL on the meaning of an order rather than a give-up timer: "cure me" is a statement
---about right now, and whoever said it repeats themselves every `reshoutMs` for exactly as long
---as it stays true. Three of those unanswered means the affliction has gone, or its owner has --
---either way the order has stopped meaning anything and acting on it would be curing somebody
---who is already clean. Our own entries are exempt: those are re-derived from our own bar every
---scan, which is a better answer than any clock.
local staleMs = reshoutMs * 3

---How recently somebody has to have asked before a cure is actually cast at them.
---
---Separate from `staleMs`, and the gap between the two is the whole of what stops cures landing on
---people who are already clean. Keeping a request is a bet that a line went missing; *casting* on
---one is a claim about the world right now, and only the afflicted character can make that claim.
---They repeat themselves every `reshoutMs` for exactly as long as it stays true and go quiet the
---moment it stops -- so silence for longer than one repeat means the affliction has gone, or has
---ticked down past `worthCuringMs`, and the entry is only still here in case a line was lost.
---
---This is the answer to the two casts nobody needed: the first went out on a statement a full
---minute old, made when the DoT had a minute left and cast when it had seconds; the second went out
---after the affliction was gone entirely, on the same silent entry. Half a repeat of slack on top,
---because one late line is exactly what this is meant to tolerate.
---
---Nothing is dropped by this -- it holds. The moment they say it again the request is live, which
---is what makes going quiet safe to act on.
local freshAskMs = reshoutMs * 1.5

---How long a look at somebody's bar is still worth believing.
---
---Another player's buffs arrive in one complete packet when this client targets them, and the
---client then **counts that snapshot down on its own**: every entry carries the duration it had
---when it arrived, and one that runs out is dropped from the cache without anybody re-targeting
---anything. So a look is not a photograph that goes out of date evenly -- it stays exactly right
---about an affliction ending, which is the question being asked here, and can only be wrong about
---one *arriving* since. That is the whole reason a look is trusted at all, and the only reason it
---has to expire: a fresh affliction of the same kind, landed while we were looking elsewhere, would
---read as a clean bar forever.
---
---One ask window, so being wrong costs one refused cure and then a cast that re-targets them and
---settles it. Long enough to cover the case this exists for -- somebody around a corner, cure
---attempt after cure attempt failing on line of sight, every one of them targeting them again --
---where the look never goes stale for as long as we keep trying.
local lookFreshMs = 20000

---How long a request is left alone after a cure lands on it.
---
---The client takes a moment to report counters coming off, and without this the very next pass
---reads the old number and casts the same cure again -- which is how one cure becomes four and
---the tank goes unhealed through all of them.
local settleMs = 1500

---How many cures one request is worth before it is dropped.
---
---Bounded because a cure strips a fixed number of counters and an affliction can carry more than
---one cure's worth, so casting again is *normal* here in a way it is not for a buff -- which is
---exactly why it needs a bound. Something the cure cannot shift (more counters than this
---character can strip before it refreshes, a client that will not report) would otherwise be
---cast at until the world intervened. Generous rather than tight: the ordinary end of a request
---is the affliction going away, and this only catches the case where that never happens.
local maxCasts = 6

---How far away somebody asking for a cure may be and still be found. The same reach `buffme` and
---`healme` look for a speaker over: a name spoken on a channel carries no position, so the spawn
---search is the only way to turn it into somebody to cast at.
local speakerRadius = 300

---How many short-duration slots are looked at alongside the buff window.
---
---The buff window is where a curable affliction lands and the count comes from the client
---(`MaxBuffSlots`); the short window has no equivalent reading, so this is a bound rather than an
---answer. Looked at anyway because the cost is nothing -- the whole walk is behind a single
---counter read that is zero almost every time -- and because being wrong in the other direction
---means an affliction nobody ever mentions.
local shortBuffSlots = 30

---Where a cure call goes when nothing has been configured to speak on.
---
---Load-bearing rather than a nicety, which is why it falls back at all instead of being swallowed:
---nobody else can see what is ticking on this character. Another player's debuffs are not readable
---until they are targeted, and nothing targets a group-mate mid-fight to check, so an unheard line
---is a DoT that runs its full length beside a healer who could have ended it. It is
---machine-to-machine traffic for whoever can answer rather than something the group reads, so bc
---rather than group chat -- `/speak cure <channel>` sends it somewhere else, and `callcure off` is
---how it is turned off; an empty speak list is not that answer.
local fallbackCureSpeak = Speak.new({ Speak.channelTypes.bc.name })

---Afflictions, and what is being done about them.
---
---Curing is two jobs that belong to different characters, and this service is the half that every
---character has: **saying what is on you**, and **holding the list of who has said it**. The other
---half -- choosing a cure and casting it -- is the heal state's, because it is a healer's job and
---has to be arbitrated against healing.
---
---The split is not tidiness. A warrior standing in a poison DoT is exactly the character that has
---to speak up and is exactly the character with no heal state, nothing to cure with, and no way to
---be *seen* to need one: another player's debuffs are unreadable until they are targeted, so the
---fact only exists where it is suffered. So the asking runs everywhere, off this character's own
---bar, and the answering runs wherever there is somebody to answer.
---
---What is held between pulses is the queue and the last reading of our own bar, and both are
---dropped the moment they stop being true: the bar is re-read from the world every scan, our own
---entries in the queue are re-derived from it, and everybody else's live on being repeated (see
---`staleMs`). There is no record of what was cured -- a cure that worked is an affliction that is
---gone, which the world says better than any memory of casting would.
---@class Curing
local Curing = {
    key = "Curing",
    eventIds = {
        -- no trailing space needed, unlike `buff `: nothing else registered starts with "cure",
        -- and a phrase is matched immediately after the channel prefix, so neither `curing` (a
        -- different letter at the fourth character) nor `callcure` (different at the first) can
        -- reach this pattern
        cure = "cure",
        callCure = "callcure"
    },
    _ = {
        isInit = false,
        lastScanMs = 0,
        ---{ [type key] = ms left on the longest affliction of that kind on this character }
        afflictions = {},
        ---{ [type key] = when we last said we had it }
        shoutedAt = {},
        ---outstanding CureRequests, oldest first
        requests = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Curing.key, str)
end

---@return Speak speak where the cure call goes
---@return boolean isFallback whether nothing was configured and the default above is answering
local function cureSpeak()
    local speak = Commands.GetCommandSpeak(Curing.eventIds.cure)
    if #speak:GetActiveSpeakChannels() > 0 then return speak, false end
    ---@diagnostic disable-next-line: return-type-mismatch
    return fallbackCureSpeak, true
end

---------------- What is on us --------------------

---@param found table
---@param buff any mq buff TLO
local function recordAffliction(found, buff)
    local spell = buff.Spell
    if spell == nil or spell.ID() == nil then return end

    -- what makes walking the whole bar affordable, and the reason this is a spell reading rather
    -- than a character one: the client answers `CounterType` out of its own spell file by looking
    -- for any of the four counter effects, and it is "None" for every buff that is not a curable
    -- affliction -- which is nearly all of them, on nearly every character, nearly always. It names
    -- only the *last* counter a spell carries, so it is a gate and not the answer: a spell that is
    -- poison and disease at once still has to be read properly, which is `TypesOf`'s job
    if tostring(spell.CounterType() or "None") == "None" then return end

    local remaining = tonumber(buff.Duration()) or 0

    for _, key in ipairs(CureTypes.TypesOf(spell)) do
        -- the longest of a kind is what decides. Two poisons on us is still one thing to ask
        -- for, and it is not dealt with until the last of them is off
        if (found[key] or -1) < remaining then found[key] = remaining end
    end
end

---What is on this character that a cure would take off, and how long it has left.
---
---The bar is walked every scan, with no "is anything on me at all" reading in front of it. There
---was one -- `Me.TotalCounters`, the obvious choice and free -- and it is **a lie on this server**:
---the client sums it out of per-buff slot data, and that slot data arrives from the server or not
---at all (EQEmu's RoF2 encoder still carries `// TODO: implement slot_data stuff` where it would
---be filled in). So it reads zero on a character standing in a poison DoT with a visible counter on
---the icon, and gating on it did not make curing cheap, it turned curing off: nothing was ever
---recorded, so nothing was ever asked for, on every character, silently.
---
---What is cheap *and* true is the spell file, which is local, complete and identical on every
---server -- so the filter moved one level in, to `recordAffliction`, where a single member per
---occupied slot answers it. Anything read off a buff's *instance* rather than its spell is suspect
---here for the same reason; duration is not, it is what the icon counts down.
---@return table afflictions { [type key] = ms left }
local function scanAfflictions()
    local found = {}

    local buffSlots = tonumber(mq.TLO.Me.MaxBuffSlots()) or shortBuffSlots
    for slot = 1, buffSlots do
        local buff = mq.TLO.Me.Buff(slot)
        if buff.ID() ~= nil then recordAffliction(found, buff) end
    end

    for slot = 1, shortBuffSlots do
        local song = mq.TLO.Me.Song(slot)
        if song.ID() ~= nil then recordAffliction(found, song) end
    end

    return found
end

---@return table afflictions { [type key] = ms left }, as last read
function Curing.GetAfflictions()
    return Curing._.afflictions
end

---@return number ms how long an affliction has to have left before it is worth anybody's cast
function Curing.WorthCuringMs()
    return worthCuringMs
end

---@param typeKey string
---@return boolean worthCuring whether we have this, with long enough left to be worth a cast
local function afflictedBy(typeKey)
    local remaining = Curing._.afflictions[typeKey]
    return remaining ~= nil and remaining >= worthCuringMs
end

---------------- The queue --------------------

---@class CureRequest
---@field id number spawn id of whoever needs it
---@field name string what to call them
---@field typeKey string which cure was asked for
---@field action CastAction what answers it here, chosen when the request was taken on
---@field needsTarget boolean whether that cast has to be aimed at them
---@field isSelf boolean our own affliction, which is re-derived rather than remembered
---@field askedMs number when this was last heard, which is what keeps it alive
---@field casts number cures that have gone out for it
---@field settleUntilMs number while the client is still reporting the counters a cure took off
---@field seenAtMs number when we last had them targeted, and so last saw their bar; 0 for never
---@field lastFailure string|nil why the last cast at them did not happen, for `/ccure`

---@return table requests outstanding cure jobs, oldest first
function Curing.GetRequests()
    return Curing._.requests
end

---@param name string
---@param typeKey string
---@return CureRequest? request
---@return number? index
local function findRequest(name, typeKey)
    for index, request in ipairs(Curing._.requests) do
        if request.typeKey == typeKey and request.name == name then
            return request, index
        end
    end
    return nil, nil
end

---What this character would answer a request of this kind with, and whether it can answer at all.
---
---Resolved once, when the request is taken on, rather than every pass: choosing means walking the
---beneficial half of the book and the AA list reading effects off each, which is far too much to
---do at loop speed and changes only when the character levels.
---@param cureType CureType
---@param targetId number who it is for
---@param isSelf boolean
---@return CastAction? action
---@return boolean needsTarget
---@return string? problem why not, when there is a cure of this kind but it cannot reach them
local function chooseAction(cureType, targetId, isSelf)
    local single, group, selfOnly = CureTypes.Best(cureType)

    -- single first, wherever it is aimed: it is the general-purpose cure, it is the one this
    -- character has the strongest version of nearly always, and it reaches somebody who is not in
    -- this group -- which is most of the people who ever ask
    if single ~= nil then return single, true, nil end

    if isSelf then
        -- a cure written to land only on us is exactly the answer to our own affliction, and a
        -- group cure covers us whether or not anybody is grouped with us
        if selfOnly ~= nil then return selfOnly, false, nil end
        if group ~= nil then return group, false, nil end
        return nil, false, nil
    end

    if group ~= nil then
        -- one cast for six people, but it only reaches this character's own group
        for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
            if tonumber(mq.TLO.Group.Member(index).Spawn.ID()) == targetId then
                return group, false, nil
            end
        end
        return nil, false, "only have " .. cureType.key .. " as a group cure"
    end

    return nil, false, nil
end

---Take a request on, or refresh one already queued for the same person and the same cure.
---
---Refreshing rather than stacking is what makes saying it twice harmless -- and saying it twice is
---the design, not a mistake: whoever is afflicted repeats themselves every `reshoutMs` for as long
---as it is still true, and that repetition is what keeps the entry alive and what tells us the
---cure we already cast did not finish the job. A second entry per repeat would be a queue that
---grows for as long as anybody is poisoned.
---@param request CureRequest
local function queueRequest(request)
    local queued = findRequest(request.name, request.typeKey)
    if queued ~= nil then
        queued.askedMs = request.askedMs
        -- the cast is re-chosen too: a level or an AA purchase since it was queued may have given
        -- this character something better to answer with
        queued.action = request.action
        queued.needsTarget = request.needsTarget
        queued.id = request.id
        return
    end

    Curing._.requests[#Curing._.requests+1] = request
    DebugLog("Queued a cure: " .. request.typeKey .. " for [" .. request.name .. "] with [" ..
        request.action:Name() .. "]")
end

---@param request CureRequest
---@param reason string
local function dropRequest(request, reason)
    for index, queued in ipairs(Curing._.requests) do
        if queued == request then
            table.remove(Curing._.requests, index)
            DebugLog("Dropping the cure of " .. request.typeKey .. " for [" .. request.name ..
                "]: " .. reason)
            return
        end
    end
end

---Keep our own place in the queue honest.
---
---Our own entries are the one part of this list that is *derived* rather than heard, so they are
---re-derived every scan: afflicted long enough to be worth a cast puts us in the queue, and no
---longer being so takes us back out. That is also why they are exempt from the staleness TTL --
---nothing has to repeat itself to us about our own bar.
local function syncSelfRequests()
    local myId = tonumber(mq.TLO.Me.ID())
    local myName = mq.TLO.Me.CleanName()
    if myId == nil or myName == nil then return end

    for _, cureType in ipairs(CureTypes.All()) do
        local queued = findRequest(myName, cureType.key)

        if afflictedBy(cureType.key) then
            if queued == nil then
                local action, needsTarget = chooseAction(cureType, myId, true)
                if action ~= nil then
                    queueRequest({
                        id = myId,
                        name = myName,
                        typeKey = cureType.key,
                        action = action,
                        needsTarget = needsTarget,
                        isSelf = true,
                        askedMs = Time.current_time(),
                        casts = 0,
                        settleUntilMs = 0,
                        seenAtMs = 0
                    })
                end
            else
                queued.id = myId
            end
        elseif queued ~= nil and queued.isSelf then
            dropRequest(queued, "it is off me")
        end
    end
end

---@param request CureRequest
---@return boolean looked whether we have had a good enough look at them to believe their bar
local function lookedRecently(request)
    local seen = request.seenAtMs or 0
    return seen > 0 and Time.current_time() - seen <= lookFreshMs
end

---Notice that we have had a look at somebody in the queue.
---
---A queued request only becomes checkable by **targeting** them: another player's bar arrives in
---one complete packet when this client looks at them, and never otherwise. This does not care why
---it happened -- a cure's own targeting, a heal aimed at the same person, the player clicking them
----- because any of them fills the same cache with the same answer.
---
---**A cast that failed still counts, and that is the point of stamping it here rather than at
---`NoteCast`.** A cure targets first and checks line of sight second, so somebody around a corner
---is targeted by every attempt and cured by none of them: their bar is sitting there, freshly read,
---for the whole time we are unable to reach them. Hanging this off successful casts is what let a
---queue build up behind a wall and then discharge into somebody whose affliction had long since
---worn off.
---
---Every pass rather than on the scan's cadence, because a target is held for the length of a cast
---and then handed to whoever wants it next; half a second is easily long enough to miss one.
---
---**Having them targeted is not the same as having their bar**, and the difference is a whole
---request: the buff packet follows the target by a round trip, so the moment between the two reads
---as a spawn with nothing on it. Stamping on the target alone would hand that gap to
---`readAffliction` as a clean bar and drop a request that was never answered. So the stamp waits
---for the cache to have something in it -- which also means a character carrying literally nothing
---never gets stamped at all, and is read as "no way to tell" rather than "clean". That is the right
---way round: it costs a cure that may not have been needed, where the other way costs somebody
---standing in a DoT nobody will come for.
local function noteLooks()
    local targetId = tonumber(mq.TLO.Target.ID())
    if targetId == nil or targetId < 1 then return end

    local now = Time.current_time()
    local populated = nil

    for _, request in ipairs(Curing._.requests) do
        if request.id == targetId then
            -- read once, and only when somebody in the queue is the one we are looking at
            if populated == nil then
                populated = (tonumber(mq.TLO.Spawn("id " .. tostring(targetId)).BuffCount()) or 0) > 0
            end
            if populated then request.seenAtMs = now end
        end
    end
end

---Is this person still afflicted, as far as this client can see?
---
---The three readings are kept apart on purpose: `true` and `false` are things the world said, and
---`nil` is "there is no way to tell from here", which must never be read as "they are clean". Being
---unable to see is what the repetition from their end is for.
---
---What separates `false` from `nil` is `lookedRecently`, not whether the cache happens to have
---anything in it. The cache is a snapshot the client keeps **counting down by itself** -- an entry
---whose duration runs out is dropped without anybody re-targeting anything -- so "we looked at them
---within the last few seconds and there is no poison there now" is a real answer even though the
---last packet is old, and it is the answer that stops a cure going out at somebody whose DoT ended
---while we were walking round to them. Without a look it is not an answer at all: an empty cache
---and a clean bar are identical from here, and reading the first as the second means never curing
---anybody we have not already cured.
---
---A `true` needs no such qualification. An affliction still sitting in the cache with time on it is
---still on them, or was cured by somebody else in the meantime -- and being wrong in that direction
---costs one cure, not a person left in a DoT.
---@param request CureRequest
---@return boolean|nil stillAfflicted
local function readAffliction(request)
    if request.isSelf then return afflictedBy(request.typeKey) end

    local cureType = CureTypes.Get(request.typeKey)
    if cureType == nil then return nil end

    local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
    if spawn.ID() == nil then return nil end

    for index = 1, (tonumber(spawn.BuffCount()) or 0) do
        local spell = spawn.Buff(index).Spell
        if spell ~= nil and spell.ID() ~= nil and spell.Beneficial() ~= true
            and Spells.HasEffect(spell, { cureType.spa }, function(base) return base > 0 end) then
            return true
        end
    end

    if not lookedRecently(request) then return nil end
    return false
end

---Drop the requests that have stopped meaning anything, so nothing is cast at somebody who does
---not need it and the queue cannot grow without bound.
local function pruneRequests()
    local now = Time.current_time()

    for index = #Curing._.requests, 1, -1 do
        local request = Curing._.requests[index]
        local reason = nil

        if request.isSelf then
            -- handled by the scan, which is a better answer than anything here could be
        elseif now - request.askedMs > staleMs then
            reason = "nobody has asked for it in a while"
        else
            local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
            if spawn.ID() == nil then
                reason = "they are gone"
            elseif spawn.Dead() then
                reason = "they died"
            elseif now >= request.settleUntilMs and readAffliction(request) == false then
                -- not gated on having cured them: a cure is only one of the ways we end up looking
                -- at somebody, and it is the least reliable of them. `readAffliction` will not say
                -- `false` without a recent look, which is the guard this used to be standing in for
                reason = "it is off them"
            end
        end

        if reason ~= nil then
            table.remove(Curing._.requests, index)
            DebugLog("Dropping the cure of " .. request.typeKey .. " for [" .. request.name ..
                "]: " .. reason)
        end
    end
end

---Why this request is not worth a cast right now, if it is not.
---
---A reason rather than a boolean, and the reason is the point: every no on the answering side of
---curing is silent -- a request sits in the queue, nothing is cast, and nothing anywhere says
---which of half a dozen gates said so. `/ccure` puts this on the waiting line, which is the
---difference between "the healer is ignoring me" and an answer.
---
---Everything about *this* request; whether the cure itself can be fired is the caller's question,
---and so is whether curing is something this character should be doing at all.
---@param request CureRequest
---@return string|nil reason nil when it can be cast
function Curing.ReasonNotActionable(request)
    if request.casts >= maxCasts then
        return "already cured " .. tostring(maxCasts) .. " times and it is still there"
    end
    if Time.current_time() < request.settleUntilMs then
        return "waiting for the client to report the last cure"
    end

    if request.isSelf then
        if afflictedBy(request.typeKey) then return nil end
        return "it is off me"
    end

    local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
    if spawn.ID() == nil then return "cannot see them from here" end
    if spawn.Dead() then return "they are dead" end

    if Time.current_time() - request.askedMs > freshAskMs then
        -- they stopped saying it, and they only stop when it stops being true. Held rather than
        -- dropped: `staleMs` still owns that, and one repeat puts this straight back
        return "they have not asked in a while, so it is likely off them already"
    end

    -- **their bar is read before the cure goes out, not only after it.** Asked here as well as in
    -- `pruneRequests` rather than left to it, for two separate reasons. The prune runs on the
    -- scan's half-second cadence while this runs every pass, so between a settle expiring and the
    -- next scan the queue still holds requests the world has already answered. And a queue that has
    -- been held up -- somebody around a corner, out of range, in a fight this character will not
    -- cure during -- is exactly a queue full of answers nobody has checked, which is what turns a
    -- blockage lifting into a burst of cures at people who no longer need them
    if readAffliction(request) == false then
        return "it is off them"
    end

    return nil
end

---@param request CureRequest
---@return boolean isActionable
function Curing.IsActionable(request)
    return Curing.ReasonNotActionable(request) == nil
end

---A cure has gone out for this request. Leave it queued: the job is finished by the affliction
---going away, which is read back afterwards, not by having cast at it.
---@param request CureRequest
function Curing.NoteCast(request)
    request.casts = request.casts + 1
    request.settleUntilMs = Time.current_time() + settleMs
    request.lastFailure = nil
    DebugLog("Cured " .. request.typeKey .. " on [" .. request.name .. "] (" ..
        tostring(request.casts) .. " of " .. tostring(maxCasts) .. ")")
end

---A cure that did not go out. Deliberately not counted against the budget -- the budget bounds
---cures that *landed* and did not finish the job, and a fizzle or a refusal put nothing on
---anybody. The settle is what stops it being asked for again on the very next pass.
---
---The reason is kept rather than only logged, because this is the one thing standing between a
---queue and the person watching it. Every gate in `ReasonNotActionable` says why it said no; a cure
---the *client* refused -- out of range, nothing in the way of line of sight but a wall -- said it
---to the debug log and nowhere else, and a request that keeps being picked up and keeps failing
---looks from `/ccure` exactly like one nobody has touched.
---@param request CureRequest
---@param reason string|nil
function Curing.NoteFailure(request, reason)
    request.settleUntilMs = Time.current_time() + settleMs
    request.lastFailure = reason ~= nil and tostring(reason) or nil
    DebugLog("Cure of " .. request.typeKey .. " on [" .. request.name .. "] failed: " ..
        tostring(reason))
end

---Forget every outstanding request. What `/ccure off` is for.
function Curing.CallOff()
    Curing._.requests = {}
    Curing._.shoutedAt = {}
end

---------------- Saying what is on us --------------------

---Ask for what we are standing in, once per affliction and again while it lasts.
---
---One line per kind rather than one per spell: a cure is chosen by counter, so two poisons are one
---request and being told about both would be two casts of the same spell for one job. Re-armed the
---moment a kind stops being worth curing, so the next one to land is news again.
local function callCure()
    if not CuringConfig.GetCallCure() then
        -- not calling is not the same as having called nothing: forget what was said, so that
        -- switching it back on while something is still ticking asks again rather than assuming
        -- somebody heard
        Curing._.shoutedAt = {}
        return
    end

    local now = Time.current_time()

    for _, cureType in ipairs(CureTypes.All()) do
        if not afflictedBy(cureType.key) then
            Curing._.shoutedAt[cureType.key] = nil
        else
            local said = Curing._.shoutedAt[cureType.key]
            if said == nil or now - said >= reshoutMs then
                Curing._.shoutedAt[cureType.key] = now
                local phrase = Curing.eventIds.cure .. " " .. cureType.key
                DebugLog("Calling for a cure: " .. phrase)
                cureSpeak():speak(phrase)
            end
        end
    end
end

---------------- Init --------------------

---@param stateMachine StateMachine
---@diagnostic disable-next-line: duplicate-set-field
function Curing.Init(stateMachine)
    if Curing._.isInit then return end

    CuringConfig.Init()

    local cureDocs = ChelpDocs.new(function() return {
        "(cure <type>) Asks whoever can for a cure of that kind, on whoever said it",
        " -- Usage: cure <" .. StringUtils.Join(CureTypes.Names(), " | ") .. ">",
        " -- Example: /bc cure poison",
        " -- Said automatically by any character carrying something of that kind with more than a",
        "    minute left on it, and said again every twenty seconds until it is gone -- so this is",
        "    rarely typed by hand. Turn that off with: callcure off",
        " -- A type names the counter rather than a spell, so one line reaches every character:",
        "    each casts the best it has of that kind, and anybody who has none says nothing.",
        " -- Whoever hears it cures on the Heal State page's own terms -- the Curing setting there",
        "    decides whether it is answered at all, and whether it is answered during a fight.",
        " -- Requests queue up and are worked through oldest first; asking again refreshes the one",
        "    already queued rather than adding another."
    } end )

    local function event_Cure(_, speaker, args)
        -- logged before the ACL, which is the only way `/debug Curing` can tell "the line never
        -- arrived" (a channel or a pattern) from "it arrived and was refused". Every other no in
        -- here already says so; being unable to see the *arrival* is what makes a refusal look
        -- exactly like silence from the far end
        DebugLog("Heard a cure call from [" .. tostring(speaker) .. "]:" .. tostring(args))

        if not Commands.GetCommandOwners(Curing.eventIds.cure):HasPermission(speaker) then
            -- **The likeliest reason a healer looks like it is ignoring people.** Every other comm
            -- command is a human order -- "heal me", "buff me", "assist" -- and an owner list is
            -- exactly the right gate for those: it is the list of people allowed to drive this
            -- character. `cure` is not one of those. It is spoken by the *software* on whichever
            -- character is standing in a DoT, reporting a fact about the world rather than asking
            -- for obedience, so the speaker is a groupmate's bot and not the player at the
            -- keyboard -- and a closed owner list refuses every one of them, silently, forever.
            DebugLog("Ignoring cure speaker [" .. tostring(speaker) ..
                "]: not an owner of this character, and the owner list is not open")
            return
        end

        ---Said out loud rather than printed, because whoever typed it is on another character and
        ---a local print is a message they never see. Only by a character that could have answered
        ---something, though: the line went to everybody, and six identical complaints about one
        ---typo are worse than the typo.
        ---@param message string
        local function complain(message)
            if not CureTypes.CouldAnswer() then return end
            Commands.GetCommandSpeak(Curing.eventIds.cure):speak("(cure) " .. message)
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            complain("Nothing named. Usage: cure <" .. StringUtils.Join(CureTypes.Names(), " | ") .. ">")
            return
        end

        local typeName = args[1]
        local cureType = CureTypes.Get(typeName)
        if cureType == nil then
            complain("No cure called [" .. typeName .. "]. /chelp cure lists them")
            return
        end

        local myName = mq.TLO.Me.CleanName()
        local isSelf = myName ~= nil and speaker:lower() == myName:lower()

        -- a name spoken on a channel carries no position, so a spawn search is the only way to
        -- turn the speaker into somebody to cast at. Our own line -- through /cself, a hotbar
        -- button, or a channel that echoes back -- is answered from what we already know about
        -- ourselves, and the scan owns the entry from there
        local id, name
        if isSelf then
            id, name = tonumber(mq.TLO.Me.ID()), myName
        else
            local spawn = mq.TLO.Spawn("pc radius " .. tostring(speakerRadius) .. " " .. speaker)
            id, name = tonumber(spawn.ID()), spawn.CleanName() or speaker
        end

        if id == nil then
            complain("Cannot see [" .. speaker .. "] to cure them")
            return
        end

        local action, needsTarget, problem = chooseAction(cureType, id, isSelf)
        if action == nil then
            if problem ~= nil then
                complain(problem .. ", and [" .. speaker .. "] is not in my group")
            else
                -- the ordinary case, and the reason it is silent: "whoever can" means every
                -- character that cannot has nothing to say
                DebugLog("Nothing here cures " .. cureType.key)
            end
            return
        end

        queueRequest({
            id = id,
            name = name,
            typeKey = cureType.key,
            action = action,
            needsTarget = needsTarget,
            isSelf = isSelf,
            askedMs = Time.current_time(),
            casts = 0,
            settleUntilMs = 0,
            seenAtMs = 0
        })
    end

    Commands.RegisterCommEvent(Command.new(Curing.eventIds.cure, event_Cure, cureDocs)
        :WithArgs({
            required = true,
            hint = "a cure type",
            default = CureTypes.Names()[1],
            choices = function()
                local choices = {}
                for _, cureType in ipairs(CureTypes.All()) do
                    choices[#choices+1] = {
                        label = cureType.summary,
                        args = cureType.key,
                        name = "Cure " .. cureType.key
                    }
                end
                return choices
            end
        }))

    ToggleCommand.Register({
        key = Curing.key,
        phrase = Curing.eventIds.callCure,
        summary = "Turns asking the group for cures on or off",
        about = {
            "On by default. Nobody else can see what is ticking on this character -- another",
            "player's debuffs are unreadable until they are targeted -- so this line is the only",
            "way an affliction becomes anybody's business.",
            "Only what has more than a minute left is asked about, and only once every twenty",
            "seconds while it lasts.",
            "It says nothing about whether this character *answers* anyone else's request: that",
            "is the Curing setting on the Heal State page."
        },
        get = CuringConfig.GetCallCure,
        set = CuringConfig.SetCallCure
    })

    local ccureDocs = ChelpDocs.new(function() return {
        "(/ccure) Report what is on this character, what it can cure, and who is waiting",
        " -- Usage: /ccure",
        " -- Usage (forget every outstanding request): /ccure off",
        " -- Run this on the healer when it looks like cure calls are being ignored. Nothing",
        "    under 'I cure' means the request never queued; a 'held:' note on a waiting line",
        "    means it queued and something is stopping the cast. If neither, the last gate is",
        "    the Heal State page's own Curing setting -- /cheal says whether it is answering",
        "    right now, and why not."
    } end )
    local function Bind_CCure(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            ccureDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            Curing.CallOff()
            print("Cure requests cleared")
            return
        end

        local afflictions = Curing.GetAfflictions()
        local anything = false
        for _, cureType in ipairs(CureTypes.All()) do
            local remaining = afflictions[cureType.key]
            if remaining ~= nil then
                anything = true
                print(" -- on me: " .. cureType.key .. ", " ..
                    tostring(math.floor(remaining / 1000)) .. "s left" ..
                    (remaining >= worthCuringMs and "" or " (too short to be worth curing)"))
            end
        end
        if not anything then
            print("Cure: nothing on me" .. (CuringConfig.GetCallCure() and "" or " (not asking anyway)"))
        end

        -- what this character would answer with, which is the first thing to know on a healer that
        -- looks like it is ignoring people. "Nothing I have" against a type is the whole diagnosis
        -- -- the request is being heard and dropped on the floor before it is ever queued, and
        -- that drop is deliberately silent (every character in earshot hears the same line, and
        -- six identical "I cannot do that" replies are worse than the silence)
        local canCure = {}
        for _, cureType in ipairs(CureTypes.All()) do
            local single, group, selfOnly = CureTypes.Best(cureType)
            local answers = {}
            if single ~= nil then answers[#answers+1] = single:Name() .. " (anyone)" end
            if group ~= nil then answers[#answers+1] = group:Name() .. " (my group)" end
            if selfOnly ~= nil then answers[#answers+1] = selfOnly:Name() .. " (only me)" end
            if #answers > 0 then
                canCure[#canCure+1] = " -- I cure " .. cureType.key .. " with " ..
                    StringUtils.Join(answers, ", ")
            end
        end
        if #canCure < 1 then
            print(" -- I cure nothing: no spell or AA here strips a counter")
        else
            for _, line in ipairs(canCure) do print(line) end
        end

        for _, request in ipairs(Curing.GetRequests()) do
            local blocked = Curing.ReasonNotActionable(request)
            -- both, when there are both: "held" is this service refusing to offer the request and
            -- "last try" is the client refusing the cast, and a line that showed only the first
            -- would report a settle where the real answer is a wall
            print(" -- waiting: " .. request.typeKey .. " for " .. request.name ..
                " with " .. request.action:Name() ..
                " (" .. tostring(request.casts) .. " of " .. tostring(maxCasts) .. " cast)" ..
                (blocked ~= nil and (" -- held: " .. blocked) or "") ..
                (request.lastFailure ~= nil and (" -- last try: " .. request.lastFailure) or ""))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("ccure", Bind_CCure, ccureDocs))

    stateMachine:RegisterService(Curing)

    Curing._.isInit = true
end

---Service contract: keep our own afflictions and our own place in the queue honest, say what we
---are standing in, and drop the requests that have stopped meaning anything.
---
---No casting happens here. This service holds no frame and makes no decision about what is worth
---doing -- that is the heal state's, arbitrated against healing like everything else it does.
function Curing.Pulse()
    local now = Time.current_time()

    -- ahead of everything and off the scan's cadence: a look is a moment, not a state, and missing
    -- one costs the only chance this client gets to know whether a queued cure is still needed
    noteLooks()

    if now - Curing._.lastScanMs >= scanIntervalMs then
        Curing._.lastScanMs = now
        Curing._.afflictions = scanAfflictions()
        syncSelfRequests()
        -- on the same cadence, and for the same reason: squaring a request against the world is a
        -- spawn read and a walk of somebody's buff cache per entry, and nothing it decides changes
        -- inside half a second. Whether a request can be *acted on* is a different question and is
        -- asked every pass by `IsActionable`, so a target that dies mid-cure is still noticed on
        -- the pass it happens rather than up to half a second later
        pruneRequests()
    end

    callCure()
end

return Curing
