local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local Timer = require("utils.Time.Timer")

local Action = require('cabby.actions.action')
local ActionCommand = require("cabby.commands.actionCommand")
local Combat = require("cabby.combat")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local MeleeStateMenu = require("cabby.ui.states.meleeStateMenu")
local Menu = require("cabby.ui.menu")
local Skills = require("cabby.actions.skills")
local Status = require('cabby.status')
local ToggleCommand = require("cabby.commands.toggleCommand")

-- How long "As Needed" waits between tanking actions so they fire one at a time
local sequentialActionDelayMs = 1500

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
        stick = "stick",
        tanking = "tanking"
    },
    _ = {
        isInit = false,
        retargetTimer = nil,
        stickTargetId = 0,
        tauntTimer = Timer.new(sequentialActionDelayMs),
        hateTimer = Timer.new(sequentialActionDelayMs)
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeState.key, str)
end

---@return boolean isIncapacitated
local function IsIncapacitated()
    return mq.TLO.Me.Stunned() or mq.TLO.Me.Mezzed() ~= nil or mq.TLO.Me.Charmed() ~= nil or mq.TLO.Me.Binding() or mq.TLO.Me.Casting() ~= nil
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
    if mq.TLO.Me.Feigning() or mq.TLO.Me.Ducking() then
        mq.cmd("/stand")
    end

    if mq.TLO.Me.Sneaking() then
        mq.cmd("/doability sneak")
    end
end

function MeleeState.GetSpawnMeleeRange(id)
    local maxRangeTo = mq.TLO.Spawn(id).MaxRangeTo()
    if maxRangeTo == nil then return 14 end
    return math.min(14, maxRangeTo - 3)
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

    MeleeState._.stickTargetId = Combat.GetTargetId()
    Movement.Stick(MeleeState._.stickTargetId, { distance = range, owner = MeleeState.key })
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
        -- let go of anything we were holding onto for a fight that is over
        if MeleeState._.stickTargetId ~= 0 then
            MeleeState._.stickTargetId = 0
            Movement.StopFor(MeleeState.key)
        end
        return false
    end

    -- Swinging needs the client on the target, which casting a heal at a group member takes away
    -- from us. Ask again on a timer rather than every frame: /mqtarget is a game command and the
    -- server answers when it answers.
    if mq.TLO.Target.ID() ~= targetId then
        if MeleeState._.retargetTimer:timer_expired() then
            mq.cmd("/mqtarget npc id " .. tostring(targetId))
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

    local range = MeleeState.GetSpawnMeleeRange(targetId)

    if MeleeStateConfig.GetStick() and not Movement.IsSticking(targetId) and distance < MeleeStateConfig.GetEngageDistance() and mq.TLO.Target.LineOfSight() then
        MeleeState.StickToCurrentTarget(range)
    end

    -- StickToCurrentTarget can yield too, so keep using the snapshot rather than re-reading
    if distance < range then
        if not mq.TLO.Me.Combat() and Status:IsFacingTarget() then
            mq.cmd("/attack on")
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
    end

    return true
end

---@return boolean isAttacking whether this state is fighting something right now
function MeleeState.IsAttacking()
    return Combat.IsEngaged()
end

---Stop meleeing, without deciding anything about the fight itself: whether we are still engaged
---is Combat's answer, and calling this off is not the same as calling that off.
function MeleeState.Reset()
    MeleeState._.retargetTimer = Timer.new(0)
    MeleeState._.stickTargetId = 0
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
            summary = "Turns sticking to the attack target on or off",
            about = {
                "Off holds position and only swings at what comes into reach.",
                "Turning it off also releases a stick already running."
            },
            get = MeleeStateConfig.GetStick,
            set = MeleeState.SetStick
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

---Turn sticking on or off. The setting only governs whether a *new* stick is started, so turning
---it off releases the one in progress as well -- otherwise the character keeps chasing the target
---it was just told to stand off from.
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

