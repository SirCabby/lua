# Cabby Architecture

Cabby is a MacroQuest Lua script intended to bot any EQ class/race. One script per character;
each running instance discovers its own capabilities and takes orders over chat channels from
owner characters. Entry point: `cabby/cabby.lua` (run `/lua run cabby/cabby`, alias `/luar`).

This document describes the system **as it exists today**, including known warts, plus the
agreed target architecture. Companion doc: [ROADMAP.md](ROADMAP.md) (gaps, bugs, phases).

---

## Runtime model

```
cabby.lua
  └─ Setup:Init(configFilePath, stateMachine)
       ├─ PluginSetup        — ensure MQ2EQBC (optional; nothing else is required)
       ├─ Config.new(path)   — per-character pickle store: configDir/cabby/<Name>-Config.lua
       ├─ *Config.Init()     — CommandConfig, DebugConfig, GeneralConfig, HotbarConfig
       │                       (MeleeStateConfig is initialized by MeleeState, so only the
       │                        classes that register it get a melee config section)
       ├─ CommandQueue.Init  — registers the command queue service (what UI presses run through)
       ├─ CabbyCasting.Init  — registers the casting service, its priority gate + /ccast
       ├─ CabbyMovement.Init — registers the movement service + /cmove
       ├─ Character.Init     — registers the discovery service + /crefresh
       ├─ Combat.Init        — registers the engagement service, /cattack + the attack order
       ├─ ClassSetup         — this character's class module assembles + registers its states
       ├─ HotbarsUI.Init()   — ImGui shell for the hotbar windows
       └─ Menu.Init()        — ImGui shell (must be last)
  └─ stateMachine:Start()    — main loop
```

**Main loop** (`stateMachine.lua`, one pass is `Frame()`): `mq.doevents()` → pulse registered
**services** → walk registered states in registration order until one returns `true` →
`mq.delay(25)` → start again from the top.

Read the return value as *"start the loop again"* rather than *"I win"*. A state returns `true`
when nothing weaker should act until what it started has resolved; the pass ends there and the
next one re-evaluates from the strongest state down, so everything **above** it is reconsidered
immediately. Returning `false` means "nothing for me to do" and the walk continues down. States
fall through until one of them finds something worth doing.

**Services** run every frame regardless of which state is busy (`RegisterService`, anything
with `key` + `Pulse()` and optionally `Stop()`). They are for work that cannot wait for its
requesting state to get another turn. Five exist: **Movement**, which has to release its keys
on the frame its task ends rather than whenever FollowState next runs; **Casting**, whose whole
point is that the caster is starving everything below it while the cast runs, so the cast has to
progress without a turn of its own; **CommandQueue** (`commandQueue.lua`), which runs command
lines pushed to it by callers that must not run commands themselves — every ImGui callback,
hotbar buttons above all; **Character** (`character.lua`), which watches for the character
gaining a level, an AA or a bag of clickies and re-reads what it can do; and **Combat**
(`combat.lua`), which holds what we are fighting for the several states that fight it.

This is a **priority-chain cooperative scheduler**: state order = priority; `Go()` returning
`false` yields to lower states. The priority bands live in `classes/priorities.lua`:

| Priority | State | Priority | State |
|---|---|---|---|
| 1 | My commands / Task / DZ | 69 | Tank / grab aggro |
| 19 | Passive mode | 79 | DPS (melee/spells) |
| 29 | Cure | 89 | Looting |
| 39 | Heal | 99 | Anchor |
| 49 | Pulling | 109 | Following |
| 59 | Mez (in combat) | 119/129 | Buff / Misc |

A bigger number is weaker. The gaps of ten are room for "the same job, but not as strongly":
`Priorities.heal + 5` is a hybrid healing below the class that heals for a living. Classes
name a band per state rather than ordering their `Register` calls by hand — see below.

**Priority gates** (`RegisterPriorityGate`) are the other half of that ordering. A state that
yields hands the frame to whatever is below it, which is right for work that can be picked up
again next frame and wrong for work already in the air: a three second heal is lost the moment
the follow state below it walks off. A gate returns the weakest priority allowed to run right
now, and `runChecks` skips every state weaker than that. The priority a state was registered at
is kept for exactly this (`Register(state, priority)`, `GetPriority(stateOrKey)`); a state
registered without one is never starved, since there is no way to judge it. Casting is the only
gate today, and anything else that commits the character for longer than a frame belongs here
too.

**Every state keeps the same contract** — written out in full in `states/baseState.lua`, which is
the thing to read before writing one. In short, `Go()` is one pass of:

1. **a quick check** of what should be happening, made from the world every pass and never from a
   mode left over from the last one (expensive reads throttled and cached, since this runs at the
   top of the chain forty times a second);
2. **starting the action without waiting for it** — anything that takes time is requested from the
   service that owns it (casting, movement) and polled on later passes, so nothing in a state ever
   blocks;
3. **releasing**, `true` to end the pass and start again from the top, `false` to hand the turn
   down.

Held state is only what cannot be re-derived, and it comes in two kinds:

- **The order we were given** — who to follow, where the anchor is, what we are fighting. Nothing
  in the world can tell you these; somebody said them. Keep the *order*, though, not a conclusion
  drawn from it: FollowState briefly held a `job` field saying whether following or anchoring was
  in force, and it turned out to be unnecessary once conflicting orders cancel each other (a
  follow and an anchor contradict, so the newer one clears the older) — with only one order ever
  standing, which one it is went back to being something to read.
- **Progress through a procedure the world cannot describe** — a clicked door looks exactly like
  an unclicked one, so FollowState's click-zone chain keeps its step.

Everything else is read fresh, and what is held is confirmed or dropped every pass. Mode is not
held state; it is a decision, and decisions are re-made — "am I following them right now" is
`Movement.IsFollowing`, not something to remember.

This is what makes the chain robust without timeouts rescuing it: no failure path can wedge a
state that re-derives its own answer every pass. A cast that cannot get started, a move that will
not finish, a target that will not take — each is looked at again on the very next pass and
dropped as soon as it stops being the right thing to do. The services have no give-up timers
because they would be rescuing a problem that cannot happen.

Timers (`utils.Time.Timer`, wall-clock ms) throttle expensive reads and pace retries; they do not
decide anything.

**States are singletons**, not instances: a module table with `Init/Go/IsEnabled/SetEnabled/
BuildMenu`. `BaseState` documents this contract but is *not* a real metatable base — the
`---@class X : BaseState` annotations are documentation-only inheritance.

## Module map

```
cabby/
  cabby.lua           entry; defines global `Global` { tracing (FlowTracer), configStore }
  setup.lua           plugin checks, config init order, class dispatch (16-way if/elseif)
  character.lua       service: what this character has, discovered and kept current
  combat.lua          service: what this character is fighting; every state that fights reads it
  stateMachine.lua    priority-chain loop + per-frame services + priority gates (instance class)
  movement.lua        wiring only: registers the movement service and /cmove
  casting.lua         wiring only: casting service, its priority gate, movement arbiter, /ccast
  commandQueue.lua    service: runs command lines pushed from ImGui callbacks, a frame later
  character.lua       capability snapshot: which skills exist (primary/secondary/melee lists)
  status.lua          shared predicates (IsFacingTarget)
  states/             baseState, followState, meleeState, spellDpsState, healState
  classes/            priorities (the bands), baseClass (assembly), classes (the registry),
                      and one profile per EQ class
  commands/           the chat-command bus (see below), incl. the toggle/action command factories
  configs/            per-domain config modules (see below)
  actions/            ActionType interface + implementations + registries
  ui/                 ImGui menu shell + per-domain panels (states/, actions/, hotbars)
  utils/ (sibling)    Movement/ and Casting/ (see below), Time/Timer/StopWatch, Config,
                      Debug/FlowTracer, FileSystem, Json, PriorityQueue (unused), Stack,
                      StringUtils, TableUtils
```

## Classes (`classes/`)

The class is the assembly axis: which states this character runs, and in what order. All
sixteen EQ classes have a module; `classes/classes.lua` maps the short name the client
reports (`Me.Class.ShortName`) to a module path and requires only that one, so a wizard never
loads the melee state.

A class module is **data**, not Init code — a `ClassProfile` handed to `BaseClass.new`:

```lua
local Warrior = BaseClass.new({
    key = "Warrior", shortName = "WAR",
    states = { { state = MeleeState, priority = Priorities.dps } },
    unimplemented = { "tanking as its own state: aggro-loss detection ...", "pulling" }
})
```

`BaseClass` merges the profile's states with the **common** ones, sorts by priority, and then
inits and registers each in that order. Rules it enforces:

- **Every class follows.** FollowState (which is also anchor and click-to-zone — one state,
  one `Go()`) is the one job that has nothing to do with what the character is, so no profile
  has to remember to ask for it. A profile naming the same state wins over the common entry,
  priority and all, which is how a class moves follow somewhere else in its chain.
- **Ties keep declaration order.** `table.sort` is not stable, so entries carry their
  declaration index as the tie-break — two states sharing a band stay in the order written.
- **A malformed profile fails loudly** at construction (no priority, an entry that is not a
  state, a missing key), because the alternative is a character silently registered to
  nothing.
- **A shell says so.** Now that every class loads, a class cabby cannot really play can no
  longer announce itself by crashing on `class.Init`. Each profile lists what the class can do
  that cabby cannot do for it yet, and Init prints it at startup under the states it did
  register. A bot that quietly follows the group around and never casts is worse than a loud
  failure, not better.

Which states a class registers is the only capability judgment made here. The nine melee classes
(WAR, PAL, SHD, MNK, ROG, BER, RNG, BST, BRD) melee; the priests and casters do not, because a
cleric that walks into melee instead of healing is worse than one that stands still. A shaman
played as a melee on emu adds the entry to its own profile. The eleven classes that can hurt
something with a spell register **SpellDpsState** a band above melee, which for a hybrid means
both. The three
priests heal, and so do the three hybrids that can (PAL, RNG, BST) — but a band lower
(`Priorities.heal + 5`), which is the whole reason the bands are numbers: a paladin's heal has to
land below a cleric's, and that is only checkable if both name the same band. A druid or shaman in
a group with no cleric should tighten to the full band, which needs the runtime priority
adjustment that does not exist yet. Everything
narrower than "can this class do this at all" — does it have bash, does it have taunt discs —
stays where it already is, in `character.lua` and the action registries.

Tanking currently rides inside MeleeState (the taunt and hate action lists), so the tank band
is unused; when tanking splits out, the plate classes gain a second entry at
`Priorities.tank` and MeleeState stays where it is.

## Command bus (`commands/`)

The most developed subsystem. Three registration kinds, all carrying self-documenting help
(`ChelpDocs`, surfaced by `/chelp` and the Help UI tab):

- **Comms** (`Command`): phrases spoken in chat channels ("followme", "attack 123"). For each
  active channel a matcher pattern is instantiated from a template containing `<<phrase>>`
  (per-channel patterns live in `Speak.channelTypes`: bc, bct, tell, raid, group) and
  registered as an `mq.event`. Changing active channels re-registers everything. A command may
  also declare, chained onto `Command.new`, what it needs to be a real order rather than a
  no-op: `:WithArgs{ required, hint, default, choices }` (attack declares a required spawn id
  defaulting to `${Target.ID}`) and `:ActsOnSpeaker()` for commands that act on whoever said them
  (followme, m2m), which cannot be issued to yourself. An order a character has to be able to give
  *itself* needs a phrase that names no speaker: `followtarget` is `followme` turned around, following
  whoever the listener has targeted, and so is the one a hand-played character binds to a hotbar
  button. Whatever offers commands to a user reads
  these — the hotbar editor prefills the default, refuses to build a line that cannot work, and
  flags one that was typed anyway. `choices` is a function, read when the command is offered rather
  than registered once, returning `{ label, args, group? }` rows: what the arguments can *be* as
  things stand. It is what separates a command a user can bind from one they have to know the
  spelling of — `action` can switch any configured action slot, which as free text means typing part
  of a discipline's name from memory, and as choices is a pick from the slots this character has.
  `:WithState(reader)` declares the other direction: a command
  that flips something whose state can be read back, so whatever *presents* the command can
  present it as that state (a hotbar button carrying `stick toggle` is drawn as the stick setting).
  The reader answers for this character and returns nil when there is no single answer.
- **Events** (`Event`): raw line patterns (group invite, generic tell-forwarder). `reregister`
  flag re-adds them last so catchall patterns sort after specific ones.
- **Slash commands** (`SlashCmd`): `mq.bind` wrappers (/chelp, /cself, /debug, /activechannels,
  /speak, /owners, /state, /cmenu, /restart).

**Two command factories** cover the shapes every state needs, so a new state registers its
commands instead of writing them (`commands/toggleCommand.lua`, `commands/actionCommand.lua`).

**Settings are commands too** (`commands/toggleCommand.lua`). A setting the menu draws as a
checkbox is also registered as a one-word comm command over that same setting — `stick off`,
`tanking on`, or the phrase by itself to flip whatever it is now. The factory writes the help
(including what the setting is *right now*, read when the help is asked for) and declares `toggle`
as the command's default arguments, so binding one to a hotbar button is a pick with no typing. It
holds no state: `get`/`set` are the config's own accessors, the ones the checkbox calls, so a
button, a chat order and the checkbox cannot disagree. Saying what changed is left to the setter,
which is where this codebase already prints it — printing in both places would report every flip
twice and still leave the checkbox as the one path that says nothing. MeleeState registers `melee`,
`stick`, `autoengage`, `tanking`, and `bashoverride` for characters that can bash; HealState
registers `healing`, `healgroup` and `healpets`. Switches that have to call off work in progress
rather than only stopping new work go through the *state* rather than the config, so the
checkboxes get the same behavior: `melee off` resets the state, `stick off` releases the stick
Movement is still holding, and `healing off` interrupts the heal in the air.

**Action lists are commands too** (`commands/actionCommand.lua`). Any state with configured action
slots gets `<phrase> <on | off | toggle> <part of an action's name>` from the same factory —
`action` for the melee lists, `healaction` for the heal list. Exact name wins; failing that every
slot whose name contains the fragment is switched together, so they end up agreeing rather than in
opposite states. `/chelp action` lists those slots with their current state, which is also what the
button editor's docs pane shows while the command is picked, and the choices it offers are the
slots configured *right now*, each of the three ways they can be switched.

**The local ("self") channel.** `Speak.channelTypes.self` is a channel that never touches chat.
`Commands.Dispatch(line)` hands a comm phrase straight to its registered handler with our own
name as the speaker, synthesizing the line the handler would have seen (`Speak.BuildLine`) so
nothing downstream — `Respond()` included — can tell the difference; replies land in our own
console via `/echo`. `/cself <command>` is the slash command form, and hotbar buttons use it.
This is what makes an order meant for *this* character possible at all: EQBC runs with
localecho off, so a `/bc followme` is heard by everyone except the character that said it.
Local channels are excluded from active-channel lists and from `GetPhrasePatterns` — there is no
chat line to listen for. `Owners:HasPermission` always says yes to our own name, so dispatching
to ourselves does not require listing ourselves as an owner.

Cross-cutting per-command/event settings, each with a global default plus per-command
overrides, persisted by CommandConfig:

- **Owners** (`owners.lua`): ACL — list of speaker names plus an `open` flag. Every comm
  handler checks `Commands.GetCommandOwners(id):HasPermission(speaker)`.
- **Speak** (`speak.lua`): which channels replies go out on; `Respond()` reverse-engineers
  the originating channel by regex-matching the incoming line against channel patterns
  (fragile — see roadmap; channel should be captured at event-registration time instead).
- **Active channels**: which channels are listened on, globally and per-command.

`configs/commandConfig.lua` (1,350 lines) persists all of the above *and* implements the
generic ImGui override editor (`buildCommandEventEditor`, 14 positional params) — splitting
it is a planned refactor.

## Movement (`utils/Movement/`, wired by `cabby/movement.lua`)

Cabby drives its own movement; MQ2MoveUtils and MQ2AdvPath are not loaded. The modules live
in `utils/` because nothing in them knows about cabby — the only cabby-side piece is
`movement.lua`, which puts the service on the state machine's per-frame pulse and registers
`/cmove` (status, and `/cmove off` to force-release the keys).

```
Movement.lua        the service: one active task, arbitration, the pause gate, status queries
  MoveTo.lua        straight-line move to a loc or spawn, with arrival radius and timeout
  Stick.lua         hold range on a spawn (loose, or `behind` to strafe into the rear arc)
  Follow.lua        breadcrumb-trail follow of a spawn, opens doors in the way
Locomotion.lua      the only thing that touches movement keys; hold/release, /face, /stand
StuckDetector.lua   position delta over wall-clock windows
Unsticker.lua       jump + alternating strafe recovery
Geometry.lua        pure distance/heading math (headings are degrees CCW, EQ style)
MovementStatus.lua  idle | moving | holding | blocked | arrived | failed
```

Design rules that matter when adding a caller:

- **One task at a time, one owner of the keys.** Starting a task cancels the previous one.
  Pass `owner = <state key>` and clean up with `Movement.StopFor(owner)`, which no-ops when
  a higher-priority state has since taken movement over — `Movement.Stop()` is unconditional.
- **The service must be pulsed every frame**, which is why it is a service and not something
  each state pokes. Keys get released the frame a task ends, and the pause gate (dead, bind,
  feign, stun, mez, charm, mid-cast for non-bards; stands up out of sit/duck) is enforced
  even while the state that asked for the move is starved.
- **Requests never touch the client; only `Pulse()` does.** `Stick`/`Follow`/`MoveTo*`/`Stop`
  record intent, and `Locomotion` holds a desired-vs-applied key state that `Pulse()`
  reconciles. This matters because callers are not all on the main loop: the MeleeState menu
  has Attack and Back Off buttons, so a movement request can originate inside the ImGui
  render callback. Running EQ's mappable commands (`/keypress`) mid-frame from there is a
  crash-to-desktop hazard — MQ2MoveUtils guarded the same call for the same reason. Anything
  new that emits a game command belongs inside `Pulse()`, and UI panels should read cached
  values (task names are resolved once at construction) rather than hitting TLOs per frame.
- **Terminal results are polled by task id**: `Movement.GetResult(id)` returns nil while the
  task runs, then `arrived`/`failed` plus a reason. `holding` is not terminal — stick and
  follow stay active and satisfied with the keys released.
- Tasks are best-effort straight-line movers with stuck detection, *not* pathfinding. Follow
  works around corners because it replays the trail the target actually walked. Real navmesh
  pathing remains out of scope (that is MQ2Nav's job).

## Casting (`utils/Casting/`, wired by `cabby/casting.lua`)

Spells, item clicks and AA activations all go through one service, for the reasons movement is
one: a cast takes seconds, cannot be hurried, and is lost if anything moves the character in the
meantime. A script that blocks for three seconds hears no chat orders and watches nobody's
health bar, so callers **request** a cast and poll the result by id. MQ2Cast is not loaded and
is not wanted — this is the same job done against our own state machine rather than against a
macro's blocking wait — but its source is worth reading for the mechanics EQ forces on anyone
doing this (`plugins/MQ2Cast`, kept for reference only).

```
Casting.lua         the service: one cast, arbitration by priority, the floor, status queries
  CastTask.lua      the sequencer: validate → target → stand still → memorize → fire → watch
  CastSubject.lua   what is being cast: spell (gem, memorize), item click, or AA
  Immobilizer.lua   "have we stopped moving long enough", including standing up and autorun
  CastOutcome.lua   why a cast ended, and the client lines that say so
  CastStatus.lua    idle | preparing | casting | succeeded | failed
```

Rules that matter when adding a caller:

- **One cast at a time, and priority decides who gets it.** `Cast(subject, { owner, priority,
  targetId })` outranks the cast in progress or it is refused outright — nothing queues up
  behind an in-flight heal hoping for a turn. Equal priority does not win, so two behaviors in
  the same band cannot interrupt each other every frame; a caller replacing its own cast says so
  with `StopFor(owner)` first. A stronger request preempts, which means `/stopcast` and a frame
  of separation before the new cast starts.
- **A cast raises the priority floor** (`GetPriorityFloor`, registered as the state machine's
  priority gate). While a cast owned by priority P is preparing *or* in flight, no state weaker
  than P gets a turn. Yielding is not enough on its own — the states below would take the frame
  the caster is not using, and that is exactly the frame that ruins the cast. It is up during
  preparation too, because a cast waiting to stand still has even more to lose from a weaker
  behavior starting to move again.
- **Standing still is arbitrated, not assumed.** A cast that outranks whoever owns the movement
  task cancels it; one that does not just waits, which is usually fine — a follow that has caught
  up is holding position with the keys released, and that is standing still. The comparison needs
  cabby's priorities, so the service takes the policy as an injected function and `cabby/casting.lua`
  supplies it from `StateMachine:GetPriority`. Bards are exempt for songs (they sing on the move,
  and the movement pause gate knows it), as is anything with a cast time under 100 ms, because
  there is no cast bar to lose.
- **Requests never touch the client; only `Pulse()` does** — targeting, `/memspell`, `/cast`,
  `/stopcast`, all of it. Same rule as movement, same reason: a cast asked for from an ImGui
  button or a chat handler must not run EQ commands mid-frame. `Interrupt()`/`StopFor()` record
  the request; the pulse carries it out. Casting is registered ahead of movement so that it
  pulses first: a cast that stops the character asks on its pulse, and movement's pulse, right
  after, is what actually releases the keys.
- **Two sources decide a cast's fate and neither is enough alone.** `Me.Casting` says *whether*
  we are still casting; only the chat lines say *why* it stopped, since a fizzle, a resist and a
  stun look identical from outside. `CastOutcome` registers an `mq.event` per line and feeds the
  reason in; the sequencer checks that before anything it can work out itself. Lines arriving
  while a cast is merely *preparing* are somebody else's (a proc, a pet) and are ignored.
- **Resists arrive late.** "Your target resisted" comes after the cast bar closes, by which time
  the cast has already been reported as a success. Rather than delay every result to wait for a
  line that usually never comes, the service refines the recorded result for a couple of seconds
  afterwards — so a caller that cares about resists reads `GetResult` on the frame *after* it
  first goes terminal.
- **A behavior level with the cast still has to be asked.** The floor starves everything
  *weaker*, but the state that asked — a melee rotation firing a spell out of its own action
  list — keeps its turn, and re-sticking to the mob is exactly what loses the cast it just
  requested. `Casting.IsHoldingStill(priority)` is the question anything that moves the
  character asks first; MeleeState's stick goes through it. A cast weaker than the asker does
  not hold it back, because a buff that cannot be cast while the group is running is a buff that
  fails and says so, not a reason to stop following.
- **It never retries.** A fizzle or an interrupt is reported and the caller decides whether
  casting again is still the right thing to do; by then the mob may be dead or the heal no longer
  needed. MQ2Cast loops internally because a macro has nowhere else to put that decision. A state
  machine does.
- Preparation runs as far as it can in one frame (the steps chain until one has to wait on the
  client), so a character standing still with the spell memorized casts on the frame it was asked
  to.
- **Preparing does not give up, and there is no setting to make it.** Waiting to stand still,
  waiting to get on target, waiting on a memorize, waiting for a hand cast to finish — every one
  is a wait for something that will change, and the retry *is* the command: `/mqtarget` and
  `/memspell` are re-issued rather than failed on a timer. There was a five second budget once,
  justified as freeing the priority chain. It did not do that: both callers re-request the moment
  a cast fails, so the chain below was starved in five second bursts either way, while each new
  attempt threw away the settling the last one had done. What actually ends a cast that is going
  nowhere is the caller no longer wanting it — a decision only the caller can make, and both of
  them make it (HealState drops a heal the moment the target no longer needs it; SpellDpsState
  drops one when the target dies). A cast stuck on the same reason for thirty seconds says so once
  in chat rather than waiting silently.

  Two things that look like give-ups are not: `notReady` after a short grace is the answer to "the
  gem is on cooldown", which is a real no rather than a not-yet, and the in-flight timeouts below
  are faults rather than waits.
- What *is* bounded is everything after the command goes out, because those are faults rather than
  waits: a cast that never appears on the client is `didNotStart`, and a cast bar that never
  closes is `timedOut`.

`/ccast <name> [item | alt | gem<#>] [targetid|<#>]` drives it by hand, at the commands band, and
reports the outcome when it lands; `/ccast` alone reports what casting is doing and `/ccast off`
cancels it. Settings (memorize gem, settle window, preparation budget) live in
`configs/castingConfig.lua`, whose menu page also shows the live status.

Callers today are `/ccast` and any configured action slot holding a spell, clicky or AA (see
Action system below). The states that would use it on their own — heal, buff, cure, mez — do not
exist yet.

## Action system (`actions/`)

`ActionType` is the interface for "a thing the character can activate":
`Name / ActionType / HasAction / EndCost / IsReady / DoAction`. Implementations:

- **Skill** (`skill.lua`): melee skills via `/doability`; static registry `skills.lua` tags
  each skill with attributes (facing, targeted, primary, secondary, melee, …) and builds
  ordered category lists. Per-instance 500 ms wall-clock cooldown timer.
- **Discipline** (`discipline.lua`): combat abilities via `/disc`; `disciplines.lua` scans
  `Me.CombatAbility(1..200)` at require time and buckets by SPA (92/192 → hate) and target
  type (Single → melee). (`taunt` bucket exists but is never populated — bug.)
- **Spell / Item / AA** (`castAction.lua`): one module for all three, because what separates
  them already lives in `CastSubject` (which TLO says it is ready, which command fires it,
  whether it has to be memorized). What is left over is the same for each — and it is not
  casting: `DoAction(request)` hands a request to the casting service and returns, so the frame
  carries on while the cast takes its three seconds. The `request` (`{ owner, priority,
  targetId }`) is how the caller says who it is; `MeleeState.CastRequest()` builds one from its
  own band, which the class profile wrote onto the state at registration.

  `IsReady(request)` is deliberately stricter than the cast's own checks, because a rotation walks
  its whole list every frame and each item on it would otherwise raise the priority floor, starve
  the states below, and then fail: not without the mana, not without a target in range, and — for
  spells — **not unless it is memorized**. The request matters twice over: `targetId` is who the
  range and line of sight are judged against (a heal is chosen for a group member nobody has
  targeted yet), and `priority` is what decides whether a cast already in flight means "not now".
  A cast in flight normally does — but a caller that outranks whoever is casting is exactly who
  should take it over (`Casting.CanPreempt`), and answering "not now" to them would put the
  priority chain's whole point out of reach: a heal could never interrupt a nuke. The casting
  service *can* memorize, and anything asking for one specific cast should let it, but a
  rotation that stops to memorize mid-fight stops for eight seconds. The picker marks which
  spells are on the bar so a slot that will never fire is visible while it is being configured.

**Action** (`action.lua`) is the *persisted config shape* for a user-configured action slot:
`{ name, actionType, enabled, luaEnabled, lua, end_type, end_threshold }`. `luaEnabled`
actions gate on a user-authored Lua predicate evaluated with `loadstring` each use — this is
the replacement for MQ2Melee downshit/holyshit lines (originals kept as reference comments at
the bottom of `meleeState.lua`). `EditAction` + `ActionUI` implement staged edit/save/cancel
editing of these slots; `MeleeStateConfig` stores three lists (actions, taunt_actions,
hate_actions) with usage modes (always / as-needed / off), reachable as one set through
`GetActionLists()`.

The slot's `enabled` switch is the exception to that staging: it is not part of *describing* an
action, it is how one is taken out of the rotation while the character is fighting, so
`Action.IsEnabled/SetEnabled` read and write the live action and persist immediately. Staged, a
flip did nothing until Save was pressed (and never persisted at all), and saving an unrelated edit
later could put back the value captured when the row was first drawn — including over a flip that
came from a hotbar button. `enabled` absent means on, which is how slots saved before the switch
existed, and slots that were just added, come forward.

### Discovery (`character.lua` + the registries)

What a character *has* is read from the client, never declared: the same shadowknight has
different discs at 45 and at 70, and a different bag of clickies after every trip to the bazaar.
Each kind has a registry that answers `Get(name)` and `Refresh()`, and holds the shared instance
for each thing (so one disc's cooldown timer is one timer, however many lists it appears in):

| Registry | Where it comes from | Buckets |
|---|---|---|
| `skills.lua` | static list, filtered by `Me.Ability` | facing, targeted, primary, secondary, melee |
| `disciplines.lua` | `Me.CombatAbility(1..200)` | taunt (SPA 199), hate (SPA 92/192), melee (Single) |
| `spells.lua` | `Me.Book(1..720)` | beneficial, detrimental; sorted by level, newest rank first |
| `aas.lua` | `Me.AltAbility(groupId)` over the id space | taunt, hate, by the AA's own spell SPAs |
| `items.lua` | worn slots 0-22 and bags 23-34 | clickies only (`Clicky`, not `Spell`) |

Three things about this are worth knowing before changing it:

- **The spellbook has holes.** A spell sits on the page the player put it on, so an empty slot
  says nothing about the ones after it — the whole 720-slot array is read every time.
- **AAs cannot be listed.** `Me.AltAbility[#]` answers for one *group id* and returns nothing
  for one this character does not own, so finding them means walking the id space (bounded at
  5000). That single scan is the reason discovery is not on a timer.
- **Only `Clicky` counts** for items. An item's `Spell` is whatever spell is attached to it,
  which for most gear is a proc or a worn effect that clicking does nothing for.

`character.lua` owns all of it and keeps it current as a service: a cheap signature — level, AA
points spent, free inventory — is read every five seconds, and only the registry that signature
says has moved is re-read (a level brings discs and spells, an AA purchase brings AAs, a change
in bag space brings clickies). `/crefresh` re-reads everything, which is what covers the cases
the signature cannot see: an even item swap, or a spell scribed over another.

Everything downstream reads through these. `Actions.Get(type, name)` resolves a configured slot
against them and returns nil when the character no longer has the thing, which is what makes a
stale config harmless rather than an error; the action editor offers exactly what they hold, with
a filter box once a list passes a dozen entries, because a spellbook is not something anyone
scrolls.

## Combat (`combat.lua`) — what we are fighting

One target, whoever put it there, and everything that fights reads it. It was a field on the
melee state until a wizard needed one too: `attack <id>` has to mean the same thing to a warrior
and a wizard, and only one of them has a melee state to keep it in.

It holds no opinion about *how* to fight. The melee state gets on target and swings, the spell dps
state casts at it, a tank state will taunt it — and each decides for itself about range, whether
it is worth it, and when to give up. What Combat does is narrow:

- **Keeps the engagement honest.** The pulse drops a target that is dead or gone, which is how
  every state finds out the fight is over at the same moment.
- **Picks one up.** With `autoengage` on, an extended-target sweep (throttled to 250 ms, and only
  while the client says we are in combat) engages whatever is on us. `Auto Hater` is the client's
  own word for "this is fighting you", which beats anything we could work out ourselves.
- **Owns the `attack` order** and the `autoengage` switch, and reports on `/cattack`.

**It issues no game commands**, which is what makes `Combat.Engage` safe to call from an ImGui
button. The Attack button used to call `MeleeState.EngageTargetId`, which ran `/mqtarget` from
inside the render callback — the crash-to-desktop hazard the movement service is built around.
Targeting is now the melee state's business, done from its own pulse, because swinging is what
needs the client's target; a cast targets through the casting service.

## The two dps states

`Priorities.dps` is one band and two jobs, so it is two states: **MeleeState** walks into range
and swings, **SpellDpsState** casts from where it stands. They were one state until spells could
be cast at all, and splitting them is what stops a state called Melee from being where a wizard's
nukes live.

**SpellDpsState registers at `dps - 1`, above the melee state.** MeleeState reports busy for as
long as it is engaged — there is always another swing coming — so a rotation below it would never
get a frame. Above it, the rotation takes the frame only when it actually starts a cast and
yields the rest of the time, which is what the `- 1` in the bands was described for. A hybrid runs
both: paladin, ranger, beastlord and shadow knight all register the pair.

What each one holds:

| | MeleeState | SpellDpsState |
|---|---|---|
| Gets on target | yes, `/mqtarget` from its own pulse | no, the casting service targets |
| Movement | sticks, at the configured engage distance | none; it casts from where it is |
| Actions offered | skills, discs, AAs, clickies | detrimental spells, AAs, clickies |
| Holds back for | nothing — swinging is free | target above `start below %`, below `stop below %`, mana under the floor |
| Switch | `melee` | `nuke` |
| Action command | `action` | `nukeaction` |

The restraints on the spell side are all the same idea: a caster with none pulls the mob off the
tank, runs itself out of mana, and spends a four second cast on something that dies in two.
`start below %` is the cheapest aggro management there is — wait for the tank to land something.
Anything more specific than those three numbers goes in a slot's Lua predicate, which is the
escape hatch the action list already had.

Both states fight whatever `Combat` says, so `attack <id>` starts both, `attack off` ends both,
and `melee off` on a paladin stops the swinging while the spells carry on.

## Heal state (`states/healState.lua`)

The first state built on the casting service, and the first one whose job is a *choice* rather
than a sequence: who is worst off, which heal suits them, and whether the heal already in the air
is still the right one. The casting does not belong to it — it asks the casting service and polls
the result — and neither does holding the rest of the chain back, which the priority floor does
for it.

**One ordered list of heal slots decides everything.** A slot is an action (a spell, an AA or a
clicky) plus the health it is *for* (`hp_threshold` — use it on someone at or below this) and who
it is for (`heal_scope`: anyone, the tank, myself, anyone else). Walking that list in order and
taking the first slot that fits is how every heal macro since AFCleric has chosen a heal; what is
different is that one mechanism covers what those macros spelled out one setting at a time. A slot
at 85% scoped to the tank is TankHealPoint. A slot at 50% scoped to yourself is SelfHealPoint. A
group heal at 60% is DivArbPoint. There is no separate setting for any of them, and a class the
author never thought about needs no new setting either.

The order things are decided in, every pulse:

1. **An order first** (`healnow <id>`, `healme`). Someone asking outranks the state's own judgment —
   that is the point of being able to ask — so the slots are read only for *which* heal suits
   them: scope still applies, the health the slot was written for does not. A target already at
   full health is refused out loud rather than healed, and an order that cannot be acted on within
   ten seconds is dropped rather than landing long after it mattered.
2. **A group heal**, when enough of the group is at or below the slot's threshold (`group_min`).
   Whether a slot *is* a group heal is read off the spell (`NeedsTarget` is false for Group v1/v2),
   not configured — a group heal is what it is, and asking the user to say so is one more thing to
   get wrong. Skipped entirely while anyone is below the emergency point: three people at 60% is
   what a group heal is for, and one person at 15% is not, however many others are scuffed.
3. **Whoever is worst off**, with the first slot whose scope and threshold fit them.

**A heal in the air is reconsidered every pulse.** It is called off when the target dies or leaves,
when they climb back above the threshold that triggered it (plus a margin, so a heal landing from
elsewhere at exactly the trigger point does not make us throw ours away), or when somebody *else*
drops below the emergency point. Calling off costs the mana already spent and saves the seconds
that matter; MQ2Cast's own docs pitch this as the reason a cast returns control immediately.

Two smaller rules worth knowing:

- **A heal that lands is not immediately cast again.** The client can take a moment to report the
  new health, and without a settle window the next pulse reads the old number and casts the same
  heal at someone who no longer needs it. Anyone below the emergency point is exempt — chain
  healing a tank at 20% is the entire job.
- **Only memorized spells are used**, because that is what `CastAction:IsReady` requires of every
  action slot (see Action system). A heal that stops to memorize stops for eight seconds.

Who is watched: this character, the group (`healgroup`), and this character's pet (`healpets`, off
by default — a pet is cheaper to summon than the mana spent keeping it up). Members who are out of
zone or offline are skipped rather than counted as healthy, since a missing member counted as a
full one is a quiet way to get the group-heal count wrong. The tank is whoever holds that role in
the group window; nothing else assigns one yet, so a group with no Main Tank set has no
tank-scoped heals firing, and the Heal State page says so.

`/cheal` reports what it is doing and everyone it is watching; `/cheal off` calls off the heal in
progress. The order is `healnow` rather than `heal` because a registered phrase also matches every
longer line starting with it — a plain `heal` would fire on `healme`, `healing off` and every other
switch in the family, complaining about spawn ids nobody typed. Worth knowing before naming the
commands for the next state: **no registered phrase may be a prefix of another**.

## Config model

- `utils/Config/Config.lua`: **shared mutable store** keyed by file path — every
  `Config.new(samePath)` returns a view over the same live table, so modules freely hold
  references into subtrees. Persisted with `mq.pickle` (a Lua file, loaded via `loadfile` —
  i.e. config is executed code). One file per character.
- Each domain owns a top-level section keyed by module key — inconsistently named:
  `CommandConfig`, `DebugConfig`, `GeneralConfig`, `HotbarConfig`, `MeleeState`, `FollowState`.
- The universal pattern is init-and-validate ("taint"): on Init, write any missing defaults,
  save if anything changed. FollowState manages its section inline; MeleeState has a
  dedicated config module; states diverge here.
- `SaveConfig()` writes the whole file on every mutation. Several getters also write
  (e.g. `MeleeStateConfig.GetPrimaryCombatAbility` self-heals invalid values and saves).
- There is a `version` key (GeneralConfig) but no migration mechanism yet.

## UI model

`ui/menu.lua` owns the ImGui window ("Cabby Menu", toggled by `/cmenu`, persisted
`isMenuOpen`): left nav tree of registered Configs and States, right pane renders the
selection's `BuildMenu()`. Domains register themselves (`Menu.RegisterConfig/RegisterState`).
Panels live with their domain (`ui/states/meleeStateMenu.lua`, `ui/actions/*`,
`ui/hotbarButtonEditor.lua`). UI code still reaches into other modules' `_` privates in places
(e.g. `MeleeState._.currentAction`, the Help tab's `Commands._.registrations`) — a coupling to
remove as the facades grow real accessors; the hotbar editor goes through `Commands.GetCommand`
/ `GetCommsPhrases` / `GetSlashCommandNames` / `GetSlashCommand` instead.

**Hotbars** (`ui/hotbarsUI.lua` + `configs/hotbarConfig.lua`) are a second ImGui shell,
independent of the menu window. One render callback ("Cabby Hotbars") draws every bar in
`HotbarConfig` as its own window, so bars can be added and removed at runtime without
registering new callbacks. Buttons flow into as many columns as the window is currently
wide — resizing a hotbar turns it into a horizontal bar, a vertical bar, or a grid, and it
never goes below one column. A bar is packed to the size of its buttons: one pixel of window
padding and of gap between buttons, no scrollbar, a lowered `WindowMinSize` (ImGui floors
window size with it *after* applying our constraints), and a title of just `HB<number>` — the
bar's name would otherwise set the width of the whole window. Its minimum size is therefore one
button plus the title bar. Bars are created from the General config page; everything else is on
the right-click menus (rename, button size, add/remove button, edit a button's commands, lock the
bar's position, remove hotbar behind a confirmation modal), and the title-bar close box hides a
bar rather than deleting it. Rules the code depends on:

- **The window snaps to its grid.** Letting go of a resize squares the window off to the
  columns × rows it is laying out, trimming the slack to the right and below; adding a button
  that no longer fits grows it (there is no scrollbar to reach a clipped button with). The
  column count is *not* re-flowed to do it — it stays whatever width the user dragged to, so a
  bar pulled into a row stays a row, and a 2x2 holding three buttons keeps its empty slot.
  `GridWindowSize` is the exact inverse of `ColumnsThatFit`, which is what makes the snap a
  fixed point rather than something that shifts the layout it measured. `RequestSnap` only
  records the size; it is applied by the *next* frame's `SetNextWindowSize`, and only while the
  left mouse button is up — `Begin` has already settled the current frame's size by the time
  the layout is known, and resizing mid-drag fights the user for the window edge.

- **Locking freezes where things sit, and nothing else.** `bar.locked` adds `NoMove` to that
  window's flags, so the bar cannot be dragged off the spot it was parked on, and it takes that
  bar's buttons out of the drag-and-drop below, so a stray click cannot shuffle a bar that is
  being played off. It still resizes, still snaps to its grid, and still opens its right-click
  menus, which is what unlocks it again. The entry sits on *both* menus, like the other bar-wide
  entries: a bar packed to its buttons has next to no empty space to right-click, so the button
  menu is often the only one within reach.
- **Buttons are rearranged by dragging them**, within a bar or across onto another one, for as
  long as the bar is unlocked. Every button is both a drag source and a drop target. The payload
  (`CABBY_HOTBAR_BUTTON`, carrying `"<bar id>:<slot>"`) names the bar it came off rather than
  handing the table over — a payload can only hold plain data, and naming the source is also what
  keeps a drop onto a *different* bar from moving whatever happens to sit at that number over
  there. `MoveButton` lifts the button and inserts it at the number it was dropped on, which in
  both directions lands it *in* that slot and shifts the rest along; the index is clamped after
  the lift, since a rightward move along one bar aims at a slot that is one lower once the button
  is off it. An empty bar's "Right-click to add a button" hint is a drop target too — without it a
  bar emptied by dragging its last button away could never be dragged back into. Three ImGui facts
  this leans on: a drag only begins once the mouse passes ImGui's own threshold, so a plain click
  still presses the button; the drag source stops reporting as hovered while it is being carried,
  so letting go over the button it was lifted off does not press it either; and a window that ends
  restores the last-item state its contents clobbered, which is what lets the drag source, the drop
  target, the tooltip and the context menu all read the same button. The editor holds its button by
  identity and re-finds it across every bar each frame, so a button dragged elsewhere mid-edit takes
  its half-finished lines with it rather than having them thrown away.
- **Mutations are deferred to the end of the frame.** Menu handlers append a closure to a
  `pending` list that runs after the draw loop, so a bar or button is never removed out from
  under the iteration drawing it. Likewise `confirmRemove` is a flag consumed on the *next*
  frame: calling `OpenPopup` from inside the context menu would open the modal at the wrong
  level of the popup stack and it would vanish with the menu.
- **A press queues, it does not run.** A button holds an ordered list of command lines; pressing
  it pushes them to `CommandQueue`, which runs them on the next main-loop frame. Running a game
  command from inside an ImGui callback is the crash-to-desktop hazard described in the Movement
  section.
- **A button that carries a switch is drawn as that switch** — accented while the setting is on,
  dimmed (fill and lettering) while it is off, and left in the theme's own colours when it carries
  no switch, because an ordinary button must not read as one that is switched off. Since nothing is
  persisted about what a line means, the state is read back out of the line text every frame
  (`Commands.ReadLineState` → `Command.stateReader`), which is exactly what makes the colour follow
  a flip that came from the menu checkbox or from another character's order. Only lines that run
  *here* count — bare text and `/cself`; a `/bc stick toggle` button is an order to the others
  listening, and our own stick is not what it changes, so it stays plain. A button carrying two
  switches shows a state only while they agree, and the tooltip says it in words as well
  ("stick is on"), which is what disambiguates a button that sets a switch to a fixed value from
  one that flips it.
- **A command line is plain text, and nothing more.** It is exactly what the user could type:
  `/bc followme`, `/cself stopfollow`, `/g attack ${Target.ID}` (TLOs resolve at press time,
  through `mq.cmd`). A line with no leading slash is treated as one of our own comm commands
  issued to this character via `Commands.Dispatch` — never spoken, so a typo cannot broadcast.
  `ui/hotbarButtonEditor.lua` edits a button: label, a line list that grows as it is filled in,
  and an action picker over the live command registries (comm commands with a channel to speak
  them on, or slash commands) whose only job is `BuildActionLine` — generating that text and
  writing it into the next free line. A command that declares argument `choices` adds an Options
  row to the picker, listing what those arguments can be right now — every action slot configured
  on the Melee State page, sectioned by whether picking it switches the slot on, off, or over — and
  picking one fills in the arguments field. That field is offered only where there is something to
  type: a comm command declaring no arguments (`followtarget`, `stopfollow`) takes none, so it gets
  no box — unless the line being edited already carries arguments, which are always shown rather
  than silently kept. A choice may also say what to call a button that runs it
  (`name`), which is how a button that switches a discipline ends up labelled after the discipline
  rather than after `action` — a bar of `action` buttons says nothing about which is which. The
  picker renames only a label it set itself or has never set (tracked per edit, not persisted), so
  changing the pick relabels the button while a label the user typed is left alone. The selection
  shown in the Options row is *derived* from the arguments field
  rather than remembered, so a hand edit cannot leave the combo claiming something the line does not
  say; the field stays the one source of truth, and stays editable, because the picker generates
  text and nothing more. Once written the line is just text, which is the point:
  the picker writes `/bc attack ${Target.ID}` and the user is free to edit it into anything.
  Nothing is persisted about where a line came from. Editing is staged and applied on Save.
- **The picker reads as well as writes.** Clicking a line's number selects it and
  `ParseActionLine` — the exact inverse of `BuildActionLine` — takes it apart into the controls
  that built it, so a saved line can be changed by picking a different channel rather than by
  retyping. `Update Line` rewrites that line, `Add as New` appends instead. Because nothing was
  persisted about the line's origin, parsing is the only way back, and it is deliberately
  narrow: it recognizes `/cself`, the channel commands, and our own slash commands, and only
  when the phrase is one this character has registered (the picker cannot offer a command it
  does not have). A line it cannot represent still selects — and says so, rather than leaving
  the picker sitting on stale values that `Update Line` would write over the top of. For the
  same reason, committing a hand edit to the selected line re-parses it.
- **A button that cannot work should not be easy to make.** Three layers, because the text is
  free-form and only the last one sees every case: the picker prefills a command's declared
  default arguments and `BuildActionLine` returns *why* instead of a line when the pick is
  incomplete (no target for `attack`, no recipient for a tell, `followme` aimed at yourself);
  `CheckLine` marks a saved line with the same problems, however it was typed, but only judges
  lines carrying one of our commands and only judges an unknown phrase on `/cself`, since a
  phrase spoken on a channel may be one only the listeners have registered; and the handlers
  themselves say what was wrong when they are reached with nothing to act on, which is the only
  layer that catches a line assembled at press time out of a TLO that resolved to nothing.
- **Bar numbers are recycled**: a new bar takes the lowest number no other bar is using, so
  deleting hotbars 1 and 2 makes the next one "Hotbar 1" again. The number is also the bar's
  ImGui window id, which has two consequences — a recycled bar opens where that number's
  window last sat, and transient per-bar ui state must not outlive the bar
  (`ForgetRemovedBarState` prunes it after any mutation).

## Foundations (`utils/`) — key facts

- **Timers are OS wall-clock** (`socket.gettime`), not game time: they tick through zoning,
  pauses, and lag.
- **Debug** is per-key binary toggles; call sites build log strings eagerly even when
  disabled (hot-path garbage); file logging reopens the file per line. No levels.
- **TableUtils** is the workhorse; note `ArrayContains`/`RemoveByValue` lowercase strings
  (silent case-insensitivity that owner/name handling relies on).
- Tests exist for utils via `IntegrationTests/mqTest.lua` (gtest-style, auto-runs on
  assignment) but must run **in-client** — every module transitively requires `mq` (Debug
  requires it at top level). `testConfig.lua` is stale (asserts a removed FileSystem/JSON
  implementation; Config now uses pickle/loadfile).
- `PriorityQueue` and `Json.Deserialize` are currently unused by cabby.

## Conventions (observed)

- LuaLS annotations (`---@class/---@param/---@return`) everywhere; designed to pair with the
  mq-definitions repo.
- "Private" state under a `_` subtable; `key` field names each module for Debug toggles.
- Instance classes use `T.__index = T` + `__call → new`; singletons are plain tables with
  dot-functions (sometimes called with `:` — harmless but inconsistent).
- Naming is mixed (PascalCase, camelCase, snake_case for config keys and timer methods);
  a style guide is part of the roadmap.

---

## Target architecture (agreed direction)

The current shape is right (priority-chain states, command bus, ActionType). The refactor
is about *formalizing contracts* so the remaining 80% of features bolt on instead of being
hand-wired:

1. **Kill `Global`** → a `Context` passed at Init (config store, logger, registries). No
   side effects at `require` time (Disciplines/Character scans, mq.cmd aliases move into
   Init).
2. **Module contract + single registrar.** A cabby module declares
   `{ states, configSections, comms, events, slashcmds, menuPanels }`; one registrar wires
   Commands/Menu/StateMachine and enforces init order. Kills the per-module
   isInit/Menu.Register/tracing boilerplate and the fragile Setup ordering.
3. **Declarative class profiles** — **landed** (see the Classes section above): all sixteen
   classes declare `{ state, priority }` against shared band constants, `BaseClass` sorts and
   registers, and a class that cannot really be played says what is missing at startup rather
   than crashing on `class.Init`. Still open: **constraints** on an entry, and adjusting
   priorities at **runtime** by role config and group makeup (no cleric present → hybrid
   heals tighten), which needs the states that would be adjusted.
4. **Crash barrier with loud errors.** pcall around each state `Go()` and event handler,
   but an error must never disappear into chat scroll: (a) an unmissable ImGui alert window
   (separate from the menu, requires dismissal), (b) full traceback appended to a log file,
   (c) dedup by traceback signature — a per-frame recurring error reports once with a
   running count, not spam, (d) after N consecutive failures the state auto-pauses and the
   alert says so; the user re-enables after fixing.
5. **Cadence:** keep the base loop modest (~10–25 ms) so priority changes and commands
   still react fast; put the cost control in per-state throttles — cheap
   `IsEnabled`/precondition checks may run every frame, expensive TLO work (XTarget sweeps,
   spawn searches) sits behind short timers with cached results so falling through many
   states stays cheap.
6. **Config Section helper:** each section declares schema + defaults + migrations once;
   getters stop writing; section keys become uniform.
7. **Split commandConfig** into store / bridge / UI; the generic editor takes a spec table
   instead of 14 positional params.
8. **Channel known at dispatch.** The capture patterns (`#1#`/`#2#`/`<<phrase>>`) are the
   info-extraction layer for commands and stay exactly as they are. What changes: each
   per-channel registered event already implies its channel, so pass that through to
   handlers/`Respond` instead of re-deriving it afterward by regexing the line
   (`Speak.GetRequestChannel`).
9. **Plugin independence.** Movement is **done** — `utils/Movement` replaced MQ2MoveUtils and
   MQ2AdvPath and neither plugin is loaded (see the Movement section above). Casting is **done**
   the same way: `utils/Casting` covers what MQ2Cast was wanted for and the plugin is not loaded
   (its source sits in `plugins/MQ2Cast` as reference for EQ's casting mechanics). Still open:
   transport. Native chat channels (tell/group/raid) are already plugin-free; MQ Lua actors
   (routed between same-machine clients by the launcher post office) become the structured-
   message backend; EQBC stays optional for bc/bct until then (open decision). MQ2DanNet is
   never adopted.
10. **UI stays colocated with its domain** (panels next to the code they control — intended
    design), but panels read through public status accessors instead of `_` privates
    (`MeleeState._.currentAction`, `Commands._.registrations`).
11. **mq facade injection** so pure logic (state transitions, command parsing, config
    validation) can be unit-tested off-client.
