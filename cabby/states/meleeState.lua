local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Timer = require("utils.Time.Timer")
local StringUtils = require("utils.StringUtils.StringUtils")

local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local Menu = require("cabby.menu")
local UserInput = require("cabby.utils.userinput")

local function passive()
    return false
end

---@class State
local MeleeState = {
    key = "MeleeState",
    eventIds = {
        attack = "attack"
    },
    _ = {
        isInit = false,
        currentAction = passive,
        currentActionTimer = nil,
        currentTargetID = 0,
        meleeActions = {
            checkForCombat = passive,
            attackTarget = passive
        },
        registrations = {
            abilities = {}
        }
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(MeleeState.key, str)
end

local function Reset()
    MeleeState._.currentAction = MeleeState._.meleeActions.checkForCombat
    MeleeState._.currentTargetID = 0
    MeleeState._.currentActionTimer = Timer.new(0)
    mq.cmd("/stick off")
end

---@return boolean isIncapacitated
local function IsIncapacitated()
    return mq.TLO.Me.Stunned() or mq.TLO.Me.Mezzed() ~= nil or mq.TLO.Me.Charmed() ~= nil or mq.TLO.Me.Binding() or mq.TLO.Me.Casting() ~= nil
end

local function FixCombatState()
    if mq.TLO.Me.Feigning() or mq.TLO.Me.Ducking() then
        mq.cmd("/stand")
    end

    if mq.TLO.Me.Sneaking() then
        mq.cmd("/doability sneak")
    end
end

local function GetSpawnMeleeRange(id)
    return math.min(14, mq.TLO.Spawn(id).MaxRangeTo() - 3)
end

---@param range number
local function StickToCurrentTarget(range)
    if MeleeStateConfig.GetStick() then
        mq.cmd("/stick id " .. tostring(MeleeState._.currentTargetID) .. " loose " .. range)
    end
end

---@param id number
local function EngageTargetId(id)
    mq.cmd("/mqtarget npc id " .. tostring(id))
    MeleeState._.currentTargetID = id
    MeleeState._.currentAction = MeleeState._.meleeActions.attackTarget
    MeleeState._.currentActionTimer = Timer.new(500)
end

MeleeState._.meleeActions.checkForCombat = function()
    -- Am I under attack?
    if MeleeStateConfig:GetAutoEngage() and mq.TLO.Me.CombatState() == "COMBAT" then
        for i = 1, 20 do
            local xtarget = mq.TLO.Me.XTarget(i)
            if xtarget.TargetType() == "Auto Hater" and xtarget.ID() > 0 then
                EngageTargetId(xtarget.ID())
                return true
            end
        end
    end
    return false
end
MeleeState._.currentAction = MeleeState._.meleeActions.checkForCombat

MeleeState._.meleeActions.attackTarget = function()
    -- Not on target? If timed out re-aquire target
    if mq.TLO.Target.ID() ~= MeleeState._.currentTargetID then
        if MeleeState._.currentActionTimer:timer_expired() then
            Reset()
        end
        return true
    end

    if mq.TLO.Target.Dead() then
        Reset()
        return true
    end

    if IsIncapacitated() then
        return true
    end

    FixCombatState()

    local range = GetSpawnMeleeRange(MeleeState._.currentTargetID)

    if MeleeStateConfig.GetStick() and not mq.TLO.Stick.Active() and mq.TLO.Target.Distance() < MeleeStateConfig.GetEngageDistance() and mq.TLO.Target.LineOfSight() then
        StickToCurrentTarget(range)
    end

    if mq.TLO.Target.Distance() < range then
        if not mq.TLO.Me.Combat() then
            mq.cmd("/attack on")
        end

        for _, meleeFunc in ipairs(MeleeState._.registrations.abilities) do
            ---@type CabbyAction
            meleeFunc = meleeFunc
            if meleeFunc.enabled then
                meleeFunc.actionFunction()
            end
        end
    end

    return true
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Init()
    if not MeleeState._.isInit then
        Menu.RegisterState(MeleeState)

        local function event_Attack(_, speaker, args)
            args = StringUtils.Split(StringUtils.TrimFront(args))

            if #args < 1 then return end

            if UserInput.IsFalse(args[1]:lower()) then
                Reset()
                return
            end

            local targetId = tonumber(args[1])
            if targetId == nil or mq.TLO.SpawnCount("id " .. args[1] .. " radius 400 los")() < 1 then return end

            if Commands.GetCommandOwners(MeleeState.eventIds.attack):HasPermission(speaker) then
                DebugLog("MeleeAttack speaker [" .. speaker .. "] targetId: [ " .. targetId .. "]")
                EngageTargetId(targetId)
                StickToCurrentTarget(GetSpawnMeleeRange(targetId))
            else
                DebugLog("Ignoring MeleeAttack speaker [" .. speaker .. "]")
            end
        end
        local function meleeAttackHelp()
            print("(attack <id>) Tells listener(s) to attack spawn with <id>")
            print("(attack off) Tells listener(s) to call off attacks")
        end
        Commands.RegisterCommEvent(Command.new(MeleeState.eventIds.attack, event_Attack, meleeAttackHelp))

        Reset()
        MeleeState._.isInit = true
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Go()
    return MeleeState._.currentAction()
end

---@param meleeAction CabbyAction
MeleeState.RegisterAction = function(meleeAction)
    table.insert(MeleeState._.registrations.abilities, meleeAction)
end

MeleeState.IsFacingTarget = function()
    if mq.TLO.Target == nil then return false end

    local calc = math.abs(mq.TLO.Target.HeadingTo.DegreesCCW() - mq.TLO.Me.Heading.DegreesCCW())
    return calc < 50 or calc > 310 -- requires heading difference < 56, so plan for < 50, or > 310 for the wrap-around
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
MeleeState.IsEnabled = function()
    return MeleeStateConfig.IsEnabled()
end

---@diagnostic disable-next-line: duplicate-set-field
MeleeState.SetEnabled = function(isEnabled)
    MeleeStateConfig.SetEnabled(isEnabled)
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.BuildMenu()
    ImGui.Text("Melee State Status")

    ImGui.SameLine(math.max(ImGui.GetContentRegionAvail() - 68, 200))
    ---@type boolean
    local clicked, result
    result, clicked = ImGui.Checkbox("Enabled", MeleeState.IsEnabled())
    if clicked then
        MeleeState.SetEnabled(result)
    end

    local tableSorting_flags = bit32.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersOuter, ImGuiTableFlags.BordersInner)
    if ImGui.BeginTable("t1", 2, tableSorting_flags) then
        ImGui.TableSetupColumn("col1", ImGuiTableColumnFlags.WidthFixed, 140)
        ImGui.TableSetupColumn("col2", ImGuiTableColumnFlags.WidthFixed, 800)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Current Action")

        ImGui.TableNextColumn()
        local currentTask = "Standby"
        local attacking = false
        if MeleeState._.currentAction == MeleeState._.meleeActions.attackTarget then
            currentTask = "Attacking: " .. tostring(MeleeState._.currentTargetID)
            attacking = true
        end
        ImGui.Text(currentTask)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.Text("Attack Target")

        ImGui.TableNextColumn()
        local targetName = "<NONE>"
        if attacking then
            targetName = mq.TLO.Spawn(MeleeState._.currentTargetID).Name()
        end
        ImGui.Text(targetName)

        ImGui.EndTable()
    end

    ---@type boolean
    local clicked, result
    result, clicked = ImGui.Checkbox("Stick", MeleeStateConfig:GetStick())
    if clicked then
        MeleeStateConfig.SetStick(result)
    end

    ImGui.SameLine()
    ---@type boolean
    local clicked, result
    result, clicked = ImGui.Checkbox("Auto-Engage", MeleeStateConfig:GetAutoEngage())
    if clicked then
        MeleeStateConfig.SetAutoEngage(result)
    end

    ImGui.PushItemWidth(40)
    ---@type integer
    local result
    ---@type boolean
    local selected
    result, selected = ImGui.DragInt("Engage Distance", MeleeStateConfig:GetEngageDistance(), 1, 0, 500)
    if selected then
        MeleeStateConfig.SetEngageDistance(result)
    end

    ImGui.SameLine()
    if ImGui.Button("Reset Default", 100, 23) then
        MeleeStateConfig.SetEngageDistance(50)
    end

    local disabled = false
    if mq.TLO.Target() == nil then
        ImGui.BeginDisabled(true)
        disabled = true
    end
    if ImGui.Button("Attack", 60, 23) then
        local targetId = mq.TLO.Target.ID()
        EngageTargetId(targetId)
        StickToCurrentTarget(GetSpawnMeleeRange(targetId))
    end
    if disabled then
        ImGui.EndDisabled()
    end

    local attackLabel = "<No Target>"
    if mq.TLO.Target() ~= nil then
        ---@type string
---@diagnostic disable-next-line: assign-type-mismatch
        attackLabel = mq.TLO.Target()
    end
    ImGui.SameLine()
    local width = ImGui.GetContentRegionAvail()
    ImGui.PushItemWidth(width)
    ImGui.LabelText("", attackLabel)

    if MeleeState._.currentAction ~= MeleeState._.meleeActions.attackTarget then
        ImGui.BeginDisabled(true)
        disabled = true
    end
    if ImGui.Button("Back Off", 70, 23) then
        Reset()
    end
    if disabled then
        ImGui.EndDisabled()
    end
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

