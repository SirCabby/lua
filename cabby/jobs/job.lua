---@diagnostic disable: duplicate-set-field

---What a job is, and the contract every one of them keeps.
---
---A **state** is a standing responsibility. It sits in the priority chain, it is asked every pass
---whether it has anything to do, and it competes with the character's other responsibilities by
---position. Healing is a state. Following is a state. Nobody switches healing on when they want
---some healing done.
---
---A **job** is the other thing: a whole activity the player sends the character off to carry out.
---Standing at a forge making combines until the materials run out is not a responsibility to be
---weighed against the others every frame -- it is the thing this character is doing now, and it
---is doing it instead of everything else. So a job is not in the chain at all. It runs as a
---**service**, pulsed every frame whatever the chain is doing, and while it is working it holds
---the chain from outside with a **priority floor** (`Priorities.job`), which starves every state
---beneath it exactly as a state returning busy would. That is the sanctioned shape for "a service
---is busy at a band" (see `stateMachine.lua`, `RegisterPriorityGate`) and it is the only one
---available: a floor cuts a contiguous tail, it cannot punch holes, and a job that wanted a hole
---would be a job at the wrong band rather than a reason for a new mechanism.
---
---# The three differences from a state, and why
---
---1. **A job holds the character, not a turn.** A state that returns busy is saying "nothing
---   weaker should act until what I started resolves". A job says "nothing else is happening at
---   all". The floor it returns is what says so, and it is returned *only while the job is
---   actually working* -- an idle job holds nothing, exactly as the casting gate holds nothing
---   with no cast in the air.
---2. **Running is never persisted.** A state's enabled switch lives in config and survives a
---   restart, because "this character heals" is a fact about the character. A job is an errand,
---   and an errand that resumed by itself when the script came back up would be a character
---   quietly walking off to a forge nobody sent it to this time. So the *setup* persists (which
---   container, which materials, which limits) and the run switch does not: every job starts off,
---   every time.
---3. **A job ends.** States are never done -- they are asked again forever. A job has limits, it
---   reaches one, and it switches itself off with a reason a person can read. That reason is the
---   whole output of a job that ran while nobody was watching, so it is kept and shown rather than
---   printed once into chat scroll.
---
---# What a job owes the rest of cabby
---
---Everything a state owes, for the same reasons, minus the frames:
---
---- **`Pulse()` never blocks.** No `mq.delay`, no waiting loop. One command per pulse at most,
---  then a look at the world on the pulses after it. The chain is starved while a job works, so a
---  job that blocked would freeze the character rather than merely delay itself.
---- **Progress is read out of the world, not counted off a clock.** A command that fired is
---  believed only once the world shows it: the cursor holding the item, the slot holding it, the
---  container emptying. The only clocks a job keeps are the two a state may keep -- an **evidence
---  window** on a command it fired (a command that produced no visible change at all did not take,
---  and there is nothing else the client will say about it), and a **pace** on its own retries.
---  Never a give-up timer, and never time measured off the scheduler.
---- **It does not fight the player.** A job takes the character when it starts and hands it back
---  when it stops; what the player does by hand while it runs is an instruction, not an obstacle.
---  Closing the container a job is combining in stops the job -- it does not get reopened.
---- **No game commands from ImGui.** The Start and Stop buttons flip a flag; the commands are
---  fired from the pulse, on the main loop, like everything else.
---
---# The shape
---
---A job is a singleton module -- a table, not an instance -- exposing:
---
---| member | what it is |
---|---|---|
---| `key` | names it, for Debug toggles, `/job` and the menu. Ends in `Job` |
---| `Init()` | config, comm and slash commands, chat events, `Menu.RegisterJob(self)` |
---| `Pulse()` | one pass; the state machine's service contract |
---| `Stop()` | the service contract's other half: called if repeated failures pause it |
---| `Hold()` | the priority floor while working, `nil` while idle |
---| `IsEnabled()` / `SetEnabled(v)` | is it running; start it or stop it |
---| `Describe()` | what it is doing right now, in words, for the page and the slash command |
---| `BuildMenu()` | its page in the Jobs section of the menu |
---@class Job
---@field key string
local Job = { key = "Job" }

function Job.Init() end

---One pass, every frame, whatever the state chain is doing. See the notes on this module.
function Job.Pulse() end

---Service contract: called if the state machine pauses this job after repeated failures. Put
---down anything that would otherwise be left half done.
function Job.Stop() end

---@return number|nil floor the weakest priority allowed to run while this job works, `nil` when
---it is holding nothing back
function Job.Hold() return nil end

---@return boolean isRunning
function Job.IsEnabled()
    print("warn: no IsEnabled override for this job")
    return false
end

---@param isEnabled boolean
function Job.SetEnabled(isEnabled)
    print("warn: no SetEnabled override for this job")
end

---@return string standing what this job is doing right now
function Job.Describe() return "standing by" end

function Job.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end

return Job
