---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Command = require("cabby.commands.command")
local Commands = require("cabby.commands.commands")
local CombatConfig = require("cabby.configs.combatConfig")
local SlashCmd = require("cabby.commands.slashcmd")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")
local UserInput = require("cabby.utils.userinput")

---What this character is fighting.
---
---This used to be a field on the melee state, which was fine for exactly as long as melee was the
---only way to hurt something. A wizard fights the same mob a warrior does and has no melee state
---to keep it in, and `attack <id>` has to mean the same thing to both, so the engagement is its
---own thing: one target, whoever put it there, and everything that fights reads it.
---
---It holds no opinion about *how* to fight. The melee state gets on target and swings, the spell
---dps state casts at it, a tank state will taunt it -- and each one decides for itself whether it
---is in range, whether it is worth it, and when to give up.
---
---**It issues no game commands.** Engaging is bookkeeping, which is what makes it safe to call
---from an ImGui button (the Attack button used to run `/mqtarget` from inside the render
---callback, which is the crash-to-desktop hazard the movement service is built around).
---@class Combat
local Combat = {
    key = "Combat",
    eventIds = {
        attack = "attack",
        autoEngage = "autoengage"
    },
    _ = {
        isInit = false,
        targetId = 0,
        engagedBy = nil,
        engagedAtMs = 0,
        lastScanMs = 0
    }
}

---How often the extended target window is swept looking for something that is attacking us.
---Twenty TLO reads is not free, and nothing is lost by noticing a quarter of a second late.
local scanIntervalMs = 250

---@param str string
local function DebugLog(str)
    Debug.Log(Combat.key, str)
end

---@return number targetId 0 when not engaged
function Combat.GetTargetId()
    return Combat._.targetId
end

---@return boolean isEngaged
function Combat.IsEngaged()
    return Combat._.targetId > 0
end

---@param id number
---@param by? string what decided this: an order, or the auto-engage sweep
function Combat.Engage(id, by)
    id = tonumber(id) or 0
    if id < 1 then return end
    if Combat._.targetId == id then return end

    Combat._.targetId = id
    Combat._.engagedBy = by or "an order"
    Combat._.engagedAtMs = Time.current_time()
    DebugLog("Engaged " .. tostring(id) .. " (" .. Combat._.engagedBy .. ")")
end

---@param reason? string
function Combat.Disengage(reason)
    if Combat._.targetId == 0 then return end

    DebugLog("Disengaged " .. tostring(Combat._.targetId) .. (reason ~= nil and (": " .. reason) or ""))
    Combat._.targetId = 0
    Combat._.engagedBy = nil
end

---@return string description for status output
function Combat.Describe()
    if not Combat.IsEngaged() then return "standby" end

    local name = mq.TLO.Spawn("id " .. tostring(Combat._.targetId)).CleanName()
    return "engaged with " .. (name or ("spawn " .. tostring(Combat._.targetId))) ..
        " (" .. tostring(Combat._.engagedBy) .. ")"
end

---Anything on the extended target window that is on us. `Auto Hater` is the client's own word for
---"this is fighting you", which is a better answer than anything we could work out ourselves.
---@return number|nil id
local function findAutoHater()
    for slot = 1, 20 do
        local xtarget = mq.TLO.Me.XTarget(slot)
        if xtarget.TargetType() == "Auto Hater" then
            local id = tonumber(xtarget.ID())
            if id ~= nil and id > 0 then return id end
        end
    end
    return nil
end

---Service contract: keep the engagement honest, and pick one up when something starts on us.
function Combat.Pulse()
    if Combat.IsEngaged() then
        local spawn = mq.TLO.Spawn("id " .. tostring(Combat._.targetId))
        if spawn.ID() == nil then
            Combat.Disengage("it is gone")
        elseif spawn.Dead() or spawn.Type() == "Corpse" then
            Combat.Disengage("it is dead")
        end
        return
    end

    if not CombatConfig.GetAutoEngage() then return end

    -- Travel mode is exactly the case for not picking a fight up. Nothing would act on it -- every
    -- state that fights is held back while flee is on -- but an engagement recorded now is one that
    -- resumes the moment the run ends, against whatever we ran past ten zones ago
    if Status.IsFleeing() then return end

    local now = Time.current_time()
    if now - Combat._.lastScanMs < scanIntervalMs then return end
    Combat._.lastScanMs = now

    -- only while the client says we are actually in a fight, so a mob that has us on its hate
    -- list from across the zone does not start one
    if mq.TLO.Me.CombatState() ~= "COMBAT" then return end

    local id = findAutoHater()
    if id ~= nil then
        Combat.Engage(id, "it attacked us")
    end
end

---@param stateMachine StateMachine
function Combat.Init(stateMachine)
    if Combat._.isInit then return end

    local ftkey = Global.tracing.open("Combat Setup")

    CombatConfig.Init()
    stateMachine:RegisterService(Combat)

    local attackDocs = ChelpDocs.new(function() return {
        "(attack <id>) Tells listener(s) to fight the spawn with <id>",
        " -- Usage: attack <spawn id>",
        " -- Usage (call it off): attack off",
        " -- What fighting means is up to the listener: a warrior gets on it and swings, a",
        "    wizard casts at it, and a character that does neither ignores it."
    } end )
    local function event_Attack(_, speaker, args)
        -- permission first: a speaker we take no orders from should cost us nothing, not even
        -- the complaints below
        if not Commands.GetCommandOwners(Combat.eventIds.attack):HasPermission(speaker) then
            DebugLog("Ignoring attack speaker [" .. speaker .. "]")
            return
        end

        args = StringUtils.Split(StringUtils.TrimFront(args or ""))

        -- these used to return silently, which is indistinguishable from a broken script when the
        -- order came from a hotbar button that was never given a target
        if #args < 1 then
            print("(attack) No target given. Usage: attack <spawn id>, or `attack off` to call it off.")
            return
        end

        if UserInput.IsFalse(args[1]:lower()) then
            Combat.Disengage("called off by " .. speaker)
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

        DebugLog("Attack ordered by [" .. speaker .. "] targetId: [" .. targetId .. "]")
        Combat.Engage(targetId, "ordered by " .. speaker)
    end
    Commands.RegisterCommEvent(Command.new(Combat.eventIds.attack, event_Attack, attackDocs)
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

    ToggleCommand.Register({
        key = Combat.key,
        phrase = Combat.eventIds.autoEngage,
        summary = "Turns engaging whatever attacks us on or off",
        about = { "Off waits to be told what to fight: an (attack <id>) order, or the Attack button." },
        get = CombatConfig.GetAutoEngage,
        set = CombatConfig.SetAutoEngage
    })

    local cattackDocs = ChelpDocs.new(function() return {
        "(/cattack) Report what this character is fighting",
        " -- Usage: /cattack",
        " -- Usage (call it off): /cattack off"
    } end )
    local function Bind_CAttack(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cattackDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            Combat.Disengage("called off by /cattack")
            print("Attack called off")
            return
        end

        print("Combat: " .. Combat.Describe())
        print(" -- auto-engage: " .. (CombatConfig.GetAutoEngage() and "on" or "off"))
        -- the one setting that makes this whole report a lie about what will happen next: an
        -- engagement is still recorded while fleeing, and nothing whatsoever acts on it
        if Status.IsFleeing() then
            print(" -- flee is on: nothing will act on this until `flee off`")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cattack", Bind_CAttack, cattackDocs))

    Combat._.isInit = true
    Global.tracing.close(ftkey)
end

return Combat
