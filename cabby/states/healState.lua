---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local Curing = require("cabby.curing")
local HealStateConfig = require("cabby.configs.healStateConfig")
local HealStateMenu = require("cabby.ui.states.healStateMenu")
local Menu = require("cabby.ui.menu")
local Rezzes = require("cabby.actions.rezzes")
local Rezzing = require("cabby.rezzing")
local Roles = require("cabby.roles")
local SlashCmd = require("cabby.commands.slashcmd")
local Speak = require("cabby.commands.speak")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---How often the group's health is read. Every frame would be affordable, but nothing here
---changes meaningfully inside a tenth of a second and a healer that is starving the states below
---it should be cheap while it watches.
local scanIntervalMs = 100

---After a heal lands, the client can take a moment to report the new health. Without this the
---next pulse sees the old number and casts the same heal again. Someone in real trouble is
---exempt -- chain healing a tank at 20% is the point of a healer.
local healSettleMs = 1000

---How far above the threshold that triggered a heal the target has to climb before the heal is
---no longer worth finishing. Some margin, because a heal landing from elsewhere at exactly the
---trigger point should not make us throw ours away.
local abortMarginPct = 10

---How long an ordered heal waits for its turn before it is forgotten. An order is about right
---now; one that could not be acted on for ten seconds is stale, and acting on it late is worse
---than not acting on it.
local orderTimeoutMs = 10000

---How long a target is left alone after a heal on them did not land.
---
---A refusal costs nothing to make, which is exactly the problem: without this, a target the
---client will not take a heal on is asked again on the very next pass, and every pass after that,
---at whatever rate the loop runs. What that looks like from the outside is a cast and a
---cancellation per frame and nothing ever leaving the ground.
---
---Deliberately *not* waived for someone below the emergency mark, which is the one thing that
---separates it from the settle window above: chain healing a tank at 20% is the point of a healer,
---but a cast that would not go out is not a heal that needs repeating faster. It is a debounce
---rather than a give-up -- the target is reconsidered the moment it runs out.
local retryAfterFailureMs = 3000

---How long *this heal* is left alone on the person it just landed on, over and above the settle
---window above.
---
---The settle window is about the client catching up and is the same for every heal. This is the
---different question of whether casting the same heal again is the right move at all: a heal that
---took six seconds to arrive has not stopped being the answer six seconds later, and re-firing it
---into its own arrival is how a healer empties a mana bar with nothing to show for it. Derived
---from the cast rather than configured, because the cast is what says how big the heal was --
---and kept per slot, so the *other* slots stay free to fire on the same person in the meantime,
---which is the whole point of having an ordered list of them.
local slotReuseMs = 1500

---How far ahead of a heal over time running out it is worth putting the next one up.
---
---A gap between the two is a tick of healing nobody gets, and the alternative -- refreshing on a
---timer of our own -- is casting a heal over a heal that is still working. This is the overlap
---that costs one cast and closes the gap.
local hotRefreshMarginMs = 3000

---How long another healer's call holds us off the person they named.
---
---Long enough to cover the cast they are about to make and no longer: a call is a statement about
---what somebody is doing now, and one that outlived the cast would leave a target nobody is
---covering because everybody thinks somebody else is.
local healCallHoldMs = 3000

---How far away a friendly on the extended target window is still worth watching.
---
---Nothing is healed at this range -- every cast is measured against the spell's own reach when it
---is started -- but the sweep has to stop somewhere, and somebody across the zone is not this
---character's problem however low they are.
local xtargetReach = 250

---Where a slot's heal can be aimed, read off the spell rather than configured -- the same model
---the buff state uses, and for the same reason: what a spell can land on is what it is, and
---asking the user to say so is one more thing to get wrong.
local aims = {
    self = "self",     -- only ever lands on the caster
    pet = "pet",       -- only ever lands on this character's pet
    group = "group",   -- one cast covers the whole group and needs no target
    single = "single", -- one person at a time
    -- a rez. Here so that a rez put in a heal slot is *recognised* rather than treated as an
    -- ordinary single-target heal and cast at somebody alive: rezzing is not configured at all
    -- (see `cabby.rezzing`), so a slot holding one is a mistake worth naming on the page
    corpse = "corpse"
}

local petTargetTypes = { ["pet"] = true, ["pet2"] = true }

---Keeping a group alive.
---
---One ordered list of heal slots decides everything (see `HealStateConfig`): who a slot is for,
---how hurt they have to be for it to be the right one, and whether it is a heal for a fight.
---This state's job is the choosing -- who is worst off, which slot fits them, and whether the heal
---already in the air is still the right heal -- because the casting service does the casting and
---the priority chain does the holding-everything-else-back.
---
---What a slot can be aimed at is not part of that configuration: the group heal, the self heal
---and the pet heal are read off the spell (`aims` below), which is what lets one list serve a
---cleric keeping six people up and a magician keeping one pet up.
---
---**Curing rides here too**, and it is the one job in this state that is not chosen from the
---slot list. A cure is not configured at all: somebody says what is on them, and the best cure of
---that kind this character owns answers it -- which is the only shape that works, since the person
---afflicted is the only one who can see it and has no idea what anybody hearing them can cast.
---`cabby.curing` owns that whole conversation (the reading, the asking, the queue); this state is
---the hands, because casting a cure is choosing not to cast a heal and that choice belongs where
---the healing is arbitrated. Where it sits in the pass is the whole of the arbitration: after
---anybody in real trouble and before everything else -- see `Go`.
---
---**Rezzing rides here too**, and for the same reason curing does: a rez is a gem and a large piece
---of the mana bar, so choosing to spend them on a corpse is choosing not to heal with them, and that
---choice belongs where the healing is arbitrated. It is configured no more than a cure is -- which
---rez to use has an exact answer in the spell data and who to rez has one in the group window, so
---all that is left to set is whether to do it during a fight. `cabby.rezzing` owns the choosing;
---this state is the hands. Where it sits in the pass is the arbitration: dead last, because
---everybody alive comes first -- see `Go`.
---
---**Health is not the whole of who needs a heal**, and the two things it leaves out are both
---read here rather than configured per slot. Whoever a mob is coming for is losing health that the
---person beside them is not, and a warrior at 70% is not in the trouble a wizard at 70% is -- so
---both move the reading a slot is judged against (`urgency` below), and neither moves the reading
---itself. What is *real* about somebody -- whether they are in trouble, whether a heal in the air
---has done its job, how much of the group a group heal would be worth -- is always asked of their
---actual health.
---
---**What is already on somebody is read where it can be and remembered where it cannot.** The
---client caches another player's buffs while they are targeted -- which a healer's target usually
---is -- so a heal over time is asked about directly (`hotRemainingMs`), and that is the only way to
---see one another healer put up. It is *also* remembered from our own cast, because the cache is
---blind to a buff that landed while the target was already selected, which is exactly the case
---after we heal somebody. Neither source alone is enough; the pair is.
---
---A debuff that wants curing is still asked for out loud (see `cabby.curing`) rather than
---discovered the same way, and the difference is not readability but *who is looking*: a healer
---would have to target its way around the group every few seconds to find one, where a heal over
---time is only ever asked about for somebody it is already considering.
---@class HealState : BaseState
local HealState = {
    key = "HealState",
    eventIds = {
        -- `healnow` rather than `heal`: a registered phrase also matches every longer line that
        -- starts with it, so a plain `heal` would fire on `healme`, `healing off` and the rest of
        -- the switches below, complaining about spawn ids nobody typed
        heal = "healnow",
        healMe = "healme",
        healing = "healing",
        healGroup = "healgroup",
        healPets = "healpets",
        healXTarget = "healxtarget",
        healAction = "healaction",
        curing = "curing",
        -- `reznow` rather than `rez`, for the reason `healnow` is not `heal`: a registered phrase
        -- also matches every longer line that starts with it, and a plain `rez` would fire on
        -- `rezme` and `rezzing off` alike
        rez = "reznow",
        rezMe = "rezme",
        rezzing = "rezzing",
        -- `onheal` rather than `heal` or `healing`, both of which are taken above -- and it reads
        -- as what it is: a statement about who this healer is on, not an instruction to anybody
        healCall = "onheal",
        healCalls = "healcalls"
    },
    _ = {
        isInit = false,
        candidates = {},
        lastScanMs = 0,
        castId = nil,
        healTarget = nil,   -- { id, name, pct } as it was when the heal started
        healSlot = nil,     -- the configured slot chosen for it
        healThreshold = nil,
        -- the CureRequest the cast in flight is answering, nil while it is an ordinary heal. The
        -- one thing that says which of the two jobs this state is in the middle of
        cureRequest = nil,
        lastCureResult = nil,
        -- the corpse the cast in flight is being rezzed, nil while it is anything else. The other
        -- half of the one field that says which of this state's three jobs it is in the middle of
        rezPick = nil,
        lastRezResult = nil,
        order = nil,        -- { id, name, expiresMs } from a `heal <id>` or `healme`
        settleUntil = {},   -- { [spawn id] = time we may consider healing them again }
        -- { [spawn id] = when a heal that did not land is worth trying on them again }. Kept apart
        -- from settleUntil because the two are waived under different conditions: see isHeldOff
        tryAgainAt = {},
        -- { ["spawn id/heal name"] = when this *particular* heal is worth casting on them again }.
        -- One heal being held is not the person being held: the slots below it stay free, which is
        -- how the ordered list keeps working while the big one is on its own clock
        slotHeldUntil = {},
        -- { ["spawn id/heal name"] = when the heal over time we put on them runs out }. The only
        -- thing knowable about what is on another player, because it is the record of what *we*
        -- did rather than a reading of them
        hotUntil = {},
        -- { [spawn id] = when another healer's call on them stops standing }
        calledBy = {},
        calledOff = false,
        lastResult = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(HealState.key, str)
end

---------------- Who needs healing --------------------

---@class HealCandidate
---@field id number
---@field name string
---@field pct number current health, as a percentage. **The truth**, and what every question about
---reality is asked of
---@field urgency number the health this person is *judged* at, once the head start below has had
---their say. **A preference, not a reading**: it orders the list and it is what a slot's threshold
---is compared against, and it is used for nothing else
---@field isSelf boolean
---@field isTank boolean the group's main tank, by the role assigned in the group window
---@field isPet boolean
---@field isHolding boolean something is coming for this one, as far as this client can tell
---@field isXTarget boolean watched off the extended target window rather than the group
---@field class string|nil short name, nil for a pet and for anyone the client will not say.
---Reported by `/cheal` and the page and read by nothing that decides anything
---@field distance number how far away, which is what a group heal's reach is measured against

---What somebody is judged at, as against what they are actually reading.
---
---One head start, and it answers the standing complaint about healing off a bare percentage.
---Health is a photograph: it says where somebody is and nothing about where they are going.
---Whoever a mob is coming for is about to be at a lower number than the person beside them reading
---the same one, and that is the closest thing to a direction of travel that can be had without
---watching one over time. One number for the whole group, because it is a fact about the fight
---rather than about the person.
---
---Bounded by `HealStateConfig` (see `maxHeadStart`), though that is not what keeps it off somebody
---who is dying -- the sort does that, by putting the emergency band first outright. The bound is
---what keeps this recognisable as a preference rather than a second threshold.
---@param pct number
---@param flags table
---@return number urgency clamped to a real percentage, so nothing downstream has to wonder
local function urgencyOf(pct, flags)
    if flags.isHolding ~= true then return pct end
    return math.max(math.min(pct - HealStateConfig.GetAggroHeadStart(), 100), 0)
end

---@param candidates table
---@param id number|nil
---@param name string|nil
---@param pct number|nil
---@param flags table
local function addCandidate(candidates, id, name, pct, flags)
    id = tonumber(id)
    pct = tonumber(pct)
    if id == nil or id < 1 or pct == nil then return end

    -- Nobody at nothing is healable, and `Dead()` is not enough to catch them: a player on the way
    -- to a corpse reads as a live spawn at zero or *below* zero health for as long as the server
    -- takes to make the corpse. Sorted worst-first, one of those outranks every real target in the
    -- group -- so it is not merely a wasted cast, it is the only cast this state will consider.
    if pct <= 0 then return end

    candidates[#candidates+1] = {
        id = id,
        name = name or tostring(id),
        pct = pct,
        urgency = urgencyOf(pct, flags),
        isSelf = flags.isSelf == true,
        isTank = flags.isTank == true,
        isPet = flags.isPet == true,
        isHolding = flags.isHolding == true,
        isXTarget = flags.isXTarget == true,
        class = flags.class,
        distance = tonumber(flags.distance) or 0
    }
end

---Who something is actually coming for, as far as this client can tell.
---
---Three answers, none of them complete and all of them free, because the complete one does not
---exist: the extended target window lists what hates *us* and a group member's does not carry
---across, so there is no reading anywhere of who a mob standing in front of somebody else is
---swinging at. What there is:
---
---- **Us**, from the same `PctAggro` reading `cabby.combat` builds `IsUnderAttack` on -- the one
---  case this client knows exactly.
---- **Whoever our target is coming for**, when what we have targeted is a mob. A healer usually
---  has a friendly targeted and this usually answers nothing, but when it answers it is right, and
---  it is the only way a *non*-tank who has pulled aggro is ever noticed.
---- **The main tank**, while there is a fight on. Not a reading at all -- it is the standing answer
---  to the question, and being wrong about it costs the tank a head start it very nearly always
---  deserves. Held to a fight so that a tank standing about between pulls is nobody special.
---@return table holding set of spawn ids
local function holdersOfAggro()
    local holding = {}

    if Combat.IsUnderAttack() then
        local meId = tonumber(mq.TLO.Me.ID())
        if meId ~= nil then holding[meId] = true end
    end

    if mq.TLO.Target.Type() == "NPC" then
        local onId = tonumber(mq.TLO.Me.TargetOfTarget.ID())
        if onId ~= nil and onId > 0 then holding[onId] = true end
    end

    if Combat.IsGroupFighting() then
        local mainTank = Roles.GetMainTank()
        local tankId = tonumber(mainTank ~= nil and mainTank.id or nil)
        if tankId ~= nil and tankId > 0 then holding[tankId] = true end
    end

    return holding
end

---Friendlies on the extended target window who are not already being watched.
---
---The one thing the group window cannot answer: a raid-mate, a boxed character grouped elsewhere,
---somebody's second-account tank. `Auto Hater` is skipped because that is the client's word for
---"this is fighting you" and a mob is nobody's heal; everything left that reads as a player or a
---pet is somebody this character can see and could keep alive.
---
---Off by default, and worth saying why it has to be asked for: it widens who this character is
---responsible for, and the mana comes out of the same bar the group is drawing on.
---@param candidates table what has already been collected, which is what stops a group member
---sitting on the window being watched twice
---@param holding table the aggro reading this scan already took, handed down rather than taken
---again: it is twenty window reads and it cannot have changed since the line above
local function addXTargets(candidates, holding)
    if not HealStateConfig.GetHealXTarget() then return end

    local seen = {}
    for _, candidate in ipairs(candidates) do seen[candidate.id] = true end

    for slot = 1, (tonumber(mq.TLO.Me.XTargetSlots()) or 0) do
        local xtarget = mq.TLO.Me.XTarget(slot)
        local kind = xtarget.TargetType()

        -- what the window says this entry *is to us*: a mob fighting us is not a heal target, and
        -- it is the one entry type that is never a friendly
        if kind ~= "Auto Hater" then
            local id = tonumber(xtarget.ID())
            local spawnType = xtarget.Type()

            if id ~= nil and id > 0 and not seen[id] and (spawnType == "PC" or spawnType == "Pet") then
                local spawn = mq.TLO.Spawn("id " .. tostring(id))
                local distance = tonumber(spawn.Distance3D()) or tonumber(spawn.Distance())

                if spawn.ID() ~= nil and not spawn.Dead() and distance ~= nil and distance <= xtargetReach then
                    seen[id] = true
                    addCandidate(candidates, id, spawn.CleanName(), Status.HealthPct(spawn), {
                        isXTarget = true,
                        isPet = spawnType == "Pet",
                        isHolding = holding[id] == true,
                        class = spawnType == "PC" and spawn.Class.ShortName() or nil,
                        distance = distance
                    })
                end
            end
        end
    end
end

---Everyone worth watching, and how they are doing.
---
---Group members who are out of the zone or offline are skipped rather than counted as healthy:
---they have no spawn to heal, and treating a missing member as a full one would be a quiet way
---to get the count for a group heal wrong.
---@return table candidates
local function scanCandidates()
    local candidates = {}

    -- Through Roles rather than off `Group.Member[#].MainTank`, so that "the tank" is one answer
    -- for the whole script -- and so it is answered for *this* character too. A paladin holding
    -- the role is who a tank-scoped slot is for, and reading the flag per group member could never
    -- say so, since we are not one of our own group members.
    local mainTank = Roles.GetMainTank()
    local holding = holdersOfAggro()

    local meId = tonumber(mq.TLO.Me.ID())
    addCandidate(candidates, meId, mq.TLO.Me.CleanName(), mq.TLO.Me.PctHPs(), {
        isSelf = true,
        isTank = Roles.IsMainTank(),
        isHolding = meId ~= nil and holding[meId] == true,
        class = mq.TLO.Me.Class.ShortName(),
        distance = 0
    })

    if HealStateConfig.GetHealGroup() then
        for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
            local member = mq.TLO.Group.Member(index)
            if not member.OtherZone() and not member.Offline() then
                local spawn = member.Spawn
                if not spawn.Dead() then
                    local id = tonumber(spawn.ID())
                    addCandidate(candidates, id, spawn.CleanName(), Status.HealthPct(spawn), {
                        isTank = Roles.Matches(mainTank, spawn.ID(), spawn.CleanName()),
                        isHolding = id ~= nil and holding[id] == true,
                        class = spawn.Class.ShortName(),
                        -- 3D, because a group heal's reach is a sphere and the member standing at
                        -- the bottom of the ramp is further away than the floor plan says
                        distance = tonumber(spawn.Distance3D()) or tonumber(spawn.Distance()) or 0
                    })
                end
            end
        end
    end

    if HealStateConfig.GetHealPets() then
        local pet = mq.TLO.Me.Pet
        if pet.ID() ~= nil and not pet.Dead() then
            addCandidate(candidates, pet.ID(), pet.CleanName(), Status.HealthPct(pet), {
                isPet = true,
                isHolding = holding[tonumber(pet.ID()) or 0] == true,
                distance = tonumber(pet.Distance3D()) or tonumber(pet.Distance()) or 0
            })
        end
    end

    addXTargets(candidates, holding)

    -- **Anybody in real trouble comes first, and no preference can reach in front of them.**
    --
    -- This is the guarantee the head start is bounded *for*, and bounding it was not enough to
    -- give it: capping an adjustment under the emergency mark still lets a healthy warrior carrying
    -- one sort ahead of somebody genuinely dying, because the two numbers being compared are the
    -- adjusted ones. So the band is the first thing sorted on and real health orders it -- a
    -- preference is about who to help first among people who are merely hurt, and it has nothing to
    -- say about who is closest to dead.
    --
    -- Everybody else is ordered by the judged reading, with real health breaking a tie so that two
    -- people a head start has levelled are still handled in a sensible order rather than in
    -- whatever order they were scanned.
    local emergency = HealStateConfig.GetEmergencyPct()
    table.sort(candidates, function(a, b)
        local aTrouble, bTrouble = a.pct <= emergency, b.pct <= emergency
        if aTrouble ~= bTrouble then return aTrouble end
        if aTrouble then return a.pct < b.pct end
        if a.urgency ~= b.urgency then return a.urgency < b.urgency end
        return a.pct < b.pct
    end)
    return candidates
end

---@return table candidates cached between scans
local function getCandidates()
    local now = Time.current_time()
    if now - HealState._.lastScanMs >= scanIntervalMs then
        HealState._.lastScanMs = now
        HealState._.candidates = scanCandidates()
    end
    return HealState._.candidates
end

---@param id number
---@return table? candidate
local function findCandidate(id)
    for _, candidate in ipairs(getCandidates()) do
        if candidate.id == id then return candidate end
    end
    return nil
end

---How many of the people we watch a group heal would actually be worth casting for.
---
---**Real health, not the judged reading.** The head start is about who to heal *first* and this
---is not that question: a group heal is cast because enough healing is genuinely needed to be
---worth one cast covering everybody, and counting a warrior at 85% as though he were at 70% would
---fire it for damage nobody has taken.
---
---**Within the heal's own reach**, which is the whole reason this takes a distance at all. A group
---heal lands on whoever is standing with us, so the member who ran off after a caster is not
---somebody it is going to help -- counting them is how three people at the camp become "enough"
---on the strength of one who is not there, and the cast goes out to heal two.
---@param pct number
---@param reach number|nil how far the heal carries; nil counts everybody, which is what a reading
---the client would not give us has to fall back to
---@return number count
local function countAtOrBelow(pct, reach)
    local count = 0
    for _, candidate in ipairs(getCandidates()) do
        if candidate.pct <= pct and (reach == nil or reach <= 0 or candidate.distance <= reach) then
            count = count + 1
        end
    end
    return count
end

---------------- Choosing a heal --------------------

---What a heal can land on, read off the spell.
---
---A pet heal is the reason this is not simply "does it need a target": EQ aims one at the pet
---with nothing targeted, exactly as it aims a group heal at the group, so the two are
---indistinguishable by `NeedsTarget` alone -- and a pet class's only heal would have been chosen
---for the group and cast because three people were scuffed.
---@param subject CastSubject
---@return string aim one of `aims`
local function aimOf(subject)
    local targetType = subject:TargetType()
    if petTargetTypes[targetType] then return aims.pet end
    if targetType == "self" then return aims.self end
    -- a rez, which is nobody's heal: it needs a target like a single-target heal does and would
    -- otherwise be chosen for whoever is worst off and cast at a living person
    if targetType == "corpse" then return aims.corpse end
    -- everything else that aims itself covers the group: Group v1/v2, and the point-blank and
    -- targeted AE heals that land on whoever is standing with us
    if not subject:NeedsTarget() then return aims.group end
    return aims.single
end

---@param action ActionType|nil
---@return string? aim nil for an action this state cannot heal with at all
local function aimOfAction(action)
    -- casts only: this state polls the cast it started, which a skill or a discipline has no
    -- equivalent of. Only casts are offered on the page; this is for a config edited by hand.
    if action == nil or action.Subject == nil then return nil end
    return aimOf(action:Subject())
end

---Is this slot meant for this person?
---
---Where the heal can be aimed comes first and scope cannot argue with it: a pet heal is for the
---pet whatever the slot says, and a self heal is for us. Scope narrows what is left over, which
---is the heals that could go to more than one person.
---@param slot Action
---@param aim string one of `aims`
---@param candidate HealCandidate
---@return boolean applies
local function appliesTo(slot, aim, candidate)
    -- nobody alive, whatever the slot says. The one place this has to be refused, since every walk
    -- that picks a heal for a person goes through here
    if aim == aims.corpse then return false end
    if aim == aims.self then return candidate.isSelf end
    if aim == aims.pet then return candidate.isPet end

    local scope = HealStateConfig.GetScope(slot)
    if scope == HealStateConfig.scopes.Self.value then return candidate.isSelf end
    if scope == HealStateConfig.scopes.Pet.value then return candidate.isPet end
    if scope == HealStateConfig.scopes.Tank.value then return candidate.isTank end
    -- a pet is not one of the others: "anyone else" is the rest of the group, and a pet has a
    -- scope of its own to be picked out with
    if scope == HealStateConfig.scopes.Others.value then
        return not candidate.isSelf and not candidate.isPet
    end
    return true
end

---Is this slot's heal one for the moment we are in?
---
---The other half of what a slot narrows by, and the half a threshold has no way to express: the
---expensive fast heal is what a fight is for and is a waste on somebody standing about at 60%
---between pulls, and the slow efficient one is worth every second of the quiet and worth nothing
---at all while the tank is being hit. Both are one slot being right at one moment and wrong at
---another, which is a fact about the fight and not about anybody's health -- so it is asked here,
---beside the scope, rather than being pushed into a number.
---
---**Read off `IsGroupFighting` rather than off our own engagement, and that is the whole of this
---working.** A healer is not *engaged*: it has no target of its own and usually has auto-engage
---off, so it stands in the middle of a fight answering "no" to `IsEngaged` for the entire length
---of one. Reading the engagement here would leave "in a fight" false all fight on exactly the
---class this setting exists for, and a slot carrying it would simply never fire. Combat publishes
---the wider fact for readers like this one -- see `Combat.IsGroupFighting`, which cures and rezzes
---deliberately do *not* use, because those two are asking whether **we** are busy fighting.
---@param slot Action
---@return boolean applies
local function appliesNow(slot)
    local when = HealStateConfig.GetWhen(slot)
    if when == HealStateConfig.whens.Any.value then return true end
    if when == HealStateConfig.whens.InCombat.value then return Combat.IsGroupFighting() end
    return not Combat.IsGroupFighting()
end

---@param candidate HealCandidate
---@return boolean isSettling true while we are waiting for a heal we already cast to show up
local function isSettling(candidate)
    if candidate.pct <= HealStateConfig.GetEmergencyPct() then return false end
    local until_ = HealState._.settleUntil[candidate.id]
    return until_ ~= nil and Time.current_time() < until_
end

---@param candidate HealCandidate
---@return boolean isHeldOff true while a heal that would not go out is being left alone
local function isHeldOff(candidate)
    local at = HealState._.tryAgainAt[candidate.id]
    return at ~= nil and Time.current_time() < at
end

---One person and one heal, which is what both of the per-slot windows below are keyed by. Named
---rather than spelled out at each site so the two can never drift apart on the way in and out.
---@param id number|nil
---@param action ActionType
---@return string|nil key nil for a heal that is for nobody in particular, which has nothing to
---remember about anybody
local function slotKey(id, action)
    if id == nil then return nil end
    return tostring(id) .. "/" .. tostring(action:Name())
end

---The same, for the one heal that is for nobody in particular.
---
---A group heal has no spawn id to be remembered against, which is exactly why `slotKey` refuses
---it -- but it still has to be left alone for a moment when the client will not take it, for the
---reason any other heal does. Keyed by the heal itself and kept in the same table, so one prune
---covers both and neither can outlive the other.
---@param action ActionType
---@return string key
local function groupSlotKey(action)
    return "group/" .. tostring(action:Name())
end

---Is another healer already on this one?
---
---Only ever a *preference*: somebody below the emergency mark is exempt, because two heals landing
---on a person who is dying is the answer being right twice, and standing back from them on the
---strength of somebody else's word is how a group loses a tank politely.
---@param candidate HealCandidate
---@return boolean isCalled
local function isCalledByAnother(candidate)
    if candidate.pct <= HealStateConfig.GetEmergencyPct() then return false end
    local until_ = HealState._.calledBy[candidate.id]
    return until_ ~= nil and Time.current_time() < until_
end

---Is anybody in real trouble at all, whether or not there is a heal for them?
---
---The blunter half of the question `emergencyPending` asks, and the one a group heal is held to:
---three people at 60% is what a group heal is for and one person at 15% is not, and that stays true
---whether or not this character happens to have something scoped to the person who is dying.
---
---Asked of everybody rather than stopped at the first person above the mark. The sort does put the
---band first, so stopping early would answer correctly today -- and that is exactly the kind of
---agreement between two distant pieces of code that is quietly broken by a later change to either.
---It is a group; asking all of it costs nothing worth counting.
---@param candidates table
---@return boolean anyone
local function anyoneInTrouble(candidates)
    local emergency = HealStateConfig.GetEmergencyPct()

    for _, candidate in ipairs(candidates) do
        if candidate.pct <= emergency then return true end
    end

    return false
end

---How long is left on this heal over time, as far as anything here can tell.
---
---Ourselves and our own pet the client answers directly. **For everybody else there are two
---sources and neither one is sufficient**, which is the whole shape of this:
---
---- **The client's cache** (`Spawn.CachedBuff`, the same reading the buff state works off) holds
---  another player's buffs from when they were last targeted, and each entry ages by itself -- what
---  it reports is what is left *now*. It is the only thing that can see a heal over time this
---  character did not cast, which matters the moment a second healer is in the group.
---- **Our own record of the cast** is what the cache is blind to. The cache is filled by the
---  client's *complete* buff message and the partial ones are discarded, so -- as the buff state
---  found the hard way -- **a buff landing on somebody already targeted is never seen**. The
---  snapshot we hold for the person we just healed predates the cast that healed them. Trusting the
---  cache alone would read "nothing on them" for the whole duration and re-apply every pass.
---
---So whichever says more time is left wins. Both are evidence that something is still running;
---neither one's silence is evidence that nothing is. That also makes the open question about
---`CachedBuff.Duration`'s units (ticks or milliseconds -- see the roadmap) harmless here: if it
---under-reads, the record still covers what we put there ourselves.
---@param candidate HealCandidate
---@param action ActionType
---@return number|nil remainingMs nil for "nothing running, as far as can be told"
local function hotRemainingMs(candidate, action)
    local name = action:Name()
    if name == nil then return nil end

    if candidate.isSelf then
        local buff = mq.TLO.Me.Buff(name)
        if buff.ID() ~= nil then return tonumber(buff.Duration()) or 0 end
        -- a short buff sits in the song window instead, and is no less on us for it. Heals over
        -- time land there often enough that asking only about buffs would answer "no" for most of
        -- them and refresh every pass
        local song = mq.TLO.Me.Song(name)
        if song.ID() ~= nil then return tonumber(song.Duration()) or 0 end
        return nil
    end

    if candidate.isPet and mq.TLO.Me.Pet.ID() == candidate.id then
        return tonumber(mq.TLO.Me.Pet.BuffDuration(name)())
    end

    local remaining = nil

    local cached = mq.TLO.Spawn("id " .. tostring(candidate.id)).CachedBuff(name)
    if cached.SpellID() ~= nil then remaining = tonumber(cached.Duration()) or 0 end

    local key = slotKey(candidate.id, action)
    local until_ = key ~= nil and HealState._.hotUntil[key] or nil
    if until_ ~= nil then
        local recorded = until_ - Time.current_time()
        if remaining == nil or recorded > remaining then remaining = recorded end
    end

    return remaining
end

---Is this heal over time already on them, with time left worth putting up against?
---
---The refresh margin is applied here rather than when the cast is written down, so that the one
---number covers both sources: a gap between two of these is a tick of healing nobody gets, and
---overlapping them costs one cast.
---@param candidate HealCandidate
---@param action ActionType
---@param durationMs number what this heal would put up; zero for one that is over when it lands
---@return boolean isRunning
local function hotIsRunning(candidate, action, durationMs)
    if durationMs <= 0 then return false end

    local remaining = hotRemainingMs(candidate, action)
    return remaining ~= nil and remaining > hotRefreshMarginMs
end

---Everything `chooseFor` would refuse this slot for that a moment will not answer differently.
---
---Range, line of sight, the mana this costs, the reserve being held to, a heal over time already
---ticking: each of those reads the same on this pass, the next one, and the one after. A heal held
---off by any of them is not a heal that is *about* to be cast, so answering yes on its strength is
---the same mistake as answering yes for somebody no slot is scoped to -- it is just harder to see.
---
---The momentary refusals are left out, and one of them would be a trap. This is asked with our own
---heal in the air, and `IsReady` refuses while the casting service is busy with somebody of equal
---rank -- so asking it here would answer no for every slot and quietly end this state's ability to
---break off for an emergency at all. The gem timer and the request cooldown are left out for the
---plainer reason: they come back within the second, whatever anybody does.
---@param slot Action
---@param action ActionType
---@param candidate HealCandidate
---@param targetId number|nil what the cast would target; nil for a heal that aims itself
---@return boolean couldCast
local function couldCast(slot, action, candidate, targetId)
    -- a heal slot has to be something castable, exactly as `readySlotAction` requires
    if action.Subject == nil then return false end
    local subject = action:Subject()
    if not subject:IsAvailable() then return false end

    -- the reserve, held to at every health but the one it was being kept for
    if candidate.pct > HealStateConfig.GetEmergencyPct() then
        local floor = HealStateConfig.GetManaFloor(slot)
        if floor > 0 and (tonumber(mq.TLO.Me.PctMana()) or 100) < floor then return false end
    end

    local manaCost = subject:ManaCost()
    if manaCost > 0 and (tonumber(mq.TLO.Me.CurrentMana()) or 0) < manaCost then return false end

    -- judged against *them*, the way `IsReady` judges it for a heal chosen for somebody who is not
    -- targeted yet. A heal that aims itself has no target to be out of reach of
    if targetId ~= nil and subject:NeedsTarget() then
        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        local spawnId = tonumber(spawn.ID())
        if spawnId == nil or spawnId < 1 then return false end

        local range = subject:Range()
        local distance = tonumber(spawn.Distance())
        if range > 0 and distance ~= nil and distance > range then return false end

        if spawn.LineOfSight() == false then return false end
    end

    return not hotIsRunning(candidate, action, subject:DurationMs())
end

---Would this pass pick this person, if it were picking?
---
---The question `reasonToAbandon` has to ask before it throws a heal away for somebody, and the one
---`emergencyPending` asks before it holds curing and rezzing back. Both are about somebody this
---state would *actually cast at*: cancelling a heal in the air is only right when there is a better
---one to cast instead, and "somebody is worse off" is not the same claim. They may be settling,
---held off after a refusal, scoped to no configured slot, stood outside the heal's reach, behind a
---wall, or already carrying the only heal that applies to them. Answering yes for any of those ends
---the cast and then re-picks the same target on the next pass -- a cast and a cancellation per frame
---for as long as they stay in that condition -- and below the emergency mark is exactly where people
---*stay*, because that is where a rez leaves them. Somebody unreachable at 20% is the case that
---closes the loop: no cast for them can ever start, so nothing ever changes the answer.
---
---So every question that outlives the pass is asked (see `couldCast`) and none of the ones that do
---not are. A gem still recovering is a reason to wait a moment, not a reason to keep casting the
---wrong heal at the wrong person.
---
---A slot's fight window (`appliesNow`) is *in*, and the difference from readiness is the one worth
---keeping straight: a gem comes back in a second whatever anybody does, where a slot kept for
---fights is not going to become castable out of one.
---@param candidate HealCandidate
---@return boolean wouldChoose
local function wouldChoose(candidate)
    if isHeldOff(candidate) or isSettling(candidate) then return false end

    for _, slot in ipairs(HealStateConfig.GetActions()) do
        if candidate.urgency <= HealStateConfig.GetThreshold(slot) then
            local action = Action.GetActionType(slot)
            local aim = aimOfAction(action)
            -- a group heal is chosen for the group, so it is not a reason to drop somebody's heal
            if aim ~= nil and aim ~= aims.group and appliesTo(slot, aim, candidate)
                and appliesNow(slot) and Action.IsEnabled(slot) and Action.GetLuaResult(slot)
                and couldCast(slot, action, candidate, aim == aims.single and candidate.id or nil) then
                return true
            end
        end
    end

    return false
end

---Drop the windows above once they have run out, so a long session does not collect an entry per
---person this character has ever tried to heal.
local function prune()
    local now = Time.current_time()
    for id, at in pairs(HealState._.settleUntil) do
        if now >= at then HealState._.settleUntil[id] = nil end
    end
    for id, at in pairs(HealState._.tryAgainAt) do
        if now >= at then HealState._.tryAgainAt[id] = nil end
    end
    for id, at in pairs(HealState._.calledBy) do
        if now >= at then HealState._.calledBy[id] = nil end
    end
    for key, at in pairs(HealState._.slotHeldUntil) do
        if now >= at then HealState._.slotHeldUntil[key] = nil end
    end
    for key, at in pairs(HealState._.hotUntil) do
        if now >= at then HealState._.hotUntil[key] = nil end
    end
end

---@class HealPick
---@field action ActionType
---@field slot Action
---@field targetId number|nil what the cast should target; nil for a heal that aims itself
---@field forId number|nil who the heal is for, which a heal that aims itself still has; nil only
---for a group heal, which is for everybody
---@field name string what is being healed, for status output
---@field threshold number the health the slot was chosen for

---Who this state is when it asks the casting service for something. The band matters to
---`IsReady` as much as to the cast itself: a heal that outranks the rotation in flight has to be
---told it *can* take it over, or it stands down and nobody heals.
---@param targetId number|nil
---@return table request
function HealState.CastRequest(targetId)
    return {
        owner = HealState.key,
        priority = HealState.priority,
        targetId = targetId
    }
end

---@param slot Action
---@param request table
---@param sparing? boolean whether the mana floor is being held to. False for somebody below the
---emergency mark, which is the moment the reserve was being kept *for*
---@return ActionType? action the slot's action, when it is usable right now
local function readySlotAction(slot, request, sparing)
    if not Action.IsEnabled(slot) then return nil end
    -- the slot's own answer to whether this is a heal for right now, asked here so that every walk
    -- which picks a slot is held to it, and asked early because it is one table read where
    -- everything below is the spellbook and the world
    if not appliesNow(slot) then return nil end

    local action = Action.GetActionType(slot)
    if action == nil then return nil end
    -- a heal slot has to be something castable: the state polls the cast it started, which a
    -- skill or a discipline has no equivalent of. Only casts are offered on the page; this is
    -- for a config that was edited by hand.
    if action.Subject == nil then return nil end

    -- Pacing, asked before readiness because it is cheaper and because it is the more common
    -- answer: `IsReady` walks the spellbook and the world, and a slot under its floor is not going
    -- to be cast whatever either of them says. The cast still has to be *payable* -- that is the
    -- casting service's own check and a different question -- this one is whether it should be.
    if sparing ~= false then
        local floor = HealStateConfig.GetManaFloor(slot)
        if floor > 0 and (tonumber(mq.TLO.Me.PctMana()) or 100) < floor then return nil end
    end

    if not action:IsReady(request) then return nil end
    if not Action.GetLuaResult(slot) then return nil end

    return action
end

---A heal that covers the whole group, when enough of it is hurt.
---
---Checked before individual heals, but only while nobody is in real trouble: three people at 60%
---is what a group heal is for, and one person at 15% is not, however many others are scuffed.
---@return HealPick? pick
local function chooseGroupHeal()
    for _, slot in ipairs(HealStateConfig.GetActions()) do
        local action = Action.GetActionType(slot)
        if aimOfAction(action) == aims.group then
            -- left alone for a moment after the client refused it, which is the same debounce every
            -- other heal gets and matters more here: this is checked before the list of people
            -- below, so a group heal that is asked for and refused every pass is a group heal that
            -- nobody underneath it ever gets past
            local heldUntil = HealState._.slotHeldUntil[groupSlotKey(action)]
            if heldUntil == nil or Time.current_time() >= heldUntil then
                local threshold = HealStateConfig.GetThreshold(slot)
                -- counted within the heal's own reach: a group heal lands on whoever is standing
                -- with us, so the member who wandered off is not somebody this cast is going to help
                -- and is not a reason to spend it. `Range` already answers with AERange for a spell
                -- that carries its reach there, which every group heal does
                local reach = action:Subject():Range()
                if countAtOrBelow(threshold, reach) >= HealStateConfig.GetGroupMin(slot) then
                    if readySlotAction(slot, HealState.CastRequest()) ~= nil then
                        return {
                            action = action, slot = slot, targetId = nil, forId = nil,
                            name = "the group", threshold = threshold
                        }
                    end
                end
            end
        end
    end
    return nil
end

---The first slot that suits this person, in the order they are configured.
---@param candidate HealCandidate
---@param ignoreThreshold? boolean for an ordered heal, which is about doing as it is told
---@return HealPick? pick
local function chooseFor(candidate, ignoreThreshold)
    -- the reserve is held to at every health but the one it was being kept for
    local sparing = candidate.pct > HealStateConfig.GetEmergencyPct()

    for _, slot in ipairs(HealStateConfig.GetActions()) do
        local threshold = HealStateConfig.GetThreshold(slot)
        -- judged rather than read: the head start is exactly the claim that this person needs a
        -- heal sooner than their number says, and a threshold is where that claim has to land
        local covers = ignoreThreshold or candidate.urgency <= threshold

        -- the health first, and the action only for a slot that passes it: resolving one is a walk
        -- through the spellbook, and this runs per slot per person every pass
        if covers then
            local action = Action.GetActionType(slot)
            local aim = aimOfAction(action)

            -- a group heal is chosen for the group, never for one person
            if aim ~= nil and aim ~= aims.group and appliesTo(slot, aim, candidate) then
                -- a heal that aims itself is cast at nobody: EQ puts a self heal on us and a pet
                -- heal on our pet with nothing targeted, and targeting for one of those would drop
                -- whatever we were looking at to no purpose
                local targetId = aim == aims.single and candidate.id or nil

                -- **this heal, on this person, recently enough that casting it again is not the
                -- move** -- and only this one. The slots under it are untouched, which is what
                -- turns a list that was only ever a priority order into something that also
                -- degrades: the big heal goes on its own clock and the small one carries on.
                --
                -- Waived for somebody in real trouble, exactly as the settle window is and for
                -- the same reason: chain healing a tank at 20% with the one heal big enough to
                -- matter is the point of a healer, and a gap held for pacing is the last thing
                -- that should be standing between them and it.
                local key = slotKey(candidate.id, action)
                local heldUntil = key ~= nil and HealState._.slotHeldUntil[key] or nil
                local held = sparing and heldUntil ~= nil and Time.current_time() < heldUntil

                if not held and readySlotAction(slot, HealState.CastRequest(targetId), sparing) ~= nil then
                    -- A heal over time that is still ticking is not a heal that needs casting: the
                    -- healing it is worth is already on its way, and putting a second one up would
                    -- overwrite the first with itself and pay for it twice. **Not** waived for an
                    -- emergency, unlike everything else here -- a second one would not land any
                    -- faster, so there is nothing to waive it *for*.
                    --
                    -- Asked last because it is the one question that costs a walk of the spellbook,
                    -- and by here the slot has already answered every cheaper one.
                    if not hotIsRunning(candidate, action, action:Subject():DurationMs()) then
                        return {
                            action = action,
                            slot = slot,
                            targetId = targetId,
                            forId = candidate.id,
                            name = candidate.name,
                            -- **what "they no longer need this" means for this heal, and it has to
                            -- be a bar this heal could actually be chosen against.** The slot's
                            -- threshold on its own is not: a heal is chosen on *judged* health, and
                            -- a tank holding aggro is judged a head start below what they are
                            -- reading, so a 70% slot picks them at 82% and then `reasonToAbandon`
                            -- reads the same 82% back against 70 plus the abort margin and calls it
                            -- off -- and the next pass, reading exactly the same world, picks it
                            -- again. A cast and a cancellation per frame for as long as they hold
                            -- aggro in that band, which starves the cure and the rez under it and
                            -- is the loop this line exists to close.
                            --
                            -- So the health they were actually at when this was chosen, whenever
                            -- that is the higher number. It is what an order has always recorded,
                            -- for a version of the same reason: what chose the heal is what "back
                            -- up again" has to be measured from, whether that was somebody asking
                            -- or the head start.
                            threshold = math.max(threshold, candidate.pct)
                        }
                    end
                end
            end
        end
    end
    return nil
end

---What to heal, and with what, right now.
---@param candidates table this pass's reading of who needs what
---@return HealPick? pick
local function choosePick(candidates)
    if #candidates < 1 then return nil end

    -- An order outranks the state's own judgment, which is the point of being able to give one:
    -- the tank knows they are about to pull, and we do not.
    local order = HealState._.order
    if order ~= nil then
        if Time.current_time() > order.expiresMs then
            print("(healnow) Too late to heal " .. order.name .. "; dropping the request")
            HealState._.order = nil
        else
            local candidate = findCandidate(order.id)
            if candidate == nil then
                -- not someone we watch (out of the group, or out of the zone): heal them anyway
                -- if they are here, since we were asked to
                local spawn = mq.TLO.Spawn("id " .. tostring(order.id))
                if spawn.ID() ~= nil and not spawn.Dead() then
                    local pct = Status.HealthPct(spawn) or 100
                    candidate = {
                        id = order.id,
                        name = spawn.CleanName() or order.name,
                        pct = pct,
                        -- the reading, unjudged. An order has already settled who needs a heal, so
                        -- there is nothing left for a head start to argue about -- and carrying one
                        -- in here would only be able to make the heal chosen for them wrong
                        urgency = pct,
                        isSelf = false, isTank = false, isPet = false,
                        isHolding = false, isXTarget = false,
                        class = spawn.Class.ShortName(),
                        distance = tonumber(spawn.Distance3D()) or tonumber(spawn.Distance()) or 0
                    }
                end
            end

            if candidate ~= nil then
                if candidate.pct <= 0 then
                    -- the same reading `addCandidate` refuses: a spawn at nothing is on its way to
                    -- being a corpse whatever `Dead()` says, and an order is not a reason to spend
                    -- the group's healer casting at one
                    print("(healnow) " .. candidate.name .. " is past healing")
                    HealState._.order = nil
                elseif candidate.pct >= 100 then
                    print("(healnow) " .. candidate.name .. " is already at full health")
                    HealState._.order = nil
                else
                    -- thresholds are how this state decides *for itself* who needs healing. An
                    -- order has already decided that, so the slots are read only for which heal
                    -- suits them -- scope and the fight window still apply, since those say which
                    -- heal is the right one rather than whether anybody needs one; the health the
                    -- slot was written for does not.
                    local pick = chooseFor(candidate, true)
                    if pick ~= nil then
                        HealState._.order = nil
                        return pick
                    end
                    -- nothing ready yet: keep the order until it times out
                end
            else
                print("(healnow) Nothing here with id " .. tostring(order.id))
                HealState._.order = nil
            end
        end
    end

    -- asked of the whole group rather than of whoever sorts first: the order is by the judged
    -- reading now, so the person at the top of the list is not necessarily the one on the lowest
    -- health, and "is anybody dying" has to be asked of everybody to be answered
    if not anyoneInTrouble(candidates) then
        local groupPick = chooseGroupHeal()
        if groupPick ~= nil then return groupPick end
    end

    for _, candidate in ipairs(candidates) do
        if not isHeldOff(candidate) and not isSettling(candidate) and not isCalledByAnother(candidate) then
            local pick = chooseFor(candidate)
            if pick ~= nil then return pick end
        end
    end

    return nil
end

---------------- Curing --------------------

---Why answering cure requests is not something this character should be doing right now, if it is
---not.
---
---Read from the world every pass rather than latched, like everything else here: a fight starting
---is what switches curing off for a character set to stay out of them, and it has to switch off on
---the pass the fight starts rather than the next time somebody asks.
---
---A reason rather than a boolean because **this is the gate that looks like a broken healer**. The
---shipped default is out of combat only, and a DoT worth curing almost always lands *in* a fight --
---so the ordinary first experience of curing is a cleric that hears every request, queues every
---one, and casts nothing, saying nothing about why. `/cheal` and the state's own status line both
---quote this now.
---@return string|nil reason nil when cures are being answered
local function reasonNotCuring()
    if not HealStateConfig.IsCuring() then return "switched off on the Heal State page" end
    if Combat.IsEngaged() and not HealStateConfig.GetCureInCombat() then
        return "in a fight, and this is set to cure out of combat only"
    end
    return nil
end

---@return boolean isCuring
local function isCuring()
    return reasonNotCuring() == nil
end

---Is somebody in real trouble that this state would actually heal?
---
---The guard that curing is held to, and it deliberately asks the second half of that question as
---well. "Somebody is below the emergency mark" on its own is not a reason to leave an affliction
---alone: they may be settling, held off after a refusal, or scoped to no configured slot at all --
---and below the emergency mark is exactly where people *stay*, because that is where a rez leaves
---them. Curing would then be blocked forever by somebody nothing was ever going to be cast at.
---**Every candidate is asked**, for the reason `anyoneInTrouble` above asks all of them: the sort
---puts the emergency band first, so a walk that stopped at the first person above the mark would be
---right today and silently wrong the day the ordering is touched again. Cheap enough not to trade.
---@param candidates table this pass's reading of who needs what
---@return boolean isPending
local function emergencyPending(candidates)
    local emergency = HealStateConfig.GetEmergencyPct()

    for _, candidate in ipairs(candidates) do
        if candidate.pct <= emergency and wouldChoose(candidate) then return true end
    end

    return false
end

---@class CurePick
---@field request CureRequest
---@field targetId number|nil what the cast should target; nil for a cure that aims itself
---@field name string who is being cured, for status output

---The first queued cure this character can actually cast right now.
---
---The whole queue is walked rather than only its head, which is where this differs from how the
---buff state answers its requests. A cure is aimed at a person: the one at the front may be out of
---range or behind a wall while the one behind them is standing right here, and holding everybody
---up for a name that cannot be reached would be a healer doing nothing while somebody it *can*
---reach asks again every twenty seconds. Order is still the rule -- it is the first that can be
---cast, not the best -- so a reachable queue is answered oldest first.
---@return CurePick? pick
local function chooseCure()
    if not isCuring() then return nil end

    for _, request in ipairs(Curing.GetRequests()) do
        if Curing.IsActionable(request) then
            -- a cure that aims itself is cast at nobody: EQ puts a group cure on the group and a
            -- self cure on us with nothing targeted, and targeting for one of those would drop
            -- whatever we were looking at to no purpose
            local targetId = request.needsTarget and request.id or nil
            if request.action:IsReady(HealState.CastRequest(targetId)) then
                return { request = request, targetId = targetId, name = request.name }
            end
        end
    end

    return nil
end

---Start the cure this pass decided on.
---@param pick CurePick
---@return boolean isBusy
local function startCure(pick)
    local request = pick.request
    local castId, refused = Casting.Cast(request.action:Subject(), HealState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Cure of [" .. pick.name .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Curing " .. request.typeKey .. " on [" .. pick.name .. "] with [" ..
        request.action:Name() .. "]")
    HealState._.castId = castId
    -- the one field that says which of this state's two jobs the cast in flight belongs to
    HealState._.cureRequest = request
    return true
end

---Is the cure in the air still worth finishing?
---@param candidates table
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandonCure(candidates)
    local request = HealState._.cureRequest
    if request == nil then return nil end

    if not isCuring() then return "curing is off now" end

    if not request.isSelf then
        local spawn = mq.TLO.Spawn("id " .. tostring(request.id))
        if spawn.ID() == nil then return "they are gone" end
        if spawn.Dead() then return "they died" end
    end

    -- the guard again, now that the cast is committed: somebody who has dropped into real trouble
    -- since it started is worth throwing a cure away for, exactly as they are worth throwing away
    -- a heal aimed at the wrong person
    if emergencyPending(candidates) then return "somebody needs healing" end

    return nil
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordCureFinished(status, outcome, reason)
    local request = HealState._.cureRequest or {}
    local spell = request.action ~= nil and request.action:Name() or "a cure"

    if status == Casting.status.succeeded then
        HealState._.lastCureResult = spell .. " on " .. tostring(request.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        -- **the request stays queued.** A cure strips a fixed number of counters and an affliction
        -- can carry more than one cast's worth, so a cure that went off is not a job that is done
        -- -- what finishes it is the counters actually being gone, which `cabby.curing` reads back
        -- off them once the client has caught up. Nothing here writes down that we cured somebody,
        -- because the world says it better.
        Curing.NoteCast(request)
    else
        if not HealState._.calledOff then
            HealState._.lastCureResult = spell .. " on " .. tostring(request.name) ..
                " failed: " .. tostring(reason)
        end
        -- a cure we called off ourselves costs nothing but its place in the queue for a moment: it
        -- was dropped because somebody was dying, and coming back to it afterwards is right
        Curing.NoteFailure(request, HealState._.calledOff and "called off" or reason)
    end

    HealState._.calledOff = false

    DebugLog("Cure finished: " .. tostring(HealState._.lastCureResult))
    HealState.Reset()
end

---------------- The state itself --------------------

function HealState.Reset()
    HealState._.castId = nil
    HealState._.healTarget = nil
    HealState._.healSlot = nil
    HealState._.healThreshold = nil
    HealState._.cureRequest = nil
    HealState._.rezPick = nil
end

---@return string description of what this state is doing, for /cheal and the menu
function HealState.Describe()
    if HealState._.castId ~= nil then
        local request = HealState._.cureRequest
        if request ~= nil then
            return "curing " .. request.typeKey .. " on " .. request.name ..
                " with " .. request.action:Name()
        end
        local rezPick = HealState._.rezPick
        if rezPick ~= nil then
            return "rezzing " .. rezPick.name .. " with " .. tostring(rezPick.spell)
        end
        if HealState._.healTarget ~= nil then
            return "healing " .. HealState._.healTarget.name .. " with " .. tostring(HealState._.healTarget.spell)
        end
    end

    local waiting = #Curing.GetRequests()
    if waiting > 0 then
        -- said even when curing is off, which is the whole point: a queue that is filling up while
        -- nothing is cast is exactly the state somebody is staring at wondering why their healer
        -- has stopped answering them
        local notCuring = reasonNotCuring()
        return "watching, with " .. tostring(waiting) ..
            (waiting == 1 and " cure" or " cures") .. " waiting" ..
            (notCuring ~= nil and (" -- not curing: " .. notCuring) or "")
    end

    return "watching"
end

---@return string|nil result how the last heal went
function HealState.GetLastResult()
    return HealState._.lastResult
end

---@return string|nil result how the last cure went
function HealState.GetLastCureResult()
    return HealState._.lastCureResult
end

---@return string|nil result how the last rez went
function HealState.GetLastRezResult()
    return HealState._.lastRezResult
end

---@return table requests the cure requests outstanding, oldest first
function HealState.GetCureRequests()
    return Curing.GetRequests()
end

---@return table candidates last read health of everyone this state watches
function HealState.GetCandidates()
    return HealState._.candidates
end

---Which scopes a slot holding this may be given.
---
---A spell that can only land on one kind of person has already answered the question scope asks,
---so there is exactly one answer to offer -- and offering the others would be offering settings
---that do nothing, which is how a pet heal comes to be scoped "the tank" and its owner to be
---waiting for a heal that was never going to be chosen for one.
---@param aim string one of `aims`
---@return table scopes set of scope values, empty when there is nothing to scope at all
local function scopesFor(aim)
    if aim == aims.self then return { [HealStateConfig.scopes.Self.value] = true } end
    if aim == aims.pet then return { [HealStateConfig.scopes.Pet.value] = true } end
    -- a group heal lands on whoever is standing there; there is no choosing to be done
    if aim == aims.group then return {} end
    -- and a rez is not scoped to anybody living at all
    if aim == aims.corpse then return {} end

    local all = {}
    for _, known in pairs(HealStateConfig.scopes) do all[known.value] = true end
    return all
end

---@class HealSlotFacts
---@field aim string one of `aims`
---@field aimText string what that means, in words
---@field scopes table set of scope values this slot may be given; one entry means it is decided
---@field isGroup boolean whether this slot is the one cast that covers everybody
---@field problem string|nil why this slot will never fire, when it will not

---What a configured slot amounts to, for whatever is showing it to a user. Everything here is
---read off the spell rather than configured, so it is also the answer to "why is this one not
---firing" -- which is otherwise a silent puzzle.
---@param slot Action
---@return HealSlotFacts facts
function HealState.DescribeSlot(slot)
    local facts = {
        aim = aims.single,
        aimText = "one at a time",
        scopes = scopesFor(aims.single),
        isGroup = false,
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
        facts.problem = "only spells, clickies and AAs can heal"
        return facts
    end

    facts.aim = aimOf(action:Subject())
    facts.aimText = ({
        [aims.self] = "on me",
        [aims.pet] = "on my pet",
        [aims.group] = "on the group, in one cast",
        [aims.single] = "one at a time",
        [aims.corpse] = "on a corpse"
    })[facts.aim]
    facts.scopes = scopesFor(facts.aim)
    facts.isGroup = facts.aim == aims.group

    if facts.aim == aims.pet and not HealStateConfig.GetHealPets() then
        facts.problem = "'Heal my pet' is off, so this never fires"
    end

    -- said rather than silently ignored, because a rez in a heal slot is a reasonable thing to
    -- have tried: it is a beneficial spell this character casts on group-mates, and the page is
    -- where its heals go. It is refused because it lands on nobody alive -- rezzing chooses its own
    -- spell off the same data the Rezzes tab shows, and its switch is the Rezzing setting above
    if facts.aim == aims.corpse then
        facts.problem = "this is a rez -- see the Rezzing setting, not a heal slot"
    end

    return facts
end

---------------- Heal calls --------------------

---Where a heal call goes when nothing has been configured to speak on.
---
---The same shape the tank's defend report has, and for the same reason: this is machine-to-machine
---traffic between healers, not something the group reads. bc reaches every connected character
---without scrolling anybody's group chat; `/speak onheal <channel>` sends it somewhere else.
local fallbackHealCallSpeak = Speak.new({ Speak.channelTypes.bc.name })

---@return Speak speak where a heal call goes
local function healCallSpeak()
    local speak = Commands.GetCommandSpeak(HealState.eventIds.healCall)
    if #speak:GetActiveSpeakChannels() > 0 then return speak end
    ---@diagnostic disable-next-line: return-type-mismatch
    return fallbackHealCallSpeak
end

---Say who this healer has just started on.
---
---**The one thing about healing that no client can work out for itself.** Two healers watching the
---same group see the same health and reach the same answer, so they cast the same heal at the same
---person and one of the two is wasted -- every time, not occasionally. Nothing in the world says
---"somebody else has this"; the only way for it to be known is for it to be said.
---
---Silent for a group heal, which is for everybody and displaces nobody, and silent unless the
---group has switched calls on -- see `HealStateConfig.GetHealCalls`.
---@param id number|nil who the heal is for; nil for a heal that is for the group
---@param name string for the log
local function callHeal(id, name)
    if id == nil or not HealStateConfig.GetHealCalls() then return end

    DebugLog("Calling the heal on [" .. name .. "] (" .. tostring(id) .. ")")
    healCallSpeak():speak(HealState.eventIds.healCall .. " " .. tostring(id))
end

---Leave this pick alone for a moment, because the client would not take it.
---
---Keyed by whoever the heal was for, so it is one person being held and not the list: the slots
---under it stay free, and everybody else is considered on the very next pass. A group heal is held
---by the heal instead, having nobody in particular to be held against.
---@param pick HealPick
local function noteRefusal(pick)
    local until_ = Time.current_time() + retryAfterFailureMs

    if pick.forId ~= nil then
        HealState._.tryAgainAt[pick.forId] = until_
        return
    end

    HealState._.slotHeldUntil[groupSlotKey(pick.action)] = until_
end

---Start the heal this pass decided on.
---@param pick HealPick
---@return boolean isBusy
local function startHeal(pick)
    local castId, refused = Casting.Cast(pick.action:Subject(), HealState.CastRequest(pick.targetId))

    if castId == nil then
        DebugLog("Heal of [" .. pick.name .. "] was refused: " .. tostring(refused))
        -- **Written down, not only logged** -- the same thing a refused rez does a few hundred
        -- lines below, and the same debounce `recordFinished` writes for a cast that started and
        -- then failed. A refusal costs nothing to make, so without this the very next pass reads
        -- the same world, makes the same pick, and is refused again, at whatever rate the loop
        -- runs.
        --
        -- What makes that worse than a wasted frame is that the pass is *over*: `Go` returns
        -- whatever this says, so nobody sorted below this pick is reached at all. One person the
        -- client will not take a heal on -- out of range for the spell actually chosen, round a
        -- corner, a gem that went grey between the check and the cast -- is therefore enough to
        -- starve the entire group, and it looks from outside exactly like a healer that has
        -- stopped: several people hurt, nothing being cast, and nothing said about why.
        noteRefusal(pick)
        return false
    end

    -- the bar it will be judged against is said when the heal starts, because the two log lines
    -- either side of it are what a loop looks like: chosen against a number and then called off
    -- against the same one
    DebugLog("Healing [" .. pick.name .. "] with [" .. pick.action:Name() .. "] (against " ..
        tostring(pick.threshold) .. "%)")
    HealState._.castId = castId
    -- who it is for, not what the cast targets: a pet heal aims itself, and the settle window and
    -- the abandon check are both about the person whose health this was chosen for
    HealState._.healTarget = {
        id = pick.forId,
        name = pick.name,
        spell = pick.action:Name(),
        -- carried from the pick rather than re-read when the cast lands: the two windows it
        -- feeds are about the heal that was *chosen*, and by the time it finishes the slot has
        -- been forgotten and the spell would have to be resolved a second time to ask
        durationMs = pick.action:Subject():DurationMs(),
        castTimeMs = pick.action:Subject():CastTimeMs()
    }
    HealState._.healSlot = pick.slot
    HealState._.healThreshold = pick.threshold

    -- **said at the start, not at the end.** The whole value of the call is that it arrives while
    -- the cast is still going out, which is the window another healer would otherwise spend
    -- starting the same heal on the same person
    callHeal(pick.forId, pick.name)
    return true
end

---Is the heal already in the air still the right heal?
---
---Read against the same reading of the group the rest of the pass uses, and deliberately not
---"would I choose this again": a heal that is merely no longer the *best* one is still a good
---one, and dropping it every time somebody else takes a scratch would mean never landing
---anything. What ends a heal is it being *wrong* -- the target does not need it, or somebody
---else needs one more than they do.
---
---**A slot's fight window is deliberately not re-asked here**, which is the same rule and worth
---naming because the neighbouring jobs look like they disagree. It says which heal to *choose*; a
---pull landing mid-cast does not make the heal already on its way the wrong one for the person it
---is aimed at, who is exactly as hurt either way, and calling it off would spend the mana and the
---seconds and leave them unhealed. Curing and rezzing do re-ask theirs (`reasonToAbandonCure`,
---`reasonToAbandonRez`) because theirs is a whole job being switched off underneath them, not a
---choice between heals.
---@param candidates table
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandon(candidates)
    local target = HealState._.healTarget
    if target == nil or target.id == nil then return nil end

    local spawn = mq.TLO.Spawn("id " .. tostring(target.id))
    if spawn.ID() == nil then return "they are gone" end
    if spawn.Dead() then return "they died" end

    local pct = Status.HealthPct(spawn)
    if pct == nil then return nil end

    -- somebody else healed them, or the mob switched targets
    if pct > (HealState._.healThreshold or 100) + abortMarginPct then
        -- the bar it is being judged against is said as well as the reading: this is the one
        -- abandon reason that can disagree with the rule that *chose* the heal, and the two
        -- numbers side by side are what tells that apart from a heal landing from elsewhere
        return "they are back up to " .. tostring(math.floor(pct)) .. "% (chosen against " ..
            tostring(HealState._.healThreshold) .. "%)"
    end

    -- Someone else is in real trouble, this heal is not for them, and -- the part that has to be
    -- asked -- we would actually heal them if we dropped this. Without that last clause the cast
    -- is thrown away for somebody nothing is going to be cast at, and the next pass starts the
    -- same heal on the same target to be thrown away again.
    local emergency = HealStateConfig.GetEmergencyPct()
    if pct > emergency then
        for _, candidate in ipairs(candidates) do
            if candidate.id ~= target.id and candidate.pct <= emergency and wouldChoose(candidate) then
                -- their reading too: the whole weight of this reason is that somebody is in
                -- trouble, and a name on its own cannot be checked against what happens next
                return candidate.name .. " needs it more (" .. tostring(math.floor(candidate.pct)) .. "%)"
            end
        end
    end

    return nil
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordFinished(status, outcome, reason)
    local target = HealState._.healTarget or {}

    if status == Casting.status.succeeded then
        HealState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        if target.id ~= nil then
            local now = Time.current_time()
            HealState._.settleUntil[target.id] = now + healSettleMs
            HealState._.tryAgainAt[target.id] = nil

            -- **this heal is on its own clock now, and only this one.** Scaled by how long the
            -- cast took, because that is the only thing said here about how big it was: a six
            -- second heal is the one worth not casting twice, and an instant clicky is barely
            -- worth holding at all. The slots under it stay free the whole time
            local key = tostring(target.id) .. "/" .. tostring(target.spell)
            HealState._.slotHeldUntil[key] = now + slotReuseMs + (tonumber(target.castTimeMs) or 0)

            -- and if it keeps working after it lands, remember until when -- the plain end of it,
            -- with no margin taken off. The margin belongs at the reading, where it can be applied
            -- to the client's answer about this heal as well as to ours
            local durationMs = tonumber(target.durationMs) or 0
            if durationMs > 0 then
                HealState._.hotUntil[key] = now + durationMs
            end
        end
    elseif not HealState._.calledOff then
        -- a heal we called off already said why; anything else is the client refusing it
        HealState._.lastResult = tostring(target.spell) .. " on " .. tostring(target.name) ..
            " failed: " .. tostring(reason)
        -- and a refusal is worth remembering for a moment. Without this the same target is chosen
        -- again on the very next pass, refused again, and the whole thing runs at loop speed --
        -- which is what a log full of a cast and a cancellation per frame actually is. A heal we
        -- called off ourselves is left out on purpose: that one was dropped because somebody else
        -- needed it more, and coming straight back to them is the right thing to do.
        if target.id ~= nil then
            HealState._.tryAgainAt[target.id] = Time.current_time() + retryAfterFailureMs
        end
    end
    HealState._.calledOff = false

    DebugLog("Heal finished: " .. tostring(HealState._.lastResult))
    HealState.Reset()
end

---------------- Rezzing --------------------

---@class HealRezPick
---@field corpseId number what the cast is aimed at
---@field name string who the corpse belongs to, for status output
---@field action CastAction
---@field expPct number what this rez hands back
---@field beatsEmergency boolean whether it is worth stepping in front of somebody in trouble

---The corpse to rez this pass, and with what.
---
---Both halves come from `cabby.rezzing`: one rez is chosen for the pass (the most experience that
---fits the time this moment allows), and the corpses are handed back in the order they are worth
---doing -- whoever asked, then the tank, then whoever is nearest. All this adds is the question
---only the casting service can answer, which is whether the rez can actually be fired at that
---corpse from here: range and line of sight are measured against the corpse rather than against
---whatever we happen to be looking at, so a corpse behind a wall is stepped over rather than
---started and refused.
---@param candidates table this pass's reading of who needs what
---@return HealRezPick? pick
local function chooseRez(candidates)
    -- the cheap gate first: it is what keeps the spawn searches below off the frames of every
    -- character that cannot rez, has it switched off, or is in a fight it stays out of
    if Rezzing.ReasonNotRezzing() ~= nil then return nil end

    local rez = Rezzing.ChooseRez()
    if rez == nil then return nil end

    for _, target in ipairs(Rezzing.GetTargets(rez, emergencyPending(candidates))) do
        if rez.action:IsReady(HealState.CastRequest(target.id)) then
            return {
                corpseId = target.id,
                name = target.name,
                action = rez.action,
                expPct = rez.expPct,
                beatsEmergency = target.beatsEmergency
            }
        end
    end

    return nil
end

---Start the rez this pass decided on.
---@param pick HealRezPick
---@return boolean isBusy
local function startRez(pick)
    local castId, refused = Casting.Cast(pick.action:Subject(), HealState.CastRequest(pick.corpseId))

    if castId == nil then
        DebugLog("Rez of [" .. pick.name .. "] was refused: " .. tostring(refused))
        -- recorded rather than only logged, and it is what stops a corpse the client will not take
        -- a rez on from being asked again on the very next pass and every pass after it
        Rezzing.NoteFailure(pick.corpseId, refused)
        return false
    end

    DebugLog("Rezzing [" .. pick.name .. "] with [" .. pick.action:Name() .. "]")
    HealState._.castId = castId
    HealState._.rezPick = {
        corpseId = pick.corpseId,
        name = pick.name,
        spell = pick.action:Name(),
        expPct = pick.expPct,
        beatsEmergency = pick.beatsEmergency
    }
    return true
end

---Is the rez in the air still worth finishing?
---@param candidates table
---@return string|nil reason to call it off, nil to let it finish
local function reasonToAbandonRez(candidates)
    local pick = HealState._.rezPick
    if pick == nil then return nil end

    -- the switch, and the fight: a rez started out of combat and set to stay out of them is exactly
    -- the cast that has to go when something pulls, which is the pass this notices
    local notRezzing = Rezzing.ReasonNotRezzing()
    if notRezzing ~= nil then return notRezzing end

    if not Rezzing.CorpseIsThere(pick.corpseId) then return "the corpse is gone" end

    -- the same guard the pick was made under, asked again now that the cast is committed. The tank's
    -- exemption is carried on the pick rather than recomputed, so a rez that was allowed to start in
    -- front of an emergency is not thrown away by the next pass for the very reason it was allowed
    if not pick.beatsEmergency and emergencyPending(candidates) then
        return "somebody needs healing"
    end

    return nil
end

---@param status string
---@param outcome string|nil
---@param reason string|nil
local function recordRezFinished(status, outcome, reason)
    local pick = HealState._.rezPick or {}
    local spell = pick.spell or "a rez"

    if status == Casting.status.succeeded then
        HealState._.lastRezResult = spell .. " on " .. tostring(pick.name) ..
            (outcome ~= Casting.outcomes.succeeded and (" (" .. tostring(reason) .. ")") or "")
        -- **the corpse is not finished with, it is answered.** A rez is an offer and nothing comes
        -- back to say it was taken -- the corpse stays lying there either way -- so what is written
        -- down is that one is outstanding. `cabby.rezzing` owns how long that stands for
        Rezzing.NoteCast(pick.corpseId, pick.name)
    else
        if not HealState._.calledOff then
            HealState._.lastRezResult = spell .. " on " .. tostring(pick.name) ..
                " failed: " .. tostring(reason)
        end
        Rezzing.NoteFailure(pick.corpseId, HealState._.calledOff and "called off" or reason)
    end

    HealState._.calledOff = false

    DebugLog("Rez finished: " .. tostring(HealState._.lastRezResult))
    HealState.Reset()
end

---------------- Orders --------------------

---@param id number
---@param name string
local function orderHeal(id, name)
    HealState._.order = { id = id, name = name, expiresMs = Time.current_time() + orderTimeoutMs }
    DebugLog("Heal ordered for [" .. name .. "] (" .. tostring(id) .. ")")
end

---Stop what this state is doing: whatever cast is in the air, and any order waiting for a turn.
---
---All three jobs, not only the healing. It is what `healing off` and `/cheal off` mean, and the
---cast in flight is the casting service's now -- leaving it would go on holding the whole chain
---back for a job this character was just told to stop.
function HealState.CallOff()
    HealState._.order = nil
    Rezzing.CallOff()
    if HealState._.castId ~= nil then
        Casting.StopFor(HealState.key)
    end
end

---Call off the heal, and only the heal: the order waiting for a turn, and the cast in the air when
---that is what it is. `healnow off` is about the heal it named, not about a cure or a rez that
---happens to be going out.
function HealState.CallOffHeal()
    HealState._.order = nil
    if HealState._.castId ~= nil and HealState._.healTarget ~= nil then
        Casting.StopFor(HealState.key)
    end
end

---Call off the rez, and only the rez: the standing order, and the cast in the air when that is what
---it is. A heal or a cure going out is not what `reznow off` was about.
function HealState.CallOffRez()
    Rezzing.CallOff()
    if HealState._.castId ~= nil and HealState._.rezPick ~= nil then
        Casting.StopFor(HealState.key)
    end
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function HealState.Init()
    if HealState._.isInit then return end

    -- our own config, so a class that does not register this state has no heal slots written
    HealStateConfig.Init()

    Menu.RegisterState(HealState)

    local healDocs = ChelpDocs.new(function() return {
        "(healnow <id>) Tells listener(s) to heal the spawn with <id> now",
        " -- Usage: healnow <spawn id>",
        " -- Usage (call off the heal in progress): healnow off",
        " -- The heal used is the first configured slot that suits them; if they are already",
        "    healthy enough that none of them applies, nothing is cast.",
        " -- An order that cannot be acted on within ten seconds is dropped rather than",
        "    landing long after it mattered."
    } end )
    local function event_Heal(_, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.heal):HasPermission(speaker) then
            DebugLog("Ignoring heal speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(healnow) No one given. Usage: healnow <spawn id>, or `healnow off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            HealState.CallOffHeal()
            return
        end

        local targetId = tonumber(args[1])
        if targetId == nil then
            print("(healnow) [" .. args[1] .. "] is not a spawn id. Usage: healnow <spawn id>")
            return
        end

        local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
        if spawn.ID() == nil then
            print("(healnow) Nothing here with id [" .. tostring(targetId) .. "]")
            return
        end

        orderHeal(targetId, spawn.CleanName() or tostring(targetId))
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.heal, event_Heal, healDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                { label = "Myself", args = "${Me.ID}", name = "Heal me" },
                { label = "Call off the heal", args = "off", name = "Stop healing" }
            } end
        }))

    local healMeDocs = ChelpDocs.new(function() return {
        "(healme) Tells listener(s) to heal whoever said it, now",
        " -- The button a tank binds: it needs no spawn id, since the healer works out who",
        "    spoke. Nothing to say to yourself, so the local channel will not take it."
    } end )
    local function event_HealMe(_, speaker)
        if not Commands.GetCommandOwners(HealState.eventIds.healMe):HasPermission(speaker) then
            DebugLog("Ignoring healme speaker [" .. speaker .. "]")
            return
        end

        local spawn = mq.TLO.Spawn("pc radius 300 " .. speaker)
        if spawn.ID() == nil then
            Commands.GetCommandSpeak(HealState.eventIds.healMe):speak("Cannot see [" .. speaker .. "] to heal them")
            return
        end

        orderHeal(spawn.ID(), speaker)
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.healMe, event_HealMe, healMeDocs)
        :ActsOnSpeaker())

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healing,
        summary = "Turns healing on or off for listener(s)",
        about = {
            "This whole state, so it is the switch for curing and rezzing as well -- both of those",
            "are the same character choosing what to spend a gem on.",
            "Off calls off whatever is in progress as well as stopping new ones."
        },
        get = HealStateConfig.IsEnabled,
        set = HealState.SetEnabled
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healGroup,
        summary = "Turns healing the rest of the group on or off",
        about = {
            "Whether group members are somebody this character heals at all.",
            "Off watches nobody but this character (and its pet, if that is on), so a",
            "group-mate at 10% is left to somebody else.",
            "Not about group heal spells: one of those is cast because enough of the people",
            "being watched are hurt, so this changes what is counted, not whether it is used."
        },
        get = HealStateConfig.GetHealGroup,
        set = HealStateConfig.SetHealGroup
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healPets,
        summary = "Turns healing this character's pet on or off",
        about = { "Off by default: a pet is cheaper to summon than the mana spent keeping it up." },
        get = HealStateConfig.GetHealPets,
        set = HealStateConfig.SetHealPets
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healXTarget,
        summary = "Turns watching extended target friendlies on or off",
        about = {
            "The people the group window cannot answer for: a raid-mate, a boxed character",
            "grouped elsewhere, somebody's second-account tank.",
            "Anything on the extended target window that reads as a player or a pet is watched",
            "and can be chosen for a heal; mobs fighting us are skipped, being nobody's heal.",
            "Off by default -- it widens who this character is responsible for, and the mana",
            "comes out of the same bar the group is drawing on."
        },
        get = HealStateConfig.GetHealXTarget,
        set = HealStateConfig.SetHealXTarget
    })

    ToggleCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healCalls,
        summary = "Turns calling and hearing heals on or off",
        about = {
            "Two healers watching the same group see the same health and reach the same answer,",
            "so they cast the same heal at the same person and one of the two is wasted. Nothing",
            "in the world says somebody else has it; the only way to know is to be told.",
            "On, this character says who it has started on and stands off anybody another healer",
            "has called -- unless they are below the emergency point, where two heals landing is",
            "the answer being right twice.",
            "Off by default: it is a group protocol, so it is worth switching on for the group's",
            "healers together rather than for one of them."
        },
        get = HealStateConfig.GetHealCalls,
        set = HealStateConfig.SetHealCalls
    })

    local healCallDocs = ChelpDocs.new(function() return {
        "(" .. HealState.eventIds.healCall .. " <id>) One healer telling the others who it is on",
        " -- Machine-to-machine: spoken by a cabby healer as its heal goes out, and acted on by",
        "    any healer with " .. HealState.eventIds.healCalls .. " switched on. There is nothing",
        "    to type here by hand.",
        " -- A called target is left to them for a moment rather than forever, and never when they",
        "    are below the emergency point: two heals on somebody dying is not a mistake.",
        " -- Whether this character speaks and hears these at all: see /chelp " ..
            HealState.eventIds.healCalls
    } end )
    local function event_HealCall(_, speaker, args)
        -- The usual ACL, widened by the group for the reason the tank's defend report is: calls
        -- are machine-spoken by whichever healers happen to be grouped with us, and a group
        -- assembled fresh would otherwise need every member added to an owner list before any of
        -- them was listened to. A stranger naming spawn ids still costs nothing -- the worst it
        -- can do is make this character pause on somebody for three seconds.
        if not Commands.GetCommandOwners(HealState.eventIds.healCall):HasPermission(speaker)
            and mq.TLO.Group.Member(speaker).ID() == nil then
            DebugLog("Ignoring heal call speaker [" .. speaker .. "]")
            return
        end

        -- our own call coming back to us through localecho: standing off ourselves would mean
        -- never casting the second heal on anybody
        if speaker == mq.TLO.Me.CleanName() then return end

        if not HealStateConfig.GetHealCalls() then return end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        local id = tonumber(args[1])
        if id == nil or id < 1 then return end

        DebugLog("[" .. speaker .. "] is healing " .. tostring(id))
        HealState._.calledBy[id] = Time.current_time() + healCallHoldMs
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.healCall, event_HealCall, healCallDocs))

    ---What a person might type for each setting. Three answers to one question, so a switch will
    ---not do -- but the words people reach for are still on/off words, and `curing on` meaning
    ---"cure, out of fights" is the reading that matches how every other switch in cabby behaves
    ---about combat: off until told otherwise.
    local cureWords = {
        ["off"] = HealStateConfig.cureModes.Off.value,
        ["no"] = HealStateConfig.cureModes.Off.value,
        ["none"] = HealStateConfig.cureModes.Off.value,
        ["disabled"] = HealStateConfig.cureModes.Off.value,
        ["on"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["yes"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["out"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["outofcombat"] = HealStateConfig.cureModes.OutOfCombat.value,
        ["combat"] = HealStateConfig.cureModes.Always.value,
        ["incombat"] = HealStateConfig.cureModes.Always.value,
        ["battle"] = HealStateConfig.cureModes.Always.value,
        ["always"] = HealStateConfig.cureModes.Always.value
    }

    local curingDocs = ChelpDocs.new(function() return {
        "(curing <off | on | combat>) Sets whether listener(s) answer cure requests, and when",
        " -- Usage: curing off      -- ignore them",
        " -- Usage: curing on       -- cure, but not while fighting",
        " -- Usage: curing combat   -- cure, fights included",
        " -- Usage: curing          -- report what it is set to now",
        " -- Nothing about a cure is configured: whoever needs one names the kind (`cure poison`)",
        "    and the best cure of that kind this character owns answers it. There is no slot list",
        "    to fill in, because the person afflicted is the only one who can see it and has no",
        "    idea what anybody hearing them can cast.",
        " -- Cures are cast ahead of ordinary heals and behind anybody below the emergency point.",
        " -- Asking for a cure is the other half of this and every class does it, whether or not",
        "    it can cure anything: see /chelp callcure",
        " -- Currently: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode())
    } end )
    local function event_Curing(_, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.curing):HasPermission(speaker) then
            DebugLog("Ignoring curing speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("Curing: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode()))
            return
        end

        local mode = cureWords[args[1]:lower()]
        if mode == nil then
            print("(curing) [" .. args[1] .. "] is not a curing setting. Usage: curing <off | on | combat>")
            return
        end

        HealStateConfig.SetCureMode(mode)
        if not HealStateConfig.IsCuring() and HealState._.cureRequest ~= nil then
            -- switched off with one in the air: it is the casting service's now, and it would go
            -- on holding the chain back for a job we were just told to stop
            Casting.StopFor(HealState.key)
        end
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.curing, event_Curing, curingDocs)
        :WithArgs({
            required = true,
            hint = "off, on, or combat",
            default = "on",
            choices = function() return {
                { label = "Do not cure", args = "off", name = "Curing off" },
                { label = "Cure, but not while fighting", args = "on", name = "Curing on" },
                { label = "Cure, fights included", args = "combat", name = "Curing in battle" }
            } end
        }))

    ---The same three answers to one question the cure mode takes, in the same words, because they
    ---are the same question: on means "yes, when it is safe to", and combat is the extra step.
    local rezWords = {
        ["off"] = HealStateConfig.rezModes.Off.value,
        ["no"] = HealStateConfig.rezModes.Off.value,
        ["none"] = HealStateConfig.rezModes.Off.value,
        ["disabled"] = HealStateConfig.rezModes.Off.value,
        ["on"] = HealStateConfig.rezModes.OutOfCombat.value,
        ["yes"] = HealStateConfig.rezModes.OutOfCombat.value,
        ["out"] = HealStateConfig.rezModes.OutOfCombat.value,
        ["outofcombat"] = HealStateConfig.rezModes.OutOfCombat.value,
        ["combat"] = HealStateConfig.rezModes.Always.value,
        ["incombat"] = HealStateConfig.rezModes.Always.value,
        ["battle"] = HealStateConfig.rezModes.Always.value,
        ["always"] = HealStateConfig.rezModes.Always.value
    }

    local rezzingDocs = ChelpDocs.new(function() return {
        "(" .. HealState.eventIds.rezzing .. " <off | on | combat>) Sets whether listener(s) rez" ..
            " the corpses lying around them, and when",
        " -- Usage: " .. HealState.eventIds.rezzing .. " off      -- leave corpses alone",
        " -- Usage: " .. HealState.eventIds.rezzing .. " on       -- rez, but not while fighting",
        " -- Usage: " .. HealState.eventIds.rezzing .. " combat   -- rez in fights too",
        " -- Usage: " .. HealState.eventIds.rezzing .. "          -- report what it is set to now",
        " -- Which rez is used is worked out unless the Heal State page names one: the most",
        "    experience returned out of a fight, the shortest cast in one -- normally an instant AA.",
        " -- Group members' corpses within " .. tostring(Rezzing.GetRadius()) .. " are rezzed on",
        "    their own, in the class order on that page, with the main tank ahead of it. Every class",
        "    is rezzed once the fighting stops; the list says which of them a fight is interrupted",
        "    for. Anybody else asks: see /chelp " .. HealState.eventIds.rezMe,
        " -- Rezzing is the last thing this state does, behind every heal and every cure. The one",
        "    exception is the tank's corpse with a rez that has no cast bar at all.",
        " -- This walks nobody anywhere: get back to the corpses first.",
        " -- Currently: " .. HealStateConfig.GetRezModeDisplay(HealStateConfig.GetRezMode())
    } end )
    local function event_Rezzing(_, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.rezzing):HasPermission(speaker) then
            DebugLog("Ignoring rezzing speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("Rezzing: " .. HealStateConfig.GetRezModeDisplay(HealStateConfig.GetRezMode()))
            return
        end

        local mode = rezWords[args[1]:lower()]
        if mode == nil then
            print("(" .. HealState.eventIds.rezzing .. ") [" .. args[1] ..
                "] is not a rezzing setting. Usage: " .. HealState.eventIds.rezzing ..
                " <off | on | combat>")
            return
        end

        HealStateConfig.SetRezMode(mode)
        if not HealStateConfig.IsRezzing() then
            -- switched off with one in the air: it is the casting service's now, and it would go on
            -- holding the chain back for a job we were just told to stop
            HealState.CallOffRez()
        end
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.rezzing, event_Rezzing, rezzingDocs)
        :WithArgs({
            required = true,
            hint = "off, on, or combat",
            default = "on",
            choices = function() return {
                { label = "Do not rez", args = "off", name = "Rezzing off" },
                { label = "Rez, but not while fighting", args = "on", name = "Rezzing on" },
                { label = "Rez, fights included", args = "combat", name = "Rezzing in battle" }
            } end
        }))

    local rezDocs = ChelpDocs.new(function() return {
        "(" .. HealState.eventIds.rez .. " <who>) Tells listener(s) to rez that character's corpse",
        " -- Usage: " .. HealState.eventIds.rez .. " <spawn id>   -- their corpse, or them",
        " -- Usage: " .. HealState.eventIds.rez .. " <name>",
        " -- Usage (call it off): " .. HealState.eventIds.rez .. " off",
        " -- The *character* is what is remembered, not the corpse: the corpse is often not in",
        "    reach yet when the order is given, so it is looked for every pass until it is.",
        " -- An order reaches somebody who is not in the group, and puts them ahead of everybody",
        "    who is. It does not override the Rezzing setting -- a character with rezzing off, or",
        "    set to stay out of fights, says so rather than taking the order on.",
        " -- Asking again clears whatever this character had already offered that corpse, which is",
        "    the way back from a rez nobody was at the keyboard to accept.",
        " -- An order nobody could act on within a minute is dropped."
    } end )
    local function event_Rez(line, speaker, args)
        if not Commands.GetCommandOwners(HealState.eventIds.rez):HasPermission(speaker) then
            DebugLog("Ignoring " .. HealState.eventIds.rez .. " speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))
        if #args < 1 then
            print("(" .. HealState.eventIds.rez .. ") No one given. Usage: " ..
                HealState.eventIds.rez .. " <spawn id or name>, or `" .. HealState.eventIds.rez ..
                " off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            HealState.CallOffRez()
            return
        end

        -- a spawn id names a corpse or the person it belongs to, and either answers "who"; anything
        -- else is the name itself, which is what a corpse carries and all this ever needs
        local name = args[1]
        local spawnId = tonumber(args[1])
        if spawnId ~= nil then
            name = Rezzing.NameForOrder(spawnId)
            if name == nil then
                Speak.Respond(line, speaker, "Nothing here with id " .. tostring(spawnId))
                return
            end
        end

        local refusal = Rezzing.TakeOrder(name)
        if refusal ~= nil then
            Speak.Respond(line, speaker, refusal)
            return
        end
        print("(" .. HealState.eventIds.rez .. ") Rezzing " .. name .. ", asked by " .. speaker)
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.rez, event_Rez, rezDocs)
        :WithArgs({
            required = true,
            hint = "a spawn id or a name, or off",
            default = "${Target.ID}",
            choices = function() return {
                { label = "Whatever I have targeted", args = "${Target.ID}" },
                { label = "Call off the rez", args = "off", name = "Stop rezzing" }
            } end
        }))

    local rezMeDocs = ChelpDocs.new(function() return {
        "(" .. HealState.eventIds.rezMe .. ") Tells listener(s) to rez whoever said it",
        " -- The button to bind on a character that dies: it needs no spawn id, since the name is",
        "    what a corpse carries and the rezzer works out who spoke. Say it while hovering or",
        "    after running back -- either way it is the corpse on the ground that is rezzed.",
        " -- Nothing to say to yourself, so the local channel will not take it.",
        " -- Group members are rezzed without being asked; this is for everybody else, and for",
        "    asking again when the first offer went unanswered."
    } end )
    local function event_RezMe(line, speaker)
        if not Commands.GetCommandOwners(HealState.eventIds.rezMe):HasPermission(speaker) then
            DebugLog("Ignoring " .. HealState.eventIds.rezMe .. " speaker [" .. speaker .. "]")
            return
        end

        -- no spawn search, unlike `healme`: a rez is aimed at a corpse, and the one thing a corpse
        -- is certain to carry is the name of the person who left it. Looking the speaker up would
        -- fail on exactly the character this is for -- one who released and is standing at a bind
        -- point in another zone while their corpse lies here
        local refusal = Rezzing.TakeOrder(speaker)
        if refusal ~= nil then
            Speak.Respond(line, speaker, refusal)
            return
        end
        print("(" .. HealState.eventIds.rezMe .. ") Rezzing " .. speaker)
    end
    Commands.RegisterCommEvent(Command.new(HealState.eventIds.rezMe, event_RezMe, rezMeDocs)
        :ActsOnSpeaker())

    ActionCommand.Register({
        key = HealState.key,
        phrase = HealState.eventIds.healAction,
        summary = "Switches one of the configured heals on or off",
        where = "Heal State page",
        getActionLists = HealStateConfig.GetActionLists
    })

    local chealDocs = ChelpDocs.new(function() return {
        "(/cheal) Report what the heal state is doing, and who it is watching",
        " -- Usage: /cheal",
        " -- Usage (call off what it is doing): /cheal off",
        " -- Heals, cures and rezzes are all this one state, in that order of precedence, so this",
        "    is the report for all three: what would be cast, what is waiting, and what is being",
        "    held back and why"
    } end )
    local function Bind_CHeal(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            chealDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            HealState.CallOff()
            print("Heal called off")
            return
        end

        print("Heal: " .. HealState.Describe() .. (HealState.IsEnabled() and "" or " (disabled)"))
        local result = HealState.GetLastResult()
        if result ~= nil then
            print(" -- last: " .. result)
        end

        -- what every slot's fight window is being read against, which is otherwise the silent
        -- reason a configured heal is not firing -- the same shape of gap the cure mode left, and
        -- the same fix. `IsGroupFighting` because that is what the slots are held to; a healer
        -- standing in a fight it is not engaged in is precisely the case that has to read "on"
        print(" -- the fight, as the heal slots see it: " ..
            (Combat.IsGroupFighting() and "one is on" or "none right now"))
        local notCuring = reasonNotCuring()
        print(" -- curing: " .. HealStateConfig.GetCureModeDisplay(HealStateConfig.GetCureMode()) ..
            (notCuring ~= nil and (" -- not answering right now: " .. notCuring) or ""))
        local cureResult = HealState.GetLastCureResult()
        if cureResult ~= nil then
            print(" -- last cure: " .. cureResult)
        end
        for _, request in ipairs(HealState.GetCureRequests()) do
            print(" -- asked for: " .. request.typeKey .. " for " .. request.name ..
                " with " .. request.action:Name())
        end

        -- The rez, and the reason there is none, are two different reports and both matter: a
        -- character with rezzing on and nothing in its book, one holding off because it is in a
        -- fight, and one standing over a corpse it already offered a rez to all look identical from
        -- outside, and all three are answered here
        local rez, notRezzing = Rezzing.ChooseRez()
        print(" -- rezzing: " .. HealStateConfig.GetRezModeDisplay(HealStateConfig.GetRezMode()) ..
            (notRezzing ~= nil and (" -- not rezzing right now: " .. notRezzing) or
                (" -- would cast " .. Rezzes.Describe(rez))))

        -- both, whichever is in force, because the one that is *not* in force is exactly what
        -- somebody is checking when they wonder why the fight went the way it did
        local outRez, outNamed, outMissing = Rezzing.RezFor(false)
        local inRez, inNamed, inMissing = Rezzing.RezFor(true)
        print("    out of a fight: " .. Rezzes.Describe(outRez) ..
            (outNamed and " (set)" or "") ..
            (outMissing ~= nil and (" -- [" .. outMissing .. "] is not in this character's book") or ""))
        print("    in a fight: " .. Rezzes.Describe(inRez) ..
            (inNamed and " (set)" or "") ..
            (inMissing ~= nil and (" -- [" .. inMissing .. "] is not in this character's book") or ""))
        local rezResult = HealState.GetLastRezResult()
        if rezResult ~= nil then
            print(" -- last rez: " .. rezResult)
        end
        local order = Rezzing.GetOrder()
        if order ~= nil then
            print(" -- asked to rez: " .. order.name)
        end
        for _, corpse in ipairs(Rezzing.GetCorpses()) do
            local held = Rezzing.ReasonHeld(corpse)
            print(" -- corpse: " .. corpse.name .. " (" .. tostring(corpse.class or "?") .. ", " ..
                tostring(corpse.id) .. ") " .. tostring(math.floor(corpse.distance)) .. " away" ..
                (corpse.isTank and " (tank)" or "") .. (corpse.isOrdered and " (asked for)" or "") ..
                (held ~= nil and (" -- held: " .. held) or ""))
        end

        print(" -- calling heals: " .. (HealStateConfig.GetHealCalls() and "on" or "off"))

        -- **the judged reading is printed beside the real one whenever the two differ**, which is
        -- the whole of explaining a head start. A healer that goes to the warrior first while the
        -- wizard shows a lower number is doing exactly what it was told to, and this is the only
        -- place that can be seen -- without it the behaviour reads as a bug with no way in
        for _, candidate in ipairs(getCandidates()) do
            local judged = math.floor(candidate.urgency)
            local real = math.floor(candidate.pct)
            print(" -- " .. candidate.name .. ": " .. tostring(real) .. "%" ..
                (judged ~= real and (" (judged " .. tostring(judged) .. "%)") or "") ..
                (candidate.class ~= nil and (" " .. tostring(candidate.class)) or "") ..
                (candidate.isTank and " (tank)" or "") .. (candidate.isPet and " (pet)" or "") ..
                (candidate.isXTarget and " (xtarget)" or "") ..
                (candidate.isHolding and " (holding aggro)" or "") ..
                (isCalledByAnother(candidate) and " -- another healer has this one" or ""))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cheal", Bind_CHeal, chealDocs))

    HealState.Reset()
    HealState._.isInit = true
end

---Read the group, decide what should be happening, act on it, and release.
---
---There is no "I am healing" mode to be stuck in. Every pass reads everyone's health afresh and
---asks the same question -- is a heal in the air still the right heal, and if there is none,
---which one should there be -- so nothing a cast does or fails to do can stop this state
---deciding. A heal that cannot get started is reconsidered on the next pass like everything else,
---and dropped the moment it stops being the right thing to do.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function HealState.Go()
    local candidates = getCandidates()

    local castId = HealState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)
        local isCure = HealState._.cureRequest ~= nil
        local isRez = HealState._.rezPick ~= nil
        local job = isCure and "cure" or (isRez and "rez" or "heal")

        if status == nil then
            local abandon
            if isCure then
                abandon = reasonToAbandonCure(candidates)
            elseif isRez then
                abandon = reasonToAbandonRez(candidates)
            else
                abandon = reasonToAbandon(candidates)
            end

            if abandon ~= nil then
                DebugLog("Calling off the " .. job .. ": " .. abandon)
                if isCure then
                    HealState._.lastCureResult = "called off: " .. abandon
                elseif isRez then
                    HealState._.lastRezResult = "called off: " .. abandon
                else
                    HealState._.lastResult = "called off: " .. abandon
                end
                HealState._.calledOff = true
                Casting.StopFor(HealState.key)
            end
            return true
        end

        if isCure then
            recordCureFinished(status, outcome, reason)
        elseif isRez then
            recordRezFinished(status, outcome, reason)
        else
            recordFinished(status, outcome, reason)
        end
        return true
    end

    prune()

    -- **A cure comes after anybody in real trouble and before everything else.**
    --
    -- Above an ordinary heal because the two are not the same kind of cost. A heal gives back what
    -- has already been taken; a cure stops the taking. An affliction with two minutes left will
    -- spend more health than the heal being weighed against it and go on spending it every tick,
    -- and it is *finite* -- once it is off, the healing that would have been owed to it never has
    -- to happen at all. Above an ordered heal for the same reason, and because a cure request is
    -- itself somebody's explicit order: both are people saying what they need, and the one that
    -- ends a recurring cost in a single cast is the one to answer first.
    --
    -- Below somebody dying, because nothing outranks that. It is the same guard a group heal is
    -- held to a few lines down, and asked the same careful way (see `emergencyPending`): whether
    -- there is somebody in trouble this state would actually cast at, rather than merely somebody
    -- with a low number, so a rezzed group-mate parked at 15% cannot block curing forever.
    if not emergencyPending(candidates) then
        local curePick = chooseCure()
        if curePick ~= nil then return startCure(curePick) end
    end

    local pick = choosePick(candidates)
    if pick ~= nil then return startHeal(pick) end

    -- **A rez comes last, because everybody alive comes first.**
    --
    -- Below every heal and every cure without exception: somebody dead is not getting any worse,
    -- and a corpse will still be lying there in three seconds. So this is the frame nothing else
    -- in this state wanted -- which out of a fight is every frame, and in one is the gap between
    -- two heals.
    --
    -- The one thing it is *not* below is the priority chain under this state, and that is the whole
    -- reason rezzing lives here rather than in a band of its own: a rez is a gem and a large piece
    -- of the mana bar, and choosing to spend them is choosing not to heal with them. Whether it
    -- happens during a fight at all is the Heal State page's Rezzing setting, and `cabby.rezzing`
    -- owns the rest of the judgment (see `chooseRez`).
    local rezPick = chooseRez(candidates)
    if rezPick ~= nil then return startRez(rezPick) end

    return false
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
HealState.IsEnabled = function()
    return HealStateConfig.IsEnabled()
end

---Switching healing off has to call off the heal in the air as well: it is the casting service's
---now, and it would go on holding the whole chain back for a job we were just told to stop.
---@diagnostic disable-next-line: duplicate-set-field
HealState.SetEnabled = function(isEnabled)
    HealStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        HealState.CallOff()
        HealState.Reset()
    end
end

function HealState.BuildMenu()
    HealStateMenu.BuildMenu(HealState)
end

return HealState
