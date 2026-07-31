---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local FleeStateConfig = require("cabby.configs.fleeStateConfig")
local FleeStateMenu = require("cabby.ui.states.fleeStateMenu")
local Menu = require("cabby.ui.menu")
local Pet = require("cabby.pet")
local SlashCmd = require("cabby.commands.slashcmd")
local ToggleCommand = require("cabby.commands.toggleCommand")
local Travel = require("cabby.travel")
local UserInput = require("cabby.utils.userinput")

---How long an unanswered `/pet back off` is left before it is said again. Pacing, not giving up:
---the answer is the pet turning round, which is a server round trip away.
local petBackOffRetryMs = 1500

---Travel mode: follow, and nothing else.
---
---This is the state whose job is what must *not* happen. A group crossing four zones does not want
---each character stopping to fight back at every add, to top somebody off, to re-buff whoever the
---last mob dispelled or to sit down every time the run pauses for a moment -- and switching each of
---those off one at a time is both several orders and a set of settings to remember to put back.
---
---**It suppresses rather than configures**, which is the whole reason it is a state and not a
---script that flips the other states off. Nothing it does is persisted onto anything else: the heal
---list, the melee switch and the buff list are exactly as they were when the order arrived, and
---`flee off` hands the character back to its normal chain with no restoring to get wrong -- and no
---way for a crash mid-run to leave a cleric that has quietly stopped healing.
---
---**How the suppressing is done is the ordinary release protocol**: at the passive band this state
---is stronger than everything except an order given to the character, and while the mode is on its
---`Go()` returns busy every pass -- so the chain never reaches anything below it, exactly as it
---never reaches below any other busy state. No gate, no exemption, no shape the ordering cannot
---express: suppression *is* position plus busy, here as everywhere.
---
---**The traveling is this state's own job while the mode is on.** The machinery -- the follow
---order, the trail-walking, the anchor, the zone-line follow-throughs -- is `cabby.travel`, the
---same core the follow state drives at the follow band in normal operation. The chain serializes
---the two drivers: flee sits above follow and is busy for as long as it is enabled, so there is
---never a pass in which both run, and neither state knows the other exists. An anchor holds
---through a flee for the same reason a follow does: it is a standing order in the same core.
---
---What it does *not* suppress is the services: movement, casting, the command queue, character
---discovery and combat all pulse every frame whatever the chain is doing. That is what keeps `flee
---off` reachable from chat, from the menu and from a hotbar button while the mode is on. A cast
---put in the air by hand (`/ccast`) mid-run pauses the walk at the movement service -- which
---refuses to drive through a cast -- and the run resumes when it lands.
---@class FleeState : BaseState
local FleeState = {
    key = "FleeState",
    eventIds = {
        flee = "flee"
    },
    _ = {
        isInit = false,
        ---when the pet was last told to let go of what it was on, for the pacing above
        petCalledAtMs = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(FleeState.key, str)
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
function FleeState.Describe()
    if not FleeState.IsEnabled() then return "standby" end

    local target = Travel.GetFollowTarget()
    if target ~= "" then return "fleeing, following " .. target end
    return "fleeing, nothing to follow"
end

---------------- Init --------------------

---@diagnostic disable-next-line: duplicate-set-field
function FleeState.Init()
    if FleeState._.isInit then return end

    FleeStateConfig.Init()
    Menu.RegisterState(FleeState)

    ToggleCommand.Register({
        key = FleeState.key,
        phrase = FleeState.eventIds.flee,
        summary = "Turns travel mode on or off: follow, and nothing else",
        about = {
            "On, this character only follows -- it does not fight back, heal, buff or rest -- so",
            "a long run does not stop for every add on the way.",
            "It rides on top of a follow order rather than replacing one: give a (followme)",
            "first, or put both lines on the same hotbar button.",
            "Turning it on lets go of the fight, the cast in the air, the swing and the pet. Turning it",
            "off hands the character straight back to its normal chain; nothing was reconfigured."
        },
        get = FleeState.IsEnabled,
        set = FleeState.SetEnabled
    })

    local cfleeDocs = ChelpDocs.new(function() return {
        "(/cflee) Report whether this character is in travel mode, and what it is holding back",
        " -- Usage: /cflee",
        " -- Usage (turn it on or off): /cflee <on | off>"
    } end )
    local function Bind_CFlee(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cfleeDocs:Print()
            return
        end

        if #args > 0 then
            if UserInput.IsTrue(args[1]) then
                FleeState.SetEnabled(true)
                return
            end
            if UserInput.IsFalse(args[1]) then
                FleeState.SetEnabled(false)
                return
            end
            cfleeDocs:Print()
            return
        end

        print("Flee: " .. FleeState.Describe())
        if FleeState.IsEnabled() then
            print(" -- holding back: everything except following (fighting, healing, buffing, resting)")
            print(" -- still running: orders, the menu and hotbar buttons")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cflee", Bind_CFlee, cfleeDocs))

    -- the one switch that is easy to have left on from another session, and the only sign of it
    -- otherwise is a character that quietly refuses to do its job
    if FleeState.IsEnabled() then
        print("Cabby: flee is ON -- this character will follow and nothing else. Say `flee off` to end it.")
    end

    FleeState._.isInit = true
end

---One pass of travel mode: drive the traveling, hold the frame.
---
---Returning busy every pass is the suppression -- see the notes on this module. Before that, the
---two things still swinging after everything below has been starved.
---
---The swing: `/attack on` is the one commitment nothing else takes back -- the melee state issues
---it, and its range gate, the one thing that ever takes it back, is not getting another turn -- so
---auto attack is read from the client every pass and dropped whenever it is found on. Reading
---first is what keeps this from being a command sent forty times a second.
---
---The pet is the other one, and it is here for exactly the same reason: `PetDpsState` would call
---it off the moment the fight closed, and it sits at the dps band, which is starved for as long as
---this mode is on. A warder still chewing on what the group is running from brings it along. Read
---first as above, and paced on top of that, because what the client says about a pet is a beat
---behind what it was told.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function FleeState.Go()
    if mq.TLO.Me.Combat() then
        DebugLog("Dropping auto attack while fleeing")
        mq.cmd("/attack off")
    end

    -- and only to a pet that is listening: an enchanter's animation takes no orders at all (see
    -- `cabby.pet`), so saying this to one is a command every second and a half for the length of
    -- the run at something that cannot hear it
    if Pet.IsFighting() and Pet.TakesOrders().backOff then
        local calledAt = FleeState._.petCalledAtMs
        if calledAt == nil or Time.current_time() - calledAt >= petBackOffRetryMs then
            DebugLog("Calling the pet off while fleeing")
            FleeState._.petCalledAtMs = Time.current_time()
            Pet.BackOff("fleeing")
        end
    else
        FleeState._.petCalledAtMs = nil
    end

    Travel.Drive()

    return true
end

---@return boolean isFleeing whether travel mode is on. The switch and the state being enabled are
---the same thing here: there is nothing for this state to do while it is not fleeing
---@diagnostic disable-next-line: duplicate-set-field
FleeState.IsEnabled = function()
    return FleeStateConfig.IsEnabled()
end

---Turning it on is where the letting go happens.
---
---The mode itself only holds the chain back, and a cast already in the air, a fight already picked
---and a stick already chasing something all date from before the order arrived -- the states that
---would have tidied them up are the states that are about to stop getting turns. Auto attack is the
---exception: `Go()` drops that every pass, because it is the one that can be switched back on by
---hand while the mode is running.
---
---The pet is the other exception, and it is left to `Go()` for the same reason auto attack is: it
---can be sent back in by hand while the mode is running, and one pass later it is dropped again.
---
---Each of these is a *request* rather than a game command, which is what makes this safe to call
---from the menu checkbox and from a hotbar button.
---@param isEnabled boolean
---@diagnostic disable-next-line: duplicate-set-field
FleeState.SetEnabled = function(isEnabled)
    local wasFleeing = FleeStateConfig.IsEnabled()
    FleeStateConfig.SetEnabled(isEnabled)

    if not isEnabled or wasFleeing then return end

    DebugLog("Fleeing: letting go of the fight, the cast and the stick")
    Casting.Interrupt()
    Combat.Disengage("fleeing")

    -- a stick started by melee would go on holding range on the very thing we are running from. A
    -- travel task already running -- a follow, or the walk back to an anchor -- is the one kind
    -- worth keeping: it is what we are about to be doing anyway, and cancelling it only costs a
    -- pass picking the trail back up
    if not Movement.IsOwnedBy(Travel.key) then
        Movement.Stop()
    end

    if Travel.GetFollowTarget() == "" then
        print("(flee) Nothing to follow -- this character will stand still until it is told to follow somebody")
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function FleeState.BuildMenu()
    FleeStateMenu.BuildMenu(FleeState)
end

return FleeState
