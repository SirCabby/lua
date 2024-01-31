local mq = require("mq")

local FollowState = require("cabby.states.followState")
local MeleeState = require("cabby.states.meleeState")

---@class Monk : BaseClass
local Monk = {}

---@param abilityName string
local function GetCombatAbilityFunction(abilityName)
    return function()
        if mq.TLO.Me.AbilityReady(abilityName) then
            mq.cmd("/doability " .. abilityName)
        end
    end
end

local function RegisterCombatAbilities()
    -- if mq.TLO.Me.Level() >= 30 and Character.HasAbility("Flying Kick") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Flying Kick"))
    -- elseif mq.TLO.Me.Level() >= 25 and Character.HasAbility("Tail Rake") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Tail Rake"))
    -- elseif mq.TLO.Me.Level() >= 25 and Character.HasAbility("Dragon Punch") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Dragon Punch"))
    -- elseif mq.TLO.Me.Level() >= 20 and Character.HasAbility("Eagle Strike") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Eagle Strike"))
    -- elseif mq.TLO.Me.Level() >= 10 and Character.HasAbility("Tiger Claw") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Tiger Claw"))
    -- elseif mq.TLO.Me.Level() >= 5 and Character.HasAbility("Round Kick") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Round Kick"))
    -- else
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Kick"))
    -- end

    -- if mq.TLO.Me.Level() >= 6 and Character.HasAbility("Intimidation") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Intimidation"))
    -- end

    -- if mq.TLO.Me.Level() >= 10 and Character.HasAbility("Disarm") then
    --     MeleeState.RegisterAbility(GetCombatAbilityFunction("Disarm"))
    -- end
end
    -- FD 17
    -- Mend 1

---@param stateMachine StateMachine
---@diagnostic disable-next-line: duplicate-set-field
Monk.Init = function(stateMachine)
    MeleeState.Init()
    -- RegisterCombatAbilities()

    FollowState.Init()

    stateMachine:Register(MeleeState)
    stateMachine:Register(FollowState)
end

return Monk
