local Casting = require("utils.Casting.Casting")
local CastSubject = require("utils.Casting.CastSubject")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")

local CastingConfig = require("cabby.configs.castingConfig")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Priorities = require("cabby.classes.priorities")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

---Cabby side wiring for the reusable casting service in `utils/Casting`.
---
---Three things happen here that the service cannot do for itself, because all three are about
---cabby's priority chain and the service knows nothing about it:
---
---1. **The service goes on the per-frame pulse**, like movement, so a cast keeps making progress
---   while the state that asked for it is starved -- which it will be, because a cast that
---   outranks other work spends most of its life with nothing else running.
---2. **The priority floor is handed to the state machine.** While a cast owned by priority P is
---   preparing or in the air, no state weaker than P gets a turn. This is what stops the follow
---   state from walking off with a heal half cast.
---3. **Movement arbitration.** Standing still is the one thing a cast cannot do without, so a
---   cast that outranks whoever owns the movement task cancels it. One that does not just waits
---   -- a follow that has caught up is standing still anyway, and a cast weaker than the follow
---   has no business overriding it.
---@class CabbyCasting
local CabbyCasting = {
    key = "Casting",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CabbyCasting.key, str)
end

---@param stateMachine StateMachine
---@return function arbiter fun(castPriority, movementOwner, castOwner): boolean
local function buildMovementArbiter(stateMachine)
    return function(castPriority, movementOwner, castOwner)
        -- nobody has claimed the movement task, so there is no one to overrule
        if movementOwner == nil then return true end

        -- a behavior always gets to stop its own movement to cast
        if castOwner ~= nil and movementOwner == castOwner then return true end

        local movementPriority = stateMachine:GetPriority(movementOwner)
        -- movement started by something that is not a registered state (a /cmove by hand, say)
        if movementPriority == nil then return true end

        -- an unranked cast does not get to cancel a ranked behavior's movement
        if type(castPriority) ~= "number" then return false end

        -- the same band counts as strong enough: two behaviors at the same priority are the
        -- same job, and the one that wants to cast is the one with something to lose
        return castPriority <= movementPriority
    end
end

---Read a `/ccast` line: everything that is not an option is part of the name.
---
---Spell names run to several words and MQ hands slash arguments over already split on spaces,
---so the name cannot be a single argument. Options are recognized by shape -- `item`, `alt`,
---`gem4`, `targetid|1234` -- and everything else, in the order it was typed, is the name.
---@param args table
---@return table request { name, kind, gem, targetId } or { error }
local function ReadCastOrder(args)
    local request = { kind = CastSubject.kinds.spell }
    local words = {}

    for _, arg in ipairs(args) do
        local lowered = arg:lower()
        local key, value = lowered:match("^(%a+)|(.+)$")

        if lowered == "item" or lowered == "alt" or lowered == "spell" then
            request.kind = lowered
        elseif lowered:match("^gem%d+$") then
            request.gem = tonumber(lowered:sub(4))
            request.kind = CastSubject.kinds.spell
        elseif key == "gem" then
            request.gem = tonumber(value)
            request.kind = CastSubject.kinds.spell
        elseif key == "targetid" then
            request.targetId = tonumber(value)
            if request.targetId == nil then
                return { error = "[" .. arg .. "] is not a spawn id" }
            end
        else
            words[#words+1] = arg
        end
    end

    if #words < 1 then return { error = "nothing named to cast" } end

    request.name = StringUtils.Join(words, " ")
    return request
end

---@param stateMachine StateMachine
function CabbyCasting.Init(stateMachine)
    if CabbyCasting._.isInit then return end

    local ftkey = Global.tracing.open("Casting Setup")

    CastingConfig.Init()
    Casting.Init({ movementArbiter = buildMovementArbiter(stateMachine) })
    stateMachine:RegisterService(Casting)
    stateMachine:RegisterPriorityGate(Casting.GetPriorityFloor)

    local ccastDocs = ChelpDocs.new(function() return {
        "(/ccast) Cast a spell, click an item or fire an AA through the casting service",
        " -- Usage: /ccast <name> [item | alt | gem<#>] [targetid|<#>]",
        " -- Usage (what casting is doing now): /ccast",
        " -- Usage (cancel the cast in progress): /ccast off",
        " -- Example: /ccast Complete Heal targetid|${Group.Member[1].ID}",
        " -- Example: /ccast Modulation Shard item",
        " -- Example: /ccast Divine Arbitration alt",
        " -- The name is everything that is not one of the options above, so it needs no quotes",
        " -- A cast from here outranks everything: while it runs, no other behavior gets a turn"
    } end )

    local function Bind_CCast(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            ccastDocs:Print()
            return
        end

        if #args < 1 then
            print("Casting: " .. Casting.Describe() .. " [" .. Casting.GetStatus() .. "]")
            local reason = Casting.GetReason()
            if reason ~= nil then
                print(" -- " .. reason)
            end
            local owner = Casting.GetOwner()
            if owner ~= nil then
                print(" -- requested by: " .. owner)
            end
            return
        end

        if #args == 1 and UserInput.IsFalse(args[1]) then
            if Casting.Interrupt() then
                print("(ccast) Cancelling " .. Casting.Describe())
            else
                print("(ccast) Nothing is casting")
            end
            return
        end

        local request = ReadCastOrder(args)
        if request.error ~= nil then
            print("(ccast) " .. request.error .. ". Usage: /ccast <name> [item | alt | gem<#>] [targetid|<#>]")
            return
        end

        DebugLog("Hand cast requested: " .. request.kind .. " " .. request.name)

        local id, refused = Casting.Cast(CastSubject.new(request.kind, request.name), {
            owner = CabbyCasting.key,
            -- an order typed by the user outranks everything the script decided to do on its own
            priority = Priorities.commands,
            targetId = request.targetId,
            gem = request.gem,
            onDone = function(status, outcome, reason)
                print("(ccast) " .. request.name .. ": " .. tostring(status) .. " -- " .. tostring(reason))
            end
        })

        if id == nil then
            print("(ccast) Refused: " .. tostring(refused))
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("ccast", Bind_CCast, ccastDocs))

    CabbyCasting._.isInit = true
    Global.tracing.close(ftkey)
end

return CabbyCasting
