local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local Commands = require("cabby.commands.commands")
local ErrorAlert = require("cabby.errorAlert")

---Runs command lines on the main loop on behalf of callers that must not run them themselves.
---
---Everything drawn in ImGui is one of those callers: issuing a game command from inside a
---render callback is the crash-to-desktop hazard the movement service is built around (see
---ARCHITECTURE.md, Movement). So hotbar buttons push their lines here and this service, pulsed
---every frame, drains them a frame later.
---
---A line is either a slash command (`/bc followme`, `/cself stopfollow`, `/g attack ${Target.ID}`)
---which is handed to mq.cmd -- TLOs and all -- or bare text, which is treated as one of this
---script's own comm commands issued to ourselves. Bare text is deliberately *never* said out
---loud: a typo in a hotkey must not broadcast to a channel.
---@class CommandQueue
local CommandQueue = {
    key = "CommandQueue",
    _ = {
        isInit = false,
        queue = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(CommandQueue.key, str)
end

---@param line string
local function run(line)
    DebugLog("Running [" .. line .. "]")

    local ok, err = xpcall(function()
        if line:sub(1, 1) == "/" then
            mq.cmd(line)
            return
        end

        if not Commands.Dispatch(line) then
            print("(Cabby) [" .. line .. "] is not one of this script's commands. Slash commands need their leading /")
        end
    end, debug.traceback)

    if not ok then
        ErrorAlert.Record("command:" .. line, err)
    end
end

---@param stateMachine StateMachine
function CommandQueue.Init(stateMachine)
    if CommandQueue._.isInit then return end

    local ftkey = Global.tracing.open("CommandQueue Setup")

    stateMachine:RegisterService(CommandQueue)

    CommandQueue._.isInit = true
    Global.tracing.close(ftkey)
end

---@param line string command line to run on the next frame
function CommandQueue.Push(line)
    if type(line) ~= "string" then return end

    line = line:match("^%s*(.-)%s*$")
    if line == "" then return end

    CommandQueue._.queue[#CommandQueue._.queue+1] = line
end

---@param lines table command lines to run on the next frame, in order
function CommandQueue.PushAll(lines)
    if type(lines) ~= "table" then return end

    for _, line in ipairs(lines) do
        CommandQueue.Push(line)
    end
end

---@return number count lines waiting to run
function CommandQueue.Count()
    return #CommandQueue._.queue
end

function CommandQueue.Pulse()
    if #CommandQueue._.queue < 1 then return end

    -- swap the queue out before running anything: a line can queue more work (a slash command
    -- of ours that pushes a follow-up), and that work belongs to the next frame rather than
    -- extending this drain indefinitely
    local lines = CommandQueue._.queue
    CommandQueue._.queue = {}

    for _, line in ipairs(lines) do
        run(line)
    end
end

---Service contract: called if the state machine pauses us after repeated failures. Drop the
---backlog rather than replaying it when we resume.
function CommandQueue.Stop()
    CommandQueue._.queue = {}
end

return CommandQueue
