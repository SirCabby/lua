local mq = require("mq")
local CabbyAction = require("cabby.actions.cabbyAction")
local FollowState = require("cabby.states.followState")
local MeleeState = require("cabby.states.meleeState")

---@type Class
local Warrior = {}

local function RegisterCombatAbilities()
    MeleeState.RegisterAction(CabbyAction.new("Taunt", true, function()
        if mq.TLO.Me.AbilityReady("Taunt") and mq.TLO.Target.Distance() < 14 and MeleeState.IsFacingTarget() then
            mq.cmd("/doability Taunt")
        end
    end,
    "Taunt"))

    MeleeState.RegisterAction(CabbyAction.new("Disarm", true, function()
        if mq.TLO.Me.AbilityReady("Disarm") and mq.TLO.Target.Distance() < 14 and MeleeState.IsFacingTarget() then
            mq.cmd("/doability Disarm")
        end
    end,
    "Disarm"))

    -- skill range
    -- skip while stun / mez / etc...
end

---@param stateMachine StateMachine
---@diagnostic disable-next-line: duplicate-set-field
Warrior.Init = function(stateMachine)
    MeleeState.Init()
    RegisterCombatAbilities()

    FollowState.Init()

    stateMachine:Register(MeleeState)
    stateMachine:Register(FollowState)
end

return Warrior
