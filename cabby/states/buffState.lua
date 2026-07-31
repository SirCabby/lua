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
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Event = require("cabby.commands.event")
local Menu = require("cabby.ui.menu")
local SlashCmd = require("cabby.commands.slashcmd")
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
---What it deliberately leaves out: buff *begging* beyond the `buffnow`/`buffme` orders, other
---people's pets, curing, and any awareness of what the other buffers in the group have already
---cast.
---@class BuffState : BaseState
local BuffState = {
    key = "BuffState",
    eventIds = {
        -- `buffnow` rather than `buff`, for the reason `healnow` is not `heal`: a registered
        -- phrase also matches every longer line that starts with it, so a plain `buff` would fire
        -- on `buffme`, `buffing off` and every other switch in this family
        buff = "buffnow",
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
        buffSlot = nil,     -- the configured slot chosen for it
        buffCoverNames = nil, -- everyone this cast is expected to land on, by name
        buffLastsMs = 0,    -- how long what we are casting lasts
        order = nil,        -- { id, name, idleUntilMs } from a `buffnow <id>` or `buffme`
        tryAgainAt = {},    -- { ["<slot>@<name>"] = when that pairing is worth looking at again }
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

---How long this buff lasts, in milliseconds.
---
---Zero means the spell has no duration at all, which is how a heal or a cure reads -- the picker
---narrows to buff headings but the game's filing is not a promise and the narrowing can be
---switched off, so one of those ending up in a buff list is a mistake worth catching rather than
---one worth casting on a loop.
---@param spell any mq spell TLO
---@return number ms
local function durationMs(spell)
    -- MyDuration carries this character's duration focus effects; Duration is the unmodified
    -- value and the fallback. Read through TotalSeconds rather than the tick count, which is what
    -- the bare member gives
    local seconds = tonumber(spell.MyDuration.TotalSeconds())
    if seconds == nil or seconds <= 0 then
        seconds = tonumber(spell.Duration.TotalSeconds())
    end
    if seconds == nil or seconds <= 0 then return 0 end
    return seconds * 1000
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

---@param candidate BuffCandidate
local function startVerify(candidate)
    local restoreId = tonumber(mq.TLO.Target.ID())
    BuffState._.verify = {
        id = candidate.id,
        name = candidate.name,
        startedMs = Time.current_time(),
        restoreId = restoreId ~= candidate.id and restoreId or nil
    }
    if restoreId ~= candidate.id then
        DebugLog("Borrowing the target to re-read [" .. candidate.name .. "]'s buffs")
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
    if targetId == verify.id and mq.TLO.Target.BuffsPopulated() == true then
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
    BuffState._.buffSlot = nil
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
    if BuffState._.castId ~= nil and BuffState._.buffTarget ~= nil then
        return "casting " .. tostring(BuffState._.buffTarget.spell) .. " on " .. BuffState._.buffTarget.name
    end
    if BuffState._.verify ~= nil then
        return "re-reading " .. BuffState._.verify.name .. "'s buffs"
    end
    if BuffState._.holdReason ~= nil then
        return "holding: " .. BuffState._.holdReason
    end
    return "watching"
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
    local castId, refused = Casting.Cast(pick.action:Subject(), BuffState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Buff of [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Buffing [" .. pick.name .. "] with [" .. pick.action:Name() .. "]")
    BuffState._.castId = castId
    BuffState._.buffTarget = { id = pick.targetId, name = pick.name, spell = pick.action:Name() }
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

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordFinished(status, outcome, reason)
    local target = BuffState._.buffTarget or {}
    local slot = BuffState._.buffSlot
    local names = BuffState._.buffCoverNames or {}

    if status == Casting.status.succeeded then
        BuffState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        if slot ~= nil then
            -- do not ask about this pairing again until the buff is nearly gone. This is what
            -- covers the people whose buffs we cannot read: the client will not tell us it landed
            -- on them, so the fact that we cast it is the only record there is. Ourselves and our
            -- pet we *can* read back, so their record only has to outlast a hand-removal grace --
            -- past that the buff itself is consulted, which is what notices one stripped early
            local landedMs = math.max(BuffState._.buffLastsMs - rebuffAtMs(slot, BuffState._.buffLastsMs), minimumRecheckMs)
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
    BuffState._.calledOff = false

    DebugLog("Buff finished: " .. tostring(BuffState._.lastResult))
    -- something changed, so the next pass is worth taking rather than waiting out the idle window
    BuffState._.nextLookMs = 0
    BuffState.Reset()
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
        " -- Usage (call off the buff in progress): /cbuff off",
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
---and asks the same question -- is the cast in the air still worth finishing, and if there is
---none, what is the first thing anybody is missing. What is held between passes is the cast we
---started and how long each answer is good for, and both are dropped the moment they stop being
---true.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function BuffState.Go()
    local code, hold = holdReason()
    BuffState._.holdReason = hold

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
