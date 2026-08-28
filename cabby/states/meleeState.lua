local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")
local Timer = require("utils.Time.Timer")

local Action = require('cabby.actions.action')
local ActionCommand = require("cabby.commands.actionCommand")
local Combat = require("cabby.combat")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local MeleeStateMenu = require("cabby.ui.states.meleeStateMenu")
local Menu = require("cabby.ui.menu")
local Mobs = require("cabby.mobs")
local Roles = require("cabby.roles")
local Skills = require("cabby.actions.skills")
local Status = require('cabby.status')
local ToggleCommand = require("cabby.commands.toggleCommand")

-- How long "As Needed" waits between tanking actions so they fire one at a time
local sequentialActionDelayMs = 1500

-- How long to leave a `/stand` before sending it again. Standing takes effect when the server says
-- so, and repeating the command every frame in the meantime is nothing but spam
local standRetryMs = 1000

-- How far inside the nearest other body -- player or somebody's pet -- the main tank aims to stand
-- on a rooted mob. Enough to be unambiguously the nearest body after the client's own rounding, and
-- no more: every unit of it is a unit further into a mob that may have an ae. One number for both,
-- because "nearest" is the same comparison whoever the body belongs to; what makes a pet cost more
-- ground is that it is standing closer to begin with and will not move, not a different rule.
local rootTankLead = 2
-- How close it will get in the attempt. Zero, at the user's direction: being the nearest body is the
-- job, somebody standing *on* a rooted mob is exactly when it matters most, and there is no distance
-- at which giving up on it is better than standing there. A stick held at 0 simply runs in and stays.
local minRootTankDistance = 0
-- How often the other players are measured against the mob. The same quarter second the roster and
-- the roles are read on, and for the same reason: it is one spawn search and a handful of reads,
-- nobody crosses a meaningful amount of ground inside one, and the answer is a hold distance rather
-- than a swing.
local groupScanIntervalMs = 250

---@class MeleeState : BaseState
local MeleeState = {
    key = "MeleeState",
    eventIds = {
        -- `attack` and `autoengage` are not here: what this character is fighting belongs to
        -- `cabby.combat`, because a wizard fights the same mob with no melee state to keep it in
        --
        -- the switches the Melee State page draws as checkboxes, each also sayable and so also
        -- bindable to a hotbar button
        action = "action",
        bashOverride = "bashoverride",
        melee = "melee",
        rootTank = "roottank",
        stick = "stick",
        tanking = "tanking"
    },
    _ = {
        isInit = false,
        retargetTimer = nil,
        standTimer = nil,
        holdTargetId = 0,
        tauntTimer = Timer.new(sequentialActionDelayMs),
        hateTimer = Timer.new(sequentialActionDelayMs),
        -- the last measurement of where the rest of the group is standing relative to what we are
        -- fighting, for the rooted-mob hold distance. A measurement, re-taken on its own cadence
        -- and thrown away the moment the fight moves to another mob
        nearestOther = { id = 0, atMs = 0, distance = nil }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeState.key, str)
end

---Nothing this state does can land right now.
---
---Feared belongs on this list beside the stun and the mez, and it has to be said *here* and not
---only down in the actions: the abilities refuse themselves already (`actions/skill.lua`,
---`actions/discipline.lua`), but the swing toggle and the stick are this state's own. Feared, the
---server is running the character -- there is nothing to face and nowhere to stand -- so the pass
---below would ask for `/attack on` on every frame the fear happened to sweep us past the mob, and
---walk a stick into ground we do not control.
---
---The frame is still held, as it is for the other four: being feared in a fight is not idle, and
---the beat spent running is not a beat for anything below the dps band to sit down in.
---@return boolean isIncapacitated
local function IsIncapacitated()
    return mq.TLO.Me.Stunned() or mq.TLO.Me.Mezzed() ~= nil or mq.TLO.Me.Charmed() ~= nil
        or mq.TLO.Me.Feared() ~= nil or mq.TLO.Me.Binding() or mq.TLO.Me.Casting() ~= nil
end

---@return boolean hasAggro Whether we are currently holding aggro on the current target
local function HasTargetAggro()
    local targetOfTarget = mq.TLO.Target.TargetOfTarget.ID()
    if targetOfTarget ~= nil and targetOfTarget > 0 then
        return targetOfTarget == mq.TLO.Me.ID()
    end

    -- Target-of-target isn't populated; fall back to the aggro meter when the server sends it
    local pctAggro = mq.TLO.Target.PctAggro()
    return type(pctAggro) == "number" and pctAggro >= 100
end

local function FixCombatState()
    -- Sitting belongs on this list for the same reason feigning does: we are engaged and about to
    -- swing, and neither posture swings. It is not covered by `Ducking`, which is the duck stand
    -- state and nothing else. RestState would stand us up for exactly this reason -- being engaged
    -- is the first thing on its hold list -- but it never gets the chance, because this state
    -- reports busy for as long as the fight lasts and everything below it is starved for the whole
    -- of it. The movement service stands us up too, but only while it is actually driving, which
    -- is not the case for a mob that walked into reach or for a character with stick switched off.
    if mq.TLO.Me.State() == "SIT" or mq.TLO.Me.Feigning() or mq.TLO.Me.Ducking() then
        if MeleeState._.standTimer:timer_expired() then
            MeleeState._.standTimer = Timer.new(standRetryMs)
            mq.cmd("/stand")
        end
    end

    if mq.TLO.Me.Sneaking() then
        mq.cmd("/doability sneak")
    end
end

---How close to stand to swing at something: inside its reach by three, and never further out than
---fourteen however big it is.
---
---Read off the mob (`Mobs.Reach`) rather than set anywhere. It is also the ceiling on how far
---`states/standoffState.lua` ever sends anybody: with a tank standing in a mob's reach, the line the
---rest of the group gets behind is the tank's own distance to it, and this is the furthest out that
---distance ever relaxes to.
---@param id number
---@return number range
function MeleeState.GetSpawnMeleeRange(id)
    local reach = Mobs.Reach(id)
    if reach == nil then return 14 end
    return math.min(14, reach - 3)
end

---The nearest body one spawn search turns up, measured to the mob and counted only if the mob could
---actually hit it.
---
---Split out because a body on our side of the fight is two searches and not one -- the client's
---spawn types are exclusive, so a `pc` search does not return anybody's pet -- and the two are the
---same handful of reads over the same question.
---@param search string a spawn search, already widened to cover the mob's reach from where we stand
---@param mobY number
---@param mobX number
---@param mobZ number
---@param reach number how far the mob can hit, so how far out a body still counts as in the way
---@param myId number ours, which is the one body this measurement is not about
---@param nearest number|nil the closest anything earlier found, carried through so the searches
---compose into one answer rather than each having its own
---@return number|nil nearest
local function nearestInSearch(search, mobY, mobX, mobZ, reach, myId, nearest)
    local count = tonumber(mq.TLO.SpawnCount(search)()) or 0
    for index = 1, count do
        local body = mq.TLO.NearestSpawn(index, search)
        local id = tonumber(body.ID()) or 0
        if id > 0 and id ~= myId then
            local y, x, z = body.Y(), body.X(), body.Z()
            if y ~= nil and x ~= nil and z ~= nil then
                local distance = Geometry.Distance3D(y, x, z, mobY, mobX, mobZ)
                if distance < reach and (nearest == nil or distance < nearest) then
                    nearest = distance
                end
            end
        end
    end

    return nearest
end

---How close the nearest other body on our side of the fight is standing to this mob.
---
---Measured between their coordinates and the mob's rather than asked of anybody: there is no reading
---another player's distance to a third spawn, and their own client is not something this one can
---interrogate. What can be had is two positions and a subtraction.
---
---**Every body near the mob counts, and none of them is asked why it is there.** Not group members
---but *bodies*, found by a spawn search, because a mob does not check the group window before it
---swings: the raid member from another group, the box with the switch off and the stranger who
---wandered into the camp are all standing in its reach, and the one standing nearest is the one it
---hits. The search is centred on us and widened to cover the mob's whole reach from wherever we are
---standing, which is the closest the client comes to "everybody near that spawn".
---
---**A pet is one of those bodies, and it is the one that cannot be sent away.** Everybody else's
---half of this is walking backwards (`states/standoffState.lua`); a pet does not do that. It holds
---its own melee range on what it was sent at for as long as the fight lasts, and calling it off its
---target to fix where it is standing is undoing an order its owner gave. So the whole of the fix
---falls on this half, and the tank closes *further* for it than it ever would for a player -- a pet
---is a small body that stands well inside where a person would have stood, and the hold has to get
---inside that with nothing coming the other way to meet it.
---
---**Player-owned pets, which is `pcpet` and includes a charm** -- a mob's own pet is on the other
---side of the fight, is somebody the group is trying to kill rather than a body it is arranging, and
---is already in the roster as such. Two searches rather than one because the client's spawn types
---are exclusive: a pet's type is *pet*, so `pc radius` never returned one and this measurement has
---been quietly blind to every pet in the camp.
---
---Nil is "nobody else to measure": solo, or nobody else near the mob. It is not zero, and the caller
---must not read it as somebody standing on the mob.
---@param targetId number
---@return number|nil distance
local function nearestOtherDistance(targetId)
    local cache = MeleeState._.nearestOther
    local now = Time.current_time()
    if cache.id == targetId and now - cache.atMs < groupScanIntervalMs then
        return cache.distance
    end

    cache.id = targetId
    cache.atMs = now
    cache.distance = nil

    local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
    local mobY, mobX, mobZ = spawn.Y(), spawn.X(), spawn.Z()
    local myDistance, reach = spawn.Distance3D(), Mobs.Reach(targetId)
    if mobY == nil or mobX == nil or mobZ == nil or myDistance == nil or reach == nil then
        return nil
    end

    -- Everyone within the mob's reach is within this of us, wherever we happen to be standing --
    -- the triangle inequality and nothing cleverer. Anybody it catches beyond that is filtered by
    -- the reach test in the search, so the width costs a few reads rather than a wrong answer.
    local radius = tostring(math.ceil(myDistance + reach) + 1)
    local myId = mq.TLO.Me.ID()

    local nearest = nearestInSearch("pc radius " .. radius, mobY, mobX, mobZ, reach, myId, nil)
    nearest = nearestInSearch("pcpet radius " .. radius, mobY, mobX, mobZ, reach, myId, nearest)

    cache.distance = nearest
    return cache.distance
end

---How close to hold station on what we are fighting.
---
---Melee range, except in the one fight where standing at melee range is not enough. **A rooted mob
---hits whoever is standing in its reach**, because reaching anybody else is the one thing it cannot
---do -- so on one of those, the group's main tank being *nearest* is not a nicety, it is the job,
---and a caster who has drifted inside the tank is the one taking the hits.
---
---Closing is expressed against where the other bodies actually are rather than against a tighter
---number, because "nearest" is a comparison and nothing else: the answer moves as they move, it is
---re-derived every pass from where everybody is standing, and it relaxes straight back to melee
---range the moment nobody is inside it. Every body near the mob counts, whatever it is doing and
---whoever it belongs to, because a mob does not check the group window before it swings.
---
---**Pets count, and they are the reason this ends up further in than it sounds.** A pet is a body
---in the reach like any other, but it is the only one with no half of its own here: a player inside
---the tank backs out (`states/standoffState.lua`) and the hold relaxes as they go, while a pet holds
---its own melee range on the mob until the fight ends. Nothing meets this half coming the other way,
---so the ground is all given by the tank -- and a pet stands closer than a person would, which is
---exactly why closing inside one costs more of it.
---
---**There is no floor.** It will stand at zero if that is what being nearest takes -- somebody
---standing *on* a rooted mob is the case this exists for, and there is no distance at which giving
---up and letting them wear it is the better answer. The only ceiling is melee range: it never
---widens past the distance it would have held anyway.
---
---**The other half is the exact mirror of this, and neither half reads the other**
---(`states/standoffState.lua`): everybody else measures *their* distance to this same mob against
---*the tank's*, and backs behind it. Both halves read bodies and a mob and nothing else, and both
---stop the moment they are no longer the one standing wrong -- which is what makes the pair settle
---instead of chase. The two directions cannot fight, either: this one only ever moves inward and
---stops at melee range, that one only ever moves outward and stops a step past wherever this one
---has got to.
---
---Only the main tank, only while the mob reads as rooted, and only while the switch is on -- so on
---any ordinary mob, for anybody else, this is melee range and nothing has changed.
---@param targetId number
---@return number range
local function holdRange(targetId)
    local range = MeleeState.GetSpawnMeleeRange(targetId)

    if not MeleeStateConfig.GetRootTank() then return range end
    if not Roles.IsMainTank() then return range end
    if not Mobs.IsRooted(targetId) then return range end

    -- Nobody inside us is nothing to fix. Measured against the hold rather than against where we
    -- happen to be standing this instant, so a tank still walking in does not read the others as
    -- being in front of it and close further than it needs to.
    local nearest = nearestOtherDistance(targetId)
    if nearest == nil or nearest > range then return range end

    return math.max(minRootTankDistance, math.min(range, nearest - rootTankLead))
end

---Who this state is, when it asks the casting service for something: its band decides whether
---it may interrupt another cast, and what gets held back while its own runs.
---@return table request
function MeleeState.CastRequest()
    return {
        owner = MeleeState.key,
        priority = MeleeState.priority,
        targetId = Combat.GetTargetId()
    }
end

---@param range number
function MeleeState.StickToCurrentTarget(range)
    if not MeleeStateConfig.GetStick() then return end

    -- A cast we are level with is one of our own action slots, and sticking is exactly what
    -- would lose it: the character is standing still waiting for the cast bar and we would walk
    -- them back into range. Nothing is lost by waiting -- the attack action re-sticks on the
    -- frame after the cast ends.
    if Casting.IsHoldingStill(MeleeState.priority) then return end

    MeleeState._.holdTargetId = Combat.GetTargetId()
    Movement.Stick(MeleeState._.holdTargetId, {
        distance = range,
        owner = MeleeState.key,
        priority = MeleeState.priority
    })
end

---Chase a mob that has turned and run, by walking the route it took.
---
---**A stick is a straight line at where the mob is standing, and a runner stops standing anywhere.**
---That line is fine while the mob is in front of us and it is the wrong thing entirely the moment
---the mob rounds a corner: the line goes through the wall, the character presses into it, and the
---stick spends its unsticker flailing at the corner while the mob leaves. So a mob that has run is
---chased the way a group member is followed -- `Movement.Follow`, the breadcrumb replay of the
---route it actually walked, which is the one route known walkable (see `utils/Movement/Follow.lua`).
---
---**Sight is asked for** (`requireSight`), which is the other half of the corner. Being inside melee
---range of something we cannot see is not having caught it -- the swing needs a view of it as much
---as the reach -- so the chase keeps walking the mob's route until we have both, rather than parking
---behind whatever is in the way. Exactly the reading `cabby/travel.lua` asks for while a fight is on,
---and for the same reason.
---
---**Held at melee range with no buffer**, unlike a follow: the room a follow leaves a group member
---to move around in would be a swing missed here.
---
---**Retuned rather than restarted while it is already ours.** A fresh `Follow` starts with no trail,
---and a chase with no trail is the beeline this exists to stop -- so a chase already running is
---adjusted in place, the same way a stick's distance is (`Movement.SetFollowHold`).
---@param targetId number
---@param range number
function MeleeState.ChaseCurrentTarget(targetId, range)
    if Movement.IsFollowing(targetId) and Movement.IsOwnedBy(MeleeState.key) then
        Movement.SetFollowHold(MeleeState.key, range, range, true)
        return
    end

    -- The same guard the stick has: a cast of ours we are level with is lost by walking, and
    -- starting a beat later costs nothing here either -- the movement service holds the character
    -- still for that cast whichever mover asked, and a held task records no route.
    if Casting.IsHoldingStill(MeleeState.priority) then return end

    MeleeState._.holdTargetId = targetId
    Movement.Follow(targetId, {
        distance = range,
        resumeDistance = range,
        requireSight = true,
        owner = MeleeState.key,
        priority = MeleeState.priority
    })
end

---Is this mob standing somewhere the stick can hold it?
---
---**The question that ends a chase, and it is not the negative of the one that starts one.** What a
---chase carries is the route the mob took, and a `Follow` started fresh carries none -- so handing
---the character back is only right when the stick can honestly do the job: the mob is **in reach,
---in sight, and no longer going anywhere.**
---
---Each of the three is there for its own failure. Range alone hands the stick a mob we are merely
---keeping pace with, at every stride, and takes the route away each time -- so the one chase that
---most needs its trail is the one that never banks one. Sight, because the stick's line at a mob we
---cannot see is the line nobody should be inventing (the same gate that has always governed starting
---one). And still, because a mob still travelling is a mob whose route we are about to want.
---
---Handing back is otherwise made cheap on purpose: it can only happen with the mob in front of us at
---arm's length, which is exactly where a chase started over again costs nothing -- its first
---breadcrumb lands where the mob is standing.
---@param targetId number
---@param distance number how far away it is, already read this pass
---@param range number how close we hold station on it
---@return boolean canHold
local function stickCanHold(targetId, distance, range)
    if distance > range then return false end
    if not mq.TLO.Target.LineOfSight() then return false end
    return mq.TLO.Spawn("id " .. tostring(targetId)).Moving() ~= true
end

---Get to what we are fighting, by whichever of the two movers the mob's own behaviour calls for.
---
---One task at a time is the movement service's rule, so this is a choice and never a blend: the
---stick runs at the mob, the chase walks its route, and which of them holds the character is
---re-derived here every pass off the world.
---
---**Leaving is what picks the chase** (`Mobs.IsRunning`), and **catching it is what gives the stick
---the character back** (`stickCanHold`) -- two different questions rather than one with slack round
---it, which is what keeps the pair from trading the character back and forth over a threshold.
---
---A chase is only ever *started* on something inside the engage ring, the same gate the stick has
---always had, so nothing here takes off after a mob that was never in reach of this fight. Once
---running it is not re-gated on distance: a mob that runs is a mob we are already committed to, and
---a leash that let go halfway would leave the character standing in the corridor it ran down.
---@param targetId number
---@param distance number
---@param range number
local function holdStationOn(targetId, distance, range)
    if not MeleeStateConfig.GetStick() then return end

    local chasing = Movement.IsFollowing(targetId) and Movement.IsOwnedBy(MeleeState.key)
    if chasing and not stickCanHold(targetId, distance, range) then
        MeleeState.ChaseCurrentTarget(targetId, range)
        return
    end

    local withinEngage = distance < MeleeStateConfig.GetEngageDistance()
    if not chasing and withinEngage and Mobs.IsRunning(targetId) then
        MeleeState.ChaseCurrentTarget(targetId, range)
        return
    end

    if not Movement.IsSticking(targetId) and withinEngage and mq.TLO.Target.LineOfSight() then
        MeleeState.StickToCurrentTarget(range)
    end
end

---@return number targetId what this state is fighting, which is whatever Combat says
function MeleeState.GetTargetId()
    return Combat.GetTargetId()
end

local function DoPrimaryCombatAction()
    ---@type ActionType
    local primaryAction
    if MeleeStateConfig:GetBashOverride() and mq.TLO.Me.Inventory("offhand").Type() == "Shield" then
        primaryAction = Skills.bash
    else
        primaryAction = MeleeStateConfig.GetPrimaryCombatAbility()

        -- Slam belongs to the race we are wearing rather than to the character, so an illusion of
        -- something that cannot slam leaves nothing to fire -- and leaves the order perfectly
        -- intact, since it was right when it was given and will be right again. The backup takes
        -- the swings for exactly as long as that is true.
        if not primaryAction:HasAction() then
            primaryAction = MeleeStateConfig.GetBackupCombatAbility()
        end
    end

    if primaryAction:IsReady(MeleeState.CastRequest()) then
        primaryAction:DoAction(MeleeState.CastRequest())
    end

    if mq.TLO.Me.Class.ShortName() == "MNK" then
        local secondaryAction = MeleeStateConfig.GetSecondaryCombatAbility()
        if secondaryAction:IsReady(MeleeState.CastRequest()) then
            secondaryAction:DoAction(MeleeState.CastRequest())
        end
    end
end

---Runs a configured tanking action list according to its usage setting
---@param actions table? configured actions, in priority order
---@param usage string? one of MeleeStateConfig.usages values
---@param timer Timer paces "as needed" actions so they fire one at a time
local function DoTankingActionList(actions, usage, timer)
    if actions == nil or usage == nil or usage == MeleeStateConfig.usages.Off.value then return end

    local asNeeded = usage == MeleeStateConfig.usages.AsNeeded.value
    if asNeeded and (HasTargetAggro() or not timer:timer_expired()) then return end

    for _, action in ipairs(actions) do
        ---@type Action
        action = action

        if Action.IsEnabled(action) then
            local actionType = Action.GetActionType(action)

            if actionType ~= nil and actionType:IsReady(MeleeState.CastRequest()) and Action.GetLuaResult(action) then
                actionType:DoAction(MeleeState.CastRequest())

                -- "As Needed" walks the list one action at a time with a short delay between
                if asNeeded then
                    timer:reset()
                    return
                end
            end
        end
    end
end

local function DoTankingActions()
    if not MeleeStateConfig.GetTanking() then return end

    DoTankingActionList(MeleeStateConfig.GetTauntActions(), MeleeStateConfig.GetTauntUsage(), MeleeState._.tauntTimer)
    DoTankingActionList(MeleeStateConfig.GetHateActions(), MeleeStateConfig.GetHateUsage(), MeleeState._.hateTimer)
end

---One pass of meleeing whatever we are fighting: get on it, get to it, and swing.
---
---Everything it decides is decided here, from the engagement and the client, every pass. There is
---no "I am attacking" mode: the fight ending, the target changing, or a heal taking the client's
---target away are all just what the next pass reads.
---@return boolean isBusy
local function melee()
    local targetId = Combat.GetTargetId()
    if targetId == 0 then
        -- let go of anything we were holding onto for a target that is gone
        if MeleeState._.holdTargetId ~= 0 then
            MeleeState._.holdTargetId = 0
            Movement.StopFor(MeleeState.key)
        end
        -- The fight can be open with no target for a beat -- Combat is seeking the successor
        -- after a death. Standing ready is this state's job then, and holding the frame is the
        -- point: the beat between two mobs of one fight is not a frame for anything below to
        -- act in.
        return Combat.IsEngaged()
    end

    -- Swinging needs the client on the target, which casting a heal at a group member takes away
    -- from us. Ask again on a timer rather than every frame: /mqtarget is a game command and the
    -- server answers when it answers. The ask is by bare id -- a fight target is not always an
    -- NPC; pets and destructibles are fights too, and a typed search excludes them, fails, and
    -- fills the log with "no spawns matching" -- but never for a corpse: a dead mob keeps its
    -- spawn id, the search language cannot say "alive", and the death is Combat's to notice,
    -- not something to snap the target onto.
    if mq.TLO.Target.ID() ~= targetId then
        if MeleeState._.retargetTimer:timer_expired() then
            local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
            if spawn.ID() ~= nil and not spawn.Dead() and spawn.Type() ~= "Corpse" then
                mq.cmd("/mqtarget id " .. tostring(targetId))
            end
            MeleeState._.retargetTimer = Timer.new(500)
        end
        return true
    end

    if IsIncapacitated() then
        return true
    end

    FixCombatState()

    -- FixCombatState issues commands, and mq.cmd yields the frame, so the target validated
    -- above can be gone by the time we get here. Read distance once and bail if it is; the
    -- next pass picks it up again.
    local distance = mq.TLO.Target.Distance()
    if distance == nil then return true end

    local range = holdRange(targetId)

    -- A hold distance that moves while the stick runs has to reach the stick that is running, or the
    -- tank closes inside the group exactly once -- on the pass the stick happened to start -- and
    -- then stands at whatever that pass decided for the rest of the fight. Only ever our own stick;
    -- a higher priority behaviour that has taken movement over is not ours to retune.
    Movement.SetStickDistance(MeleeState.key, range)

    -- We have pulled it off the tank: stop hitting it until the tank has it back. Combat answers
    -- whether that is what has happened -- both halves of it are its own facts -- and this is what
    -- this state does about it: the swing goes off, and the whole offense below is skipped, taunts
    -- and hate included. Those two above all -- a character holding the mob the main tank should be
    -- holding, taunting it, is the state pulling one way and the group the other.
    --
    -- Off through Combat rather than a bare `/attack off` for the same reason the range gate is:
    -- it is bookkeeping, and reading it as `attack off` said with the keyboard would close the
    -- fight over a mob we are still very much in one with (`disengageonattackoff`).
    --
    -- Ahead of the stick, and only ahead of it: a mob that is coming for us needs no ground crossed
    -- to reach us, so this is not the moment to start closing any. A stick already running is left
    -- alone -- hate is not shed by walking away, it is shed by the tank building more while we add
    -- none, and standing off would only mean crossing that ground again on the pass this comes back
    -- on. The frame is held because we are still in a fight: eased off is not idle, and nothing
    -- below the dps band should be sitting down in it.
    local easeOff, easeWhy = Combat.ShouldEaseOff()
    if easeOff then
        Combat.SetAutoAttack(false, "easing off: " .. tostring(easeWhy))
        return true
    end

    holdStationOn(targetId, distance, range)

    -- Starting a move can yield too, so keep using the snapshot rather than re-reading
    if distance < range then
        if not mq.TLO.Me.Combat() and Status:IsFacingTarget() then
            Combat.SetAutoAttack(true, "in melee range")
        end

        DoPrimaryCombatAction()
        DoTankingActions()

        for _, action in ipairs(MeleeStateConfig.GetActions()) do
            ---@type Action
            action = action

            if Action.IsEnabled(action) then
                local actionType = Action.GetActionType(action)

                if actionType ~= nil and actionType:IsReady(MeleeState.CastRequest()) and Action.GetLuaResult(action) then
                    actionType:DoAction(MeleeState.CastRequest())
                end
            end
        end

    -- The swing is range-gated the other way too: out of reach, auto attack is held off until we
    -- are back inside it. Off past the spawn's true reach (MaxRangeTo) rather than at our own
    -- engage ring, which sits a few units inside it -- a mob dancing on one line must not flap
    -- the toggle. Through Combat rather than a bare `/attack off`, because the player's own
    -- switch-off can be an order (disengageonattackoff) and this is bookkeeping: stepping out of
    -- reach must not close the fight, or call anyone else off it.
    elseif mq.TLO.Me.Combat() and distance > (mq.TLO.Target.MaxRangeTo() or range) then
        Combat.SetAutoAttack(false, "out of melee range")
    end

    return true
end

---@return boolean isAttacking whether this state is fighting something right now
function MeleeState.IsAttacking()
    return Combat.IsEngaged()
end

---@return string description of what this state is doing, for the page
---
---Asked of Combat every time rather than written down as the pass goes by: the answer is cheap
---(cached facts either side of it) and a remembered one would be a page still reporting an ease-off
---from a pass that ended in a retarget, a stun, or a mob that died.
function MeleeState.Describe()
    local easeOff, easeWhy = Combat.ShouldEaseOff()
    if easeOff then return "Easing off -- " .. tostring(easeWhy) end
    return MeleeState.IsAttacking() and "Attacking" or "Standby"
end

---Stop meleeing, without deciding anything about the fight itself: whether we are still engaged
---is Combat's answer, and calling this off is not the same as calling that off.
function MeleeState.Reset()
    MeleeState._.retargetTimer = Timer.new(0)
    MeleeState._.standTimer = Timer.new(0)
    MeleeState._.holdTargetId = 0
    MeleeState._.nearestOther = { id = 0, atMs = 0, distance = nil }
    -- only our own stick; a higher priority behavior may have taken movement over since
    Movement.StopFor(MeleeState.key)
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Init()
    if not MeleeState._.isInit then
        -- our own config, rather than one more line in Setup's fixed list: a class that does
        -- not register this state has no melee action slots to write defaults for
        MeleeStateConfig.Init()

        Menu.RegisterState(MeleeState)

        -- Every switch on the Melee State page, as something that can also be said -- and so
        -- bound to a hotbar button, since the button editor offers every registered command. They
        -- go through the same setters the checkboxes call, so the two cannot disagree.
        ToggleCommand.Register({
            key = MeleeState.key,
            phrase = MeleeState.eventIds.melee,
            summary = "Turns melee combat on or off for listener(s)",
            about = { "Off calls off an attack in progress and stops picking up new ones." },
            get = MeleeStateConfig.IsEnabled,
            set = MeleeState.SetEnabled
        })

        ToggleCommand.Register({
            key = MeleeState.key,
            phrase = MeleeState.eventIds.stick,
            summary = "Turns closing on the attack target on or off",
            about = {
                "On, a mob standing still is held at melee range by a stick, and one that has",
                "turned and run is chased along the route it walked -- the same breadcrumb",
                "follow used for followtarget, which is what gets round a corner.",
                "Off holds position and only swings at what comes into reach.",
                "Turning it off also releases a stick or a chase already running."
            },
            get = MeleeStateConfig.GetStick,
            set = MeleeState.SetStick
        })

        ToggleCommand.Register({
            key = MeleeState.key,
            phrase = MeleeState.eventIds.rootTank,
            summary = "Turns closing inside the group on a rooted mob on or off",
            about = {
                "Only ever acts on the group's main tank, and only on a mob that reads as rooted.",
                "A mob that cannot move hits whoever is standing in its reach, so the tank closes",
                "until it is the nearest body and relaxes back to melee range once it is.",
                "Pets count as bodies too, and they are the ones that never back off -- so closing",
                "inside a pet is all on the tank, and goes as far in as zero.",
                "The other half is everyone else standing off (the Standoff page)."
            },
            get = MeleeStateConfig.GetRootTank,
            set = MeleeStateConfig.SetRootTank
        })

        ToggleCommand.Register({
            key = MeleeState.key,
            phrase = MeleeState.eventIds.tanking,
            summary = "Turns the tanking action lists (taunts and hate) on or off",
            about = { "The lists keep their own usage settings; this is the master switch over both." },
            get = MeleeStateConfig.GetTanking,
            set = MeleeStateConfig.SetTanking
        })

        -- offered only to characters that can bash, exactly as the checkbox is
        if Skills.bash:HasAction() then
            ToggleCommand.Register({
                key = MeleeState.key,
                phrase = MeleeState.eventIds.bashOverride,
                summary = "Turns bashing in place of the primary melee skill on or off",
                about = { "Only applies while a shield is actually equipped." },
                get = MeleeStateConfig.GetBashOverride,
                set = MeleeStateConfig.SetBashOverride
            })
        end

        -- the same command every state with an action list wants, registered from one place
        ActionCommand.Register({
            key = MeleeState.key,
            phrase = MeleeState.eventIds.action,
            summary = "Switches one of the configured melee actions on or off",
            where = "Melee State page, Tanking and Melee tabs",
            getActionLists = MeleeStateConfig.GetActionLists
        })

        MeleeState.Reset()
        MeleeState._.isInit = true
    end
end

---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Go()
    return melee()
end

MeleeState.IsTargetInCombatAbilityRange = function()
    local distance = mq.TLO.Target.Distance()
    return distance ~= nil and distance < 14
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
MeleeState.IsEnabled = function()
    return MeleeStateConfig.IsEnabled()
end

---Switching the state off has to call off what it was doing, not just stop it being asked for
---another turn: the stick it started is Movement's now and would go on holding range on the
---target we were just told to stop fighting. What it does *not* do is call off the fight -- a
---paladin told to stop swinging is still fighting the same mob with spells.
---@diagnostic disable-next-line: duplicate-set-field
MeleeState.SetEnabled = function(isEnabled)
    MeleeStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        MeleeState.Reset()
    end
end

---Turn closing on the attack target on or off, both movers -- the stick that holds a mob standing
---still and the chase that walks a runner's route are the same order, and the switch is over the
---order rather than over one of its shapes.
---
---It governs whether a *new* one is started, so turning it off releases the one in progress as
---well -- otherwise the character keeps chasing the target it was just told to stand off from.
---@param enable boolean
function MeleeState.SetStick(enable)
    MeleeStateConfig.SetStick(enable)
    if not enable then
        Movement.StopFor(MeleeState.key)
    end
end

function MeleeState.BuildMenu()
    MeleeStateMenu.BuildMenu(MeleeState)
end

return MeleeState

-- aggroed someone in group? me?
-- someone pulling?



-- in combat? find target
-- approach target
-- trigger combat skills

-- running away?
-- group/raid roles for targetting / tanking
-- use marks for assist instead of MA?


--- Enable Attack
-- downshit1=/if (${Stick.Active} && (${Target.Distance} < 16) && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking}) /squelch /attack on
-- downshit2=/if (!${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && ${Me.CombatState.Equal[COMBAT]}) /multiline ; /if (${Target.Dead} || ${Target.Type.Equal[Corpse]}) /squelch /target clear; /if ((${Target.Type.Equal[NPC]} || ${Target.Type.Equal[Pet]}) && ${Target.Distance} < ${Math.Calc[${Target.MaxRange} + 30]}) /squelch /attack on

--- Endurance Regen
-- downshit3=/if (!${Me.CombatState.Equal[COMBAT]} && ${Me.CombatAbilityReady[Breather Rk. III]} && (${Me.PctEndurance} < 25) && ${Me.CurrentEndurance} > 50 && !${Bool[${Melee.DiscID}]}) /disc Breather Rk. III

--- Clickies / Aura
-- downshit4=/if (!${Me.Moving} && !${Me.Invis} && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && !${Me.Binding} && !${Me.State.Equal[STUN]} && !${Me.Trader} && !${Stick.Active} && !${Me.Casting.ID}) /multiline ; /if (${Me.CombatState.NotEqual[COMBAT]} && !${Bool[${Me.Aura}]} && ${Me.CombatAbilityReady[Master's Aura]} && ${Me.CurrentEndurance} > 250) /disc Master; /if (${Cast.Ready[Transcended Fistwraps of Immortality]} && (${Me.PctHPs} < 80)) /casting "Transcended Fistwraps of Immortality"; /if (${Spell[Familiar: Dragon Sage].Stacks} && !${Me.Buff[Familiar: Dragon Sage].ID}) /casting "Familiar of Lord Nagafen"; /if (${Spell[Twitching Speed].Stacks} && !${Me.Buff[Twitching Speed].ID} && ${Me.Haste} < 190 && !${Me.Slowed.ID}) /casting "Lizardscale Plated Girdle"; /if (${Spell[Arch Shielding].Stacks} && !${Me.Buff[Arch Shielding].ID}) /casting "Tri-Plated Golden Hackle Hammer"
-- downshit5=/if (!${Me.Moving} && !${Me.Invis} && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && !${Me.Binding} && !${Me.State.Equal[STUN]} && !${Me.Trader} && !${Stick.Active} && !${Me.Casting.ID}) /multiline ; /if (${Spell[Illusionary Spikes XX].Stacks} && !${Me.Buff[Illusionary Spikes XX].ID}) /casting "Crater-Dust Cloak"; /if (${Spell[Storm Guard].Stacks} && !${Me.Buff[Storm Guard].ID}) /casting "Stormeye Band"; /if (${Spell[Frightful Aura].Stacks} && !${Me.Buff[Frightful Aura].ID}) /casting "Grelleth's Royal Seal"

--- Remove illusions / mounts from clickies
-- downshit6=/if (!${Me.Moving} && !${Me.Invis} && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && !${Me.Binding} && !${Me.State.Equal[STUN]} && !${Me.Trader} && !${Stick.Active} && !${Me.Casting.ID}) /multiline ; /if (${illusionFlag} == 1 && ${Spell[Illusion: Gnoll Reaver].Stacks} && !${Me.Buff[Illusion: Gnoll Reaver].ID}) /casting "Amulet of Necropotence"; /if (${illusionFlag} == 1 && ${Me.Buff[Illusion: Skeleton].ID}) /varset illusionFlag 2; /if (${illusionFlag} == 2) /removebuff Illusion:
-- downshit7=/if (!${Me.Moving} && !${Me.Invis} && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && !${Me.Binding} && !${Me.State.Equal[STUN]} && !${Me.Trader} && !${Stick.Active} && !${Me.Casting.ID}) /multiline ; /if (${mountFlag} == 2 && ${Spell[Illusion: Gnoll Reaver].Stacks} && !${Me.Buff[Illusion: Gnoll Reaver].ID} && !${Zone.Indoor}) /casting "Bridle of Queen Velazul's Sokokar"; /if (${mountFlag} == 2 && ${Me.Buff[Mount Blessing Sana].ID} && ${Me.Mount.ID}) /varset mountFlag 1; /if (${mountFlag} == 1 && ${Me.Buff[Mount Blessing Sana].ID}) /multiline @ /varset mountFlag 0 @ /dismount
-- downshit8=/multiline ; /if (${mountFlag} == 0 && ${Spell[Mount Blessing Sana].Stacks} && !${Me.Buff[Mount Blessing Sana].ID} && !${Me.Mount.ID}) /varset mountFlag 2; /if (${illusionFlag} == 0 && !${Me.Buff[Illusion Benefit Greater Jann].ID}) /varset illusionFlag 1; /if (${illusionFlag} == 2 && !${Me.Buff[Illusion: Skeleton].ID}) /varset illusionFlag 0

--- Auto food
-- downshit9=/if (!${Me.Moving} && !${Me.Invis} && !${Me.Feigning} && !${Me.Ducking} && !${Me.Sneaking} && !${Me.AFK} && !${Me.Binding} && !${Me.State.Equal[STUN]} && !${Me.Trader} && !${Stick.Active} && !${Me.Casting.ID}) /multiline ; /if (${FindItemCount["=${autoFood}"]} < 16 && ${Cast.Ready[Wee'er Harvester]}) /casting "Wee'er Harvester"; /if (${FindItemCount["=${autoDrink}"]} < 16 && ${Cast.Ready[Bigger Belt of the River]}) /casting "Bigger Belt of the River"
-- downshit10=/multiline ; /if (${Cursor.Name.Equal[${autoFood}]} || ${Cursor.Name.Equal[${autoDrink}]}) /autoinv; /if (${Me.Hunger} < 6000 && ${FindItemCount["=${autoFood}"]} > 1) /useitem "${autoFood}"; /if (${Me.Thirst} < 6000 && ${FindItemCount["=${autoDrink}"]} > 1) /useitem "${autoDrink}"

--- Disable FD out of combat
-- downshit11=/if (${Me.Feigning}) /stand

--- Manage AA
-- downshit12=/multiline ; /if (${Me.Exp} >= 329 && ${Me.AAPoints} <= ${Math.Calc[${Me.Level} * 2]} && ${Window[AAWindow].Child[AAW_PercentCount].Text.NotEqual[100%]}) /alt on; /if (${Me.Exp} < 329 && ${Window[AAWindow].Child[AAW_PercentCount].Text.NotEqual[0%]}) /alt off
-- downshit13=/multiline ; /if (${AltAbility[Glyph of Fireworks I].CanTrain} && ${Macro.Paused} == NULL) /alt buy ${AltAbility[Glyph of Fireworks I].Index}; /if (${Me.AAPoints} >= 215 && ${Me.AltAbilityReady[Glyph of Fireworks I]}) /alt act ${Me.AltAbility[Glyph of Fireworks I].ID}

--- Stick to Target
-- holyshit1=/if (!${Stick.Active}) /squelch /stick loose 10
-- holyshit2=/if (!${Stick.Active}) /squelch /stick loose ${Math.Calc[${Target.MaxRangeTo}-3]}

--- Epic
-- holyshit3=/if (!${Me.State.Equal[STUN]} && !${Me.Casting.ID} && ${Cast.Ready[Transcended Fistwraps of Immortality]} && (${Me.PctHPs} < 80) && !${Me.Moving}) /casting "Transcended Fistwraps of Immortality"

--- Abilities
-- holyshit4=/if (${Me.PctEndurance} > 0 && !${Me.State.Equal[STUN]} && !${Me.Casting.ID} && ${Target.Type.NotEqual[PC]} && (${Target.Distance} < 50)) /multiline ; /if (${Me.CombatAbilityReady[Firewalker's Synergy Rk. II]}) /disc Firewalker's Synergy Rk. II; /if (${Me.CombatAbilityReady[Firestorm of Fists Rk. II]}) /disc Firestorm of Fists Rk. II
-- holyshit5=/if (${Me.PctEndurance} > 0 && !${Me.State.Equal[STUN]} && !${Me.Casting.ID} && (${Target.Distance} < 50)) /multiline ; /if (${Me.CombatAbilityReady[Hoshkar's Fang Rk. II]}) /disc Hoshkar's Fang Rk. II; /if (${Me.CombatAbilityReady[Curse of the Thirteen Fingers]}) /disc Curse of the Thirteen Fingers; /if (${Me.AltAbilityReady[Two-Finger Wasp Touch]}) /alt act ${Me.AltAbility[Two-Finger Wasp Touch].ID}
-- holyshit10=/multiline ; /if (${Me.AltAbilityReady[Infusion of Thunder]}) /alt act ${Me.AltAbility[Infusion of Thunder].ID}; /if (${Me.AltAbilityReady[Fundament: Second Spire of the Sensei]}) /alt act ${Me.AltAbility[Fundament: Second Spire of the Sensei].ID}; /if (${Me.AltAbilityReady[Zan Fi's Whistle]} && ${Me.PctEndurance} > 0) /alt act ${Me.AltAbility[Zan Fi's Whistle].ID}; /if (${Me.CombatAbilityReady[Tiger's Poise Rk. II]} && ${Me.PctEndurance} > 0) /disc Tiger's Poise Rk. II; /if (${Cast.Ready[Battleworn Stalwart Moon Soulforge Tunic]}) /casting "Battleworn Stalwart Moon Soulforge Tunic"
-- holyshit11=/if (${Me.CombatAbilityReady[Dichotomic Form]} && ${Me.PctEndurance} > 50) /disc 49132;

--- Stop Attacking if Target DS
-- holyshit6=/if (${Target.DSed.ID}) /multiline ; /echo ${Target} has DS; /target clear

