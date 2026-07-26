local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")
local Timer = require("utils.Time.Timer")
local StringUtils = require("utils.StringUtils.StringUtils")

local Action = require('cabby.actions.action')
local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local MeleeStateConfig = require("cabby.configs.meleeStateConfig")
local MeleeStateMenu = require("cabby.ui.states.meleeStateMenu")
local Menu = require("cabby.ui.menu")
local Skills = require("cabby.actions.skills")
local Status = require('cabby.status')
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

local function passive()
    return false
end

-- How long "As Needed" waits between tanking actions so they fire one at a time
local sequentialActionDelayMs = 1500

---@class MeleeState : BaseState
local MeleeState = {
    key = "MeleeState",
    eventIds = {
        attack = "attack",
        -- the switches the Melee State page draws as checkboxes, each also sayable and so also
        -- bindable to a hotbar button
        action = "action",
        autoEngage = "autoengage",
        bashOverride = "bashoverride",
        melee = "melee",
        stick = "stick",
        tanking = "tanking"
    },
    _ = {
        isInit = false,
        currentAction = passive,
        currentActionTimer = nil,
        currentTargetID = 0,
        tauntTimer = Timer.new(sequentialActionDelayMs),
        hateTimer = Timer.new(sequentialActionDelayMs),
        meleeActions = {
            checkForCombat = passive,
            attackTarget = passive
        }
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

---@param range number
function MeleeState.StickToCurrentTarget(range)
    if MeleeStateConfig.GetStick() then
        Movement.Stick(MeleeState._.currentTargetID, { distance = range, owner = MeleeState.key })
    end
end

---@param id number
function MeleeState.EngageTargetId(id)
    mq.cmd("/mqtarget npc id " .. tostring(id))
    MeleeState._.currentTargetID = id
    MeleeState._.currentAction = MeleeState._.meleeActions.attackTarget
    MeleeState._.currentActionTimer = Timer.new(500)
end

local function DoPrimaryCombatAction()
    ---@type ActionType
    local primaryAction
    if MeleeStateConfig:GetBashOverride() and mq.TLO.Me.Inventory("offhand").Type() == "Shield" then
        primaryAction = Skills.bash
    else
        primaryAction = MeleeStateConfig.GetPrimaryCombatAbility()
    end

    if primaryAction:IsReady() then
        primaryAction:DoAction()
    end

    if mq.TLO.Me.Class.ShortName() == "MNK" then
        local secondaryAction = MeleeStateConfig.GetSecondaryCombatAbility()
        if secondaryAction:IsReady() then
            secondaryAction:DoAction()
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

            if actionType ~= nil and actionType:IsReady() and Action.GetLuaResult(action) then
                actionType:DoAction()

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

MeleeState._.meleeActions.checkForCombat = function()
    -- Am I under attack?
    if MeleeStateConfig:GetAutoEngage() and mq.TLO.Me.CombatState() == "COMBAT" then
        for i = 1, 20 do
            local xtarget = mq.TLO.Me.XTarget(i)
            if xtarget.TargetType() == "Auto Hater" and xtarget.ID() > 0 then
                MeleeState.EngageTargetId(xtarget.ID())
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
            MeleeState.Reset()
        end
        return true
    end

    if mq.TLO.Target.Dead() then
        MeleeState.Reset()
        return true
    end

    if IsIncapacitated() then
        return true
    end

    FixCombatState()

    -- FixCombatState issues commands, and mq.cmd yields the frame, so the target validated
    -- above can be gone by the time we get here. Read distance once and bail if it is; the
    -- next pulse falls into the re-aquire branch and lets the timer decide whether to reset.
    local distance = mq.TLO.Target.Distance()
    if distance == nil then return true end

    local range = MeleeState.GetSpawnMeleeRange(MeleeState._.currentTargetID)

    if MeleeStateConfig.GetStick() and not Movement.IsSticking(MeleeState._.currentTargetID) and distance < MeleeStateConfig.GetEngageDistance() and mq.TLO.Target.LineOfSight() then
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

                if actionType ~= nil and actionType:IsReady() and Action.GetLuaResult(action) then
                    actionType:DoAction()
                end
            end
        end
    end

    return true
end

function MeleeState.Reset()
    MeleeState._.currentAction = MeleeState._.meleeActions.checkForCombat
    MeleeState._.currentTargetID = 0
    MeleeState._.currentActionTimer = Timer.new(0)
    -- only our own stick; a higher priority behavior may have taken movement over since
    Movement.StopFor(MeleeState.key)
end

---@param words table
---@param index number first word to take
---@return string text those words back as one string
local function JoinFrom(words, index)
    local rest = {}
    for wordIndex = index, #words do
        rest[#rest+1] = words[wordIndex]
    end
    return StringUtils.Join(rest, " ")
end

---Read what an `action` order is asking for. The switch comes first because the name cannot:
---action names run to several words ("Firestorm of Fists Rk. II"), so everything after the switch
---is name. A name with no switch in front of it flips whatever that slot is now, which is what a
---hotbar button wants to be.
---@param args string everything said after the phrase
---@return string? switch "on", "off" or "toggle"; nil when the order names nothing to switch
---@return string? name what to match against the configured slots
local function ReadActionOrder(args)
    local words = StringUtils.Split(StringUtils.TrimFront(args or ""))
    if #words < 1 then return nil, nil end

    local first = words[1]:lower()
    local switch
    if first == "toggle" or first == "flip" then
        switch = "toggle"
    elseif UserInput.IsTrue(first) then
        switch = "on"
    elseif UserInput.IsFalse(first) then
        switch = "off"
    end

    if switch ~= nil then
        -- a switch and nothing else says what to do without saying what to do it to
        if #words < 2 then return nil, nil end
        return switch, JoinFrom(words, 2)
    end

    return "toggle", JoinFrom(words, 1)
end

---Which configured slots an order is about. An exact name wins outright; failing that, any slot
---whose name contains what was said, so a button can be bound with `off firestorm` rather than
---the whole of "Firestorm of Fists Rk. II".
---@param name string
---@return table matches array of { label = string, action = Action }
local function FindActionSlots(name)
    name = name:lower()
    local exact, partial = {}, {}

    for _, list in ipairs(MeleeStateConfig.GetActionLists()) do
        for _, action in ipairs(list.actions) do
            local actionName = tostring(action.name or ""):lower()
            if actionName == name then
                exact[#exact+1] = { label = list.label, action = action }
            elseif actionName:find(name, 1, true) ~= nil then
                partial[#partial+1] = { label = list.label, action = action }
            end
        end
    end

    if #exact > 0 then return exact end
    return partial
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Init()
    if not MeleeState._.isInit then
        Menu.RegisterState(MeleeState)

        local attackDocs = ChelpDocs.new(function() return {
            "(attack <id>) Tells listener(s) to attack spawn with <id>",
            "(attack off) Tells listener(s) to call off attacks"
        } end )
        local function event_Attack(_, speaker, args)
            -- permission first: a speaker we take no orders from should cost us nothing, not
            -- even the complaints below
            if not Commands.GetCommandOwners(MeleeState.eventIds.attack):HasPermission(speaker) then
                DebugLog("Ignoring MeleeAttack speaker [" .. speaker .. "]")
                return
            end

            args = StringUtils.Split(StringUtils.TrimFront(args))

            -- these used to return silently, which is indistinguishable from a broken script
            -- when the order came from a hotbar button that was never given a target
            if #args < 1 then
                print("(attack) No target given. Usage: attack <spawn id>, or `attack off` to call it off.")
                return
            end

            if UserInput.IsFalse(args[1]:lower()) then
                MeleeState.Reset()
                return
            end

            local targetId = tonumber(args[1])
            if targetId == nil then
                print("(attack) [" .. args[1] .. "] is not a spawn id. Usage: attack <spawn id>")
                return
            end

            if mq.TLO.SpawnCount("id " .. tostring(targetId) .. " radius 400 los")() < 1 then
                print("(attack) Nothing in range and in sight with id [" .. tostring(targetId) .. "]")
                return
            end

            DebugLog("MeleeAttack speaker [" .. speaker .. "] targetId: [ " .. targetId .. "]")
            MeleeState.EngageTargetId(targetId)
            MeleeState.StickToCurrentTarget(MeleeState.GetSpawnMeleeRange(targetId))
        end
        Commands.RegisterCommEvent(Command.new(MeleeState.eventIds.attack, event_Attack, attackDocs)
            :WithArgs({
                required = true,
                hint = "a spawn id, or off",
                default = "${Target.ID}",
                choices = function() return {
                    { label = "Whatever I have targeted", args = "${Target.ID}" },
                    -- a button that calls the attack off should not be labelled "attack"
                    { label = "Call off the attack", args = "off", name = "Back off" }
                } end
            }))

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
            phrase = MeleeState.eventIds.autoEngage,
            summary = "Turns engaging whatever attacks us on or off",
            about = { "Off waits to be told what to attack: an (attack <id>) order, or the menu's Attack button." },
            get = MeleeStateConfig.GetAutoEngage,
            set = MeleeStateConfig.SetAutoEngage
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

        local actionDocs = ChelpDocs.new(function()
            local lines = {
                "(action) Switches one of the configured melee actions on or off",
                " -- Usage: action <on | off | toggle> <part of the action's name>",
                " -- Or: action <part of the action's name>, to flip whatever it is now",
                " -- Example: action off firestorm",
                " -- Enough of the name to pick the action out is enough, and case does not",
                "    matter. Every slot the name matches is switched together.",
                " -- Configured slots (Melee State page, Tanking and Melee tabs):"
            }

            local anyConfigured = false
            for _, list in ipairs(MeleeStateConfig.GetActionLists()) do
                for _, action in ipairs(list.actions) do
                    anyConfigured = true
                    lines[#lines+1] = "    " .. list.label .. ": " .. tostring(action.name) ..
                        " [" .. (Action.IsEnabled(action) and "on" or "off") .. "]"
                end
            end
            if not anyConfigured then
                lines[#lines+1] = "    <none configured yet>"
            end

            return lines
        end )
        local function event_Action(_, speaker, args)
            if not Commands.GetCommandOwners(MeleeState.eventIds.action):HasPermission(speaker) then
                DebugLog("Ignoring action speaker [" .. speaker .. "]")
                return
            end

            local switch, name = ReadActionOrder(args)
            if switch == nil or name == nil then
                print("(action) Nothing named to switch. Usage: action <on | off | toggle> <part of the action's name>")
                return
            end

            local matches = FindActionSlots(name)
            if #matches < 1 then
                print("(action) No configured action matches [" .. name .. "]. /chelp action lists them.")
                return
            end

            -- one value for all of them, taken from the first, so a name fragment that catches
            -- more than one slot leaves those slots agreeing rather than in opposite states
            local value = switch == "on"
            if switch == "toggle" then
                value = not Action.IsEnabled(matches[1].action)
            end

            for _, match in ipairs(matches) do
                Action.SetEnabled(match.action, value)
                print("(action) " .. match.label .. ": " .. tostring(match.action.name) ..
                    " [" .. (value and "on" or "off") .. "]")
            end
        end
        ---What the button editor offers as arguments for this command: every action slot this
        ---character has configured, each of the three ways it can be switched. This is what makes
        ---the command bindable without knowing how a discipline is spelled -- the alternative is
        ---typing part of "Firestorm of Fists Rk. II" from memory into a text field.
        ---
        ---Read when it is offered rather than built once, so a slot added or renamed on the Melee
        ---State page is offered here on the next frame. Slots still being filled in have no name to
        ---switch by and are left out.
        ---@return table choices
        local function ActionArgChoices()
            -- `suffix` is for the button's name, not for the command: a button that flips a
            -- discipline wants to be called after the discipline, and one that only ever turns it
            -- on or off wants to say which
            local switches = {
                { args = "toggle", group = "Toggle", suffix = "" },
                { args = "on", group = "Turn on", suffix = " on" },
                { args = "off", group = "Turn off", suffix = " off" }
            }

            local choices = {}
            for _, switch in ipairs(switches) do
                for _, list in ipairs(MeleeStateConfig.GetActionLists()) do
                    for _, action in ipairs(list.actions) do
                        local name = tostring(action.name or "")
                        if name ~= "" and name:lower() ~= "none" then
                            choices[#choices+1] = {
                                label = list.label .. ": " .. name,
                                args = switch.args .. " " .. name,
                                group = switch.group,
                                name = name .. switch.suffix
                            }
                        end
                    end
                end
            end
            return choices
        end

        ---What a button carrying this command shows: the state of the slots it names, when they
        ---have one between them.
        ---@param args string
        ---@return boolean? state
        local function ReadActionState(args)
            local _, name = ReadActionOrder(args)
            if name == nil then return nil end

            local matches = FindActionSlots(name)
            if #matches < 1 then return nil end

            local state = Action.IsEnabled(matches[1].action)
            for _, match in ipairs(matches) do
                -- slots that do not agree have no one state to show
                if Action.IsEnabled(match.action) ~= state then return nil end
            end
            return state
        end

        Commands.RegisterCommEvent(Command.new(MeleeState.eventIds.action, event_Action, actionDocs)
            :WithArgs({
                required = true,
                hint = "on, off or toggle, then part of the action's name",
                choices = ActionArgChoices
            })
            :WithState(ReadActionState))

        MeleeState.Reset()
        MeleeState._.isInit = true
    end
end

---@diagnostic disable-next-line: duplicate-set-field
function MeleeState.Go()
    return MeleeState._.currentAction()
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
---target we were just told to stop fighting.
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

