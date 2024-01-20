local mq = require("mq")
local CabbyAction = require("cabby.actions.cabbyAction")
local Character = require("cabby.character")
local FollowState = require("cabby.states.followState")
local MeleeState = require("cabby.states.meleeState")

---@type Class
local Warrior = {}

---@param abilityName string
local function GetCombatAbilityFunction(abilityName)
    return function()
        if mq.TLO.Me.AbilityReady(abilityName) then
            mq.cmd("/doability " .. abilityName)
        end
    end
end

local function RegisterCombatAbilities()
    MeleeState.RegisterAction(CabbyAction.new("Kick", true, function()
        if mq.TLO.Me.AbilityReady("kick") and mq.TLO.Target.Distance() < 14 and MeleeState.IsFacingTarget() then
            mq.cmd("/doability kick")
        end
    end,
    "Kick"))

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
    -- skip while stun / mez / etc...w
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
