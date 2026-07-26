local Debug = require("utils.Debug.Debug")
local Movement = require("utils.Movement.Movement")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local UserInput = require("cabby.utils.userinput")

---Cabby side wiring for the reusable movement service in `utils/Movement`.
---
---States drive movement by requiring `utils.Movement.Movement` directly; all this module
---does is put the service on the state machine's per-frame pulse and expose `/cmove` for
---looking at (or killing) whatever movement is currently doing.
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

---@param stateMachine StateMachine
function CabbyMovement.Init(stateMachine)
    if CabbyMovement._.isInit then return end

    local ftkey = Global.tracing.open("Movement Setup")

    Movement.Init()
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
