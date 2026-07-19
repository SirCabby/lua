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
       ├─ PluginSetup        — ensure MQ2EQBC (connected), MQ2MoveUtils, MQ2AdvPath
       ├─ Config.new(path)   — per-character pickle store: configDir/cabby/<Name>-Config.lua
       ├─ *Config.Init()     — CommandConfig, DebugConfig, GeneralConfig, MeleeStateConfig
       ├─ ClassSetup         — class module Init(stateMachine) registers states
       └─ Menu.Init()        — ImGui shell (must be last)
  └─ stateMachine:Start()    — main loop
```

**Main loop** (`stateMachine.lua`): `mq.doevents()` → walk registered states in registration
order → first enabled state whose `Go()` returns `true` ("busy") wins the frame; everything
below it is starved → `mq.delay(1)`.

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
  stateMachine.lua    priority-chain loop (instance class)
  character.lua       capability snapshot: which skills exist (primary/secondary/melee lists)
  status.lua          shared predicates (IsFacingTarget)
  states/             baseState, followState, meleeState
  classes/            baseClass, monk, warrior — thin: Init() registers states
  commands/           the chat-command bus (see below)
  configs/            per-domain config modules (see below)
  actions/            ActionType interface + implementations + registries
  ui/                 ImGui menu shell + per-domain panels
  utils/ (sibling)    Time/Timer/StopWatch, Config, Debug/FlowTracer, FileSystem, Json,
                      PriorityQueue (unused), Stack, StringUtils, TableUtils
```

## Command bus (`commands/`)

The most developed subsystem. Three registration kinds, all carrying self-documenting help
(`ChelpDocs`, surfaced by `/chelp` and the Help UI tab):

- **Comms** (`Command`): phrases spoken in chat channels ("followme", "attack 123"). For each
  active channel a matcher pattern is instantiated from a template containing `<<phrase>>`
  (per-channel patterns live in `Speak.channelTypes`: bc, bct, tell, raid, group) and
  registered as an `mq.event`. Changing active channels re-registers everything.
- **Events** (`Event`): raw line patterns (group invite, generic tell-forwarder). `reregister`
  flag re-adds them last so catchall patterns sort after specific ones.
- **Slash commands** (`SlashCmd`): `mq.bind` wrappers (/chelp, /debug, /activechannels,
  /speak, /owners, /state, /cmenu, /restart).

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
  `CommandConfig`, `DebugConfig`, `GeneralConfig`, `MeleeState`, `FollowState`.
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
Panels live with their domain (`ui/states/meleeStateMenu.lua`, `ui/actions/*`). UI code
currently reaches into other modules' `_` privates (e.g. `MeleeState._.currentAction`,
`Commands._.registrations`) — a coupling to remove when the facades grow real accessors.

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
9. **Plugin independence.** Replace MQ2MoveUtils and MQ2AdvPath (and never adopt MQ2DanNet)
   with reusable Lua modules behind service interfaces — see ROADMAP "Plugin independence".
   States stop calling plugin commands directly; plugin backends remain a fallback until
   the Lua implementations reach parity. Transport: native chat channels (tell/group/raid)
   are already plugin-free; MQ Lua actors (routed between same-machine clients by the
   launcher post office) become the structured-message backend; EQBC stays optional for
   bc/bct until then (open decision).
10. **UI stays colocated with its domain** (panels next to the code they control — intended
    design), but panels read through public status accessors instead of `_` privates
    (`MeleeState._.currentAction`, `Commands._.registrations`).
11. **mq facade injection** so pure logic (state transitions, command parsing, config
    validation) can be unit-tested off-client.
