---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Movement = require("utils.Movement.Movement")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local Menu = require("cabby.ui.menu")
local Mobs = require("cabby.mobs")
local Roles = require("cabby.roles")
local SlashCmd = require("cabby.commands.slashcmd")
local StandoffStateConfig = require("cabby.configs.standoffStateConfig")
local StandoffStateMenu = require("cabby.ui.states.standoffStateMenu")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

-- How far past the line to aim, so that arriving lands us outside it rather than exactly on it,
-- where a step in any direction would put us back inside. Flat rather than a fraction of anything
-- because what it buys is the same either way: room for a footstep.
local standoffMargin = 3
-- How close the walk has to get to the spot it aimed at to count as arrived. Bigger than a
-- MoveTo's default would be pointless precision for a retreat measured in units.
local arrivalSlack = 2
-- How long one retreat is given before the walk gives up. Evidence, not patience: a few units of
-- open ground take a moment, and anything still walking well past that is walking into something.
local retreatTimeoutMs = 8000
-- How far from the spot a retreat ran out of room the lesson still applies. Once we are further
-- away than this, we are somewhere else and what that spot could not do says nothing about here.
local heldAtSlack = 5

---Stand out of a rooted mob's reach, so the tank is the one in it.
---
---**A mob that cannot move hits whoever is standing in its reach.** That is the whole of it: reaching
---the thing it hates most is the one thing a root takes away, so it swings at what is there instead,
---and who is standing where stops being cosmetic and becomes the whole question of who takes the
---beating. The group's answer has two halves and they are held in two places, because they are two
---different jobs done by two different characters: the main tank closes until it is the nearest body
---(`states/meleeState.lua`, which is where the tank's positioning already lives), and everybody else
---gets behind it, which is this.
---
---**One mob, one comparison, and neither is a setting.** The mob is the one the group's main tank
---has hold of (`Combat.GetTankTargetId`) and nothing else in the zone is looked at -- a rooted add
---off to the side that nobody is fighting is not a question about who takes a beating, because
---nobody is taking one. The comparison is our distance to that mob against **the tank's** distance
---to it: further out than the tank is far enough, and that is the whole test.
---
---A mob's reach (`Mobs.Reach`) is in there once, as a gate and not as a target -- outside it we are
---not being hit at all, so nothing happens however anybody is standing. Using the tank rather than
---the reach as the line is what keeps the walk honest: backing out past a dragon's forty units takes
---a healer most of the way out of the fight to fix something the tank standing at fourteen had
---already fixed. Nobody is ever sent past about seventeen units, because melee range plus a step is
---the furthest the tank's own hold ever relaxes to.
---
---The tank half is the mirror and lives where the tank's positioning already lives (`holdRange` in
---`states/meleeState.lua`): it measures the other bodies near that same mob and closes inside
---whichever is nearest, as far as zero if that is what it takes. Neither half reads the other. Both
---read bodies and a mob, which is all either of them needs.
---
---**A pet is a body over there with no half of its own here.** It stands in the reach and gets hit
---like anybody, but it will not walk backwards: it holds its melee range on the mob until the fight
---is over, and calling it off its target to move it would be undoing an order its owner gave. So the
---pair does not settle from both ends on a pet the way it does on a person -- the tank gives all the
---ground, and more of it, because a pet is standing closer than a person would have been.
---
---**"Everybody else" is whoever is not already standing there on purpose, and the world is what
---says so.** A character swinging at that mob belongs in its reach and this is the state that would
---walk it out from under itself every pass, so two readings are taken before anything moves: the
---client's own attack toggle (`Me.Combat`, the one thing that means "we are hitting something"),
---and whether a stick is running, which is the same job a moment earlier, on its way in and not yet
---swinging. The main tank is the third exemption and the only one named, since being
---nearest is its job. Nothing is asked about anyone's class and nobody is listed: what is left over
---is the healer between heals, the caster out of mana, the hybrid whose swing is off -- exactly the
---people with no business standing in a mob's reach.
---
---**That answer used to come from the chain, for free, and it was free at the wrong price.** Down at
---the old band below the rotations, a state with work in hand was busy above this one and the pass
---never got this far -- which is a fine way to leave a melee alone, and a terrible one for the
---healer the state was written for. A healer *is* reached down there, between casts, but a heal in
---flight starves everything weaker than it (the casting floor) *and* outranks the walk already
---running, so every retreat a healer began was cancelled by their own next heal -- and a retreat
---that ends short marks the spot as one with no room left, which stops the pass after that from
---trying. The character taking the worst of a rooted mob was the one character guaranteed never to
---step out of it. At `Priorities.standoff` the step back is what outranks the cast instead.
---
---**A retreat holds the frame while it runs**, which costs more up here than it did below: a heal is
---among the things starved for the second or two of walking. It is not optional. The movement
---service carries one task and gives it to whoever asked last, so the follow below would start its
---own walk over the top of ours the moment we yielded -- and a heal cannot be cast on the move
---anyway, so what the frame costs is a wait the arbitration was already going to impose.
---
---**Sight is what stops it, and it is read by walking.** There is no asking the world what can be
---seen from a spot we are not standing on, so the retreat is watched rather than planned: while the
---mob is in sight it keeps going, and the pass the mob goes out of sight is the pass it stops. A
---retreat that ran out of room -- sight, a wall, anything -- marks the spot it ran out at, and while
---we are still standing there nothing tries again. The mark is a measurement and dies like one: the
---mob leaving the fight, the root dropping, or us ending up somewhere else all spend it. Nothing here
---is timed, and nothing gives up because it has been a while.
---@class StandoffState : BaseState
local StandoffState = {
    key = "StandoffState",
    eventIds = {
        standoff = "standoff"
    },
    _ = {
        isInit = false,
        -- the mob a retreat of ours is currently backing away from, and the walk doing it
        retreat = nil,
        -- where a retreat ran out of room, and off which mob. Held because the world cannot say it
        -- twice: a spot that has no way out backward looks exactly like one that has
        heldAt = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(StandoffState.key, str)
end

---@param id number
---@return any spawn mq spawn TLO
local function spawnOf(id)
    return mq.TLO.Spawn("id " .. tostring(id))
end

---Where the group's main tank is standing, if there is a tank in the zone to stand behind.
---
---Read by coordinates, the way `states/meleeState.lua` reads the rest of the group and for the same
---reason: there is no asking the world for another player's distance to a third spawn, and their
---client is not something this one can interrogate. What can be had is two positions and a
---subtraction.
---
---**A main tank is a group role and only a group role** (see `cabby.roles`), which is the right
---answer inside a raid as well: the tank of *this* group is the body standing between this character
---and the thing hitting it, whoever else the raid has named.
---
---Nil is **"there is no tank body here"** -- the group has not named one, they are out of the zone,
---or they are dead -- and it is a different answer from "the tank is far away". A caller that read
---it as a large number would decide it was standing behind somebody who is not there.
---@return number|nil y
---@return number|nil x
---@return number|nil z
local function tankPosition()
    local tank = Roles.GetMainTank()
    if tank == nil or (tank.id or 0) < 1 then return nil end

    local spawn = spawnOf(tank.id)
    if (spawn.ID() or 0) < 1 or spawn.Dead() then return nil end

    local y, x, z = spawn.Y(), spawn.X(), spawn.Z()
    if y == nil or x == nil or z == nil then return nil end
    return y, x, z
end

---The tank's mob, if we are standing in front of the tank on it.
---
---**One mob, and it is the one the group's main tank has hold of** (`Combat.GetTankTargetId`).
---That is the whole scope of this: who stands where only decides who takes a beating on a mob that
---cannot walk to its hate target, and the mob that matters is the one the tank is holding. A rooted
---add off to the side that nobody is fighting is not this state's business, and neither is anything
---else in the roster.
---
---**Then one comparison, and it is against the tank.** Reach (`Mobs.Reach`) says only whether the
---mob can hit us at all -- outside it we are not being hit and there is nothing to fix however
---anybody is standing. Inside it, the question stops being about the mob and becomes *are we in
---front of the body it is supposed to be swinging at*, which is two positions and a subtraction.
---Further out than the tank is far enough; that is the entire test, and it is why nobody is walked
---most of the way out of a fight to get past a dragon's forty units when the tank standing at
---fourteen had already settled it.
---
---Nil where the tank cannot be found or placed -- no main tank named, out of the zone, dead, or
---nobody here can say what it is on. That is "no comparison to make", and standing still is what
---not knowing deserves; it is emphatically not "back out of everything", which is the absolute
---answer this state used to give and the one being deliberately left behind.
---
---Sight is part of being a problem rather than a detail of the retreat: a mob we cannot see is one
---we cannot judge, cannot be swung at by through whatever is between us, and cannot walk away from
---with any idea of where we are going.
---@return number|nil id the tank's mob
---@return number|nil distance how close we are standing to it
---@return number|nil line how close the tank is standing to it, which is as close as we may be
local function crowdingTankMob()
    local id = Combat.GetTankTargetId()
    if id == nil or id < 1 then return nil end
    if not Mobs.IsRooted(id) then return nil end

    local spawn = spawnOf(id)
    local reach = Mobs.Reach(id)
    local distance = spawn.Distance3D()

    -- Out of its reach is not being hit by it, whoever else is standing where. Asked before the tank
    -- is, so that a tank running in from thirty units is never read as a line to get behind on a mob
    -- that cannot touch us in the first place.
    if reach == nil or distance == nil or distance >= reach then return nil end
    if not spawn.LineOfSight() then return nil end

    local tankY, tankX, tankZ = tankPosition()
    if tankY == nil then return nil end

    local mobY, mobX, mobZ = spawn.Y(), spawn.X(), spawn.Z()
    if mobY == nil or mobX == nil or mobZ == nil then return nil end

    local line = Geometry.Distance3D(tankY, tankX, tankZ, mobY, mobX, mobZ)
    if distance >= line then return nil end

    return id, distance, line
end

---Is somebody already holding this character where it is standing?
---
---What the chain used to answer by never handing this band a frame during a fight. Two readings,
---both of the world and neither of any state:
---
---**We are swinging.** `Me.Combat` is the client's own attack toggle and the only fact that says
---"this character is hitting something"; a body in a mob's reach with its swing going is a body
---doing a job in there, and backing it out is undoing the job rather than doing this one. Nothing
---in cabby turns that toggle on but the melee state (through `Combat.SetAutoAttack`), so a caster
---with no melee of its own reads false here and is still walked out, which is the whole point.
---Deliberately not `Combat.IsEngaged`: a character can be in a fight and have no business in the
---reach of the mob the tank is holding, and that is precisely who this state is for.
---
---**Or a stick is running.** The same job one moment earlier -- on its way in, inside the mob's
---reach already and not yet close enough or turned enough for the swing to have started. Without it
---a melee walking in is met halfway by a retreat, walked back out, and starts over. Which spawn the
---stick is on is not asked: sticking to an add while standing in the rooted mob's reach is still a
---job that put us here, and giving that ground would lose the add instead.
---@return boolean isHeld
local function standingOnPurpose()
    if mq.TLO.Me.Combat() == true then return true end

    return Movement.GetTaskType() == Movement.taskTypes.stick
end

---Write down that a retreat from this mob ran out of room where we are standing.
---@param id number
---@param why string in words, for the page and the log
local function markHeldAt(id, why)
    local y, x = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if y == nil or x == nil then return end

    StandoffState._.heldAt = { id = id, y = y, x = x, why = why }
    DebugLog("Backed off " .. tostring(id) .. " as far as this spot allows: " .. why)
end

---Are we standing where a retreat from this mob already ran out of room?
---@param id number
---@return boolean isHeld
local function isHeldAt(id)
    local heldAt = StandoffState._.heldAt
    if heldAt == nil or heldAt.id ~= id then return false end

    local y, x = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if y == nil or x == nil then return false end

    return Geometry.Distance2D(y, x, heldAt.y, heldAt.x) <= heldAtSlack
end

---Let go of a retreat of ours, without touching one somebody else is running.
local function release()
    StandoffState._.retreat = nil
    Movement.StopFor(StandoffState.key)
end

---One pass of a retreat already running: does it keep going?
---@param retreat table
---@return boolean isBusy
local function driveRetreat(retreat)
    local spawn = spawnOf(retreat.id)

    -- Nothing to back away from any more: it died, it went, or the root dropped and it is free to
    -- follow us wherever we were going. Giving ground to a mob that can take it back is a fight
    -- walked across the zone a step at a time, which is exactly what `Stick:ShouldMoveBack` refuses
    -- to do for the same reason.
    if (spawn.ID() or 0) < 1 or spawn.Dead() or not Mobs.IsRooted(retreat.id) then
        DebugLog("Nothing left to stand off from, ending the retreat")
        release()
        return false
    end

    -- The world answering the question the destination could not be asked: this is as far out as
    -- this spot goes. Stopped on the pass it says so rather than a step later.
    if not spawn.LineOfSight() then
        Movement.StopFor(StandoffState.key)
        StandoffState._.retreat = nil
        markHeldAt(retreat.id, "backing up any further loses sight of it")
        return true
    end

    return true
end

---A retreat of ours that is no longer running: what, if anything, we learned from it.
---
---Arriving is the ordinary end and says nothing worth writing down. Ending while we are **still**
---inside the line is a spot with no way out backward -- the walk hit a wall, ran out of time, or was
---taken off us -- and saying so is the whole of what keeps the next pass from starting the identical
---walk from the identical spot, forever. The mark costs nothing if we were wrong about it: it is
---spent the moment we are standing somewhere else, which is exactly what being taken off us leads
---to.
---
---The line is asked for again rather than taken off the retreat, because it moves while the walk
---runs -- the tank closing in lowers it, and a walk that was going to fall short of the old one may
---be standing comfortably past the new one.
---@param retreat table
local function endRetreat(retreat)
    StandoffState._.retreat = nil

    local id = crowdingTankMob()
    if id == retreat.id then
        markHeldAt(retreat.id, "the walk ended short of the room I wanted")
    end
end

---One pass of standing behind the tank on the mob it is holding.
---
---Everything is decided here, from the world: what the tank has hold of, whether it is rooted,
---whether it can reach us, whether we can see it, where the tank is standing, and whether backing
---away from where we stand has already been tried. Nothing is remembered except the walk in progress
---and the spot one ran out at.
---@return boolean isBusy
local function standoff()
    -- Being nearest is the tank's job, and this is the state that would undo it every pass
    if Roles.IsMainTank() then
        if StandoffState._.retreat ~= nil then release() end
        return false
    end

    -- Already standing there on purpose: see the note on the band. Read here rather than left to
    -- the chain, which said it for nothing while this sat below the rotations and says nothing at
    -- all from above them.
    if standingOnPurpose() then
        if StandoffState._.retreat ~= nil then release() end
        return false
    end

    local retreat = StandoffState._.retreat
    if retreat ~= nil then
        -- ours and still walking, or over -- either way the answer is re-derived rather than assumed
        if Movement.IsOwnedBy(StandoffState.key) and Movement.IsMovingTo() then
            return driveRetreat(retreat)
        end
        endRetreat(retreat)
    end

    local id, distance, line = crowdingTankMob()
    if id == nil then
        -- standing clear of everything: whatever a spot could not do for us is not worth carrying
        StandoffState._.heldAt = nil
        return false
    end

    if isHeldAt(id) then return false end
    StandoffState._.heldAt = nil

    local spawn = spawnOf(id)
    local mobY, mobX = spawn.Y(), spawn.X()
    local myY, myX = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if mobY == nil or mobX == nil or myY == nil or myX == nil then return false end

    -- Straight back along the line between us, which is the one bearing that keeps whatever we can
    -- see of it in front of us the whole way -- and the one a step of which is a step out of its
    -- reach rather than around it.
    local rad = math.rad(Geometry.HeadingTo(mobY, mobX, myY, myX))
    local want = line + standoffMargin
    local destY = mobY + math.cos(rad) * want
    local destX = mobX + math.sin(rad) * want

    -- resolved once: Describe() is read by the state page every rendered frame, and neither a spawn
    -- search nor a reading of where the tank is standing belongs in the render path
    local name = spawn.CleanName() or tostring(id)
    DebugLog(string.format("In front of the tank on %s -- us at %.0f, tank at %.0f: backing to %.0f, %.0f",
        name, distance or 0, line, destY, destX))

    StandoffState._.retreat = {
        id = id,
        name = name,
        line = line,
        taskId = Movement.MoveToLoc(destY, destX, {
            owner = StandoffState.key,
            priority = StandoffState.priority,
            distance = arrivalSlack,
            timeoutMs = retreatTimeoutMs
        })
    }
    return true
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
---
---Read out of what the last pass decided rather than re-deciding it: the page redraws every rendered
---frame, and deciding it means a spawn search for the mob and another for the tank.
function StandoffState.Describe()
    if Roles.IsMainTank() then return "main tank -- standing in, not off" end

    local retreat = StandoffState._.retreat
    if retreat ~= nil then
        return string.format("backing off %s to behind the tank (%.0f)", retreat.name, retreat.line)
    end

    local heldAt = StandoffState._.heldAt
    if heldAt ~= nil and isHeldAt(heldAt.id) then
        return "as far off as this spot allows -- " .. heldAt.why
    end

    return "standby"
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function StandoffState.Init()
    if StandoffState._.isInit then return end

    StandoffStateConfig.Init()
    Menu.RegisterState(StandoffState)

    ToggleCommand.Register({
        key = StandoffState.key,
        phrase = StandoffState.eventIds.standoff,
        summary = "Turns standing out of a rooted mob's reach on or off for listener(s)",
        about = {
            "A rooted mob hits whoever is standing in its reach, so everyone but the main tank",
            "backs behind it -- straight back, and only while the mob stays in sight. Only the",
            "tank's own target is looked at, and how far out is measured against where the tank",
            "is standing rather than set anywhere.",
            "Pets have no half here: they hold their ground, so the tank closes inside them.",
            "It only ever reaches a character with nothing else to do in the fight: anything with",
            "a job in hand is busy at a band above this one and is never moved.",
            "The other half is the tank closing in (the Melee State page's roottank switch)."
        },
        get = StandoffState.IsEnabled,
        set = StandoffState.SetEnabled
    })

    local cstandoffDocs = ChelpDocs.new(function() return {
        "(/cstandoff) Report what this character is standing off from, and how far",
        " -- Usage: /cstandoff",
        " -- Usage (turn it on or off): /cstandoff <on | off>",
        " -- Only the group's main tank's own target is looked at, and only while it reads as",
        "    rooted -- nothing else in the zone moves this character.",
        " -- How far out is measured, not set here: a step past wherever the tank is standing.",
        "    Standing further out than the tank already is nothing to fix.",
        " -- Rooted is read off the mob's own debuffs while it is somebody's target -- see /cmobs.",
        " -- The main tank never stands off: being the nearest body is its job."
    } end )
    local function Bind_CStandoff(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cstandoffDocs:Print()
            return
        end

        if #args > 0 then
            if UserInput.IsTrue(args[1]) then
                StandoffState.SetEnabled(true)
                return
            end
            if UserInput.IsFalse(args[1]) then
                StandoffState.SetEnabled(false)
                return
            end
            cstandoffDocs:Print()
            return
        end

        print("Standoff: " .. StandoffState.Describe())
        print(" -- only the main tank's own target is looked at, and only while it reads as rooted")
        print(" -- room kept is measured, not set: a step past wherever the tank is standing")
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cstandoff", Bind_CStandoff, cstandoffDocs))

    StandoffState._.isInit = true
end

---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function StandoffState.Go()
    return standoff()
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
StandoffState.IsEnabled = function()
    return StandoffStateConfig.IsEnabled()
end

---Switching it off has to call off the walk it started, not just stop it being asked for another
---turn: the retreat is the movement service's now and would carry on backing away from a mob this
---character was just told to stop worrying about.
---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
StandoffState.SetEnabled = function(isEnabled)
    StandoffStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        release()
        StandoffState._.heldAt = nil
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function StandoffState.BuildMenu()
    StandoffStateMenu.BuildMenu(StandoffState)
end

return StandoffState
