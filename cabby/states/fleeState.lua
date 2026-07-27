---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local FleeStateConfig = require("cabby.configs.fleeStateConfig")
local FleeStateMenu = require("cabby.ui.states.fleeStateMenu")
local FollowState = require("cabby.states.followState")
local Menu = require("cabby.ui.menu")
local Priorities = require("cabby.classes.priorities")
local SlashCmd = require("cabby.commands.slashcmd")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

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
---**How the suppressing is done** is a priority gate (see `stateMachine.RegisterPriorityGate`). At
---the passive band this state is stronger than everything except an order given to the character,
---and while it is on its gate holds the chain at that band with one exemption: FollowState. So the
---chain walks flee, skips cure/heal/dps/loot/anchor, runs follow, and skips buff/rest. Suppressing
---by *yielding* could not do this -- a state that returns false hands the turn to the next state
---down, which is the heal state, and one that returns true starves follow along with everything
---else. Two disjoint ranges have to go, and only the gate can say that.
---
---Follow is the exemption rather than a job of its own here because it is already the one state
---that knows how to keep up with somebody, work around a corner on their own trail, and click
---through the zone line they went out of -- all three of which are exactly what a long run is. A
---flee that reimplemented any of it would be a second follow to keep in step with the first.
---
---What it does *not* suppress is the services: movement, casting, the command queue, character
---discovery and combat all pulse every frame whatever the chain is doing. That is what keeps `flee
---off` reachable from chat, from the menu and from a hotbar button while the mode is on.
---@class FleeState : BaseState
local FleeState = {
    key = "FleeState",
    eventIds = {
        flee = "flee"
    },
    _ = {
        isInit = false
    }
}

---The states the flee gate lets through. Everything at or above the flee band runs anyway (an
---order given to this character is not what fleeing is meant to stop), so this is only ever about
---something further down the chain that is still worth doing while running.
local fleeExemptions = {
    [FollowState.key] = true
}

---@param str string
local function DebugLog(str)
    Debug.Log(FleeState.key, str)
end

---------------- Status --------------------

---@return string description of what this state is doing, for the page and /state
function FleeState.Describe()
    if not FleeState.IsEnabled() then return "standby" end

    local target = FollowState.GetFollowTarget()
    if target ~= "" then return "fleeing, following " .. target end
    return "fleeing, nothing to follow"
end

---------------- Init --------------------

---@param stateMachine StateMachine handed over by `BaseClass` as it registers the chain.
---
---Flee is the one state that talks to the state machine directly, because holding the rest of the
---chain back is not something a state can do from inside its own `Go()` -- a gate is how it is
---said, and the gate has to be registered somewhere.
---@diagnostic disable-next-line: duplicate-set-field
function FleeState.Init(stateMachine)
    if FleeState._.isInit then return end

    FleeStateConfig.Init()
    Menu.RegisterState(FleeState)

    if stateMachine == nil then
        -- without the gate this state can still be switched on and would then do nothing at all
        -- while claiming to, which is the one outcome worth being loud about
        print("(flee) FleeState.Init got no state machine: flee mode will not hold anything back")
    else
        stateMachine:RegisterPriorityGate(function()
            if not FleeState.IsEnabled() then return nil end
            -- the band is written onto the state by BaseClass at registration; the fallback is for
            -- a flee state initialized outside a class profile
            return FleeState.priority or Priorities.passive, fleeExemptions
        end)
    end

    ToggleCommand.Register({
        key = FleeState.key,
        phrase = FleeState.eventIds.flee,
        summary = "Turns travel mode on or off: follow, and nothing else",
        about = {
            "On, this character only follows -- it does not fight back, heal, buff or rest -- so",
            "a long run does not stop for every add on the way.",
            "It rides on top of a follow order rather than replacing one: give a (followme)",
            "first, or put both lines on the same hotbar button.",
            "Turning it on lets go of the fight, the cast in the air and the swing. Turning it",
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

---One pass.
---
---Fleeing is a mode about what must not happen and the gate is what makes that true, so this never
---holds the frame: it hands the turn straight down to follow, the one state the gate lets through.
---
---What is left is the swing. `/attack on` is the one commitment nothing else takes back -- the
---melee state issues it and never issues the other half, and it is not getting another turn in
---which to notice -- so auto attack is read from the client every pass and dropped whenever it is
---found on. Reading first is what keeps this from being a command sent forty times a second.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function FleeState.Go()
    if mq.TLO.Me.Combat() then
        DebugLog("Dropping auto attack while fleeing")
        mq.cmd("/attack off")
    end

    return false
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
    -- follow already running is the one movement task worth keeping: it is what we are about to be
    -- doing anyway, and cancelling it only costs a pass picking the trail back up
    if not Movement.IsOwnedBy(FollowState.key) then
        Movement.Stop()
    end

    if FollowState.GetFollowTarget() == "" then
        print("(flee) Nothing to follow -- this character will stand still until it is told to follow somebody")
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function FleeState.BuildMenu()
    FleeStateMenu.BuildMenu(FleeState)
end

return FleeState
