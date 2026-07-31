---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local Combat = require("cabby.combat")
local Menu = require("cabby.ui.menu")
local Roles = require("cabby.roles")
local SpellDpsStateConfig = require("cabby.configs.spellDpsStateConfig")
local SpellDpsStateMenu = require("cabby.ui.states.spellDpsStateMenu")
local ToggleCommand = require("cabby.commands.toggleCommand")

---How long something this state just landed is trusted to still be there before the world is
---believed instead. A cast reports success the moment the cast bar closes; the effect shows up in
---a buff list a server round-trip later, and for that beat "not on them yet" reads exactly like
---"dropped". This is the evidence window that bridges it -- once it has passed, what the world
---shows is the answer.
local justLandedMs = 2000

---How often the group is re-read, for a rotation holding something cast on a friend. Nothing
---about who is standing here changes inside half a second, and a rotation of plain nukes never
---asks at all.
local scanIntervalMs = 500

---Where a slot's spell can be aimed, read off the spell rather than configured -- the same model
---the heal and buff states use, and for the same reason: what a spell can land on is what it is,
---and asking the user to say so is one more thing to get wrong.
local aims = {
    self = "self",     -- only ever lands on the caster
    pet = "pet",       -- only ever lands on this character's pet
    group = "group",   -- one cast covers the whole group and needs no target
    single = "single"  -- one person at a time
}

local groupTargetTypes = { ["group v1"] = true, ["group v2"] = true }
local petTargetTypes = { ["pet"] = true, ["pet2"] = true }

---Hurting whatever this character is fighting, with spells rather than with a weapon.
---
---The other half of the dps band. `MeleeState` walks into range and swings; this casts from
---wherever it is standing, and the two are separate states because they are separate jobs: a
---wizard has no melee state to hang a rotation off, a warrior has no spells, and the hybrids in
---between want both without one pretending to be the other. What they share -- what we are
---fighting -- is `cabby.combat`, so an `attack <id>` order means the same thing to all of them.
---
---**It registers above the melee state.** MeleeState reports busy for as long as it is engaged
---(there is always another swing coming), so a rotation below it would never get a frame. Above
---it, this state takes the frame only when it actually starts a cast and yields the rest of the
---time, which is what `Priorities.dps - 1` in the bands is for.
---
---Not everything in a rotation is aimed at the mob. A damage shield is damage by every measure
---that matters and a buff by every other one -- beneficial, cast on a person, sitting on their
---bar -- and the band it belongs in is this one: below the melee state nothing gets a frame while
---a fight is on, so a shield that only the buff state could cast would go up after the fight
---rather than for it. A slot holding one is aimed by scope (see `SpellDpsStateConfig`) exactly as
---a heal slot is, and everything else about it -- who it can land on, how long it lasts, whether
---it is already up -- is read off the spell and off the world.
---
---What a slot aimed at the mob carries instead is *when* (`dps_timing`). The three numbers on the
---page are one answer for the whole rotation, and a debuff is where that is not enough: the same
---root is a fight-opener, a runner-stopper held back for the last fifth of a fight, or something
---kept for the moment the mob actually turns and goes, and nothing about the spell says which. It
---is a gate and only a gate -- re-derived every pass off the world, narrowing what the order and
---the numbers have already allowed, with nothing remembered between passes. "And reapply it if it
---fades" needs no setting at all, because a spell that leaves an effect behind is already left
---alone while the effect is there (`alreadyWorking`).
---
---The debuff's other question is *how many* (`dps_spread`), and it is the one thing the order in
---the list cannot answer. A slow, a tash or a snare belongs on everything in the fight before a
---second nuke belongs on the one we are killing -- so a slot switched to spread is not finished
---while any mob in the fight is still short of its effect, and a rotation walked strongest-first
---never reaches what is under it until they all have it. That falls out of the walk rather than
---being enforced: the slot simply still has something to do. Which mobs those are is Combat's
---answer (`GetFightIds`), never this state's guess.
---@class SpellDpsState : BaseState
local SpellDpsState = {
    key = "SpellDpsState",
    eventIds = {
        nuke = "nuke",
        nukeAction = "nukeaction"
    },
    _ = {
        isInit = false,
        candidates = {},
        lastScanMs = 0,
        castId = nil,
        castName = nil,
        castOn = nil,       -- who it was cast on, for a cast aimed at a friend; nil for the mob
        castWitnesses = {}, -- what to remember once it lands, see `witnessFor`
        lastResult = nil,
        holdReason = nil,
        landed = {}         -- { ["<effect>@<who>"] = trusted until }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(SpellDpsState.key, str)
end

---Who this state is when it asks the casting service for something.
---@param targetId number|nil what the cast should aim at; nil for a spell that aims itself
---@return table request
function SpellDpsState.CastRequest(targetId)
    return {
        owner = SpellDpsState.key,
        priority = SpellDpsState.priority,
        targetId = targetId
    }
end

---Reasons to hold everything, in the order they are worth reporting. Each one is a way a caster
---makes a fight worse by casting: pulling the mob off the tank before it has settled, going on
---hurting one it has already pulled off, burning the mana that the next fight needs, or spending a
---cast on something already dead.
---
---The code matters as well as the words: `noTarget` is the only one that also means "and stop
---what you are already doing", because a cast in flight at something that is dead or gone is the
---one case where finishing it is worse than dropping it. A mob that has dropped below the stop
---point mid-cast, by contrast, is a cast that is nearly finished too.
---@return string|nil code
---@return string|nil reason in words
---@return any spawn what we are fighting, when it is still there to be fought -- read once here
---and handed on, since every slot aimed at it is judged against the same reading
local function holdReason()
    local targetId = Combat.GetTargetId()
    if targetId == 0 then return "noTarget", "nothing to fight" end

    local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
    if spawn.ID() == nil or spawn.Dead() then return "noTarget", "the target is gone" end

    -- We have pulled it off the tank. Asked before the numbers below because it is the one worth
    -- reading on the page while it is true, and because it outranks them: a rotation that would
    -- have fired anyway is exactly the rotation that has to stop. Combat answers it -- the aggro
    -- and the tank's target are both its facts -- and it goes on answering true for as long as the
    -- mob is coming for us, so nothing here has to remember or time anything.
    local easeOff, easeWhy = Combat.ShouldEaseOff()
    if easeOff then return "easeOff", "easing off -- " .. tostring(easeWhy), spawn end

    local pct = tonumber(spawn.PctHPs())
    if pct ~= nil then
        if pct > SpellDpsStateConfig.GetStartPct() then
            return "tooHealthy",
                "waiting for it to drop below " .. tostring(SpellDpsStateConfig.GetStartPct()) .. "%", spawn
        end
        if pct < SpellDpsStateConfig.GetStopPct() then
            return "nearlyDead", "it is nearly dead", spawn
        end
    end

    local manaFloor = SpellDpsStateConfig.GetManaFloor()
    if manaFloor > 0 and (tonumber(mq.TLO.Me.PctMana()) or 0) < manaFloor then
        return "lowMana", "saving mana below " .. tostring(manaFloor) .. "%", spawn
    end

    return nil, nil, spawn
end

---Does this hold still leave something runnable?
---
---The two aggro holds are the ones that do, and it is the same reasoning for both: they are about
---damage *we* aim at the mob, and a shield put on somebody is not that. `tooHealthy` is a moment
---for the tank to land something before we start; `easeOff` is the same moment arriving late,
---after we have already taken the mob off it. Held back by either, a shield would go up a fifth of
---the way into every fight -- or not at all in the fights that went wrong, which is when the
---person wearing it needs it most. The other holds are the fight being over, nearly over, or not
---worth the mana, and those are equally true of everything.
---@param code string|nil
---@return boolean friendlyOnly
local function friendlyOnly(code)
    return code == "tooHealthy" or code == "easeOff"
end

---How long this spell's effect hangs on whatever it lands on, in milliseconds. Zero is a true
---nuke: all of its work is done the moment it lands.
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

---@param spell any mq spell TLO
---@return boolean isFriendly whether it is cast on a friend rather than at what we are fighting
local function isFriendly(spell)
    return spell ~= nil and spell.Beneficial() == true
end

---@param subject CastSubject
---@return string aim one of `aims`
local function aimOf(subject)
    local targetType = subject:TargetType()
    if groupTargetTypes[targetType] then return aims.group end
    if petTargetTypes[targetType] then return aims.pet end
    if targetType == "self" then return aims.self end
    return aims.single
end

---------------- What is already on whom --------------------

---What a landed cast is remembered against. A friend is remembered by name, because a zone deals
---everybody a new spawn id and a shield does not fall off in the zone line; what we are fighting
---is remembered by id, because two mobs of one name are two different things to debuff.
---@param effect string
---@param who table
---@return string key
local function landedKey(effect, who)
    return effect .. "@" .. (who.name or tostring(who.id))
end

---Dying strips everything at once, so every record held for whoever died is a record of something
---false. Dropped the moment a death is observed rather than left to run out, which is what would
---otherwise leave somebody rezzed and back on their feet without the shield they are owed for as
---long as their record had left to run.
---@param name string|nil
local function effectsWereStripped(name)
    if name == nil then return end
    local suffix = "@" .. name
    for key in pairs(SpellDpsState._.landed) do
        if key:sub(-#suffix) == suffix then
            SpellDpsState._.landed[key] = nil
        end
    end
end

---Drop records that have run out, so a long session does not collect one per person this
---character has ever shielded.
local function prune()
    local now = Time.current_time()
    for key, until_ in pairs(SpellDpsState._.landed) do
        if now >= until_ then
            SpellDpsState._.landed[key] = nil
        end
    end
end

---@class DpsCandidate
---@field id number
---@field name string
---@field isSelf boolean
---@field isTank boolean the group's main tank, by the role assigned in the group window
---@field isPet boolean
---@field inGroup boolean whether one group cast from here would reach them

---Everybody a slot cast on a friend could be meant for.
---
---Group members out of the zone or offline are skipped rather than counted: they have no spawn to
---cast at, and a group cast does not reach them either.
---@return table candidates
local function scanCandidates()
    local candidates = {}

    local function add(id, name, flags)
        id = tonumber(id)
        if id == nil or id < 1 then return end
        candidates[#candidates+1] = {
            id = id,
            name = name or tostring(id),
            isSelf = flags.isSelf == true,
            isTank = flags.isTank == true,
            isPet = flags.isPet == true,
            inGroup = flags.inGroup == true
        }
    end

    -- Through Roles rather than off `Group.Member[#].MainTank`, so that "the tank" is one answer
    -- for the whole script -- and so it is answered for *this* character too, which reading the
    -- flag per group member could never do, since we are not one of our own group members.
    local mainTank = Roles.GetMainTank()

    add(mq.TLO.Me.ID(), mq.TLO.Me.CleanName(), { isSelf = true, isTank = Roles.IsMainTank(), inGroup = true })

    for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
        local member = mq.TLO.Group.Member(index)
        if not member.OtherZone() and not member.Offline() then
            local spawn = member.Spawn
            -- the member, not just the spawn: a dead player often has no live spawn left to
            -- resolve -- hovering leaves only a corpse under another name -- but the group window
            -- still reports them at nothing
            if spawn.Dead() or (tonumber(member.PctHPs()) or 100) <= 0 then
                effectsWereStripped(member.Name())
            else
                add(spawn.ID(), spawn.CleanName(),
                    { isTank = Roles.Matches(mainTank, spawn.ID(), spawn.CleanName()), inGroup = true })
            end
        end
    end

    local pet = mq.TLO.Me.Pet
    if pet.ID() ~= nil then
        if pet.Dead() then
            effectsWereStripped(pet.CleanName())
        else
            add(pet.ID(), pet.CleanName(), { isPet = true })
        end
    end

    return candidates
end

---@return table candidates cached between scans
local function getCandidates()
    local now = Time.current_time()
    if now - SpellDpsState._.lastScanMs >= scanIntervalMs then
        SpellDpsState._.lastScanMs = now
        SpellDpsState._.candidates = scanCandidates()
    end
    return SpellDpsState._.candidates
end

---What `alreadyWorking` and the landed records read a mob as.
---
---`readable` is the question of whether the *world* will still be answering for this a couple of
---seconds from now, and for a mob that means the client is looking at it: it caches the buffs of
---whatever is targeted, and what we target in a fight is what we are killing. A slot spread
---across the fight is where that stops being true -- it borrows the target for exactly as long as
---each cast takes and moves on -- so those mobs are read the way a group member is, with what we
---cast as the only record there is.
---@param id number
---@param readable boolean
---@return table who
local function whoOfMob(id, readable)
    return { id = id, readable = readable }
end

---What `alreadyWorking` and the landed records read somebody as.
---@param candidate DpsCandidate|nil nil for whatever we are fighting
---@return table who
local function whoOf(candidate)
    if candidate == nil then
        return whoOfMob(Combat.GetTargetId(), true)
    end
    return {
        id = candidate.id,
        name = candidate.name,
        isSelf = candidate.isSelf,
        isPet = candidate.isPet,
        -- our own bar and our pet's are there to be read; everybody else's is visible only once
        -- the client has cached it, which happens when they are targeted
        readable = candidate.isSelf or candidate.isPet
    }
end

---What to remember about a cast, once it lands, and for how long.
---
---For anything whose bar can be read back, a couple of seconds is all that is wanted: enough to
---bridge the server round trip, after which the world answers for itself. For everybody else the
---fact that we cast it is the only record there is, so it is kept for as long as what we cast
---lasts -- and runs out exactly when the effect does, which is when it is worth casting again.
---@param effect string
---@param who table
---@param spell any mq spell TLO
---@return table witness { key, ms }
local function witnessFor(effect, who, spell)
    return {
        key = landedKey(effect, who),
        ms = who.readable and justLandedMs or math.max(durationMs(spell), justLandedMs)
    }
end

---Is this spell's effect already doing its work on whoever it would land on?
---
---What separates a debuff from a nuke, and a shield already up from one worth casting, without
---asking the user to label any of them: a spell that leaves something behind -- a weakness, a
---snare, a shield -- has done its whole job for as long as that something is there, and casting
---it again spends a cast and the mana to change nothing. A nuke leaves nothing behind and recasts
---freely. Read off the spell rather than configured, the same way the buff state reads a buff's
---aim and duration.
---
---Answered from the world wherever the world can be read -- our own bar, our pet's, the cache the
---client keeps for whatever has been targeted, which is what we are fighting -- and from what we
---remember casting where it cannot. The stacking check covers what neither can: a stronger effect
---in the same line, usually somebody else's, that this one would bounce off with "did not take
---hold" -- which recasting does not fix either.
---@param spell any mq spell TLO
---@param who table
---@return boolean isWorking
local function alreadyWorking(spell, who)
    if spell == nil then return false end
    if durationMs(spell) <= 0 then return false end

    local name = spell.Name()
    if name == nil then return false end

    -- our own cast, landed a beat ago: trusted ahead of a bar still catching up
    local trustedUntil = SpellDpsState._.landed[landedKey(name, who)]
    if trustedUntil ~= nil and Time.current_time() < trustedUntil then return true end

    -- a readable zero is the effect having run out, while ticking down, a permanent's negative,
    -- or unreadable are all still on them
    if who.isSelf then
        local buff = mq.TLO.Me.Buff(name)
        if buff.ID() ~= nil then return tonumber(buff.Duration()) ~= 0 end
        -- a short one sits in the song window instead, and is no less on us for it
        local song = mq.TLO.Me.Song(name)
        if song.ID() ~= nil then return tonumber(song.Duration()) ~= 0 end
        -- one the player has blocked reports as cast and never appears, so asking here is the
        -- difference between a wasted cast every time it comes round and none
        if mq.TLO.Me.BlockedBuff(name).ID() ~= nil then return true end
        return spell.Stacks() ~= true
    end

    if who.isPet then
        local remaining = tonumber(mq.TLO.Me.Pet.BuffDuration(name)())
        if remaining ~= nil then return remaining ~= 0 end
        return spell.StacksPet() ~= true
    end

    local cached = mq.TLO.Spawn("id " .. tostring(who.id)).CachedBuff(name)
    if cached.SpellID() ~= nil then
        return tonumber(cached.Duration()) ~= 0
    end

    return spell.StacksSpawn(who.id)() ~= true
end

---------------- Choosing what to cast --------------------

---Which scopes a slot holding this may be given.
---
---A spell that can only land on one kind of person has already answered the question scope asks,
---so there is exactly one answer to offer -- and offering the others would be offering settings
---that do nothing, which is how a pet shield comes to be scoped "the tank" and its owner to be
---waiting for a cast that was never going to be chosen for one.
---@param aim string one of `aims`
---@return table scopes set of scope values
local function scopesFor(aim)
    if aim == aims.self then return { [SpellDpsStateConfig.scopes.Self.value] = true } end
    if aim == aims.pet then return { [SpellDpsStateConfig.scopes.Pet.value] = true } end

    local all = {}
    for _, known in pairs(SpellDpsStateConfig.scopes) do all[known.value] = true end
    return all
end

---Is this slot meant for this person?
---
---Where the spell can be aimed comes first and scope cannot argue with it: a pet spell is for the
---pet whatever the slot says, and a self spell is for us. Scope narrows what is left over, which
---is what could go to more than one person -- and it narrows a group cast too, which is what
---stops a group shield being cast because the healer standing at the back is missing it.
---@param slot Action
---@param aim string one of `aims`
---@param candidate DpsCandidate
---@return boolean applies
local function appliesTo(slot, aim, candidate)
    if aim == aims.self then return candidate.isSelf end
    if aim == aims.pet then return candidate.isPet end
    if aim == aims.group and not candidate.inGroup then return false end

    local scope = SpellDpsStateConfig.GetScope(slot)
    if scope == SpellDpsStateConfig.scopes.Self.value then return candidate.isSelf end
    if scope == SpellDpsStateConfig.scopes.Pet.value then return candidate.isPet end
    if scope == SpellDpsStateConfig.scopes.Tank.value then return candidate.isTank end
    -- a pet is not one of the others: "anyone else" is the rest of the group, and a pet has a
    -- scope of its own to be picked out with
    if scope == SpellDpsStateConfig.scopes.Others.value then
        return not candidate.isSelf and not candidate.isPet
    end
    return true
end

---@param candidates table
---@return table covered everyone one group cast from here would land on
local function groupCoverage(candidates)
    local covered = {}
    for _, candidate in ipairs(candidates) do
        if candidate.inGroup and not candidate.isPet then covered[#covered+1] = candidate end
    end
    return covered
end

---Has this mob turned and run?
---
---There is no flag for it. The client's own `Fleeing` is pure geometry -- whether the mob is
---*facing* away from me -- and standing behind something the tank is holding answers yes for the
---whole fight. So it is asked together with the mob actually moving, which is what the two of them
---mean between them: a mob in melee with anybody stands still, and one that is moving while
---pointed away from us is going somewhere that is not us.
---
---Honest rather than perfect, and the ways it is wrong are the cheap ones. A mob that runs past
---us at somebody behind reads as running, and rooting that is not a bad thing to have done. What
---it will not do is read yes for the whole of a normal fight, which is the failure that would
---make the setting meaningless.
---@param spawn any mq spawn TLO
---@return boolean isRunning
local function isRunning(spawn)
    return spawn.Moving() == true and spawn.Fleeing() == true
end

---Is this slot's moment now?
---
---Only ever narrows what the order and the numbers have already allowed, and is asked fresh every
---pass off the world -- a slot held back at 60% is the same slot that fires at 20% without
---anything having been remembered in between. Nothing here says "and again when it fades": a
---spell that leaves something behind is already left alone while that something is on the mob
---(`alreadyWorking`), so the reapply is what happens when this gate is still open and the effect
---is not.
---@param slot Action
---@param spawn any mq spawn TLO for what we are fighting
---@return boolean isTime
local function timingAllows(slot, spawn)
    local timing = SpellDpsStateConfig.GetTiming(slot)

    if timing == SpellDpsStateConfig.timings.Hurt.value then
        local pct = tonumber(spawn.PctHPs())
        -- unreadable health is not "it is hurt enough": a slot saved for the end of a fight waits
        -- rather than fires when the world will not say
        return pct ~= nil and pct <= SpellDpsStateConfig.GetTimingPct(slot)
    end

    if timing == SpellDpsStateConfig.timings.Fleeing.value then
        return isRunning(spawn)
    end

    return true
end

---@class DpsPick
---@field action ActionType
---@field targetId number|nil what the cast should aim at; nil for a spell that aims itself
---@field on string|nil who it is being cast on, for status; nil for what we are fighting
---@field witnesses table what to remember once it lands

---What this slot has to do to one particular mob, if anything.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@param spawn any mq spawn TLO for that mob
---@param who table
---@return DpsPick? pick
local function pickAtMob(slot, action, spell, spawn, who)
    if not timingAllows(slot, spawn) then return nil end
    if alreadyWorking(spell, who) then return nil end
    if not action:IsReady(SpellDpsState.CastRequest(who.id)) then return nil end

    local effect = durationMs(spell) > 0 and spell.Name() or nil
    return {
        action = action,
        targetId = who.id,
        on = nil,
        witnesses = effect ~= nil and { witnessFor(effect, who, spell) } or {}
    }
end

---The mob, for a slot aimed at it.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@param spawn any mq spawn TLO for what we are fighting
---@return DpsPick? pick
local function pickAtTarget(slot, action, spell, spawn)
    return pickAtMob(slot, action, spell, spawn, whoOf(nil))
end

---The first mob in the fight this slot still has work to do on, for a slot spread across all of
---them.
---
---This is the one thing a debuff wants that the order in the list cannot say on its own. A slow
---or a tash is worth more on the second mob than a nuke is worth on the first, and while any of
---them is still short of it this slot has something to do -- so it keeps winning the walk down
---the rotation and nothing below it is reached. It stops the moment they all have it, with
---nothing remembered: the answer is re-derived from the fight and from what is on each mob every
---pass, so an add that arrives late is picked up on the pass it arrives.
---
---What we are killing comes first (Combat orders the fight that way) and the rest follow. Each
---one is asked its own timing question, because *when* is a fact about the mob the cast is aimed
---at: "once it runs" spread across the fight is a snare on each mob as it turns, which is what it
---should mean. A mob that cannot be cast at right now -- out of range, out of sight, on the far
---side of a wall from the group member it is beating on -- is passed over rather than waited for,
---exactly as a friend out of range is: it says nothing about the next mob, and the pass after this
---one will ask again anyway.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@return DpsPick? pick
local function pickAcrossFight(slot, action, spell)
    local targetId = Combat.GetTargetId()

    for _, id in ipairs(Combat.GetFightIds()) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        -- the roster is as fresh as the sweep that built it; a corpse hitting the ground between
        -- one and the other is caught here, where it costs a read of a spawn we are about to
        -- judge anyway
        if spawn.ID() ~= nil and not spawn.Dead() then
            local pick = pickAtMob(slot, action, spell, spawn, whoOfMob(id, false))
            if pick ~= nil then
                -- named only when it is not the one being killed, so the ordinary case reads the
                -- way it always has and the spread reads as what it is: a cast aimed off to the side
                if id ~= targetId then pick.on = spawn.CleanName() end
                return pick
            end
        end
    end

    return nil
end

---The first person this slot is worth casting on right now.
---@param slot Action
---@param action ActionType
---@param spell any mq spell TLO
---@return DpsPick? pick
local function pickOnFriend(slot, action, spell)
    -- a friendly cast that leaves nothing behind has no way of being finished with: there is
    -- nothing to read back, so it would go out again every time the gem came up. `DescribeSlot`
    -- says so on the page rather than leaving it a silent puzzle
    if durationMs(spell) <= 0 then return nil end

    local subject = action:Subject()
    local aim = aimOf(subject)
    local needsTarget = subject:NeedsTarget()
    local candidates = getCandidates()
    local effect = spell.Name()

    for _, candidate in ipairs(candidates) do
        if appliesTo(slot, aim, candidate) then
            local who = whoOf(candidate)
            if not alreadyWorking(spell, who) then
                -- a spell that aims itself is cast at nobody: EQ puts a self buff on us, a pet
                -- spell on our pet and a group spell on the group with nothing targeted, and
                -- targeting for one of those would drop what we are fighting to no purpose
                local targetId = needsTarget and candidate.id or nil
                local isGroupCast = aim == aims.group

                if action:IsReady(SpellDpsState.CastRequest(targetId)) then
                    local witnesses = {}
                    -- one person short of it is enough to cast a group spell, and everyone it
                    -- covers has it afterwards whether they were short of it or not
                    for _, covered in ipairs(isGroupCast and groupCoverage(candidates) or { candidate }) do
                        witnesses[#witnesses+1] = witnessFor(effect, whoOf(covered), spell)
                    end

                    return {
                        action = action,
                        targetId = targetId,
                        on = isGroupCast and "the group" or candidate.name,
                        witnesses = witnesses
                    }
                end

                -- one cast, whoever it was chosen for: there is no other candidate to try
                if isGroupCast then return nil end
                -- otherwise "not castable at *them*" -- out of range, out of sight -- says nothing
                -- about the next person on the list, so keep looking rather than dropping the slot
            end
        end
    end

    return nil
end

---Is this slot spread across the fight?
---
---Asked of the spell as well as of the setting, because a spell that leaves nothing behind has no
---way of being finished with anybody: spread across the fight it would pick the same mob every
---pass, which is what it does anyway. `DescribeSlot` says so on the page, so the switch is only
---ever offered where it means something; this is for a config that was edited by hand.
---@param slot Action
---@param spell any mq spell TLO
---@return boolean isSpread
local function isSpread(slot, spell)
    return SpellDpsStateConfig.GetSpread(slot) and durationMs(spell) > 0
end

---The first slot in the rotation that is worth firing right now.
---@param onlyFriendly boolean while the mob is still too healthy to start on
---@param spawn any mq spawn TLO for what we are fighting
---@return DpsPick? pick
local function choosePick(onlyFriendly, spawn)
    for _, slot in ipairs(SpellDpsStateConfig.GetActions()) do
        if Action.IsEnabled(slot) then
            local action = Action.GetActionType(slot)
            -- casts only: this state polls the cast it started, which a skill or a discipline has
            -- no equivalent of. Only casts are offered on the page; this is for a config that was
            -- edited by hand.
            if action ~= nil and action.Subject ~= nil then
                local spell = action:Subject():Spelldata()
                if spell ~= nil then
                    local friendly = isFriendly(spell)
                    if (friendly or not onlyFriendly) and Action.GetLuaResult(slot) then
                        local pick
                        if friendly then
                            pick = pickOnFriend(slot, action, spell)
                        elseif isSpread(slot, spell) then
                            pick = pickAcrossFight(slot, action, spell)
                        else
                            pick = pickAtTarget(slot, action, spell, spawn)
                        end
                        if pick ~= nil then return pick end
                    end
                end
            end
        end
    end
    return nil
end

---------------- The state itself --------------------

---@return string description of what this state is doing, for the page and /state
function SpellDpsState.Describe()
    if SpellDpsState._.castId ~= nil then
        return "casting " .. tostring(SpellDpsState._.castName) ..
            (SpellDpsState._.castOn ~= nil and (" on " .. SpellDpsState._.castOn) or "")
    end
    if SpellDpsState._.holdReason ~= nil then
        return "holding: " .. SpellDpsState._.holdReason
    end
    return "watching"
end

---@return string|nil result what the last cast did
function SpellDpsState.GetLastResult()
    return SpellDpsState._.lastResult
end

function SpellDpsState.Reset()
    SpellDpsState._.castId = nil
    SpellDpsState._.castName = nil
    SpellDpsState._.castOn = nil
    SpellDpsState._.castWitnesses = {}
end

---@class DpsSlotFacts
---@field friendly boolean whether this slot is cast on a friend rather than at what we are fighting
---@field timed boolean whether *when in a fight* is a question this slot can be asked. True for a
---slot aimed at what we are fighting; false for one cast on a friend, whose moment is decided for
---it -- when somebody is short of it -- and false for a row nobody has finished filling in
---@field spreadable boolean whether *every mob in the fight* is a question this slot can be
---asked. A slot aimed at the mob, holding something that leaves an effect behind -- which is the
---debuff half of the list and nothing else: a nuke has nothing to finish, and a slot cast on a
---friend is already told who it is for
---@field aim string one of `aims`
---@field aimText string what that means, in words
---@field scopes table set of scope values this slot may be given; one entry means it is decided,
---and none means there is nothing to choose between
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user. Everything here is
---read off the spell rather than configured, so it is also the answer to "why is this one not
---firing" -- which is otherwise a silent puzzle.
---@param slot Action
---@return DpsSlotFacts facts
function SpellDpsState.DescribeSlot(slot)
    local facts = {
        friendly = false,
        timed = false,
        spreadable = false,
        aim = aims.single,
        aimText = "at what we are fighting",
        scopes = {},
        problem = nil
    }

    -- a row being filled in has nothing to report yet, and "this character does not have it" is a
    -- strange thing to say about a spell nobody has picked
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

    local subject = action:Subject()
    local spell = subject:Spelldata()
    if spell == nil then
        facts.problem = "no spell data"
        return facts
    end

    facts.friendly = isFriendly(spell)
    facts.timed = not facts.friendly
    -- the debuff half of the list: aimed at the mob and leaving something behind, which is the
    -- only thing that can be finished with one mob and gone on to the next
    facts.spreadable = facts.timed and durationMs(spell) > 0
    if not facts.friendly then return facts end

    facts.aim = aimOf(subject)
    facts.aimText = ({
        [aims.self] = "on me",
        [aims.pet] = "on my pet",
        [aims.group] = "on the group, in one cast",
        [aims.single] = "on one of us at a time"
    })[facts.aim]
    facts.scopes = scopesFor(facts.aim)

    if durationMs(spell) <= 0 then
        facts.problem = "it lands on a friend and leaves nothing behind, so it is not one of these"
    end

    return facts
end

---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsState.Init()
    if SpellDpsState._.isInit then return end

    -- our own config, so a class that does not register this state gets no rotation written
    SpellDpsStateConfig.Init()

    Menu.RegisterState(SpellDpsState)

    ToggleCommand.Register({
        key = SpellDpsState.key,
        phrase = SpellDpsState.eventIds.nuke,
        summary = "Turns the spell damage rotation on or off for listener(s)",
        about = {
            "Off calls off a cast in progress and stops starting new ones.",
            "Melee, healing and everything else carry on regardless -- this is only the spells."
        },
        get = SpellDpsStateConfig.IsEnabled,
        set = SpellDpsState.SetEnabled
    })

    ActionCommand.Register({
        key = SpellDpsState.key,
        phrase = SpellDpsState.eventIds.nukeAction,
        summary = "Switches one of the configured spell damage actions on or off",
        where = "Spell DPS page",
        getActionLists = SpellDpsStateConfig.GetActionLists
    })

    SpellDpsState.Reset()
    SpellDpsState._.isInit = true
end

---Look at the fight, decide what should be happening, act on it, and release.
---
---Same shape as every other state and for the same reason: there is no "I am casting" mode to be
---stuck in. Each pass asks whether there is any reason to hold, whether the cast in the air is
---still aimed at something worth casting at, and -- if there is nothing in the air -- what to
---start. A cast that cannot get itself started is reconsidered here every pass like anything
---else.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsState.Go()
    local code, hold, target = holdReason()
    SpellDpsState._.holdReason = hold

    local castId = SpellDpsState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        if status == nil then
            if code == "noTarget" then
                DebugLog("Calling off the cast: " .. tostring(hold))
                SpellDpsState._.lastResult = tostring(SpellDpsState._.castName) .. ": called off, " .. tostring(hold)
                Casting.StopFor(SpellDpsState.key)
            end
            return true
        end

        local what = tostring(SpellDpsState._.castName) ..
            (SpellDpsState._.castOn ~= nil and (" on " .. SpellDpsState._.castOn) or "")

        if status == Casting.status.succeeded and outcome == Casting.outcomes.succeeded then
            SpellDpsState._.lastResult = what .. ": landed"
            local now = Time.current_time()
            for _, witness in ipairs(SpellDpsState._.castWitnesses) do
                SpellDpsState._.landed[witness.key] = now + witness.ms
            end
        else
            SpellDpsState._.lastResult = what .. ": " .. tostring(reason)
        end

        DebugLog("Cast finished: " .. tostring(SpellDpsState._.lastResult))
        SpellDpsState.Reset()
        return true
    end

    if hold ~= nil and not friendlyOnly(code) then return false end

    prune()

    local pick = choosePick(friendlyOnly(code), target)
    if pick == nil then return false end

    local newCastId, refused = Casting.Cast(pick.action:Subject(), SpellDpsState.CastRequest(pick.targetId))
    if newCastId == nil then
        DebugLog("Cast of [" .. pick.action:Name() .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Casting [" .. pick.action:Name() .. "] on " .. tostring(pick.on or pick.targetId))
    SpellDpsState._.castId = newCastId
    SpellDpsState._.castName = pick.action:Name()
    SpellDpsState._.castOn = pick.on
    SpellDpsState._.castWitnesses = pick.witnesses
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
SpellDpsState.IsEnabled = function()
    return SpellDpsStateConfig.IsEnabled()
end

---Switching it off calls off the cast in the air: it is the casting service's now, and it would
---hold the chain back for a rotation we were just told to stop running. The fight itself is not
---called off -- `attack off` does that, and a character told to stop nuking still swings.
---@diagnostic disable-next-line: duplicate-set-field
SpellDpsState.SetEnabled = function(isEnabled)
    SpellDpsStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        Casting.StopFor(SpellDpsState.key)
        SpellDpsState.Reset()
    end
end

function SpellDpsState.BuildMenu()
    SpellDpsStateMenu.BuildMenu(SpellDpsState)
end

return SpellDpsState
