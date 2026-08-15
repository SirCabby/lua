local Casting = require("utils.Casting.Casting")
local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

---Cabby side wiring for the reusable movement service in `utils/Movement`.
---
---States drive movement by requiring `utils.Movement.Movement` directly; all this module
---does is put the service on the state machine's per-frame pulse, tell it how to weigh a cast
---against the move it is carrying, and expose `/cmove` for looking at (or killing) whatever
---movement is currently doing.
---@class CabbyMovement
local CabbyMovement = {
    key = "Movement",
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CabbyMovement.key, str)
end

---Whether a cast in the air is worth standing still for, from the movement service's side of the
---same arbitration `cabby/casting.lua` does from the cast's side.
---
---Two things are being told apart. A cast **this script started** carries a band, so it is weighed
---against the band the move was asked for at: a heal holds the follow below it still, and a buff
---does not -- it is the buff that gives way, by being lost to the walking, which is what a buff
---that cannot be cast on the move is worth. A cast **nothing here started** is the player's own,
---and there is no band to weigh: walking out of somebody's hand cast is not ours to do.
---@param stateMachine StateMachine
---@return function arbiter fun(movementOwner, movementPriority): boolean
local function buildCastArbiter(stateMachine)
    return function(movementOwner, movementPriority)
        -- Asked with a cast bar already up, so a bar with nothing of ours committed behind it is
        -- the player's own -- or another script's. There is no band to weigh it against, and
        -- walking out of somebody's hand cast is not ours to do.
        if not Casting.IsCommitted() then return true end

        if movementPriority == nil and movementOwner ~= nil then
            movementPriority = stateMachine:GetPriority(movementOwner)
        end

        return Casting.IsHoldingStill(movementPriority)
    end
end

---@param stateMachine StateMachine
function CabbyMovement.Init(stateMachine)
    if CabbyMovement._.isInit then return end

    local ftkey = Global.tracing.open("Movement Setup")

    Movement.Init({ castArbiter = buildCastArbiter(stateMachine) })
    stateMachine:RegisterService(Movement)

    local cmoveDocs = ChelpDocs.new(function() return {
        "(/cmove) Report what the movement service is currently doing",
        " -- Usage: /cmove",
        " -- Usage (cancel the current move and release the movement keys): /cmove off"
    } end )
    local function Bind_CMove(...)
        local args = {...} or {}

        if #args > 0 and args[1]:lower() == "help" then
            cmoveDocs:Print()
            return
        end

        if #args > 0 and UserInput.IsFalse(args[1]) then
            DebugLog("Movement stopped by /cmove")
            Movement.Stop()
            print("Movement stopped")
            return
        end

        print("Movement: " .. Movement.Describe() .. " [" .. Movement.GetStatus() .. "]")
        local blockedReason = Movement.GetBlockedReason()
        if blockedReason ~= nil then
            print(" -- blocked: " .. blockedReason)
        end
        local owner = Movement.GetOwner()
        if owner ~= nil then
            print(" -- requested by: " .. owner)
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cmove", Bind_CMove, cmoveDocs))

    CabbyMovement._.isInit = true
    Global.tracing.close(ftkey)
end

return CabbyMovement
