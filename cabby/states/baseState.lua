---@diagnostic disable: duplicate-set-field

---What a state is, and the contract every one of them keeps.
---
---A state is one job -- healing, meleeing, following -- and the state machine walks the
---registered states in priority order, strongest first, until one of them says it is busy. Read
---this before writing a new one: the whole design rests on every state behaving the same way, and
---a state that holds on to a turn, or waits inside one, breaks the chain for everything below it.
---
---# One pass
---
---`Go()` is called once per pass and does three things, in this order:
---
---1. **Check, quickly, what should be happening.** Every pass, from the world -- health, the
---    engagement, what is configured. Never from a mode this state was left in last time. The
---    check runs at the top of the chain forty times a second, so anything expensive (an XTarget
---    sweep, a spawn search, a group scan) is throttled behind a short timer with the last answer
---    cached.
---2. **Start the action, without waiting for it.** Anything that takes time -- a cast, a move --
---    is *requested* from the service that owns it (`utils.Casting`, `utils.Movement`) and polled
---    on later passes. Nothing in a state ever blocks: no `mq.delay`, no loop waiting on a TLO.
---    The character has other things to do while a heal is going out, and the script has chat to
---    listen to.
---3. **Release**, by returning:
---    - **`true` -- start the loop again from the top.** Not "I am blocking" and not "I win": the
---      pass ends here and the next one re-evaluates from the strongest state down. Return this
---      when nothing weaker should act until what this state started has resolved -- a cast in the
---      air, a target being acquired. Because the next pass starts at the top, everything
---      *stronger* than this state gets re-evaluated immediately, which is what makes holding a
---      turn safe.
---    - **`false` -- I have nothing to do.** The walk carries on to the next state down, which is
---      how a character with nothing to heal ends up following the group in the same pass.
---
---# State held across passes
---
---Keep only what cannot be re-derived from the world: the id of the cast we started, the spawn we
---are fighting, the target a heal was chosen for. Everything else is read fresh.
---
---**What is kept must be kept accurate.** Every pass either confirms it or drops it -- a cast id
---is cleared when the cast goes terminal, an engagement is dropped when the target dies, a heal's
---target is re-checked against this pass's reading of the group. Stale remembered state is the
---one way a state can lie to itself, and it is what the "decide every pass" rule exists to
---prevent.
---
---Mode -- "I am in the middle of healing" -- is not state worth keeping. It is a decision, and
---decisions are re-made. The exception is genuine *progress through a procedure* that the world
---cannot tell you about: FollowState's click-zone chain has clicked the door and is waiting for
---the zone, which is not something a fresh look at the world can reconstruct.
---
---# Why it holds together
---
---No failure path can wedge a chain of states built this way. A cast that cannot get started, a
---move that cannot finish, a target that will not take: each is looked at again on the very next
---pass by a state that re-derives its own answer, and dropped as soon as it stops being the right
---thing to do. That is why the services have no give-up timers -- they would be rescuing a
---problem that cannot happen.
---@class BaseState
---@field key string names this state, for Debug toggles, /state and the menu
---@field priority number|nil the band it was registered at, written by `BaseClass` at Init from
---the class profile. States that ask a service to arbitrate for them -- the casting service is
---the one that does -- pass this so it knows where they sit in the chain.
local BaseState = { key = "BaseState" }

function BaseState.Init() end

---One pass: check what should be happening, start it, release. See the notes on this module.
---@return boolean isBusy `true` to end the pass and start the next one from the top of the chain,
---`false` to hand the turn to the next state down
function BaseState.Go() return false end

function BaseState.BuildMenu()
    ImGui.Text("No menu exists yet for this page")
end

---@return boolean isEnabled
function BaseState.IsEnabled()
    print("warn: no IsEnabled override for this state")
    return false
end

---@param isEnabled boolean
function BaseState.SetEnabled(isEnabled)
    print("warn: no SetEnabled override for this state")
    return {}
end
