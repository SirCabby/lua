---@diagnostic disable: undefined-field
local mq = require("mq")

local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")

local Action = require("cabby.actions.action")
local ActionCommand = require("cabby.commands.actionCommand")
local Combat = require("cabby.combat")
local Menu = require("cabby.ui.menu")
local SpellDpsStateConfig = require("cabby.configs.spellDpsStateConfig")
local SpellDpsStateMenu = require("cabby.ui.states.spellDpsStateMenu")
local ToggleCommand = require("cabby.commands.toggleCommand")

---Hurting whatever this character is fighting, with spells rather than with a weapon.
---
---The other half of the dps band. `MeleeState` walks into range and swings; this casts from
---wherever it is standing, and the two are separate states because they are separate jobs: a
---wizard has no melee state to hang a rotation off, a warrior has no spells, and the hybrids in
---between want both without one pretending to be the other. What they share -- what we are
---fighting -- is `cabby.combat`, so an `attack <id>` order means the same thing to all of them.
---
---**It registers above the melee state.** MeleeState reports busy for as long as it is engaged
---(there is always another swing coming), so a rotation below it would never get a frame. Above
---it, this state takes the frame only when it actually starts a cast and yields the rest of the
---time, which is what `Priorities.dps - 1` in the bands is for.
---@class SpellDpsState : BaseState
local SpellDpsState = {
    key = "SpellDpsState",
    eventIds = {
        nuke = "nuke",
        nukeAction = "nukeaction"
    },
    _ = {
        isInit = false,
        castId = nil,
        castTargetId = 0,
        castName = nil,
        lastResult = nil,
        holdReason = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(SpellDpsState.key, str)
end

---Who this state is when it asks the casting service for something.
---@return table request
function SpellDpsState.CastRequest()
    return {
        owner = SpellDpsState.key,
        priority = SpellDpsState.priority,
        targetId = Combat.GetTargetId()
    }
end

---Reasons to hold everything, in the order they are worth reporting. Each one is a way a caster
---makes a fight worse by casting: pulling the mob off the tank before it has settled, burning the
---mana that the next fight needs, or spending a cast on something already dead.
---
---The code matters as well as the words: `noTarget` is the only one that also means "and stop
---what you are already doing", because a cast in flight at something that is dead or gone is the
---one case where finishing it is worse than dropping it. A mob that has dropped below the stop
---point mid-cast, by contrast, is a cast that is nearly finished too.
---@return string|nil code
---@return string|nil reason in words
local function holdReason()
    local targetId = Combat.GetTargetId()
    if targetId == 0 then return "noTarget", "nothing to fight" end

    local spawn = mq.TLO.Spawn("id " .. tostring(targetId))
    if spawn.ID() == nil or spawn.Dead() then return "noTarget", "the target is gone" end

    local pct = tonumber(spawn.PctHPs())
    if pct ~= nil then
        if pct > SpellDpsStateConfig.GetStartPct() then
            return "tooHealthy", "waiting for it to drop below " .. tostring(SpellDpsStateConfig.GetStartPct()) .. "%"
        end
        if pct < SpellDpsStateConfig.GetStopPct() then
            return "nearlyDead", "it is nearly dead"
        end
    end

    local manaFloor = SpellDpsStateConfig.GetManaFloor()
    if manaFloor > 0 and (tonumber(mq.TLO.Me.PctMana()) or 0) < manaFloor then
        return "lowMana", "saving mana below " .. tostring(manaFloor) .. "%"
    end

    return nil, nil
end

---@return string description of what this state is doing, for the page and /state
function SpellDpsState.Describe()
    if SpellDpsState._.castId ~= nil then
        return "casting " .. tostring(SpellDpsState._.castName)
    end
    if SpellDpsState._.holdReason ~= nil then
        return "holding: " .. SpellDpsState._.holdReason
    end
    return "watching"
end

---@return string|nil result what the last cast did
function SpellDpsState.GetLastResult()
    return SpellDpsState._.lastResult
end

function SpellDpsState.Reset()
    SpellDpsState._.castId = nil
    SpellDpsState._.castTargetId = 0
    SpellDpsState._.castName = nil
end

---The first action in the rotation that is worth firing right now.
---@param request table
---@return ActionType? action
local function nextAction(request)
    for _, slot in ipairs(SpellDpsStateConfig.GetActions()) do
        if Action.IsEnabled(slot) then
            local action = Action.GetActionType(slot)
            -- casts only: this state polls the cast it started, which a skill or a discipline has
            -- no equivalent of. Only casts are offered on the page; this is for a config that was
            -- edited by hand.
            if action ~= nil and action.Subject ~= nil and action:IsReady(request) and Action.GetLuaResult(slot) then
                return action
            end
        end
    end
    return nil
end

---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsState.Init()
    if SpellDpsState._.isInit then return end

    -- our own config, so a class that does not register this state gets no rotation written
    SpellDpsStateConfig.Init()

    Menu.RegisterState(SpellDpsState)

    ToggleCommand.Register({
        key = SpellDpsState.key,
        phrase = SpellDpsState.eventIds.nuke,
        summary = "Turns the spell damage rotation on or off for listener(s)",
        about = {
            "Off calls off a cast in progress and stops starting new ones.",
            "Melee, healing and everything else carry on regardless -- this is only the spells."
        },
        get = SpellDpsStateConfig.IsEnabled,
        set = SpellDpsState.SetEnabled
    })

    ActionCommand.Register({
        key = SpellDpsState.key,
        phrase = SpellDpsState.eventIds.nukeAction,
        summary = "Switches one of the configured spell damage actions on or off",
        where = "Spell DPS page",
        getActionLists = SpellDpsStateConfig.GetActionLists
    })

    SpellDpsState.Reset()
    SpellDpsState._.isInit = true
end

---Look at the fight, decide what should be happening, act on it, and release.
---
---Same shape as every other state and for the same reason: there is no "I am casting" mode to be
---stuck in. Each pass asks whether there is any reason to hold, whether the cast in the air is
---still aimed at something worth casting at, and -- if there is nothing in the air -- what to
---start. A cast that cannot get itself started is reconsidered here every pass like anything
---else.
---@return boolean isBusy
---@diagnostic disable-next-line: duplicate-set-field
function SpellDpsState.Go()
    local code, hold = holdReason()
    SpellDpsState._.holdReason = hold

    local castId = SpellDpsState._.castId
    if castId ~= nil then
        local status, outcome, reason = Casting.GetResult(castId)

        if status == nil then
            if code == "noTarget" then
                DebugLog("Calling off the cast: " .. tostring(hold))
                SpellDpsState._.lastResult = tostring(SpellDpsState._.castName) .. ": called off, " .. tostring(hold)
                Casting.StopFor(SpellDpsState.key)
            end
            return true
        end

        if status == Casting.status.succeeded and outcome == Casting.outcomes.succeeded then
            SpellDpsState._.lastResult = tostring(SpellDpsState._.castName) .. ": landed"
        else
            SpellDpsState._.lastResult = tostring(SpellDpsState._.castName) .. ": " .. tostring(reason)
        end

        DebugLog("Cast finished: " .. tostring(SpellDpsState._.lastResult))
        SpellDpsState.Reset()
        return true
    end

    if hold ~= nil then return false end

    local request = SpellDpsState.CastRequest()
    local action = nextAction(request)
    if action == nil then return false end

    local newCastId, refused = Casting.Cast(action:Subject(), request)
    if newCastId == nil then
        DebugLog("Cast of [" .. action:Name() .. "] was refused: " .. tostring(refused))
        return false
    end

    DebugLog("Casting [" .. action:Name() .. "] at " .. tostring(request.targetId))
    SpellDpsState._.castId = newCastId
    SpellDpsState._.castTargetId = request.targetId
    SpellDpsState._.castName = action:Name()
    return true
end

---@return boolean isEnabled
---@diagnostic disable-next-line: duplicate-set-field
SpellDpsState.IsEnabled = function()
    return SpellDpsStateConfig.IsEnabled()
end

---Switching it off calls off the cast in the air: it is the casting service's now, and it would
---hold the chain back for a rotation we were just told to stop running. The fight itself is not
---called off -- `attack off` does that, and a character told to stop nuking still swings.
---@diagnostic disable-next-line: duplicate-set-field
SpellDpsState.SetEnabled = function(isEnabled)
    SpellDpsStateConfig.SetEnabled(isEnabled)
    if not isEnabled then
        Casting.StopFor(SpellDpsState.key)
        SpellDpsState.Reset()
    end
end

function SpellDpsState.BuildMenu()
    SpellDpsStateMenu.BuildMenu(SpellDpsState)
end

return SpellDpsState
