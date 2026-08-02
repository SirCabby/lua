---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local BuffStateConfig = require("cabby.configs.buffStateConfig")
local BuffStateMenu = require("cabby.ui.states.buffStateMenu")
local BuffTypes = require("cabby.actions.buffTypes")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
local Spells = require("cabby.actions.spells")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How often the group is re-read. Nothing about who is standing here changes inside half a
---second, and this state watches far more than it acts.
local scanIntervalMs = 500

---How long to leave it before looking again, once a pass has found nothing to buff. Walking
---every slot against everybody is the most expensive thing this state does -- a duration read
---and a stacking check per pairing -- and it is also the answer that changes least often, since
---a buff that has just been checked has half an hour left on it. Cleared the moment something
---*is* cast, so a character being buffed from nothing is buffed at the speed of the casts rather
---than one a second.
local idleLookIntervalMs = 1000

---How long before a pairing is reconsidered after a cast that did not land. Refusals cost
---nothing, so this is only here to stop the same hopeless cast being asked for every pass.
local retryAfterFailureMs = 5000

---The floor under the "it landed, leave it alone" window -- and the *whole* of that window for
---anybody whose buffs can be read back (ourselves, our pet). Past it the buff itself is consulted
---rather than the memory of having cast it, which is what notices one stripped early -- a death,
---a dispel -- inside this long rather than trusted for its full duration. What is left of the
---window doubles as the grace that keeps a buff the player clicked off by hand from being slapped
---straight back on.
local minimumRecheckMs = 30000

---How long an order waits with nothing left to cast before it is treated as finished. A buff
---order is not one cast, it is "give them everything they are missing", so it ends when there is
---nothing more to give rather than when the first cast lands.
local orderIdleMs = 15000

---How far away somebody asking for a buff by name may be and still be found. The same reach
---`buffme` and `healme` look for a speaker over: a name spoken on a channel carries no position,
---so the spawn search is the only way to turn it into somebody to cast at.
local speakerRadius = 300

---How many times one name in a request is cast at before the order gives up on them.
---
---This exists because of the fizzle. A cast that failed did not put the buff on anybody, and the
---commonest reason for one is pure chance -- so moving on after a single failure means a person
---silently never gets what they asked for, which is exactly what the order was for. Four is
---generous against a fizzle rate that is a few percent and still bounded, which matters more:
---somebody standing behind a wall must not hold up everybody queued behind them.
local maxRequestAttempts = 4

---How long before a name is cast at again after a failure.
---
---Long enough for the gem to come back, which is the point: a fizzle puts the spell on its recast,
---and asking again immediately spends an attempt on "not ready yet" instead of on a real cast.
local requestRetryMs = 3000

---How stale a verified answer about another player may grow before it is worth borrowing the
---target to re-read them. Verification exists to catch what the windows cannot know -- a dispel,
---a death nobody saw -- so it only needs to be fast relative to how long anybody would care,
---not relative to the machine.
local verifyIntervalMs = 60000

---How long the buff packet gets to arrive after the target swap before the read is called off.
---An evidence window on the one action verification fires: the target took, so the packet is
---the world's only remaining way of answering, and a second is several server beats. Running
---out is *inconclusive* -- the world said nothing, not "they are naked" -- so the windows stand
---un-contradicted rather than being voided into a blind recast.
local verifyEvidenceMs = 1000

---How long a cast that says it went off waits to be *seen* on the bar of the person it was cast
---at. One target swap and a round trip, which is what a fresh reading costs -- see
---`buffsReadSince` for why it cannot simply be watched for. Running out is inconclusive on the
---same terms as verification: the world said nothing, so the cast's own account of itself stands.
local confirmEvidenceMs = 1500

---How long one pairing is taken at the cast's word again after a sighting has contradicted it.
---
---A backstop against the one shape of mistake this whole idea can make: a buff that lands and is
---never *visible* to us would otherwise be recast the moment its five-second failure window ran
---out, forever. The song window is the known case and is excluded outright (see `startConfirm`),
---so this is for whatever else turns out to behave like it -- one extra cast every few minutes
---rather than one every five seconds, which is cheap enough to be wrong about.
local doubtIntervalMs = 300000

---Where a slot's spell can be aimed, read off the spell rather than configured.
local aims = {
    self = "self",     -- only ever lands on the caster
    pet = "pet",       -- only ever lands on a pet
    group = "group",   -- one cast covers the whole group and needs no target
    single = "single"  -- one person at a time
}

local groupTargetTypes = { ["group v1"] = true, ["group v2"] = true }
local petTargetTypes = { ["pet"] = true, ["pet2"] = true }

---Keeping the buffs up.
---
---The same shape as the heal state, and for the same reason -- the job is a *choice*, not a
---sequence -- but the question is the other way round. Healing asks "who is worst off"; buffing
---asks "what is missing", and the honest answer to that is only partly readable. Your own buffs
---and your pet's are there to be read; everybody else's are visible only once the client has
---cached them, which happens when they are targeted, and an empty cache reads exactly like a
---clean target. So this state reads what it can, casts when what it reads says to, and does not
---ask the same question again for a while afterwards -- which is what the per-pairing retry
---window below is. It is not a give-up timer: it is how long an answer is good for -- and an
---answer can be voided early. Dying strips every buff at once, so an observed death (the scan
---seeing them down, or the world's slain line arriving mid-fight) drops every window held for
---that name, and they are looked at afresh the moment they are back on their feet. Windows on
---the people we *can* read back -- ourselves, our pet -- are kept short instead, so the buff
---itself is re-read and a strip noticed even when no death was seen. And everybody else gets
---the same honesty a minute at a time: when there is nothing to cast, the state borrows the
---target long enough for the server to send what is actually on somebody -- a swap, then a
---status re-checked every pass until the packet lands or a second runs out, never a held frame
----- squares every window it holds for them against the answer, and puts the target back.
---
---Alongside the upkeep there is the other kind of buffing, which is somebody asking for one:
---`buffnow`/`buffme` hand over everything the configured list covers, and `buff <type>` hands over
---one named thing -- see the Requests section below. Requests are answered first, and nothing is
---remembered about them afterwards; a buff handed over on request and a buff kept up are different
---jobs, and only the second one is a record of what is on anybody.
---
---What it deliberately leaves out: other people's pets, curing, and any awareness of what the
---other buffers in the group have already cast.
---@class BuffState : BaseState
local BuffState = {
    key = "BuffState",
    eventIds = {
        -- `buffnow` rather than `buff`, for the reason `healnow` is not `heal`: a registered
        -- phrase also matches every longer line that starts with it, so a plain `buff` would fire
        -- on `buffme`, `buffing off` and every other switch in this family
        buff = "buffnow",
        -- **the trailing space is the whole reason this one is safe**, and it is not a typo. It
        -- goes into the channel pattern with the phrase (`<#1#> buff #2#`), so the literal text
        -- being matched is "buff " -- which `buffme`, `buffgroup`, `buffing` and the rest of the
        -- family do not contain, and every line this command is actually for does, since a type
        -- has to follow it. Everything downstream reads the phrase as `Split(...)[1]`, so the
        -- space never leaves this registration
        buffRequest = "buff ",
        buffMe = "buffme",
        buffing = "buffing",
        buffGroup = "buffgroup",
        buffPets = "buffpets",
        buffCombat = "buffcombat",
        buffAction = "buffaction",
        -- not orders: the world's own death notices, which void the buff records held for
        -- whoever they name
        slain = "buffslain",
        died = "buffdied"
    },
    _ = {
        isInit = false,
        candidates = {},
        lastScanMs = 0,
        nextLookMs = 0,
        castId = nil,
        buffTarget = nil,   -- { id, name, spell } as it was when the cast started
        buffSpell = nil,    -- the spell it actually lands, which for a clicky is not its name
        confirm = nil,      -- { id, name, ... } a cast being squared with the target's own bar
        buffSlot = nil,     -- the configured slot chosen for it, nil for a request
        buffRequest = nil,  -- the BuffRequest it was for, nil for the upkeep list
        buffCoverNames = nil, -- everyone this cast is expected to land on, by name
        buffLastsMs = 0,    -- how long what we are casting lasts
        order = nil,        -- { id, name, idleUntilMs } from a `buffnow <id>` or `buffme`
        requests = {},      -- outstanding `buff <type>` orders, oldest first
        tryAgainAt = {},    -- { ["<slot>@<name>"] = when that pairing is worth looking at again }
        doubted = {},       -- { ["<slot>@<name>"] = when a sighting last contradicted a cast }
        verify = nil,       -- { id, name, startedMs, restoreId } a target-swap re-read in flight
        verifiedAt = {},    -- { [name] = when another player's buffs were last actually seen }
        calledOff = false,
        lastResult = nil,
        holdReason = nil,
        isBard = false      -- read once at Init; a class does not change mid-session
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(BuffState.key, str)
end

---Defined with the rest of the window bookkeeping below; the scan observes the deaths that
---void windows, so it needs the name early.
local buffsWereStripped

---------------- Who we are keeping buffed --------------------

---@class BuffCandidate
---@field id number
---@field name string
---@field class string EQ short name, uppercased; "" when it cannot be read
---@field isSelf boolean
---@field isPet boolean this character's pet
---@field inGroup boolean whether a group cast would reach them

---Everyone worth buffing, and enough about them to decide with.
---
---Group members who are out of the zone or offline are skipped rather than counted as buffed:
---they have no spawn to cast at, and a missing member treated as a present one would hold a group
---buff open forever.
---@return table candidates
local function scanCandidates()
    local candidates = {}
    local seen = {}

    ---@param id number|nil
    ---@param name string|nil
    ---@param class string|nil
    ---@param flags table
    local function add(id, name, class, flags)
        id = tonumber(id)
        if id == nil or id < 1 or seen[id] then return end
        seen[id] = true

        -- `Dead()` is not the whole answer: a player on the way to a corpse reads as a live spawn
        -- at zero or below for as long as the server takes to make the corpse, and every stacking
        -- check on one of those comes back "they need it". Read through `Status`, not `PctHPs`,
        -- which reports a group member the client knows no maximum for as somebody at nothing --
        -- and this is a check that *drops* people, so a wrong reading here empties the group out
        -- of the list and leaves this character buffing nobody but itself
        local pct = Status.HealthPct(mq.TLO.Spawn("id " .. tostring(id)))
        if pct ~= nil and pct <= 0 then
            buffsWereStripped(name or tostring(id))
            return
        end

        candidates[#candidates+1] = {
            id = id,
            name = name or tostring(id),
            class = tostring(class or ""):upper(),
            isSelf = flags.isSelf == true,
            isPet = flags.isPet == true,
            inGroup = flags.inGroup == true
        }
    end

    -- HOVER is dead-but-not-released; DEAD is the beat before it. Our own bar is empty for
    -- either, and everything we remembered casting on ourselves went with it
    local myState = mq.TLO.Me.State()
    if myState == "DEAD" or myState == "HOVER" then
        buffsWereStripped(mq.TLO.Me.CleanName())
    else
        add(mq.TLO.Me.ID(), mq.TLO.Me.CleanName(), mq.TLO.Me.Class.ShortName(), { isSelf = true, inGroup = true })
    end

    if BuffStateConfig.GetBuffGroup() then
        for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
            local member = mq.TLO.Group.Member(index)
            if not member.OtherZone() and not member.Offline() then
                local spawn = member.Spawn
                -- the member, not just the spawn: a dead player often has no live spawn left to
                -- resolve -- hovering leaves only a corpse under another name -- but the group
                -- window still reports them at nothing
                if spawn.Dead() or (tonumber(member.PctHPs()) or 100) <= 0 then
                    buffsWereStripped(member.Name())
                else
                    add(spawn.ID(), spawn.CleanName(), spawn.Class.ShortName(), { inGroup = true })
                end
            end
        end
    end

    if BuffStateConfig.GetBuffPets() then
        local pet = mq.TLO.Me.Pet
        if pet.ID() ~= nil then
            if pet.Dead() then
                buffsWereStripped(pet.CleanName())
            else
                add(pet.ID(), pet.CleanName(), pet.Class.ShortName(), { isPet = true })
            end
        end
    end

    -- whoever asked. They are usually not in the group -- that is the whole point of asking --
    -- so a group cast does not reach them and `inGroup` stays false
    local order = BuffState._.order
    if order ~= nil then
        local spawn = mq.TLO.Spawn("id " .. tostring(order.id))
        if spawn.ID() ~= nil then
            if spawn.Dead() then
                buffsWereStripped(order.name)
            else
                add(spawn.ID(), spawn.CleanName() or order.name, spawn.Class.ShortName(), {})
            end
        end
    end

    return candidates
end

---@return table candidates cached between scans
local function getCandidates()
    local now = Time.current_time()
    if now - BuffState._.lastScanMs >= scanIntervalMs then
        BuffState._.lastScanMs = now
        BuffState._.candidates = scanCandidates()
    end
    return BuffState._.candidates
end

---------------- Reading what is on them --------------------

---@param slot Action
---@return string key naming this slot for the retry window
local function slotKey(slot)
    return tostring(slot.actionType) .. ":" .. tostring(slot.name)
end

---Pairings are named rather than numbered: a spawn id is the zone's name for somebody, and
---zoning deals everybody a new one. These windows are the only record that a cast landed on
---people whose buffs cannot be read back, so a record keyed by id was wiped by every zone line
---and the whole group read as freshly unbuffed on arrival.
---@param slot Action
---@param name string
---@return string key
local function pairKey(slot, name)
    return slotKey(slot) .. "@" .. name
end

---A death voids the records. The hold-off windows say "the buff is on them for another while
---yet", and dying strips every buff at once, so every window held for the dead person's name is
---now a record of something false -- kept, it is exactly the stale remembered state that leaves
---somebody rezzed and standing in the group unbuffed for as long as their windows had left to
---run. Dropped the moment a death is observed instead; a name that never had records is a no-op.
---(Forward-declared above: the candidate scan is what does most of the observing.)
---@param name string|nil
function buffsWereStripped(name)
    if name == nil then return end
    local suffix = "@" .. name
    for key in pairs(BuffState._.tryAgainAt) do
        if key:sub(-#suffix) == suffix then
            BuffState._.tryAgainAt[key] = nil
        end
    end
end

---Drop retry windows that have run out. They are the only thing this state accumulates, and a
---long session in a busy zone would otherwise collect one per person it ever buffed.
local function prune()
    local now = Time.current_time()
    for key, at in pairs(BuffState._.tryAgainAt) do
        if now >= at then
            BuffState._.tryAgainAt[key] = nil
        end
    end
    for key, at in pairs(BuffState._.doubted) do
        if now - at >= doubtIntervalMs then
            BuffState._.doubted[key] = nil
        end
    end
end

---@param slot Action
---@param name string
---@return boolean isDue whether this pairing is worth looking at again yet
local function dueNow(slot, name)
    local at = BuffState._.tryAgainAt[pairKey(slot, name)]
    return at == nil or Time.current_time() >= at
end

---@param slot Action
---@param names table everyone the cast was expected to land on
---@param delayMs number
local function holdOff(slot, names, delayMs)
    local until_ = Time.current_time() + delayMs
    for _, name in ipairs(names or {}) do
        BuffState._.tryAgainAt[pairKey(slot, name)] = until_
    end
end

---How long this buff lasts, in milliseconds. Zero means the spell has no duration at all, which
---is how a heal or a cure reads -- the picker narrows to buff headings but the game's filing is
---not a promise and the narrowing can be switched off, so one of those ending up in a buff list is
---a mistake worth catching rather than one worth casting on a loop. Read through `Spells`, which
---is where the ad-hoc `buff <type>` requests read it from too.
---@param spell any mq spell TLO
---@return number ms
local function durationMs(spell)
    return Spells.DurationMs(spell)
end

---The name of what a cast actually leaves on somebody, which is not always what the cast is
---called: a clicky is named for the item and an AA for the ability, while the thing that turns up
---on a buff bar is the spell behind either. Read once when the cast starts, because that is the
---name to go looking for afterwards.
---@param subject CastSubject
---@return string|nil name nil when the spell behind it cannot be read
local function spellNameOf(subject)
    local spell = subject:Spelldata()
    if spell == nil then return nil end
    return spell.Name()
end

---How little has to be left on this slot's buff before it is recast: the slot's own dial, but
---never more than half of what the buff actually lasts. Without the clamp, "rebuff early" on a
---buff shorter than the headroom would mean recasting it the moment it lands -- the dial says
---how close to fading is too close, and a buff cannot spend its whole life nearly gone.
---@param slot Action
---@param lastsMs number what the buff lasts, from `durationMs`
---@return number ms
local function rebuffAtMs(slot, lastsMs)
    local configured = BuffStateConfig.GetRebuffMs(slot)
    if lastsMs <= 0 then return configured end
    return math.min(configured, math.floor(lastsMs / 2))
end

---How long is left on this buff, where the client can tell us.
---
---`nil` means "not on them" *and* "we cannot see", which for anybody but ourselves and our pet
---are the same reading: another player's buffs are only visible once the client has cached them,
---which happens when they are targeted, and an empty cache is indistinguishable from a clean
---one. A cached entry ages by itself -- what it reports is what is left *now*, not what was left
---when it was cached -- so a stale cache decays into "they need it" rather than lying about it.
---@param spell any mq spell TLO
---@param candidate BuffCandidate
---@return number|nil ms
local function remainingMs(spell, candidate)
    local name = spell.Name()
    if name == nil then return nil end

    if candidate.isSelf then
        local buff = mq.TLO.Me.Buff(name)
        if buff.ID() ~= nil then
            return tonumber(buff.Duration()) or 0
        end
        -- a short buff sits in the song window instead, and is no less on us for it
        local song = mq.TLO.Me.Song(name)
        if song.ID() ~= nil then
            return tonumber(song.Duration()) or 0
        end
        return nil
    end

    if candidate.isPet then
        return tonumber(mq.TLO.Me.Pet.BuffDuration(name)())
    end

    local cached = mq.TLO.Spawn("id " .. tostring(candidate.id)).CachedBuff(name)
    if cached.SpellID() == nil then return nil end
    return tonumber(cached.Duration()) or 0
end

---Whether what the client holds for this spawn's buffs was read *after* a given moment.
---
---There is one place another player's buffs can be read from, and it is filled solely by the
---client's **complete** buff message. The partial ones -- a single buff sent down on its own,
---which is what the server sends when one lands on somebody we are looking at -- are thrown away
---on purpose, because a buff arriving without the rest would leave the cache reporting a bar
---nobody has.
---
---Which has a consequence worth stating plainly, because it is the opposite of what watching a
---target feels like: **a buff landing on somebody we already have targeted is never seen.** The
---reading we hold is the snapshot taken when the target last landed on them -- for a cast, from
---before it was even fired -- and it will sit there unchanged however long it is watched. The only
---way to a newer one is to make the client ask for the whole bar again, which it does when the
---target changes.
---
---So freshness is read off the cache entries themselves, each of which carries the moment its
---packet arrived. Nothing fresh is not the same as nothing there: a bar we have never been sent
---reads exactly like an empty one, and this is the question that tells those apart -- which is
---what makes an absent buff worth acting on rather than a shrug.
---@param id number
---@param sinceMs number a reading older than this is the snapshot from before
---@return boolean isFresh
local function buffsReadSince(id, sinceMs)
    local spawn = mq.TLO.Spawn("id " .. tostring(id))
    local count = tonumber(spawn.CachedBuffCount()) or 0
    local age = Time.current_time() - sinceMs

    for index = 1, count do
        local staleness = tonumber(spawn.Buff(index).Staleness())
        if staleness ~= nil and staleness <= age then return true end
    end

    return false
end

---Should this buff be cast on this person right now?
---
---Two questions, in the order that answers them cheapest. If it is on them, the only thing left
---to ask is whether it is nearly gone -- "nearly" being the slot's own dial. If it is not, the
---question is whether it would land at all -- which is what the client's own stacking check
---answers, and it answers more than "do they already have it": a better buff in the same line,
---or a buff too powerful for them to take, both come back as "no" without a cast being spent to
---find out.
---@param slot Action
---@param spell any mq spell TLO
---@param lastsMs number what the buff lasts
---@param candidate BuffCandidate
---@return boolean needsIt
local function needsBuff(slot, spell, lastsMs, candidate)
    local remaining = remainingMs(spell, candidate)
    if remaining ~= nil then
        return remaining <= rebuffAtMs(slot, lastsMs)
    end

    if candidate.isSelf then
        -- a buff the player has blocked will report as cast and never appear, so asking here is
        -- the difference between one wasted cast every half hour and none
        if mq.TLO.Me.BlockedBuff(spell.Name()).ID() ~= nil then return false end
        return spell.Stacks() == true
    end

    if candidate.isPet then
        return spell.StacksPet() == true
    end

    return spell.StacksSpawn(candidate.id)() == true
end

---------------- Choosing a buff --------------------

---@param subject CastSubject
---@return string aim one of `aims`
local function aimOf(subject)
    local targetType = subject:TargetType()
    if groupTargetTypes[targetType] then return aims.group end
    if petTargetTypes[targetType] then return aims.pet end
    if targetType == "self" then return aims.self end
    return aims.single
end

---Is this slot meant for this person?
---
---What the spell can be aimed at is read off the spell and comes first: a pet buff is for pets
---whatever the slot says, and a self buff is for us. Scope and the class list narrow what is left
----- and they narrow a group buff too, which is what stops a group haste being cast because the
---wizard is missing it.
---@param slot Action
---@param aim string
---@param candidate BuffCandidate
---@return boolean applies
local function appliesTo(slot, aim, candidate)
    if aim == aims.self then return candidate.isSelf end
    if aim == aims.pet then return candidate.isPet end

    -- what is left is cast on people, and a pet is not one
    if candidate.isPet then return false end
    if aim == aims.group and not candidate.inGroup then return false end

    if not BuffStateConfig.IsClassAllowed(slot, candidate.class) then return false end

    local scope = BuffStateConfig.GetScope(slot)
    if scope == BuffStateConfig.scopes.Self.value then return candidate.isSelf end
    if scope == BuffStateConfig.scopes.Others.value then return not candidate.isSelf end
    return true
end

---@param candidates table
---@return table names everyone a group cast from here would land on
local function groupCoverage(candidates)
    local names = {}
    for _, candidate in ipairs(candidates) do
        if candidate.inGroup and not candidate.isPet then
            names[#names+1] = candidate.name
        end
    end
    return names
end

---@class BuffPick
---@field action ActionType
---@field slot Action
---@field targetId number|nil nil for a group buff, which needs no target
---@field name string what is being buffed, for status output
---@field coverNames table everyone this cast is expected to land on, by name
---@field lastsMs number how long what it lands lasts

---Who this state is when it asks the casting service for something.
---@param targetId number|nil
---@return table request
function BuffState.CastRequest(targetId)
    return {
        owner = BuffState.key,
        priority = BuffState.priority,
        targetId = targetId
    }
end

---The first person this slot is worth casting on right now.
---@param slot Action
---@param candidates table
---@return BuffPick? pick
local function choosePickFor(slot, candidates)
    if not Action.IsEnabled(slot) then return nil end

    local action = Action.GetActionType(slot)
    -- casts only: this state polls the cast it started, which a skill or a discipline has no
    -- equivalent of. Only casts are offered on the page; this is for a config edited by hand.
    if action == nil or action.Subject == nil then return nil end

    local subject = action:Subject()
    local spell = subject:Spelldata()
    if spell == nil then return nil end

    local lastsMs = durationMs(spell)
    if lastsMs <= 0 then return nil end

    if not Action.GetLuaResult(slot) then return nil end

    local aim = aimOf(subject)
    local needsTarget = subject:NeedsTarget()

    for _, candidate in ipairs(candidates) do
        if appliesTo(slot, aim, candidate) and dueNow(slot, candidate.name) and needsBuff(slot, spell, lastsMs, candidate) then
            -- a spell that aims itself is cast at nobody. EQ puts a self buff on us and a pet buff
            -- on our pet with nothing targeted, and a group buff on the group; targeting for one
            -- of those would drop whatever we were looking at to no purpose
            local targetId = needsTarget and candidate.id or nil
            local isGroupCast = aim == aims.group

            if action:IsReady(BuffState.CastRequest(targetId)) then
                return {
                    action = action,
                    slot = slot,
                    targetId = targetId,
                    name = isGroupCast and "the group" or candidate.name,
                    -- one person short of it is enough to cast a group buff, and the rest of the
                    -- group gets it whether they were short of it or not
                    coverNames = isGroupCast and groupCoverage(candidates) or { candidate.name },
                    lastsMs = lastsMs
                }
            end

            -- one cast, whoever it was chosen for: there is no other candidate to try
            if isGroupCast then return nil end
            -- otherwise "not castable at *them*" -- out of range, out of sight -- says nothing
            -- about the next person on the list, so keep looking rather than dropping the slot
        end
    end

    return nil
end

---What to cast, and on whom, right now.
---
---The list order is the whole priority: the first slot that somebody is missing wins, which is
---why the page says to put what matters at the top. Unlike healing there is nobody to rank --
---everyone standing here is equally unbuffed -- so the ordering that matters is the one the user
---already gave us.
---@param candidates table
---@return BuffPick? pick
local function choosePick(candidates)
    if #candidates < 1 then return nil end

    for _, slot in ipairs(BuffStateConfig.GetActions()) do
        local pick = choosePickFor(slot, candidates)
        if pick ~= nil then return pick end
    end

    return nil
end

---------------- Re-reading the watch list --------------------

---Whoever the target lands on next, the client fills that spawn's buff cache from the server's
---answer -- which is the one way another player's bar can actually be read. The procedure is a
---swap and a wait, and the wait is a status looked at again every pass, never a held frame: the
---packet arrives on the server's clock, and nothing below this state conflicts with standing
---here while it does. Only spent on somebody a buff could actually be cast at from here: the
---swap is an intrusion on the player's target, and the answer is worth nothing if the recast it
---might call for would be refused for range or line of sight anyway.

---Is anything held for them worth the swap -- and could we do anything about the answer?
---
---Two halves of one question. There is nothing to square if no live window is held for them, and
---nothing to be done about a voided one if they are out of reach or behind a wall: everything
---this state would do about it is a cast at them, and that cast is refused for exactly those two
---reasons. So the reach is read off the spells whose windows are live, the same way the cast
---itself reads it, rather than being a number of our own. Somebody skipped this way keeps their
---unread mark rather than being marked looked-at, so they are read the moment they walk back
---into reach instead of a minute afterwards.
---@param candidate BuffCandidate
---@return boolean worthReading
local function hasReachableWindows(candidate)
    local spawn = mq.TLO.Spawn("id " .. tostring(candidate.id))
    if spawn.ID() == nil then return false end
    if spawn.LineOfSight() == false then return false end

    local distance = tonumber(spawn.Distance())
    local now = Time.current_time()

    for _, slot in ipairs(BuffStateConfig.GetActions()) do
        local at = BuffState._.tryAgainAt[pairKey(slot, candidate.name)]
        if at ~= nil and at > now then
            local action = Action.GetActionType(slot)
            local subject = (action ~= nil and action.Subject ~= nil) and action:Subject() or nil
            if subject ~= nil then
                -- no range at all means the spell carries no limit worth checking, not that it
                -- cannot reach; an unreadable distance is the same non-answer
                local range = subject:Range()
                if range <= 0 or distance == nil or distance <= range then return true end
            end
        end
    end

    return false
end

---The first person whose records are worth re-reading against the world: somebody whose buffs
---cannot be read from here, holding at least one live window they are still in reach of, not
---looked at for a while. A landed cast counts as looked at -- verification is for what changes
---*between* casts.
---@param candidates table
---@return BuffCandidate? candidate
local function chooseVerify(candidates)
    local now = Time.current_time()
    for _, candidate in ipairs(candidates) do
        if not candidate.isSelf and not candidate.isPet then
            local at = BuffState._.verifiedAt[candidate.name]
            if (at == nil or now - at >= verifyIntervalMs) and hasReachableWindows(candidate) then
                return candidate
            end
        end
    end
    return nil
end

---Look somewhere else for a moment, so that looking back at somebody counts as a *change* and the
---client asks the server for their bar again -- which it does then and at no other time.
---
---Ourselves, by name rather than by spawn id: `myself` is answered from the local player directly,
---so it is the one target that is always there, always in reach, and cannot be refused or wander
---off between the frame that looks away and the frame that looks back.
local function lookAway()
    mq.cmd("/mqtarget myself")
end

---@param candidate BuffCandidate
local function startVerify(candidate)
    local restoreId = tonumber(mq.TLO.Target.ID())
    BuffState._.verify = {
        id = candidate.id,
        name = candidate.name,
        startedMs = Time.current_time(),
        restoreId = restoreId ~= candidate.id and restoreId or nil,
        -- Already looking at them, so there is nothing to change and nothing will be sent. The
        -- reading we hold is whatever arrived when the target first landed on them, which is
        -- exactly the answer this is here to go behind, so the look has to start by looking away.
        lookAway = restoreId == candidate.id
    }

    DebugLog("Borrowing the target to re-read [" .. candidate.name .. "]'s buffs")
    if restoreId ~= candidate.id then
        mq.cmdf("/mqtarget id %d", candidate.id)
    end
end

---A cast leaves its target where it lands, but a read has no business leaving a mark: whatever
---was targeted before the swap goes back -- unless somebody else has taken the target since,
---in which case it is theirs now.
---@param verify table
local function restoreTarget(verify)
    if verify.restoreId == nil then return end
    if tonumber(mq.TLO.Target.ID()) ~= verify.id then return end
    if mq.TLO.Spawn("id " .. tostring(verify.restoreId)).ID() == nil then return end
    mq.cmdf("/mqtarget id %d", verify.restoreId)
end

---The packet is in and the client just replaced their whole cache with it, so for one moment
---another player's bar reads like our own. Every live window held for them is squared against
---it: a buff that is gone voids its record, one still up resyncs the record to what is actually
---left -- longer or shorter, observation replaces inference. The recast decision itself is not
---made here: voided records make the next look ask its normal questions, against this same
---fresh cache.
---@param verify table
local function concludeVerify(verify)
    local now = Time.current_time()
    local candidate = { id = verify.id, name = verify.name }

    for _, slot in ipairs(BuffStateConfig.GetActions()) do
        local key = pairKey(slot, verify.name)
        local at = BuffState._.tryAgainAt[key]
        if at ~= nil and at > now then
            local action = Action.GetActionType(slot)
            local spell = (action ~= nil and action.Subject ~= nil) and action:Subject():Spelldata() or nil
            if spell ~= nil then
                local rebuffMs = rebuffAtMs(slot, durationMs(spell))
                local remaining = remainingMs(spell, candidate)
                if remaining == nil or remaining <= rebuffMs then
                    BuffState._.tryAgainAt[key] = nil
                else
                    BuffState._.tryAgainAt[key] = now + remaining - rebuffMs
                end
            end
        end
    end

    BuffState._.verifiedAt[verify.name] = now
    -- something may have been voided; the very next pass is worth a real look
    BuffState._.nextLookMs = 0
    DebugLog("Re-read [" .. verify.name .. "]'s buffs from the target window")
end

---One pass of the re-read: quick checks from the world, then out of the way.
---@param code string|nil the hold code this pass, if any
local function progressVerify(code)
    local verify = BuffState._.verify

    -- a fight owns the target now. The swap is abandoned where it stands: whoever the fight
    -- picks is not ours to put back
    if code == "fighting" then
        BuffState._.verify = nil
        return
    end

    local spawn = mq.TLO.Spawn("id " .. tostring(verify.id))
    if spawn.ID() == nil or spawn.Dead() then
        -- gone or dead mid-read; the death observations already handle their records
        restoreTarget(verify)
        BuffState._.verify = nil
        return
    end

    local targetId = tonumber(mq.TLO.Target.ID())

    -- one frame away and one frame back, which is the whole of "ask the server again"
    if verify.lookAway then
        if Time.current_time() - verify.startedMs > verifyEvidenceMs then
            -- the swap never took; leave the windows standing and try again in a minute
            BuffState._.verifiedAt[verify.name] = Time.current_time()
            BuffState._.verify = nil
            return
        end

        if targetId == verify.id then
            if not verify.lookedAway then
                verify.lookedAway = true
                lookAway()
            end
            return
        end

        verify.lookAway = false
        -- the clock starts here: what came before the look was the reading being gone behind
        verify.startedMs = Time.current_time()
        mq.cmdf("/mqtarget id %d", verify.id)
        return
    end

    if targetId == verify.id and buffsReadSince(verify.id, verify.startedMs) then
        concludeVerify(verify)
        restoreTarget(verify)
        BuffState._.verify = nil
        return
    end

    if Time.current_time() - verify.startedMs > verifyEvidenceMs then
        -- ran out without an answer -- or without ever holding the target, which includes the
        -- player taking it mid-read, so only a swap we still hold is put back
        BuffState._.verifiedAt[verify.name] = Time.current_time()
        if targetId == verify.id then
            restoreTarget(verify)
        end
        BuffState._.verify = nil
    end
end

---------------- The state itself --------------------

function BuffState.Reset()
    BuffState._.castId = nil
    BuffState._.buffTarget = nil
    BuffState._.buffSpell = nil
    BuffState._.confirm = nil
    BuffState._.buffSlot = nil
    BuffState._.buffRequest = nil
    BuffState._.buffCoverNames = nil
    BuffState._.buffLastsMs = 0
    BuffState._.verify = nil
end

---Reasons to hold everything, in the order they are worth reporting.
---
---`fighting` also means "and stop what you are already doing": a buff landing two seconds before
---the mob dies is mana the healer wanted, and the cast holds the target away from what is being
---fought while it runs.
---@return string|nil code
---@return string|nil reason in words
local function holdReason()
    if Combat.IsEngaged() and not BuffStateConfig.GetInCombat() then
        return "fighting", "not while we are fighting"
    end

    -- bards sing on the move, which the casting service already knows; for everyone else a buff
    -- asked for while running is a cast that sits holding a target and a gem until the group
    -- stops, and this is a state that can afford to ask again later instead
    if not BuffState._.isBard and mq.TLO.Me.Moving() then
        return "moving", "waiting until we stop moving"
    end

    return nil, nil
end

---@return string description of what this state is doing, for /cbuff and the menu
function BuffState.Describe()
    if BuffState._.confirm ~= nil then
        return "checking that " .. BuffState._.confirm.spell .. " landed on " .. BuffState._.confirm.name
    end
    if BuffState._.castId ~= nil and BuffState._.buffTarget ~= nil then
        return "casting " .. tostring(BuffState._.buffTarget.spell) .. " on " .. BuffState._.buffTarget.name
    end
    if BuffState._.verify ~= nil then
        return "re-reading " .. BuffState._.verify.name .. "'s buffs"
    end
    if BuffState._.holdReason ~= nil then
        return "holding: " .. BuffState._.holdReason
    end
    local requests = #BuffState._.requests
    if requests > 0 then
        return "watching, with " .. tostring(requests) .. (requests == 1 and " request" or " requests") .. " waiting"
    end
    return "watching"
end

---@return table requests the `buff <type>` orders still outstanding, oldest first
function BuffState.GetRequests()
    return BuffState._.requests
end

---@return string|nil result how the last buff went
function BuffState.GetLastResult()
    return BuffState._.lastResult
end

---@return table candidates everyone this state is keeping buffed, as last read
function BuffState.GetCandidates()
    return BuffState._.candidates
end

---How many configured buffs somebody is missing right now. Worked out on demand rather than
---kept: it is a whole pass over the list per person, which is exactly what the state throttles
---itself for, and nothing but a status readout ever asks.
---@param candidate BuffCandidate
---@return number count
---@return number configured how many slots could apply to them at all
function BuffState.CountMissing(candidate)
    local missing, configured = 0, 0

    for _, slot in ipairs(BuffStateConfig.GetActions()) do
        local action = Action.IsEnabled(slot) and Action.GetActionType(slot) or nil
        if action ~= nil and action.Subject ~= nil then
            local subject = action:Subject()
            local spell = subject:Spelldata()
            local lastsMs = spell ~= nil and durationMs(spell) or 0
            if lastsMs > 0 and appliesTo(slot, aimOf(subject), candidate) then
                configured = configured + 1
                if needsBuff(slot, spell, lastsMs, candidate) then
                    missing = missing + 1
                end
            end
        end
    end

    return missing, configured
end

---@class BuffSlotFacts
---@field aim string one of `aims`
---@field aimText string what that means, in words
---@field scoped boolean whether there is anybody to choose between, and so anything to scope
---@field lastsMs number how long what it lands lasts
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user. Everything here is
---read off the spell rather than configured, so it is also the answer to "why is this one not
---firing" -- which is otherwise a silent puzzle.
---@param slot Action
---@return BuffSlotFacts facts
function BuffState.DescribeSlot(slot)
    local facts = { aim = aims.single, aimText = "one at a time", scoped = true, lastsMs = 0, problem = nil }

    -- a row being filled in has nothing to report yet, and "this character does not have it" is a
    -- strange thing to say about a spell nobody has picked
    if slot.name == nil or slot.name == "" then return facts end

    local action = Action.GetActionType(slot)
    if action == nil then
        facts.problem = "this character does not have it"
        return facts
    end
    if action.Subject == nil then
        facts.problem = "only spells, clickies and AAs can be kept up"
        return facts
    end

    local subject = action:Subject()
    facts.aim = aimOf(subject)
    facts.aimText = ({
        [aims.self] = "on me",
        [aims.pet] = "on a pet",
        [aims.group] = "on the group, in one cast",
        [aims.single] = "one at a time"
    })[facts.aim]
    -- a self buff and a pet buff have nobody to choose between, so there is nothing to scope
    facts.scoped = facts.aim ~= aims.self and facts.aim ~= aims.pet

    local spell = subject:Spelldata()
    if spell == nil then
        facts.problem = "no spell data"
        return facts
    end

    facts.lastsMs = durationMs(spell)
    if facts.lastsMs <= 0 then
        facts.problem = "it has no duration, so it is not a buff"
    end

    return facts
end

---Start the buff this pass decided on.
---@param pick BuffPick
---@return boolean isBusy
local function startBuff(pick)
    local subject = pick.action:Subject()
    local castId, refused = Casting.Cast(subject, BuffState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Buff of [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Buffing [" .. pick.name .. "] with [" .. pick.action:Name() .. "]")
    BuffState._.castId = castId
    BuffState._.buffTarget = { id = pick.targetId, name = pick.name, spell = pick.action:Name() }
    -- what actually lands, which for a clicky or an AA is not what the slot is called, and is what
    -- has to be looked for on the bar afterwards
    BuffState._.buffSpell = spellNameOf(subject)
    BuffState._.buffSlot = pick.slot
    BuffState._.buffCoverNames = pick.coverNames
    BuffState._.buffLastsMs = pick.lastsMs

    -- an order is "give them everything they are missing", so every cast that reaches them is a
    -- reason to keep it open
    local order = BuffState._.order
    if order ~= nil then
        for _, name in ipairs(pick.coverNames) do
            if name == order.name then
                order.idleUntilMs = Time.current_time() + orderIdleMs
            end
        end
    end

    return true
end

---Is the buff in the air still worth finishing?
---@param code string|nil the hold code this pass, if any
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandon(code)
    if code == "fighting" then return "a fight started" end

    local target = BuffState._.buffTarget
    if target == nil or target.id == nil then return nil end

    local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
    if spawn.ID() == nil then return "they are gone" end
    if spawn.Dead() then return "they died" end

    return nil
end

---------------- Squaring a cast with the person it was cast at --------------------

---A cast that says it went off is the *client* saying so, and on this one question the client is
---not the authority. A fizzle is rolled at the server's end of the cast, so the line announcing it
---can arrive after our own cast bar has closed and the cast has already been called a success --
---and for a buff that is the one mistake there is no coming back from on its own: the person is
---crossed off, and nothing asks about them again until a buff that was never cast would have run
---out. Somebody standing in the group without the invisibility they asked for, and no message
---anywhere saying so.
---
---So a cast aimed at one person is not believed until the buff has been *seen* on them. Which is
---not the same thing as watching for it to appear: the reading we hold was taken when the cast
---targeted them, from before it was fired, and the update that carries the new buff is thrown away
---for being partial (`buffsReadSince` has the why). The client has to be made to ask for the whole
---bar again, and the look away and back below is that.
---
---Three answers, and the third is what keeps it honest:
---
---- **seen** -- it landed, whatever the cast said, and what is really left on it is now known.
---- **a fresh reading without it** -- it did not land, whatever the cast said. This is the answer
---  that was missing, and it goes back to the caller as the failure it is: a request retries at
---  the same person exactly as it always has for a fizzle it heard about in time.
---- **no fresh reading at all** -- the world did not answer. The cast's own account stands, which
---  is what happened before any of this existed, so a quiet server costs the wait and nothing else.

---What the world says about a buff we think we have just put on somebody.
---@param confirm table
---@return boolean|nil isOn nil when nothing fresh enough to answer has arrived
---@return number|nil remaining what is left on it, when it is on them
local function sightBuff(confirm)
    local spell = mq.TLO.Spell(confirm.spell)
    if spell.ID() == nil then return nil, nil end

    -- our own bar and our pet's are there to be read at any moment: no packet to wait on and no
    -- swap to pay for, so the only reason not to see it yet is that it has not arrived
    if confirm.readable then
        local remaining = remainingMs(spell, { id = confirm.id, isSelf = confirm.isSelf, isPet = confirm.isPet })
        if remaining == nil then return nil, nil end
        return true, remaining
    end

    if not buffsReadSince(confirm.id, confirm.startedMs) then return nil, nil end

    local cached = mq.TLO.Spawn("id " .. tostring(confirm.id)).CachedBuff(confirm.spell)
    if cached.SpellID() == nil then return false, nil end
    return true, tonumber(cached.Duration()) or 0
end

---Take the cast that has just finished and go and look, when looking is worth it.
---@param status string what the cast reported
---@param outcome string|nil
---@param reason string|nil
---@param code string|nil the hold code this pass, if any
---@return boolean isConfirming true when the result is not to be recorded yet
local function startConfirm(status, outcome, reason, code)
    -- A cast that says it failed is about to be cast again. Hearing it from the buff bar as well
    -- would only put a target swap between the failure and the retry.
    if status ~= Casting.status.succeeded then return false end

    -- one we called off ourselves: nobody is waiting on the answer any more
    if BuffState._.calledOff then return false end

    -- Only a cast aimed at one named person can be squared this way: a group cast lands on six
    -- bars at once, and a self-aimed buff is cast at nobody's target at all.
    local target = BuffState._.buffTarget
    local spellName = BuffState._.buffSpell
    if target == nil or target.id == nil or spellName == nil then return false end

    -- a fight has a better claim on the target than a piece of bookkeeping does
    if code == "fighting" then return false end

    -- A song is never going to be seen, whether or not it landed: the client sends songs down with
    -- the rest of a target's bar and the game's own reader throws that part away, so there is no
    -- reading of anybody else's songs to be had at any price. Asking would fail every bard song
    -- ever cast and recast it until the budget ran out. Where the spell lands is the question --
    -- not what class we are -- so a short clicky that files itself the same way is covered too.
    local spell = mq.TLO.Spell(spellName)
    if spell.ID() == nil or tonumber(spell.DurationWindow()) ~= 0 then return false end

    local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
    if spawn.ID() == nil or spawn.Dead() then return false end

    local myId = tonumber(mq.TLO.Me.ID())
    local petId = tonumber(mq.TLO.Me.Pet.ID())
    local isSelf = target.id == myId
    local isPet = petId ~= nil and target.id == petId

    BuffState._.confirm = {
        id = target.id,
        name = target.name,
        spell = spellName,
        status = status,
        outcome = outcome,
        reason = reason,
        startedMs = Time.current_time(),
        isSelf = isSelf,
        isPet = isPet,
        readable = isSelf or isPet,
        -- the cast left the target on them, which is where a cast leaves it, so there is nothing
        -- to put back when this is done
        restoreId = nil,
        lookAway = not (isSelf or isPet)
    }

    return true
end

---One pass of the look. Same shape as the re-read above: quick questions of the world, then out
---of the way.
---@param code string|nil the hold code this pass, if any
---@return table|nil settled { status, outcome, reason, remainingMs } once there is an answer
local function progressConfirm(code)
    local confirm = BuffState._.confirm
    local now = Time.current_time()

    ---@param status string
    ---@param remaining number|nil
    ---@param note string|nil
    ---@return table settled
    local function settle(status, remaining, note)
        restoreTarget(confirm)
        BuffState._.confirm = nil
        return {
            status = status,
            outcome = confirm.outcome,
            reason = note or confirm.reason,
            remainingMs = remaining
        }
    end

    -- a fight owns the target now; the look is abandoned where it stands and the cast keeps the
    -- account it gave of itself
    if code == "fighting" then return settle(confirm.status, nil) end

    local spawn = mq.TLO.Spawn("id " .. tostring(confirm.id))
    if spawn.ID() == nil or spawn.Dead() then return settle(confirm.status, nil) end

    -- one frame away and one frame back, which is the whole of asking for their bar again
    if confirm.lookAway then
        -- The look never got going. Nothing here is worth holding the state up over: this is a
        -- check on a cast that is already over, and the cast's own account of itself is what
        -- stood before there was anything to check it against.
        if now - confirm.startedMs > confirmEvidenceMs then
            DebugLog("Could not borrow the target to look at [" .. confirm.name .. "]'s buffs")
            return settle(confirm.status, nil)
        end

        if tonumber(mq.TLO.Target.ID()) == confirm.id then
            -- asked once; the window above is what covers a swap that does not take
            if not confirm.lookedAway then
                confirm.lookedAway = true
                lookAway()
            end
            return nil
        end

        confirm.lookAway = false
        -- the clock starts here: everything read before the look is the answer being gone behind
        confirm.startedMs = now
        mq.cmdf("/mqtarget id %d", confirm.id)
        return nil
    end

    ---Contradicting the cast, if we have not just done so about this same pairing.
    ---@return table settled
    local function contradict()
        local slot = BuffState._.buffSlot

        -- An order somebody typed needs no backstop: it is bounded by its own budget of tries and
        -- says out loud what it gave up on. The upkeep list is the one that would go round for
        -- ever, since a pairing that fails is simply due again five seconds later.
        if slot ~= nil then
            local key = pairKey(slot, confirm.name)
            local doubtedAt = BuffState._.doubted[key]
            if doubtedAt ~= nil and now - doubtedAt < doubtIntervalMs then
                DebugLog("[" .. confirm.spell .. "] is still not showing on [" .. confirm.name ..
                    "]; taking the cast at its word rather than casting it again")
                return settle(confirm.status, nil)
            end
            BuffState._.doubted[key] = now
        end

        DebugLog("[" .. confirm.spell .. "] is not on [" .. confirm.name .. "], and the cast said it landed")
        return settle(Casting.status.failed, nil, "it did not land on " .. confirm.name)
    end

    local isOn, remaining = sightBuff(confirm)

    if isOn == true then
        DebugLog("[" .. confirm.spell .. "] is on [" .. confirm.name .. "]")
        local slot = BuffState._.buffSlot
        if slot ~= nil then
            BuffState._.doubted[pairKey(slot, confirm.name)] = nil
        end
        return settle(Casting.status.succeeded, remaining)
    end

    if isOn == false then return contradict() end

    if now - confirm.startedMs <= confirmEvidenceMs then return nil end

    -- Ran out. On a bar we can read that *is* the answer -- it is not on them. On one we cannot,
    -- it is the world saying nothing, which is no reason to call a cast that reported success a
    -- failure and cast it a second time.
    if confirm.readable then
        DebugLog("[" .. confirm.spell .. "] never appeared on [" .. confirm.name .. "]")
        return contradict()
    end

    DebugLog("No fresh reading of [" .. confirm.name .. "]'s buffs, so the cast stands as reported")
    return settle(confirm.status, nil)
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
---@param observedRemainingMs number|nil what was actually left on the buff, when it was seen
local function recordFinished(status, outcome, reason, observedRemainingMs)
    local target = BuffState._.buffTarget or {}
    local slot = BuffState._.buffSlot
    local names = BuffState._.buffCoverNames or {}
    local request = BuffState._.buffRequest

    if status == Casting.status.succeeded then
        BuffState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        if slot ~= nil then
            -- do not ask about this pairing again until the buff is nearly gone. This is what
            -- covers the people whose buffs we cannot read: the client will not tell us it landed
            -- on them, so the fact that we cast it is the only record there is. Ourselves and our
            -- pet we *can* read back, so their record only has to outlast a hand-removal grace --
            -- past that the buff itself is consulted, which is what notices one stripped early
            -- What was really left on it when the bar was read, where it was read, rather than
            -- what the spell says it lasts: observation replaces inference here for the same
            -- reason it does in the re-read, and a buff seen with ten minutes to go is not one
            -- that has just been cast.
            local lastsMs = BuffState._.buffLastsMs
            local landedMs = math.max((observedRemainingMs or lastsMs) - rebuffAtMs(slot, lastsMs), minimumRecheckMs)
            local myName = mq.TLO.Me.CleanName()
            local petName = mq.TLO.Me.Pet.CleanName()
            for _, name in ipairs(names) do
                local isReadable = name == myName or (petName ~= nil and name == petName)
                holdOff(slot, { name }, isReadable and minimumRecheckMs or landedMs)
                if not isReadable then
                    -- a landed cast is as good as a look at their bar: verification is for what
                    -- changes between casts, and this starts that clock over
                    BuffState._.verifiedAt[name] = Time.current_time()
                end
            end
        end
    else
        if not BuffState._.calledOff then
            -- a buff we called off already said why; anything else is the client refusing it
            BuffState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
                " failed: " .. tostring(reason)
        end
        if slot ~= nil then
            holdOff(slot, names, retryAfterFailureMs)
        end
    end

    -- How a request moves on, which is a different question from how the upkeep list does.
    --
    -- **A cast that failed did not put the buff on anybody**, and the order was to put it on them.
    -- The status is the whole of the reading: the casting service reports a landed cast as
    -- `succeeded` and refines it afterwards if it turned out to be resisted or unnecessary, so
    -- `succeeded` means "the spell went off" and there is nothing more to do at this person --
    -- casting it again would have the same no effect. `failed` means the opposite: a fizzle or an
    -- interrupt spent the mana and lost it, a refusal never left the ground, and in every one of
    -- those cases they still do not have it.
    --
    -- So a failure is tried again rather than skipped past. This is the case the casting service
    -- deliberately leaves to the caller -- it will not retry a cast that was spent, and says so,
    -- because only the caller knows whether casting again is still the right thing to do. For an
    -- order somebody typed it is: the commonest failure is a fizzle, which is pure chance and
    -- means nothing about whether the next one lands.
    --
    -- Bounded, because "try until it works" would let one person behind a wall hold up everybody
    -- queued behind them. Past the budget the name is dropped with the reason said out loud, which
    -- is the one outcome nobody should have to guess at.
    --
    -- A cast we called off ourselves is not a failure at all -- a fight starting mid-order is the
    -- usual reason -- so it costs no attempt and keeps its place until the holding stops.
    local retryDelayMs = 0

    if request ~= nil and not BuffState._.calledOff then
        local subject = request.isGroupCast and "the group" or (request.targets[1] or {}).name

        if status == Casting.status.succeeded then
            request.done = request.done + 1
            request.attempts = 0
            if request.isGroupCast then
                request.groupCastDone = true
            else
                table.remove(request.targets, 1)
            end
        else
            request.attempts = (request.attempts or 0) + 1

            if request.attempts >= maxRequestAttempts then
                print("(buff) Giving up on " .. tostring(subject) .. " for " .. request.label ..
                    " after " .. tostring(request.attempts) .. " tries: " .. tostring(reason))
                request.attempts = 0
                if request.isGroupCast then
                    request.groupCastDone = true
                else
                    table.remove(request.targets, 1)
                end
            else
                DebugLog("Retrying " .. request.label .. " at [" .. tostring(subject) .. "]: " ..
                    tostring(reason) .. " (try " .. tostring(request.attempts + 1) .. " of " ..
                    tostring(maxRequestAttempts) .. ")")
                retryDelayMs = requestRetryMs
            end
        end
    end

    BuffState._.calledOff = false

    DebugLog("Buff finished: " .. tostring(BuffState._.lastResult))
    -- something changed, so the next pass is worth taking rather than waiting out the idle window
    -- -- unless it is a retry, which waits for the gem the failed cast just put on its recast
    BuffState._.nextLookMs = Time.current_time() + retryDelayMs
    BuffState.Reset()
end

---------------- Requests --------------------

---`buff <type>` -- somebody naming a buff instead of a spell.
---
---The other half of buffing, and the opposite question to the slot list above. A slot says "keep
---this on these people forever" and is answered from configuration; a request says "hand me one of
---these, now" and is answered from the book, by whoever turns out to have one. Nobody asking has
---to know what anybody hearing them can cast, which is the whole point: one line reaches a group of
---six and the two characters with an invisibility spell answer it.
---
---These are answered **before** the upkeep list. An order somebody typed is worth more than a
---rebuff that is not due for another twenty minutes, and the upkeep list will still be there
---afterwards.

---@class BuffRequest
---@field typeKey string which buff was asked for
---@field label string what to call this order in status output
---@field action CastAction the spell chosen to answer it
---@field isGroupCast boolean whether one cast covers everybody, so there is nobody to target
---@field targets table remaining { id, name } to cast on, in the order they get it
---@field asked string who asked
---@field done number casts that landed
---@field attempts number failures against whoever is at the front of the queue right now, which
---is what bounds the retries; reset whenever the front moves on
---@field groupCastDone boolean the one cast a group order needs has landed (or run out of tries)

---Whether a spawn is in this character's group, which is what decides if a group cast reaches them.
---@param id number
---@return boolean inGroup
local function isInMyGroup(id)
    for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
        if tonumber(mq.TLO.Group.Member(index).Spawn.ID()) == id then return true end
    end
    return false
end

---Turn a name spoken on a channel into somebody standing here.
---
---A name carries no position, so the spawn search is the only way to find them -- and not finding
---them answers a second question at the same time: whoever asked is not in this zone, so this
---character is not one of the ones being asked.
---@param speaker string
---@return number? id nil when they are not in this zone
---@return string name
local function findSpeaker(speaker)
    -- our own name, through /cself or a hotbar button. Whether a pc-radius search answers with
    -- ourselves is not worth depending on, and there is no doubt about where we are
    local myName = mq.TLO.Me.CleanName()
    if myName ~= nil and speaker:lower() == myName:lower() then
        return tonumber(mq.TLO.Me.ID()), myName
    end

    local spawn = mq.TLO.Spawn("pc radius " .. tostring(speakerRadius) .. " " .. speaker)
    local id = tonumber(spawn.ID())
    if id == nil or id < 1 then return nil, speaker end
    return id, spawn.CleanName() or speaker
end

---Who a request is for, in the order they get it.
---
---**The caster goes last, and that is the whole of the ordering.** Casting drops invisibility, so a
---character that invises itself first has nothing left to hand anybody -- it would have to be
---re-cast on itself afterwards, which is a cast spent to undo a cast. The same is true of every
---buff that a cast breaks, and true of none that it does not, so it costs nothing to always order
---this way. Everybody else's order does not matter, so it is the group window's, which is at least
---stable between passes.
---
---Whoever asked comes first, whether or not they are in the group: they are the reason this is
---being cast, and the character being asked is often not grouped with them at all -- that is what a
---buff bot is. Unless the one who asked is this character, which is the one name that has to be
---last.
---@param askerId number who asked, already resolved to a spawn in this zone
---@param askerName string
---@param isGroup boolean whether the whole group was asked for
---@return table targets the one who asked is always in it, since they were found here
local function requestTargets(askerId, askerName, isGroup)
    local targets = {}
    local seen = {}
    local myId = tonumber(mq.TLO.Me.ID())

    ---@param id number|nil
    ---@param name string|nil
    local function add(id, name)
        id = tonumber(id)
        if id == nil or id < 1 or seen[id] then return end
        seen[id] = true
        targets[#targets+1] = { id = id, name = name or tostring(id) }
    end

    if not isGroup then
        add(askerId, askerName)
        return targets
    end

    if askerId ~= myId then
        add(askerId, askerName)
    end

    for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
        local member = mq.TLO.Group.Member(index)
        if not member.OtherZone() and not member.Offline() then
            local spawn = member.Spawn
            -- a dead member has no bar to put anything on, and hovering often leaves no live spawn
            -- to resolve at all. Read through `Status` rather than `PctHPs` for the reason the
            -- candidate scan does: another player's spawn carries no maximum, and `PctHPs` divides
            -- by it and reports nothing -- which here would drop a live group member out of the
            -- request silently, so the one line that was meant to buff everybody buffs everybody
            -- but them
            local pct = Status.HealthPct(spawn)
            if not spawn.Dead() and (pct == nil or pct > 0) then
                add(spawn.ID(), spawn.CleanName())
            end
        end
    end

    add(myId, mq.TLO.Me.CleanName())
    return targets
end

---Take a request on, or replace one already queued for the same buff from the same person.
---
---Replacing rather than stacking is what makes asking twice harmless. Somebody who has not been
---invised yet says so again -- that is what people do -- and it should mean "still waiting", not
---two casts and two gem timers.
---@param request BuffRequest
local function queueRequest(request)
    for index, queued in ipairs(BuffState._.requests) do
        if queued.typeKey == request.typeKey and queued.asked == request.asked then
            BuffState._.requests[index] = request
            BuffState._.nextLookMs = 0
            DebugLog("Replacing the outstanding request for " .. request.label)
            return
        end
    end

    BuffState._.requests[#BuffState._.requests+1] = request
    BuffState._.nextLookMs = 0
    DebugLog("Queued a request: " .. request.label .. " with [" .. request.action:Name() .. "]")
end

---@class RequestPick
---@field request BuffRequest
---@field targetId number|nil nil for a group cast, which needs no target
---@field name string who is being buffed, for status output

---The next cast an outstanding request calls for.
---
---Every pass re-derives whether the head of the queue still has anybody to cast at rather than
---trusting the list it was built from: somebody who has zoned, died or gone is dropped where they
---stand. That, and not a timer, is what finishes a request -- an order ends when there is nobody
---left in it.
---@return RequestPick? pick
local function chooseRequestPick()
    while #BuffState._.requests > 0 do
        local request = BuffState._.requests[1]

        if request.isGroupCast then
            if not request.groupCastDone then
                return { request = request, targetId = nil, name = "the group" }
            end
        else
            while #request.targets > 0 do
                local target = request.targets[1]
                local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
                if spawn.ID() ~= nil and not spawn.Dead() then
                    return { request = request, targetId = target.id, name = target.name }
                end
                DebugLog("Dropping [" .. target.name .. "] from " .. request.label .. ": gone or dead")
                -- the budget belongs to whoever is at the front of the queue, so it starts over
                -- for the next name rather than being inherited from the one that just left
                request.attempts = 0
                table.remove(request.targets, 1)
            end
        end

        print("(buff) " .. request.label .. ": done, " .. tostring(request.done) ..
            (request.done == 1 and " cast" or " casts"))
        table.remove(BuffState._.requests, 1)
    end

    return nil
end

---Start the cast an outstanding request called for.
---@param pick RequestPick
---@return boolean isBusy
local function startRequest(pick)
    local request = pick.request
    local subject = request.action:Subject()
    local castId, refused = Casting.Cast(subject, BuffState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Requested " .. request.typeKey .. " for [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Casting [" .. request.action:Name() .. "] on [" .. pick.name .. "] for " .. request.label)
    BuffState._.castId = castId
    BuffState._.buffTarget = { id = pick.targetId, name = pick.name, spell = request.action:Name() }
    BuffState._.buffSpell = spellNameOf(subject)
    BuffState._.buffRequest = request
    -- no slot, so none of the upkeep bookkeeping applies: a request is a cast somebody asked for,
    -- not a record of what is on anybody. Whether it landed is squared with the world by the
    -- normal reading, next time the upkeep list looks
    BuffState._.buffSlot = nil
    BuffState._.buffCoverNames = nil
    BuffState._.buffLastsMs = 0

    return true
end

---------------- Orders --------------------

---@param id number
---@param name string
local function orderBuff(id, name)
    BuffState._.order = { id = id, name = name, idleUntilMs = Time.current_time() + orderIdleMs }
    BuffState._.nextLookMs = 0
    DebugLog("Buffs ordered for [" .. name .. "] (" .. tostring(id) .. ")")
end

---An order ends when there is nothing left to give, which is not something to be told -- it is a
---run of casts going quiet. Checked here rather than in the choosing, because "no slot picked
---them this pass" also happens while a gem is recovering.
local function expireOrder()
    local order = BuffState._.order
    if order == nil then return end

    local spawn = mq.TLO.Spawn("id " .. tostring(order.id))
    if spawn.ID() == nil then
        print("(buffnow) " .. order.name .. " left before they were done")
        BuffState._.order = nil
        return
    end

    if Time.current_time() > order.idleUntilMs then
        print("(buffnow) Nothing left to buff on " .. order.name)
        BuffState._.order = nil
    end
end

---Call off whatever is being cast right now, and forget any order waiting for its turn.
function BuffState.CallOff()
    BuffState._.order = nil
    BuffState._.requests = {}

    -- a cast already over and only being checked up on: there is nothing left to interrupt, and
    -- the answer is no longer worth waiting for now that nobody is waiting on the buff
    if BuffState._.confirm ~= nil then
        restoreTarget(BuffState._.confirm)
        BuffState.Reset()
        return
    end

    if BuffState._.castId ~= nil then
        Casting.StopFor(BuffState.key)
    end
end

---Look at everything again from scratch: every retry window dropped, so the very next pass walks
---the whole list against everybody. What `/cbuff refresh` is for, and what a user reaches for
---after changing a slot or after somebody's buffs were stripped.
function BuffState.Recheck()
    BuffState._.tryAgainAt = {}
    BuffState._.verifiedAt = {}
    BuffState._.doubted = {}
    BuffState._.lastScanMs = 0
    BuffState._.nextLookMs = 0
end

---------------- Init --------------------

---The world announcing a death. The candidate scan observes most deaths itself, but it only
---runs when this state gets frames -- and a fight owns them exactly when people die, so somebody
---battle-rezzed and back on their feet before the fight ends, or gone to a bind point in another
---zone, is a death the scan never sees. This line arrives regardless. Both patterns hear every
---death in range; a name holding no records is a no-op, so there is nothing to filter.
---@param name string|nil who died, cleaned to its last word by the listener
local function event_SomeoneDied(_, name)
    buffsWereStripped(name)
end

---@diagnostic disable-next-line: duplicate-set-field
function BuffState.Init()
    if BuffState._.isInit then return end

    -- our own config, so a class that does not register this state has no buff slots written
    BuffStateConfig.Init()

    BuffState._.isBard = mq.TLO.Me.Class.ShortName() == "BRD"

    Menu.RegisterState(BuffState)

    local buffDocs = ChelpDocs.new(function() return {
        "(buffnow <id>) Tells listener(s) to buff the spawn with <id> with everything it is missing",
        " -- Usage: buffnow <spawn id>",
        " -- Usage (call off the buff in progress): buffnow off",
        " -- Every configured buff whose scope and class list cover them is cast, in order, and",
        "    the order ends once there is nothing left to give them.",
        " -- They do not have to be in the group: this is how a buff is handed to somebody who",
        "    asked for one."
    } end )
    local function event_Buff(_, speaker, args)
        if not Commands.GetCommandOwners(BuffState.eventIds.buff):HasPermission(speaker) then
            DebugLog("Ignoring buffnow speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(buffnow) No one given. Usage: buffnow <spawn id>, or `buffnow off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            BuffState.CallOff()
            return
        end

        local targetId = tonumber(args[1])
        if targetId == nil then
            print("(buffnow) [" .. args[1] .. "] is not a spawn id. Usage: buffnow <spawn id>")
            return
        end

        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        if spawn.ID() == nil then
            print("(buffnow) Nothing here with id [" .. tostring(targetId) .. "]")
            return
        end

        orderBuff(targetId, spawn.CleanName() or tostring(targetId))
    end
    Commands.RegisterCommEvent(Command.new(BuffState.eventIds.buff, event_Buff, buffDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                { label = "Myself", args = "${Me.ID}", name = "Buff me" },
                { label = "Call off the buff", args = "off", name = "Stop buffing" }
            } end
        }))

    local buffMeDocs = ChelpDocs.new(function() return {
        "(buffme) Tells listener(s) to buff whoever said it",
        " -- The button somebody binds for themselves: it needs no spawn id, since the buffer",
        "    works out who spoke. Nothing to say to yourself, so the local channel will not take",
        "    it -- `buffnow ${Me.ID}` is that."
    } end )
    local function event_BuffMe(_, speaker)
        if not Commands.GetCommandOwners(BuffState.eventIds.buffMe):HasPermission(speaker) then
            DebugLog("Ignoring buffme speaker [" .. speaker .. "]")
            return
        end

        local spawn = mq.TLO.Spawn("pc radius 300 " .. speaker)
        if spawn.ID() == nil then
            Commands.GetCommandSpeak(BuffState.eventIds.buffMe):speak("Cannot see [" .. speaker .. "] to buff them")
            return
        end

        orderBuff(spawn.ID(), speaker)
    end
    Commands.RegisterCommEvent(Command.new(BuffState.eventIds.buffMe, event_BuffMe, buffMeDocs)
        :ActsOnSpeaker())

    ---Sixteen names on one line runs off the side of a chat window; /chelp prints a line at a time.
    ---@return table lines
    local function typeLines()
        local lines = {}
        local names = BuffTypes.Names()
        local perLine = 6

        for index = 1, #names, perLine do
            local chunk = {}
            for offset = 0, perLine - 1 do
                if names[index + offset] ~= nil then
                    chunk[#chunk+1] = names[index + offset]
                end
            end
            lines[#lines+1] = "    " .. StringUtils.Join(chunk, ", ")
        end

        return lines
    end

    local buffRequestDocs = ChelpDocs.new(function()
        local lines = {
            "(buff <type>) Asks whoever has one for a buff of that kind",
            " -- Usage: buff <type>            -- cast on whoever asked",
            " -- Usage: buff group <type>      -- cast on the whole group",
            " -- Example: /bc buff invis",
            " -- Example: /bc buff group lev",
            " -- A type names what the buff *does* rather than a spell, so one line reaches every",
            "    character: each casts the best it has of that kind, whatever that turns out to be,",
            "    and anybody who has none of that kind says nothing at all.",
            " -- A group buff is one cast when this character has a group version of it. Where it",
            "    is one at a time, everybody else is cast on first and the caster last, because",
            "    casting drops invisibility -- a character that invises itself first has nothing",
            "    left to hand out.",
            " -- Either way, only characters in the same zone as whoever asked answer at all, and",
            "    group members who are elsewhere are left out of the ones cast on one at a time.",
            " -- Nothing is remembered afterwards: this is a buff handed over on request, not a",
            "    buff kept up. Keeping one up is a slot on the Buff State page.",
            " -- Types:"
        }

        for _, line in ipairs(typeLines()) do
            lines[#lines+1] = line
        end

        return lines
    end )

    local function event_BuffRequest(_, speaker, args)
        if not Commands.GetCommandOwners(BuffState.eventIds.buffRequest):HasPermission(speaker) then
            DebugLog("Ignoring buff speaker [" .. speaker .. "]")
            return
        end

        ---Said out loud rather than printed, because whoever typed it is on another character and
        ---a local print is a message they never see. Only by a character that could have answered
        ---something, though: the line went to everybody, and six identical complaints about one
        ---typo are worse than the typo.
        ---@param message string
        local function complain(message)
            if not BuffTypes.CouldAnswer() then return end
            Commands.GetCommandSpeak(BuffState.eventIds.buffRequest):speak("(buff) " .. message)
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))

        local first = 1
        local isGroup = false
        if #args > 0 and args[1]:lower() == "group" then
            isGroup = true
            first = 2
        end

        -- everything left is the name, so `see invis` is read the same as `seeinvis`
        local words = {}
        for index = first, #args do
            words[#words+1] = args[index]
        end
        local typeName = StringUtils.Join(words, " ")

        if typeName == "" then
            complain("Nothing named. Usage: buff [group] <type>")
            return
        end

        local buffType = BuffTypes.Get(typeName)
        if buffType == nil then
            complain("No buff called [" .. typeName .. "]. /chelp buff lists them")
            return
        end

        local single, group = BuffTypes.Best(buffType)
        if single == nil and group == nil then
            -- the ordinary case, and the reason it is silent: "whoever has one" means every
            -- character that has none has nothing to say
            DebugLog("Nothing here casts " .. buffType.key)
            return
        end

        -- Whoever asked has to be standing here, and that is as true of `group` as it is of one
        -- name. A group cast reaches the group members in *this* zone, so a character somewhere
        -- else answering this line buffs whoever happens to be around it instead of the people the
        -- line was said to -- and it spends a gem doing it. Silently, unlike the single case: the
        -- line went to everybody, the characters in the zone are answering it, and a character in
        -- another zone has nothing to say about a request that was never its to take.
        local askerId, askerName = findSpeaker(speaker)
        if askerId == nil then
            if isGroup then
                DebugLog("[" .. speaker .. "] is not in this zone, so this group buff is not ours")
                return
            end
            complain("Cannot see [" .. speaker .. "] to buff them")
            return
        end

        local targets = requestTargets(askerId, askerName, isGroup)

        local action, isGroupCast
        if isGroup then
            -- one cast for six people whenever there is one to make; the ordered list is what it
            -- falls back to, and that is where the caster-last ordering earns its keep
            action = group or single
            isGroupCast = group ~= nil
        elseif single ~= nil then
            action, isGroupCast = single, false
        elseif isInMyGroup(targets[1].id) then
            -- only a group version of it exists here, and it reaches the one who asked only
            -- because they happen to be in this group
            action, isGroupCast = group, true
        else
            complain("Only have " .. buffType.key .. " as a group spell, and [" ..
                speaker .. "] is not in my group")
            return
        end

        queueRequest({
            typeKey = buffType.key,
            label = buffType.key .. " for " .. (isGroup and "the group" or speaker),
            action = action,
            isGroupCast = isGroupCast,
            targets = isGroupCast and {} or targets,
            asked = speaker,
            done = 0,
            attempts = 0,
            groupCastDone = false
        })
    end
    Commands.RegisterCommEvent(Command.new(BuffState.eventIds.buffRequest, event_BuffRequest, buffRequestDocs)
        :WithArgs({
            required = true,
            hint = "a buff type, with an optional `group` in front",
            default = "invis",
            choices = function()
                local choices = {}

                for _, buffType in ipairs(BuffTypes.All()) do
                    choices[#choices+1] = {
                        label = buffType.summary,
                        args = buffType.key,
                        group = "For me",
                        name = "Buff " .. buffType.key
                    }
                end
                for _, buffType in ipairs(BuffTypes.All()) do
                    choices[#choices+1] = {
                        label = buffType.summary,
                        args = "group " .. buffType.key,
                        group = "For my group",
                        name = "Group " .. buffType.key
                    }
                end

                return choices
            end
        }))

    local slainDocs = ChelpDocs.new(function() return {
        "(buffslain) Notices somebody being slain and forgets every buff record held for them",
        " -- Dying strips buffs, so whoever died is looked at afresh once they are back up."
    } end)
    Commands.RegisterEvent(Event.new(BuffState.eventIds.slain, "#1# has been slain by #2#!", event_SomeoneDied, slainDocs))

    local diedDocs = ChelpDocs.new(function() return {
        "(buffdied) Notices somebody dying without a slayer named, same as buffslain"
    } end)
    Commands.RegisterEvent(Event.new(BuffState.eventIds.died, "#1# died.", event_SomeoneDied, diedDocs))

    ToggleCommand.Register({
        key = BuffState.key,
        phrase = BuffState.eventIds.buffing,
        summary = "Turns buffing on or off for listener(s)",
        about = { "Off calls off a buff in progress as well as stopping new ones." },
        get = BuffStateConfig.IsEnabled,
        set = BuffState.SetEnabled
    })

    ToggleCommand.Register({
        key = BuffState.key,
        phrase = BuffState.eventIds.buffGroup,
        summary = "Turns buffing the rest of the group on or off",
        about = { "Off buffs nobody but this character (and its pet, if that is on)." },
        get = BuffStateConfig.GetBuffGroup,
        set = BuffStateConfig.SetBuffGroup
    })

    ToggleCommand.Register({
        key = BuffState.key,
        phrase = BuffState.eventIds.buffPets,
        summary = "Turns buffing this character's pet on or off",
        about = { "Pet buffs are the ones the spell itself says are for a pet." },
        get = BuffStateConfig.GetBuffPets,
        set = BuffStateConfig.SetBuffPets
    })

    ToggleCommand.Register({
        key = BuffState.key,
        phrase = BuffState.eventIds.buffCombat,
        summary = "Turns buffing during a fight on or off",
        about = {
            "Off by default: buffing mid-fight spends the mana the healing needs and holds the",
            "target away from what is being fought.",
            "Off also calls off a buff that is in the air when a fight starts."
        },
        get = BuffStateConfig.GetInCombat,
        set = BuffStateConfig.SetInCombat
    })

    ActionCommand.Register({
        key = BuffState.key,
        phrase = BuffState.eventIds.buffAction,
        summary = "Switches one of the configured buffs on or off",
        where = "Buff State page",
        getActionLists = BuffStateConfig.GetActionLists
    })

    local cbuffDocs = ChelpDocs.new(function() return {
        "(/cbuff) Report what the buff state is doing, and who it is keeping buffed",
        " -- Usage: /cbuff",
        " -- Usage (call off the buff in progress, and every outstanding request): /cbuff off",
        " -- Usage (look at everybody again from scratch): /cbuff refresh"
    } end )
    local function Bind_CBuff(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cbuffDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            BuffState.CallOff()
            print("Buffing called off")
            return
        end

        if #args > 0 and args[1]:lower() == "refresh" then
            BuffState.Recheck()
            print("Buffing: looking at everybody again")
            return
        end

        print("Buff: " .. BuffState.Describe() .. (BuffState.IsEnabled() and "" or " (disabled)"))
        local result = BuffState.GetLastResult()
        if result ~= nil then
            print(" -- last: " .. result)
        end
        for _, request in ipairs(BuffState.GetRequests()) do
            print(" -- asked for: " .. request.label .. " with " .. request.action:Name() ..
                (request.isGroupCast and " (one group cast)"
                    or (" (" .. tostring(#request.targets) .. " to go)")))
        end
        for _, candidate in ipairs(getCandidates()) do
            local missing, configured = BuffState.CountMissing(candidate)
            print(" -- " .. candidate.name .. " (" .. (candidate.class ~= "" and candidate.class or "?") .. "): " ..
                tostring(missing) .. " of " .. tostring(configured) .. " missing" ..
                (candidate.isPet and " (pet)" or ""))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cbuff", Bind_CBuff, cbuffDocs))

    BuffState.Reset()
    BuffState._.isInit = true
end

---Read who is here, work out what they are missing, cast one thing, release.
---
---There is no "I am buffing" mode to be stuck in. Every pass that looks reads the group afresh
---and asks the same question -- is the cast in the air still worth finishing, then has anybody
---asked for something, and if not, what is the first thing anybody is missing. What is held
---between passes is the cast we started, the orders still outstanding, and how long each answer is
---good for; all three are dropped the moment they stop being true -- a request's next name is
---re-checked against the world every pass, and dropped where it stands if they have gone.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function BuffState.Go()
    local code, hold = holdReason()
    BuffState._.holdReason = hold

    -- A cast being squared with the bar of the person it was cast at holds the state exactly as
    -- the cast did: it is the same job, and what it comes back with *is* that cast's result.
    if BuffState._.confirm ~= nil then
        local settled = progressConfirm(code)
        if settled == nil then return true end
        recordFinished(settled.status, settled.outcome, settled.reason, settled.remainingMs)
        return true
    end

    local castId = BuffState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        if status == nil then
            local abandon = reasonToAbandon(code)
            if abandon ~= nil then
                DebugLog("Calling off the buff: " .. abandon)
                BuffState._.lastResult = "called off: " .. abandon
                BuffState._.calledOff = true
                Casting.StopFor(BuffState.key)
            end
            return true
        end

        -- the cast says it went off; the person it was aimed at says whether it did
        if startConfirm(status, outcome, reason, code) then return true end

        recordFinished(status, outcome, reason)
        return true
    end

    -- a re-read in flight is a status, not a job: it advances by being looked at, holds no
    -- frame, and no cast is chosen under it -- a cast would take the very target it is borrowing
    if BuffState._.verify ~= nil then
        progressVerify(code)
        return false
    end

    if hold ~= nil then return false end

    if Time.current_time() < BuffState._.nextLookMs then return false end

    prune()
    expireOrder()

    -- an order somebody typed comes before a rebuff that is not due for another twenty minutes
    local requestPick = chooseRequestPick()
    if requestPick ~= nil then
        return startRequest(requestPick)
    end

    local candidates = getCandidates()
    local pick = choosePick(candidates)
    if pick == nil then
        local watch = chooseVerify(candidates)
        if watch ~= nil then
            startVerify(watch)
        else
            BuffState._.nextLookMs = Time.current_time() + idleLookIntervalMs
        end
        return false
    end

    return startBuff(pick)
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
BuffState.IsEnabled = function()
    return BuffStateConfig.IsEnabled()
end

---Switching buffing off has to call off the cast in the air as well: it is the casting service's
---now, and it would go on holding the chain back for a job we were just told to stop.
---@diagnostic disable-next-line: duplicate-set-field
BuffState.SetEnabled = function(isEnabled)
    BuffStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        BuffState.CallOff()
        BuffState.Reset()
    else
        -- back on after being off for a while: everything we thought we knew is out of date
        BuffState.Recheck()
    end
end

function BuffState.BuildMenu()
    BuffStateMenu.BuildMenu(BuffState)
end

return BuffState
