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
       │                       (MeleeStateConfig is initialized by MeleeState, which every class
       │                        registers now, so every character gets a melee config section)
       ├─ CommandQueue.Init  — registers the command queue service (what UI presses run through)
       ├─ CabbyCasting.Init  — registers the casting service, its priority gate + /ccast
       ├─ CabbyMovement.Init — registers the movement service + /cmove
       ├─ Character.Init     — registers the discovery service + /crefresh
       ├─ Roles.Init         — registers /croles (who holds which job in the group)
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
| 19 | Flee (travel mode) / passive | 79 | DPS (melee/spells) |
| 29 | Cure | 89 | Looting |
| 39 | Heal | 99 | Anchor |
| 49 | Pulling | 109 | Following |
| 59 | Mez (in combat) | 119/129 | Buff / Rest (misc) |

A bigger number is weaker. The gaps of ten are room for "the same job, but not as strongly":
`Priorities.heal + 5` is a hybrid healing below the class that heals for a living. Classes
name a band per state rather than ordering their `Register` calls by hand — see below.

**Priority gates** (`RegisterPriorityGate`) are how a *service* is busy at a band. A state that
yields hands the frame to whatever is below it, which is right for work that can be picked up
again next frame and wrong for work already in the air: a three second heal is lost the moment
the follow state below it walks off, and a cast can be in the air with no state holding a frame
for it (`/ccast` from a hotbar). A gate returns the weakest priority allowed to run right now,
and `runChecks` skips every state weaker than that — exactly as if a state at that band had
returned busy. The priority a state was registered at is kept for exactly this
(`Register(state, priority)`, `GetPriority(stateOrKey)`); a state registered without one is never
starved, since there is no way to judge it.

A floor is all a gate may say. It cuts a contiguous tail off the chain, which is the only shape
the ordering can express — no exemptions, no holes, no out-of-band suppression. A job that must
keep running below somebody's floor is a job registered at the wrong band, and the fix is where
it sits: travel mode is the worked example — flee suppresses by returning busy at the passive
band and drives the traveling core (`travel.lua`) itself, where it once gated the chain and
exempted FollowState. One gate exists: **casting**.

**Busy signals are the whole of cross-state coordination, and the chain is the only arbiter.**
What position promises a lower state is exactly this: *a frame you are given is a frame nothing
above you wanted*. That guarantee is all a state ever knows about the states around it — a state
never reads, models or compensates for another state, and finding yourself wanting to is the
smell that some busy signal upstream is lying. Signals must therefore be **domain-honest and
continuous**: "we are in a fight" is continuous across one mob dying and the next picking up, so
`IsEngaged` is too (Combat holds a lost-target fight open while it seeks the successor — see
Combat), and a gap in any signal built on a continuous fact is fixed at the service that owns the
fact, never by teaching a downstream state to distrust its frames. Reading a **service** is
different and fine: services act without owning frames, so their published facts are the only way
not to contradict them — RestState holding for Combat's engagement and Movement's driving is
that, not state-to-state knowledge. And the machine itself never pads any of this: no linger, no
held frames, re-arbitration from the top every pass, an order landing on the next pass its state
is entitled to. The windows a state keeps (retry throttles, a grace before undoing the player, a
settle over a genuinely flickery world read) pace only that state's own actions, and never
measure the scheduler.

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
  roles.lua           reader: main tank / main assist, out of the group and raid windows
  travel.lua          the traveling core: follow/anchor orders, trail-follow, and following
                      through zone lines -- clicking a switch, or walking through after a target
                      that vanished mid-stride where there is none; driven by FollowState
                      (follow band) or FleeState (passive band), whichever the chain gives the
                      frame to
  stateMachine.lua    priority-chain loop + per-frame services + priority gates (instance class)
  movement.lua        wiring only: registers the movement service and /cmove
  casting.lua         wiring only: casting service, its priority gate, movement arbiter, /ccast
  commandQueue.lua    service: runs command lines pushed from ImGui callbacks, a frame later
  character.lua       capability snapshot: which skills exist (primary/secondary/melee lists)
  status.lua          shared predicates (IsFacingTarget)
  states/             baseState, fleeState, followState, meleeState, spellDpsState, healState,
                      buffState, advLootState, restState
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
reports (`Me.Class.ShortName`) to a module path and requires only that one, so a character
never loads the states of a class it is not.

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

- **Every class flees, follows, rests, melees — and minds the loot window.** FleeState,
  FollowState (which is also anchor and click-to-zone — one state, one `Go()`), RestState,
  MeleeState and AdvLootState are the five jobs that have
  nothing to do with what the character is, so no profile has to remember to ask for them. Flee is
  there for a second reason as well: it is not a job at all but the absence of every job below it,
  so what it holds back is the same list whatever the character can do. It is also the only state
  handed the state machine at `Init`, because a gate has to be registered with the machine that
  consults it. Melee
  comes in at `dps + 5` rather than `dps`, weak enough that a caster's rotation always gets the
  frame first. A profile naming the same state wins over the common entry, priority and all,
  which is how a class moves follow somewhere else in its chain — and how the melee classes keep
  their melee at `dps`.
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

Which states a class registers is the only capability judgment made here. **Every class melees**,
because anyone can swing a weapon — but not at the same strength. The nine melee classes (WAR,
PAL, SHD, MNK, ROG, BER, RNG, BST, BRD) declare **MeleeState** themselves at `Priorities.dps`;
everyone else picks it up from the common states one step weaker, at `dps + 5`. The gap is the
capability judgment: the melee state reports busy for as long as it is engaged, so at `dps` a
caster's swing would be as important as a warrior's, while at `dps + 5` it only gets the frames
the spell rotation passed on. It is also off in config until switched on, so what a cleric gains
is the option, not the habit — the ordering is what stops it walking into melee instead of
healing. A shaman played as a melee on emu moves the entry up by declaring it in its own profile.
The eleven classes that can hurt something with a spell register **SpellDpsState** a band above
melee, which for a hybrid means both. The three
priests heal, and so do the three hybrids that can (PAL, RNG, BST) — but a band lower
(`Priorities.heal + 5`), which is the whole reason the bands are numbers: a paladin's heal has to
land below a cleric's, and that is only checkable if both name the same band. A druid or shaman in
a group with no cleric should tighten to the full band, which needs the runtime priority
adjustment that does not exist yet. The twelve classes with a spellbook register **BuffState** at
the buff band; the four with none (WAR, MNK, ROG, BER) do not, since a buff list holding nothing
but clickies is not enough of a job to be a state. Everything
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
- **Events** (`Event`): raw line patterns (group invite, generic tell-forwarder). One pattern can
  need more than one `mq.event` to be heard (see Chat timestamps), so an event holds a list of the
  ids it is registered under. `reregister` flag re-adds them last so catchall patterns sort after
  specific ones.
- **Slash commands** (`SlashCmd`): `mq.bind` wrappers (/chelp, /cself, /debug, /activechannels,
  /speak, /owners, /state, /cmenu, /restart).

**Chat timestamps.** Some clients (RoF2 client-plus among them) stamp every chat line, and MQ
feeds Blech the line as rendered — so `[23:39:30] Haedes tells you, 'followme'` is what the
patterns actually see. Blech matches the *whole* line, which splits the patterns three ways, and
the handling is different for each:

Blech files each pattern under the first character it can match and tests a line only against the
patterns filed under the line's own first character, plus those filed under "starts with a
variable" — which is what decides each case:

- A pattern starting with a scan variable (`#1#`, `#*#` — tell, group, raid, and both raw events)
  is tested against every line, so it still matches, but the wildcard swallows the timestamp into
  the speaker capture. Since the first thing every handler does is an ACL check, the symptom is a
  character that silently ignores its own owners — and, for the group-invite event, one that
  actively `/disband`s every invitation it is sent.
- `bct`'s `[#1#(msg)]` also still matches, because the timestamp's own `[` satisfies the leading
  literal; it captures from inside it (`23:39:30] [Haedes`).
- A pattern starting with literal text — `bc`'s `<#1#>`, or an event like `You have been slain by
  #1#!` — is filed under that letter and never tested against a line beginning with `[`. Those are
  not refused, they are never heard, and nothing says so.

So there are two fixes, and the second is narrower than it looks. `Speak.CleanSpeaker` takes the
name back off the end of the capture (EQ names are letters, chat carries the first name alone),
applied once in `protectChatHandler` — the wrapper every comm command and raw event already passes
through, and slash commands deliberately do not, having no speaker. And `Speak.GetListenPatterns`
expands a pattern into everything that has to be registered for it to be heard: itself, plus a
timestamped copy **only where the plain one cannot match a stamped line**. Giving one to the others
would be actively harmful: the line would match both patterns, every command would run twice, and
on a toggle that is two flips and no visible effect.

Both registration paths expand through it — `Speak.GetPhrasePatterns` for comm channels, where it
is `bc` alone, and `Commands.RegisterEvent` for raw events, which is why an `Event` carries a list
of mq event ids the way a `Command` does. No pattern registered today needs the copy (both events
open with `#1#`), but the shape that does is the ordinary one for a raw event: a line about the
world rather than about a speaker starts with literal text. Registering an event pattern any other
way is how one gets added that never fires. `Speak.Respond` needs nothing — `GetRequestChannel`
searches with `string.find` rather than anchoring, so it already tolerates the prefix.

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
`stick`, `tanking`, and `bashoverride` for characters that can bash; Combat registers `autoengage`
and `callassist`; HealState
registers `healing`, `healgroup` and `healpets`; BuffState registers `buffing`, `buffgroup`,
`buffpets` and `buffcombat`. Switches that have to call off work in progress
rather than only stopping new work go through the *state* rather than the config, so the
checkboxes get the same behavior: `melee off` resets the state, `stick off` releases the stick
Movement is still holding, `healing off` interrupts the heal in the air, and `resting off` stands
the character up (through the command queue, since a checkbox calls the same setter).
RestState registers `resting` and `restcombat`.

**Action lists are commands too** (`commands/actionCommand.lua`). Any state with configured action
slots gets `<phrase> <on | off | toggle> <part of an action's name>` from the same factory —
`action` for the melee lists, `healaction` for the heal list, `nukeaction` and `buffaction` for
theirs. Exact name wins; failing that every
slot whose name contains the fragment is switched together, so they end up agreeing rather than in
opposite states. `/chelp action` lists those slots with their current state, which is also what the
button editor's docs pane shows while the command is picked, and the choices it offers are the
slots configured *right now*, each of the three ways they can be switched.

**The local ("self") channel.** `Speak.channelTypes.self` is a channel that never touches chat.
`Commands.Dispatch(line)` hands a comm phrase straight to its registered handler with our own
name as the speaker, synthesizing the line the handler would have seen (`Speak.BuildLine`) so
nothing downstream — `Respond()` included — can tell the difference; replies land in our own
console via `/echo`. `/cself <command>` is the slash command form, and hotbar buttons use it.
This is what makes an order meant for *this* character possible at all: a `/bc followme` is an
order to the others on the channel, not to its speaker. eqbcs localecho (on by default) loops
our own broadcasts back to us as ordinary chat lines, so `protectChatHandler` owner-gates any
channel line spoken by our own name — it runs only if we are listed as an owner or the list is
open, the same terms as anybody else. Local channels are excluded from active-channel lists and
from `GetPhrasePatterns` — there is no chat line to listen for. `Owners:HasPermission` always
says yes to our own name, so dispatching to ourselves does not require listing ourselves as an
owner; that unconditional trust belongs to the local channel alone.

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
StuckDetector.lua   summed travel over wall-clock windows
Unsticker.lua       escalating recovery: alternating strafe first, jump only on a repeat attempt
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
- **Follow holds a buffer zone, sticks and moves do not.** `Follow` takes two ranges — it closes
  to `distance` (20 for `followme`/`followtarget`, comfortably outside melee range and deliberately
  so) and then holds until the target is `resumeDistance` away (35), rather than re-closing the moment
  they take a step. The two are tuned together — what matters is the room between them, so moving
  one without the other either parks the group on the leader or thins the buffer to nothing. One threshold
  makes a follower a shadow, matching the target's every move to the inch, which is what being
  followed by a bot looked like before. The hysteresis is one bit of task state, so *which*
  threshold applies is only knowable from the task: `Follow:WithinHold` and `IsParked` are the
  readings, and FollowState asks `Movement.IsParked()` rather than measuring the distance itself.
  Nothing else inherits this — `m2m` is a `MoveTo` and still arrives exactly, and `Stick` holds
  its engage range for melee, where a buffer would be a swing missed.
- **The trail is the route, and the route is walked exactly** (2026-07, replacing beeline-on-sight
  at the user's direction — the `/afollow` model from MQ2AdvPath). `Follow` samples where the
  target has been into breadcrumbs and replays them corner for corner whether or not the target is
  visible, because line of sight is not walkability: a leader visible below a ledge, across a
  chasm railing or down a switchback is one confident straight line away over a drop. The route
  they walked is the one route known walkable, so it is the only thing we steer at; the spawn's
  own position is used for arrival (the hold buffer above ends the replay wherever the trail
  happens to be) and as the destination once the trail runs out, nothing else. What keeps the
  replay from being the drunk walk that beelining was invented to avoid: every pulse the trail is
  dropped through the furthest breadcrumb we are *standing on*, wherever in the trail it is, and
  holding at the target retires the whole route that got us there — so the trail drains instead of
  stockpiling camp wander, and a stale head reconnects the moment the target comes back to us or
  their route crosses ours; a backward jog recorded off a rubber-banding
  target is skipped by arc (MQ2AdvPath's ClearLag); and the radius that counts as "reached" widens
  with our own per-pulse travel, so background frame rates do not orbit waypoints they can no
  longer stop inside (the `leadPulses` actuation-lag reasoning applied to waypoints). A jump in
  the target's position too big to be walking is recorded as a **warp seam**: the follower walks
  the trail to the seam and parks there — `IsParked`, so resting works while waiting — rather than
  walking a leg nobody walked, and a target that is gone fails the task at the seam so Travel's
  zone-line logic takes over. `Follow:Describe` (so `/cmove` and the Follow State panel) reports
  **trailing (N waypoints)** or **waiting out a warp**.
- **Arriving leads by half a pulse, measured on the gap.** The stop test is
  `distance - closing/2`, where `closing` is how much the *distance to the target* shrank since the
  last pulse — not how far we moved. Stopping is decided once per pulse, so a pulse of closing is
  the error bar on where we come to rest: testing the gap as it is now is always a pulse late, and
  aiming half a pulse ahead centres the miss on the range we asked for. Own-speed is the wrong
  measure because a leader running back through the group closes the gap at both speeds at once,
  which is exactly when a follower ends up stood on them. `Follow:Describe` reports the gap and the
  per-pulse figure, so a large `/pulse` number in `/cmove` is the loop being too slow to stop on a
  mark — a thing no threshold can fix.

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

Callers today are `/ccast`, any configured action slot holding a spell, clicky or AA (see Action
system below), and the three states that ask for casts directly: heal, spell dps and buff. Cure
and mez do not exist yet.

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

## Roles (`roles.lua`) — who holds which job

Main tank and main assist, read out of the client and never configured. The group window already
answers this and every EQ player already sets it, so a group that reassigns the tank mid-session has
said everything it needs to say and no cabby character has to be told separately.

It **reads and nothing else** — whether a role is worth acting on belongs to whoever asks.
`combat.lua` uses the assist's target to decide what to fight; `states/healState.lua` uses the tank
to decide who a tank-scoped heal is for. That split is what lets the tank matter to the healer
without the healer knowing anything about how the group engages.

Two client facts shape what can be answered:

- **Main tank is a group role, and only a group role.** The raid window has a main assist (three of
  them) and a leader, but no tank — inside a raid the tank of *this* group is still the group
  window's, which is what a healer wants anyway. Main assist is read from the group window first,
  since a group inside a raid is often working on something of its own, and falls back to the raid's.
- **The assist's target comes from the client, not from watching them.** There is no TLO for what
  another player has targeted; what there is, is the client's own assist target
  (`Me.GroupAssistTarget`, `Me.RaidAssistTarget[#]`) — the same value `/assist` and the group
  window's assist display work off.

`Roles.Matches(role, id, name)` is how anything else asks "is that them": by spawn id where both
sides have one, by name otherwise, since a role holder out of the zone has no spawn and the group
window works in names either way. Everything is cached behind one 250 ms scan, because the menu
pages read it every frame. `/croles` reports it and refreshes first.

## Combat (`combat.lua`) — what we are fighting

One target, whoever put it there, and everything that fights reads it. It was a field on the
melee state until a wizard needed one too: `attack <id>` has to mean the same thing to a warrior
and a wizard, and only one of them has a melee state to keep it in.

It holds no opinion about *how* to fight. The melee state gets on target and swings, the spell dps
state casts at it, a tank state will taunt it — and each decides for itself about range, whether
it is worth it, and when to give up. What Combat does is narrow:

- **Keeps the engagement honest, continuity included.** A fight outlives any one target: losing
  one to a death or a despawn does not close the fight, it opens a **seek** — `IsEngaged` stays
  true with `GetTargetId` at 0 while the sweep runs every pulse for up to `fightLingerMs` (500 ms)
  looking for the successor, and only an empty seek, an order (`attack off`, an `assist off`
  call), or flee actually closes it. This is what the chain's blocking runs on: the states that
  fight hold their frames off `IsEngaged`, so "the fight is over" blinking true between two mobs
  — because the extended target window is a beat behind a corpse — would hand one frame to the
  bottom of the chain in the middle of a pull. It did, once: that was the warrior sitting down
  mid-fight. The linger is deliberately shorter than any real gap between pulls, because between
  pulls the fight *is* over and falling through to rest is the design working.
- **Picks one up.** With `autoengage` on (throttled to 250 ms; every pulse while seeking), the
  main assist's target first and an extended-target sweep after it — see Assisting below.
  `Auto Hater` is the client's own word for "this is fighting you", which beats anything we could
  work out ourselves.
- **Honors a fight started by hand**, above the `autoengage` gate: the player's attack being on
  while the client says real combat has begun engages the client's target as an order. The combat
  flag is asked as well as the toggle because the toggle alone is not intent — autoattack survives
  a kill, and a leftover toggle plus a curious click must not order a charge. The `engageonattack`
  switch (off by default) reads the *press itself* as the order instead: the moment the toggle
  turns on, the target under it is engaged with no wait for the swing or the aggro, so pressing
  attack at range is a charge. Only the turning-on reads that way — what a leftover toggle may do
  is unchanged — and Combat watches the toggle every pulse without exception, so a press consumed
  while engaged (our own melee turns the swing on) is never saved up to fire late.
- **Honors calling it off by hand**, behind two switches (both off by default). With
  `disengageonattackoff`, the player switching auto attack off closes the fight the way the Back
  Off button does, seek and all — edge-read like the press, so only the act itself orders
  anything, and a toggle *taken* rather than chosen (a mez, a charm or a stun dropping auto
  attack) orders nothing. With `disengageontargetclear`, the player clearing the client's target
  while it sits on the fight's own, still-standing mob does the same — a clear of anything else
  (the group member a heal targeted, a mob being inspected) is not an order, and the world taking
  the target (the death, the poofed corpse) is the seek's business, not this switch's. Neither
  reads while flee is on: travel drops auto attack every pass as bookkeeping, and the flee order
  has already said everything there is to say about the fight.
- **Owns the `attack` order**, the `assist` call, the `autoengage`, `callassist`,
  `engageonattack`, `assistonengage`, `disengageonattackoff` and `disengageontargetclear`
  switches, and reports on `/cattack`.

**It runs no game command that decides anything**, which is what makes `Combat.Engage` safe to call
from an ImGui button. The Attack button used to call `MeleeState.EngageTargetId`, which ran
`/mqtarget` from inside the render callback — the crash-to-desktop hazard the movement service is
built around. Targeting is now the melee state's business, done from its own pulse, because
swinging is what needs the client's target; a cast targets through the casting service. The one
thing Combat says out loud — the tank calling the assist — is said from `Pulse` and nowhere else,
for that same reason.

### Assisting — how a group ends up on one mob

Six characters that each fight whatever is hitting them are six characters fighting one mob each.
What turns them into a group is the two roles the group window already holds (`roles.lua` reads
them), and the two directions they work in are deliberately different mechanisms, because one of
them cannot be relied on everywhere:

- **The main assist's target says what the group is on.** Read from the client's own assist target
  (`Me.GroupAssistTarget`, falling back to `Me.RaidAssistTarget[#]`), which is the value `/assist`
  and the group window's assist display work off — there is no way to read what another player has
  targeted, and this is the client being told. Where a server does not keep it current it reads as
  "the assist is on nothing", and everything below still works.
- **The main tank's call says when.** Whoever holds the tank role says `assist <id>` out loud every
  time what they are fighting changes, and `assist off` when they drop it. That depends on nothing
  but chat, so it is the path that carries a group whose server says nothing about assist targets —
  and it is also the answer to "the tank wants everyone to stop", which no amount of target-reading
  can express.

Which gives three ways an engagement is decided, and `Combat.sources` records which, because that
is what says whether something weaker may replace it:

| Source | Set by | Replaced automatically? |
|---|---|---|
| `order` | `attack <id>`, the Attack button, attacking by hand | no — somebody chose it |
| `assist` | an `assist` call, or the assist's target | only by the next call |
| `hater` | the extended-target sweep | no, while it lives |

Rules the code depends on:

- **A call is an order, the assist's target is not.** `assist <id>` engages exactly as `attack <id>`
  does, ACL and all. The *reading* of the assist's target only ever picks a fight up when there is
  none: it asks for something fightable — an NPC, a pet, a destructible object; never a player and
  never a corpse — that has **taken damage**, which is the difference between a thing the group is
  fighting and one the assist targeted to read the name off. That check is why there is no
  assist-percentage setting — the call is what opens a fight, and the read is only the standing
  question of what the group is already on.
- **The assist never assists itself.** A character holding the role reads its own target back
  through that TLO, so following it would mean attacking whatever it looks at. `Roles.IsMainAssist`
  is checked first.
- **One line per target, not a heartbeat.** The tank calls on change only. A character that misses a
  call has its own auto-engage to fall back on, and chat that repeats itself is chat nobody reads.
  Not calling is not the same as having called nothing: losing the role, or the switch, forgets what
  was said, so getting either back re-announces the fight rather than assuming everyone heard.
- **Called off as loudly as called on.** The tank dropping its target says `assist off`, which is
  what makes the Back Off button and `flee on` stop the whole group rather than one character —
  both end with the tank disengaged, and the next pulse says so.
- **A call is refused while fleeing**, for the same reason the sweep is: nothing would act on it
  during a run, and the engagement would come back the moment the run ended.
- Unlike `attack`, a call is not range- or line-of-sight-checked. It arrives the instant the tank
  engages, which is exactly when the rest of the group is still coming round the corner; refusing it
  there would drop the one call that mattered. Whether the thing is reachable is each state's own
  question, asked again every pass.

`callassist` is the switch on the calling side, on by default and silent on every character that is
not the tank; the call goes out on that command's own speak channels (`/speak assist`). `/cattack`
reports all of it: the roles, what the assist is on, and where calls are being spoken.

`assistonengage` (off by default) is the calling side with no role in front of it: a character
carrying it announces its own fights — and calls them off — exactly as the tank does, on the same
speak channels and through the same one-line-per-target machinery. It is how a group is led by
whichever character the player is actually driving rather than by the group window's roles; with
`engageonattack` beside it, the driver's own attack key is the whole chain — the press starts the
fight, the fight is announced, the group joins it — and the `disengageonattackoff` /
`disengageontargetclear` switches close the loop, turning the same key (or ESC) into the
group-wide off-call.

- **The call falls back to the group channel**, alone among the things cabby speaks. Every other
  `speak` is a *report* — "cannot see you to heal you", "I failed to click into the zone" — and a
  character with no speak channels keeping those to itself is a reasonable thing to be. This one is
  not a report: it **is** assisting, it is on by default, and with an empty speak list the group
  hears nothing and is told nothing about why. An empty list is not how the feature is turned off;
  `callassist off` is.

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

Both states fight whatever `Combat` says, so `attack <id>` starts both, `attack off` ends both, an
`assist` call from the tank starts both, and `melee off` on a paladin stops the swinging while the
spells carry on.

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
full one is a quiet way to get the group-heal count wrong. The tank is whoever `roles.lua` says
holds the role, which is also how a hybrid holding it is tank-scoped to *itself* — reading the flag
per group member could never say so, since we are not one of our own group members. A group with no
Main Tank set has no tank-scoped heals firing, and the Heal State page says so.

`/cheal` reports what it is doing and everyone it is watching; `/cheal off` calls off the heal in
progress. The order is `healnow` rather than `heal` because a registered phrase also matches every
longer line starting with it — a plain `heal` would fire on `healme`, `healing off` and every other
switch in the family, complaining about spawn ids nobody typed. Worth knowing before naming the
commands for the next state: **no registered phrase may be a prefix of another**.

## Buff state (`states/buffState.lua`)

The same shape as the heal state — one ordered list of slots, walked in order — asking the
opposite question. Healing asks *who is worst off*; buffing asks *what is missing*, and the honest
answer to that is only partly readable.

**A buff slot is an action plus who it is for.** `buff_scope` (anyone / myself / anyone else) and
`buff_classes` (the classes worth spending it on, empty meaning all of them). That second dial is
what buffing needs and healing did not: clarity is for casters and strength is for melee, and a
bot that cannot say so either wastes half its casts or grows a setting per buff line, which is
what the macros it replaces did.

**Everything else about a slot is read off the spell**, in the same spirit as the heal state
reading group heals off `NeedsTarget`. The spell's target type says where it can be aimed — at
me (`self`), at a pet (`pet`, `pet2`), at the whole group in one cast (`group v1/v2`), or at one
person at a time — so a pet buff is for pets whatever the slot says, and scope is only offered
where there is somebody to choose between. The spell's duration says how long what it lands
lasts, and a slot whose spell has *no* duration is not a buff at all: the picker offers the whole
beneficial half of the spellbook, heals included, so a heal ending up in a buff list is a mistake
worth catching rather than one worth casting on a loop. The page says so on the row.

**Three questions decide every pairing**, cheapest first:

1. **Is it on them, and how long has it got?** `Me.Buff[x].Duration` for ourselves,
   `Me.Pet.BuffDuration[x]` for the pet, `Spawn[id].CachedBuff[x].Duration` for anybody else —
   all three in milliseconds. Under `rebuff_secs`, it is worth recasting; over, it is not. That
   one dial is the whole of the timing model, and the escape hatch for anything more specific is
   the slot's own Lua expression, as it is everywhere else.
2. **Would it land?** `Spell.Stacks` / `StacksPet` / `StacksSpawn[id]`, which answer more than
   "do they already have it": a better buff in the same line, or a buff too powerful for them to
   take, both come back as no without a cast being spent to find out. For ourselves,
   `Me.BlockedBuff` as well — a blocked buff reports as cast and never appears.
3. **How long is that answer good for?** This is the part buffing has and healing does not.
   Another player's buffs are visible only once the client has cached them, which happens when
   they are *targeted*, and an empty cache is indistinguishable from a clean one —
   `StacksSpawn` says yes to a spawn it knows nothing about. So the fact that we cast something is
   sometimes the only record there is, and each (slot, spawn) pairing carries a time before it is
   worth asking about again: the buff's own duration less the rebuff window after one lands, a few
   seconds after one fails. It is not a give-up timer, and it is dropped wholesale by
   `/cbuff refresh` or the Check Everybody Now button — which is what to reach for after somebody
   has been dispelled. A cached entry ages by itself (it reports what is left *now*), so a stale
   cache decays into "they need it" rather than lying about it.

The order things are decided in, every pass that looks:

1. **Reasons to hold.** Not during a fight (`in_combat`, off by default — buffing mid-fight spends
   the mana the healing wants and holds the target away from what is being fought; a fight starting
   also calls off the buff in the air), and not while running. The second is a choice rather than a
   necessity: the casting service would happily wait to stand still, but it would wait holding a
   target and a gem, and a state at the bottom of the chain can afford to ask again later. Bards
   are exempt, since they sing on the move and the casting service knows it.
2. **The first slot somebody is missing.** List order is the whole priority — unlike healing there
   is nobody to rank, since everyone standing here is equally unbuffed, so the ordering that
   matters is the one the user already gave. A group buff is cast as soon as one person in scope is
   short of it, and covers the rest.

Who is watched: this character, the group (`buffgroup`), this character's pet (`buffpets`, on by
default — unlike healing a pet, a buff is cast once and lasts the session), and whoever asked
(`buffnow <id>`, `buffme`), who does not have to be in the group at all. That last is the buff-bot
case the old hail macros existed for: an order is not one cast but "give them everything they are
missing", so it stays open until a run of casts goes quiet rather than ending on the first one.

**This state gets its frames because follow yields.** At `Priorities.buff` it sits below following,
which reports busy only while it is actually walking — so buffing happens exactly when the group is
standing still, without any of the `- 1` band juggling the two dps states needed.

`/cbuff` reports what it is doing and how many buffs each person is missing (worked out on demand;
it is a whole pass over the list per person). `/cbuff off` calls off the buff in progress,
`/cbuff refresh` forgets what was worked out about who has what.

## AdvLoot state (`states/advLootState.lua`)

Loot etiquette for the akk-stack advloot system: whoever controls the loot deals with the items,
and everybody else answers **Pass** to every roll nobody has answered, so no roll ever waits on
this character.

This is written against the custom system, not live EQ's. The RoF2 client has no native advanced
loot window, this MacroQuest build compiles its `AdvLoot` TLO out entirely (it exists only for
clients dated 2015+), and the server never fills the client's master-looter group role — so
`${AdvLoot}`, `/advloot shared <n> no` and `${Group.MasterLooter}` are all dead ends here. What
exists instead is `lootwnd.asi` (akk-stack's client mod): a real SIDL window, **`AdvLootWnd`**,
twelve rows of `ADLW_*` controls that MacroQuest can read with the `Window` TLO and click with
`/notify`. The server decides who controls the loot — the group's delegated looter if one is set,
otherwise the leader; solo and raid characters control their own — and tells the window.

**The window is the world, and it already knows everything**, so the state asks nothing about the
group at all:

- a row is *showing* while its `ADLW_Name<r>` label is visible with text in it;
- it is *rolling* while its `ADLW_Loot<r>` button says **Need** — free-for-all loot (solo kills,
  and anything still locked when the corpse's decay clock runs short) relabels the row's buttons
  Loot/Give/Sell, and that last one is why the mode is checked at all: **the Pass button of a
  rolling row is the Sell button of a free-for-all row**;
- it is *unanswered* while the vote buttons are still visible — the window hides them the moment
  a vote goes out, and a vote is irrevocable;
- it is *ours to deal with* while `ADLW_Roll<r>` (the controller-only Lock/Unlock button) is
  visible. The state passes only on a row whose controller button it can **positively see
  hidden** — an unreadable row is treated as ours, because passing wrongly is how the whole group
  ends up passing, and a roll everybody passed on strands the item on the corpse.

**Only Pass is ever clicked** (`/notify AdvLootWnd ADLW_Never<r> leftmouseup`, only while the row
reads as a roll). Everything else on that window is somebody's decision or a permanent one: Give
hands the item to whatever we happen to have targeted, the four Always buttons write per-item
preferences into the database, Deny opts out of the coin split, and Need/Greed are wants this
state does not have. A roll the player already answered is never touched, and rolls have no
deadline of their own — the corpse's decay clock is the only timer, and it belongs to the server.

**Every answer comes from a look taken this pass**, one click per settle window. The window
compacts rows upward whenever one clears, so a row number even a quarter second old can name a
different item by now; the scan and the click it decides on share a frame, and the passes in
between hand their turn straight down. The settle window is an evidence window on our own click —
the row disappears at once, but the server's tally messages are in flight around it, a vote is
irrevocable, and a second one is answered with "You have already rolled".

Where it sits does the rest (`Priorities.loot`, registered for every class by `BaseClass` — what
to do with loot has nothing to do with what the character is): below the fighting bands, so
nothing is answered ahead of a swing mid-fight, and above follow and rest, so a stack of rolls is
cleared promptly once the fighting is over.

`advloot` is the switch, `/cadvloot` reports the controller, what is waiting on us, and what is
showing. (The phrase is cabby's own comm command over chat; the client mod separately owns the
`/advloot` slash command, which this state never uses.)

## Rest state (`states/restState.lua`)

Sitting to get health, mana and stamina back. The job is one sentence — sit while something is
short, stand once nothing is — and what makes it work is *where* it sits rather than what it does.

**It is the weakest state in the chain** (`Priorities.misc`, registered for every class by
`BaseClass` alongside follow). That is the whole design: it runs on exactly the frames nobody else
wants, which is what "at rest" means in practice — parked on an anchor, caught up behind whoever we
follow, or standing around after a fight. Everything above it gets first refusal every pass, and
the services take the character back without being asked: movement stands it up out of a sit when a
task starts (the pause gate), and the casting service stands it up before a cast. So the state
never has to argue for the character, and nothing above it has to know it exists.

**"Should I be sitting right now" is asked from the world every pass** and read both directions:
sitting when the answer turns yes, standing when it turns no. That is what makes it safe, with no
held mode to go stale.

**The one thing it remembers is whose sit this is**, because the world will not tell it. There is
no TLO for "the user pressed the sit key", so ownership is inferred from what was asked for: a sit
that turns up while this state's own `/sit on` is still outstanding (two seconds, since the server
answers inside a ping) is ours, and every other one is not. It is confirmed against the world every
pass — the moment the character is not sitting, the sit is not ours — so it cannot go stale the way
a remembered *mode* would.

A sit that is not ours is left alone entirely, at any threshold and against every reason to be
standing. The reason somebody sat down is not readable from here, and the commonest one — the
spellbook, which only opens sitting — is destroyed by standing up. That is also why the state will
not stand out of *its own* sit while the spellbook is open: everything that genuinely needs the
character upright (casting, movement, melee) stands it up itself, so the only stand this state ever
owes is "sitting has stopped being worth it", which is never worth a lost memorize.

The courtesy runs the other way too. A stand this state did not order — somebody getting up by
hand, or a service taking the character to cast or to move — buys a five-second grace before it
sits down again. It is a debounce and not a give-up: resting resumes on its own once nothing else
is happening, and in a fight it has the happy side effect of leaving a healer on its feet between
casts rather than sitting and standing for every heal.

Which pools are watched is read, not configured: health always, mana and stamina where the
character has them (`MaxMana` of zero is what says there is no mana bar — read the other way round,
a warrior would sit forever waiting on mana at 0%). Two thresholds decide the rest: `sit_below_pct`
and `stand_at_pct`, both 100 by default, which is "sit for anything short of full, get up when
nothing is". The pair is kept in order by the setters, because standing at less than we sit at is
the one combination that oscillates — sit, read as rested on the next pass, stand, repeat.

What holds it back, in the order it reports:

1. **Being engaged.** A character in a fight has a fight to be in, whatever the settings say.
2. **A cast in the air.** Usually moot — the casting priority floor has been starving this state
   since the cast began — but a hand-cast from the player is not.
3. **A fight it has not joined**, and this is the case worth naming. With `restcombat` on it *will*
   sit through one, because a caster that has not engaged would rather fill its bar than start
   something.

The chain is its shield for the whole of any fight: melee holds every frame from the first
engagement to the last corpse — including the beat between one mob and the next, because Combat
holds a lost-target fight open while it seeks the successor — so this state never sees a
mid-fight frame and knows nothing about fights beyond the engagement hold above. Its own windows
exist for its own reasons only: pacing its posture commands, a grace before undoing a stand the
player chose, and smoothing world reads that genuinely flicker. None of them measures anything
about the chain, and none of them delays anyone but this state.

Two smaller rules: a posture the state did not choose is left alone (feigning, mounted, ducking,
hovering dead), so it only ever sits a standing character and stands a sitting one; and sitting
waits on a short settle window after the character stops moving, because a group that pauses
mid-run is not a rest and sitting for it buys a stand-up on the next step.

`resting` and `restcombat` are the switches, `/crest` reports what it is doing and what each pool
reads. Switching resting off stands the character up if it was resting — pushed through
`CommandQueue`, since the menu checkbox calls the same setter and a game command from inside a
render callback is the crash hazard the movement service is built around.

The rest of the misc band is still empty: the out-of-combat regen discs, auto-food, and illusion and
mount management from the MQ2Melee lines at the bottom of `meleeState.lua` are the obvious
neighbours, and each is its own job rather than something to bolt onto this one.

## Flee state (`states/fleeState.lua`)

Travel mode: follow, and nothing else. The state whose job is what must *not* happen.

A group crossing four zones does not want each character stopping to fight back at every add on the
way, to top somebody off, to re-buff whoever the last mob dispelled, or to sit down every time the
run pauses for a moment. Switching each of those off one at a time is several orders *and* a set of
settings to remember to put back afterwards.

**It suppresses rather than configures**, which is why it is a state and not a script that flips the
other states off. Nothing it does is persisted onto anything else: the heal list, the melee switch
and the buff list are exactly as they were when the order arrived, `flee off` hands the character
back to its normal chain with no restoring to get wrong, and a crash mid-run cannot leave behind a
cleric that has quietly stopped healing.

**The suppressing is the ordinary release protocol.** At `Priorities.passive` this state is
stronger than everything except an order given to the character, and while the mode is on its
`Go()` returns busy every pass — so the chain never reaches anything below it, exactly as it never
reaches below any other busy state. It used to be a priority gate with a FollowState exemption;
the exemption was removed because it punched a hole in the ordering that no chain position could
express, which made it the one piece of out-of-band suppression in the design.

**The traveling is flee's own job while the mode is on.** The machinery — the follow order, the
trail-walking, the anchor, the zone-line procedures (clicking a switch, or walking through a
walk-through line after a target that vanished mid-stride) — is `travel.lua`, the same
core FollowState drives at the follow band in normal operation, moved out of the follow state
exactly the way the engagement moved out of the melee state into `combat.lua` when a second
state needed it. The chain serializes the two drivers: flee sits above follow and is busy for as
long as it is enabled, so there is never a pass in which both run, and neither state knows the
other exists. `anchor` still holds during a flee, since it is a standing order in the same core.
A cast put in the air by hand (`/ccast`) mid-run pauses the walk at the movement service — which
refuses to drive through a cast — and the run resumes when it lands, which replaces the old
"follow is exempt from flee but starved by casting" gate interaction.

**Services are not suppressed.** Movement, casting, the command queue, character discovery and
combat pulse every frame whatever the chain is doing, which is what keeps `flee off` reachable from
chat, from the menu and from a hotbar button while the mode is on.

What turning it on lets go of, once, on the transition: the cast in the air (`Casting.Interrupt`),
the fight (`Combat.Disengage`), and the movement task — unless follow already owns it, since that is
what we are about to be doing anyway and cancelling it only costs a pass picking the trail back up.
A stick started by the melee state is exactly the one to drop: it would go on holding range on the
very thing we are running from. Each of those is a *request* rather than a game command, which is
what makes the menu checkbox and a hotbar button safe.

Two things are read every pass instead of being done once. Auto attack, because `/attack on` is the
one commitment nothing else takes back — the melee state issues it and never issues the other half,
and it is not getting another turn in which to notice — so `Go()` reads `Me.Combat` and drops it
whenever it finds it on, which also covers the player switching it back on by hand. And the
auto-engage sweep, which `Combat.Pulse` skips while `Status.IsFleeing()`: nothing would act on a new
engagement, but one recorded now is one that resumes the moment the run ends, against whatever we
ran past ten zones ago.

`flee` is the switch (so `flee on`, `flee off`, or `flee` on its own to flip it — and `/state flee`,
and a hotbar button that draws itself as the setting like every other toggle), `/cflee` reports and
also takes `on`/`off`. It rides on top of a follow order rather than replacing one, so turning it on
with nothing to follow says so; the natural binding is one hotbar button carrying both lines
(`/bc followme` then `/bc flee on`). The switch is persisted like every other one, which means a
character that was fleeing when the script reloaded comes back fleeing — right far more often than
not, since a long run is not over because a client restarted, but also the setting easiest to leave
on by accident, so `Init` says so at startup.

The passive band is shared with the global pause that does not exist yet; when it lands it is this
same shape with an empty exemption set.

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
