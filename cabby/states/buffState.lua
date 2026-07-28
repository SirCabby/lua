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

---The floor under the "it landed, leave it alone" window. A buff that reports no duration we can
---read still should not be recast on the next pass.
local minimumRecheckMs = 30000

---How long an order waits with nothing left to cast before it is treated as finished. A buff
---order is not one cast, it is "give them everything they are missing", so it ends when there is
---nothing more to give rather than when the first cast lands.
local orderIdleMs = 15000

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
---window below is. It is not a give-up timer: it is how long an answer is good for.
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
        buffAction = "buffaction"
    },
    _ = {
        isInit = false,
        candidates = {},
        lastScanMs = 0,
        nextLookMs = 0,
        castId = nil,
        buffTarget = nil,   -- { id, name, spell } as it was when the cast started
        buffSlot = nil,     -- the configured slot chosen for it
        buffCoverIds = nil, -- everyone this cast is expected to land on
        buffLastsMs = 0,    -- how long what we are casting lasts
        order = nil,        -- { id, name, idleUntilMs } from a `buffnow <id>` or `buffme`
        tryAgainAt = {},    -- { ["<slot>@<spawn id>"] = when that pairing is worth looking at again }
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
        if pct ~= nil and pct <= 0 then return end

        candidates[#candidates+1] = {
            id = id,
            name = name or tostring(id),
            class = tostring(class or ""):upper(),
            isSelf = flags.isSelf == true,
            isPet = flags.isPet == true,
            inGroup = flags.inGroup == true
        }
    end

    add(mq.TLO.Me.ID(), mq.TLO.Me.CleanName(), mq.TLO.Me.Class.ShortName(), { isSelf = true, inGroup = true })

    if BuffStateConfig.GetBuffGroup() then
        for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
            local member = mq.TLO.Group.Member(index)
            if not member.OtherZone() and not member.Offline() then
                local spawn = member.Spawn
                if not spawn.Dead() then
                    add(spawn.ID(), spawn.CleanName(), spawn.Class.ShortName(), { inGroup = true })
                end
            end
        end
    end

    if BuffStateConfig.GetBuffPets() then
        local pet = mq.TLO.Me.Pet
        if pet.ID() ~= nil and not pet.Dead() then
            add(pet.ID(), pet.CleanName(), pet.Class.ShortName(), { isPet = true })
        end
    end

    -- whoever asked. They are usually not in the group -- that is the whole point of asking --
    -- so a group cast does not reach them and `inGroup` stays false
    local order = BuffState._.order
    if order ~= nil then
        local spawn = mq.TLO.Spawn("id " .. tostring(order.id))
        if spawn.ID() ~= nil and not spawn.Dead() then
            add(spawn.ID(), spawn.CleanName() or order.name, spawn.Class.ShortName(), {})
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

---@param slot Action
---@param id number
---@return string key
local function pairKey(slot, id)
    return slotKey(slot) .. "@" .. tostring(id)
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
---@param id number
---@return boolean isDue whether this pairing is worth looking at again yet
local function dueNow(slot, id)
    local at = BuffState._.tryAgainAt[pairKey(slot, id)]
    return at == nil or Time.current_time() >= at
end

---@param slot Action
---@param ids table everyone the cast was expected to land on
---@param delayMs number
local function holdOff(slot, ids, delayMs)
    local until_ = Time.current_time() + delayMs
    for _, id in ipairs(ids or {}) do
        BuffState._.tryAgainAt[pairKey(slot, id)] = until_
    end
end

---How long this buff lasts, in milliseconds.
---
---Zero means the spell has no duration at all, which is how a heal or a cure reads -- the action
---picker offers the whole beneficial half of the spellbook, so one of those ending up in a buff
---list is a mistake worth catching rather than one worth casting on a loop.
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
        if buff.ID() == nil then return nil end
        return tonumber(buff.Duration()) or 0
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
---to ask is whether it is nearly gone. If it is not, the question is whether it would land at all
----- which is what the client's own stacking check answers, and it answers more than "do they
---already have it": a better buff in the same line, or a buff too powerful for them to take, both
---come back as "no" without a cast being spent to find out.
---@param spell any mq spell TLO
---@param candidate BuffCandidate
---@return boolean needsIt
local function needsBuff(spell, candidate)
    local remaining = remainingMs(spell, candidate)
    if remaining ~= nil then
        return remaining <= BuffStateConfig.GetRebuffMs()
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
---@return table ids everyone a group cast from here would land on
local function groupCoverage(candidates)
    local ids = {}
    for _, candidate in ipairs(candidates) do
        if candidate.inGroup and not candidate.isPet then
            ids[#ids+1] = candidate.id
        end
    end
    return ids
end

---@class BuffPick
---@field action ActionType
---@field slot Action
---@field targetId number|nil nil for a group buff, which needs no target
---@field name string what is being buffed, for status output
---@field coverIds table everyone this cast is expected to land on
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
        if appliesTo(slot, aim, candidate) and dueNow(slot, candidate.id) and needsBuff(spell, candidate) then
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
                    coverIds = isGroupCast and groupCoverage(candidates) or { candidate.id },
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

---------------- The state itself --------------------

function BuffState.Reset()
    BuffState._.castId = nil
    BuffState._.buffTarget = nil
    BuffState._.buffSlot = nil
    BuffState._.buffCoverIds = nil
    BuffState._.buffLastsMs = 0
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
            if spell ~= nil and durationMs(spell) > 0 and appliesTo(slot, aimOf(subject), candidate) then
                configured = configured + 1
                if needsBuff(spell, candidate) then
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
    BuffState._.buffCoverIds = pick.coverIds
    BuffState._.buffLastsMs = pick.lastsMs

    -- an order is "give them everything they are missing", so every cast that reaches them is a
    -- reason to keep it open
    local order = BuffState._.order
    if order ~= nil then
        for _, id in ipairs(pick.coverIds) do
            if id == order.id then
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
    local ids = BuffState._.buffCoverIds or {}

    if status == Casting.status.succeeded then
        BuffState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        if slot ~= nil then
            -- do not ask about this pairing again until the buff is nearly gone. This is what
            -- covers the people whose buffs we cannot read: the client will not tell us it landed
            -- on them, so the fact that we cast it is the only record there is
            local delay = math.max(BuffState._.buffLastsMs - BuffStateConfig.GetRebuffMs(), minimumRecheckMs)
            holdOff(slot, ids, delay)
        end
    else
        if not BuffState._.calledOff then
            -- a buff we called off already said why; anything else is the client refusing it
            BuffState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
                " failed: " .. tostring(reason)
        end
        if slot ~= nil then
            holdOff(slot, ids, retryAfterFailureMs)
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
    BuffState._.lastScanMs = 0
    BuffState._.nextLookMs = 0
end

---------------- Init --------------------

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

    if hold ~= nil then return false end

    if Time.current_time() < BuffState._.nextLookMs then return false end

    prune()
    expireOrder()

    local pick = choosePick(getCandidates())
    if pick == nil then
        BuffState._.nextLookMs = Time.current_time() + idleLookIntervalMs
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
