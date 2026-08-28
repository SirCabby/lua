local Debug = require("utils.Debug.Debug")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local SlashCmd = require("cabby.commands.slashcmd")
local TradeskillJob = require("cabby.jobs.tradeskillJob")
local UserInput = require("cabby.utils.userinput")

---The registry of jobs -- the errands a character can be sent on, as opposed to the standing
---responsibilities the state chain arbitrates between. What a job is, and why it is not a state,
---is written out in `cabby/jobs/job.lua`.
---
---Each one is wired in twice, and both halves are existing machinery rather than anything new:
---
---1. as a **service**, so it is pulsed every frame whatever the chain is doing -- which it has to
---   be, because while it works the chain is starved and there is nobody left to drive it. It also
---   gets the service crash barrier for free: three faults in a row and that job alone is paused,
---   with an alert saying so.
---2. as a **priority gate**, so it can be busy at a band. The floor a job returns cuts the chain
---   off beneath it exactly as a state returning busy would (`stateMachine.lua`, `activeGates`),
---   and a job that is not running returns nothing and holds nothing back.
---
---Jobs are class-independent -- anybody can stand at a forge -- so they are wired up in `Setup`
---alongside the services rather than by a class profile.
---@class Jobs
local Jobs = {
    key = "Jobs",
    _ = {
        isInit = false,
        registered = {}
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Jobs.key, str)
end

---@param stateMachine StateMachine
---@param job Job
function Jobs.Register(stateMachine, job)
    job.Init()

    stateMachine:RegisterService(job)
    stateMachine:RegisterPriorityGate(function() return job.Hold() end)

    Jobs._.registered[#Jobs._.registered+1] = job
    DebugLog("Registered job [" .. tostring(job.key) .. "]")
end

---@return table jobs every registered job, in registration order
function Jobs.GetAll()
    return Jobs._.registered
end

---@param name string the job's key without its `Job` suffix, any case
---@return Job|nil
function Jobs.Get(name)
    name = tostring(name or ""):lower()
    for _, job in ipairs(Jobs._.registered) do
        if job.key:sub(1, -4):lower() == name then return job end
    end
    return nil
end

---@param stateMachine StateMachine
function Jobs.Init(stateMachine)
    if Jobs._.isInit then return end

    local ftkey = Global.tracing.open("Jobs Setup")

    Jobs.Register(stateMachine, TradeskillJob)

    local jobDocs = ChelpDocs.new(function()
        local result = { "(/job) Registered Jobs:" }
        for i, job in ipairs(Jobs._.registered) do
            ---@type Job
            job = job
            result[#result+1] = i .. ") " .. job.key:sub(1, -4) .. ": " ..
                (job.IsEnabled() and "running" or "off") .. " -- " .. job.Describe()
        end
        result[#result+1] = "  -- Start or stop a job: /job <name>"
        result[#result+1] = "  -- Set running: /job <name> <0 | 1>"
        result[#result+1] = "  -- A job takes the character: nothing in the state chain runs while"
        result[#result+1] = "     one is going, and no job is ever running when the script starts"
        return result
    end )

    local function Bind_Job(...)
        local args = {...} or {}
        if #args < 1 or #args > 2 or args[1]:lower() == "help" then
            jobDocs:Print()
            return
        end

        local job = Jobs.Get(args[1])
        if job == nil then
            jobDocs:Print()
            return
        end

        if #args == 2 then
            job.SetEnabled(UserInput.IsTrue(args[2]))
        else
            job.SetEnabled(not job.IsEnabled())
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("job", Bind_Job, jobDocs))

    Jobs._.isInit = true
    Global.tracing.close(ftkey)
end

return Jobs
