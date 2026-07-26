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
       ├─ *Config.Init()     — CommandConfig, DebugConfig, GeneralConfig, HotbarConfig,
       │                       MeleeStateConfig
       ├─ CommandQueue.Init  — registers the command queue service (what UI presses run through)
       ├─ CabbyMovement.Init — registers the movement service + /cmove
       ├─ ClassSetup         — class module Init(stateMachine) registers states
       ├─ HotbarsUI.Init()   — ImGui shell for the hotbar windows
       └─ Menu.Init()        — ImGui shell (must be last)
  └─ stateMachine:Start()    — main loop
```

**Main loop** (`stateMachine.lua`): `mq.doevents()` → pulse registered **services** → walk
registered states in registration order → first enabled state whose `Go()` returns `true`
("busy") wins the frame; everything below it is starved → `mq.delay(25)`.

**Services** run every frame regardless of which state is busy (`RegisterService`, anything
with `key` + `Pulse()` and optionally `Stop()`). They are for work that cannot wait for its
requesting state to get another turn. Two exist: **Movement**, which has to release its keys on
the frame its task ends rather than whenever FollowState next runs, and **CommandQueue**
(`commandQueue.lua`), which runs command lines pushed to it by callers that must not run
commands themselves — every ImGui callback, hotbar buttons above all.

This is a **priority-chain cooperative scheduler**: state order = priority; `Go()` returning
`false` yields to lower states. The intended priority bands (from the comment block in
`setup.lua`) are:

| Priority | State | Priority | State |
|---|---|---|---|
| 1 | My commands / Task / DZ | 69 | Tank / grab aggro |
| 19 | Passive mode | 79 | DPS (melee/spells) |
| 29 | Cure | 89 | Looting |
| 39 | Heal | 99 | Anchor |
| 49 | Pulling | 109 | Following |
| 59 | Mez (in combat) | 119/129 | Buff / Misc |

Today priorities are implicit (whatever order the class module registers). Formalizing them
as a declared `priority` field is a planned refactor.

**States are mini-FSMs.** Each state keeps a `_.currentAction` function pointer; action
functions do one frame of work, mutate `currentAction` to transition, and return busy/yield.
Example: FollowState's actions are `findFollowTarget → keepClose` plus a click-zone chain
(`findingSwitch → clickingSwitch → waitingToZone`) and `stayingAtAnchor`. Timers
(`utils.Time.Timer`, wall-clock ms) drive stuck detection and timeouts.

**States are singletons**, not instances: a module table with `Init/Go/IsEnabled/SetEnabled/
BuildMenu`. `BaseState` documents this contract but is *not* a real metatable base — the
`---@class X : BaseState` annotations are documentation-only inheritance.

## Module map

```
cabby/
  cabby.lua           entry; defines global `Global` { tracing (FlowTracer), configStore }
  setup.lua           plugin checks, config init order, class dispatch (16-way if/elseif)
  stateMachine.lua    priority-chain loop + per-frame services (instance class)
  movement.lua        wiring only: registers the movement service and /cmove
  commandQueue.lua    service: runs command lines pushed from ImGui callbacks, a frame later
  character.lua       capability snapshot: which skills exist (primary/secondary/melee lists)
  status.lua          shared predicates (IsFacingTarget)
  states/             baseState, followState, meleeState
  classes/            baseClass, monk, warrior — thin: Init() registers states
  commands/           the chat-command bus (see below)
  configs/            per-domain config modules (see below)
  actions/            ActionType interface + implementations + registries
  ui/                 ImGui menu shell + per-domain panels
  utils/ (sibling)    Movement/ (see below), Time/Timer/StopWatch, Config, Debug/FlowTracer,
                      FileSystem, Json, PriorityQueue (unused), Stack, StringUtils, TableUtils
```

## Command bus (`commands/`)

The most developed subsystem. Three registration kinds, all carrying self-documenting help
(`ChelpDocs`, surfaced by `/chelp` and the Help UI tab):

- **Comms** (`Command`): phrases spoken in chat channels ("followme", "attack 123"). For each
  active channel a matcher pattern is instantiated from a template containing `<<phrase>>`
  (per-channel patterns live in `Speak.channelTypes`: bc, bct, tell, raid, group) and
  registered as an `mq.event`. Changing active channels re-registers everything. A command may
  also declare, chained onto `Command.new`, what it needs to be a real order rather than a
  no-op: `:WithArgs{ required, hint, default }` (attack declares a required spawn id defaulting
  to `${Target.ID}`) and `:ActsOnSpeaker()` for commands that act on whoever said them
  (followme, m2m), which cannot be issued to yourself. Whatever offers commands to a user reads
  these — the hotbar editor prefills the default, refuses to build a line that cannot work, and
  flags one that was typed anyway.
- **Events** (`Event`): raw line patterns (group invite, generic tell-forwarder). `reregister`
  flag re-adds them last so catchall patterns sort after specific ones.
- **Slash commands** (`SlashCmd`): `mq.bind` wrappers (/chelp, /cself, /debug, /activechannels,
  /speak, /owners, /state, /cmenu, /restart).

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

## Action system (`actions/`)

`ActionType` is the interface for "a thing the character can activate":
`Name / ActionType / HasAction / EndCost / IsReady / DoAction`. Implementations:

- **Skill** (`skill.lua`): melee skills via `/doability`; static registry `skills.lua` tags
  each skill with attributes (facing, targeted, primary, secondary, melee, …) and builds
  ordered category lists. Per-instance 500 ms wall-clock cooldown timer.
- **Discipline** (`discipline.lua`): combat abilities via `/disc`; `disciplines.lua` scans
  `Me.CombatAbility(1..200)` at require time and buckets by SPA (92/192 → hate) and target
  type (Single → melee). (`taunt` bucket exists but is never populated — bug.)
- **AA / Item / Spell**: enum values and UI plumbing exist (`actionType.lua`, `actionUI.lua`)
  but `Actions.Get` only resolves Ability and Discipline. Casters are unsupported today.

**Action** (`action.lua`) is the *persisted config shape* for a user-configured action slot:
`{ name, actionType, enabled, luaEnabled, lua, end_type, end_threshold }`. `luaEnabled`
actions gate on a user-authored Lua predicate evaluated with `loadstring` each use — this is
the replacement for MQ2Melee downshit/holyshit lines (originals kept as reference comments at
the bottom of `meleeState.lua`). `EditAction` + `ActionUI` implement staged edit/save/cancel
editing of these slots; `MeleeStateConfig` stores three lists (actions, taunt_actions,
hate_actions) with usage modes (always / as-needed / off).

`character.lua` is the capability layer: which skills/discs this character actually has,
snapshotted at load (refresh triggers are a known gap: level-ups, gear swaps, respecs).

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
the right-click menus (rename, button size, add/remove button, edit a button's commands, remove
hotbar behind a confirmation modal), and the title-bar close box hides a bar rather than
deleting it. Rules the code depends on:

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

- **Mutations are deferred to the end of the frame.** Menu handlers append a closure to a
  `pending` list that runs after the draw loop, so a bar or button is never removed out from
  under the iteration drawing it. Likewise `confirmRemove` is a flag consumed on the *next*
  frame: calling `OpenPopup` from inside the context menu would open the modal at the wrong
  level of the popup stack and it would vanish with the menu.
- **A press queues, it does not run.** A button holds an ordered list of command lines; pressing
  it pushes them to `CommandQueue`, which runs them on the next main-loop frame. Running a game
  command from inside an ImGui callback is the crash-to-desktop hazard described in the Movement
  section.
- **A command line is plain text, and nothing more.** It is exactly what the user could type:
  `/bc followme`, `/cself stopfollow`, `/g attack ${Target.ID}` (TLOs resolve at press time,
  through `mq.cmd`). A line with no leading slash is treated as one of our own comm commands
  issued to this character via `Commands.Dispatch` — never spoken, so a typo cannot broadcast.
  `ui/hotbarButtonEditor.lua` edits a button: label, a line list that grows as it is filled in,
  and an action picker over the live command registries (comm commands with a channel to speak
  them on, or slash commands) whose only job is `BuildActionLine` — generating that text and
  writing it into the next free line. Once written the line is just text, which is the point:
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
3. **Declarative class profiles.** Classes stay the assembly axis — a warrior has no
   business registering crowd control, and a paladin's heal state must not sit at cleric
   priority — but the assembly becomes data, not imperative Init code: each class declares
   `{ { state = HealState, priority = Bands.heal + N, constraints = {...} }, ... }` drawing
   from shared priority-band constants so cross-class ordering stays predictable. Priorities
   and constraints must be adjustable at **runtime** by role config and group makeup (no
   cleric present → hybrid heals tighten). Unimplemented classes keep failing loudly until
   built out — that is intended.
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
   MQ2AdvPath and neither plugin is loaded (see the Movement section above). Still open:
   transport. Native chat channels (tell/group/raid) are already plugin-free; MQ Lua actors
   (routed between same-machine clients by the launcher post office) become the structured-
   message backend; EQBC stays optional for bc/bct until then (open decision). MQ2DanNet is
   never adopted.
10. **UI stays colocated with its domain** (panels next to the code they control — intended
    design), but panels read through public status accessors instead of `_` privates
    (`MeleeState._.currentAction`, `Commands._.registrations`).
11. **mq facade injection** so pure logic (state transitions, command parsing, config
    validation) can be unit-tested off-client.
