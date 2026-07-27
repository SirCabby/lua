# Cabby Roadmap

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Origin: design review 2026-07-18.
Vision: one script that bots any class/race — states for every band in the priority table
(commands, passive, cure, heal, pull, mez, tank, dps, loot, anchor, follow, buff).

Current coverage: Follow/Anchor/ClickZone and Melee states; all sixteen classes load, but
only as profiles over those two states (the nine melee classes melee, everyone follows);
melee-only action types (Skill, Discipline). The casting service exists (Phase 3) but no state
uses it yet — `/ccast` is the only caller. Everything else below.

---

## Phase 0 — Stabilize (fix before building on top)

Status 2026-07-18: **all rows below fixed** except 1 (intended) and 14 (needs in-game
verification). Fixes are parse-checked (LuaJIT) and the pure-logic ones are covered by an
off-game harness; **in-game smoke test still pending**.

| # | Where | Bug | Status |
|---|---|---|---|
| 1 | `setup.lua:113` | `class.Init` on nil for the 14 unimplemented classes (and ROG, which the 16-way if/elseif left out entirely, so a rogue could never run cabby at all) | fixed — every class has a profile; the dispatch is a registry lookup, and an unknown short name prints and exits. "Loud" is now a startup notice listing what the class cannot do yet |
| 2 | `configs/meleeStateConfig.lua` | taunt/hate cleanup loops ran *outside* their `HasTaunts`/`HasHates` guards → `#nil` crash on fresh config for classes without taunts/hate discs | fixed |
| 3 | `configs/meleeStateConfig.lua` | checked `primary_combat_ability == nil` instead of `secondary_combat_ability` → secondary default never written | fixed |
| 4 | `states/followState.lua` | `Math.Distance` string missing comma between x and z → stuck-detection distance garbage | fixed |
| 5 | `status.lua` | `mq.TLO.Target == nil` never true; no-target case could report "facing target" | fixed (checks `Target.ID()`) |
| 6 | `states/followState.lua` | `Spawn(...) ~= nil` / `Switch ~= nil` always true; nil `Distance()` compares crash; `/moveto id NULL` on missing spawn; `.ID` missing call parens | fixed (ID/Distance captured + nil-guarded) |
| 7 | `ui/actions/editAction.lua` | `SwitchType` → `Actions.Get(newType, oldName):EndCost()` crashed on fresh actions (nil name) and AA/Item/Spell types (nil return) | fixed (nil guards both layers) |
| 8 | `actions/discipline.lua` | `HasAction` inverted (also `.ID()` on the int-typed name lookup) | fixed (`CombatAbility(name)() ~= nil`) |
| 9 | `actions/disciplines.lua` | `Disciplines.taunt` never populated; hate/melee buckets held duplicate instances with independent cooldown timers | fixed (SPA 199 → taunt, needs in-game verify; one shared instance per disc) |
| 10 | `configs/commandConfig.lua` | `/activechannels <cmd> reset` dereferenced the override it just removed | fixed |
| 11 | `commands/commands.lua` | `arg = ...` leaked a global | fixed |
| 12 | `states/meleeState.lua` | `MaxRangeTo()` nil race → arithmetic on nil | fixed (defaults to 14) |
| 13 | `stateMachine.lua` | No pcall barrier (any state error killed the script); 1 ms hot loop | fixed (see barrier note below; base delay 25 ms via `SetLoopDelay`) |
| 14 | `configs/generalConfig.lua` | tellToMe catchall likely *also* fires for command tells (only filters NPCs) | open — see Verify list |
| 15 | `commands/event.lua` + `commands.lua` | `Event.new` dropped its `id` — event registrations were keyed by *pattern*, so `/chelp`, `/owners <event>`, `/speak <event>` matched patterns while handlers looked up ids → per-event owner/speak overrides could never apply | fixed (id stored; registrations, mq.event names, GetEventIds all keyed by id) |

**Crash barrier (landed, initial version):** every state `Go()`/`IsEnabled()` and every
command/event/slash handler runs under `xpcall` with `debug.traceback`. Errors go to
`cabby/errorAlert.lua`: dedicated "Cabby Alerts" ImGui window (dismiss required; separate
from chat), append to `configDir/cabby/<Name>-errors.log`, dedup by raise-site signature
with a running count, one-line red chat notice on first occurrence only. A state that fails
3 consecutive frames is paused (runtime only — config untouched) and its alert shows a
Resume button. Verified off-game: healthy states keep running while a broken state errors;
dedup, auto-pause, resume, re-pause, and log writes all covered by
`scratchpad/test_barrier.lua`-style harness under LuaJIT and Lua 5.1.

Utils layer (from the utils sub-review; fix opportunistically):
~~`StopWatch:split` always returns 0~~ (fixed); ~~`StringUtils.Split` infinite loop on
leading single-char delimiter~~ (fixed, harness-tested); `Config.new()` no-arg nil-deref
(`Config.lua:38`); `TableUtils.GetKeys` sort crash on mixed-key tables; `GetValues` returns
arrays by reference; `Compare` throws on divergent nesting; `Stack.Push(nil)` stores `"nil"`;
`testConfig.lua` asserts a removed implementation (stale); Debug eager string building +
per-line file reopen; timers are wall-clock (decision to ratify or change).

## Phase 1 — Skeleton refactors

In rough order (details in ARCHITECTURE.md "Target architecture"):

1. ~~Crash barrier + **error surfacing**~~ — **done** (initial version; see Phase 0 barrier
   note). Remaining polish: route through the Phase 1 Logger once it exists.
2. Loop cadence: base delay now 25 ms (**done**); still to do: per-state throttles so
   expensive TLO scans (XTarget sweep, spawn searches) run behind short timers with cached
   results instead of every frame.
3. Config `Section` helper (schema/defaults/migration; kills taint boilerplate + writing getters).
4. Module contract + registrar (kills isInit/Menu.Register/Setup-order boilerplate).
5. ~~Declarative class profiles~~ — **done** for the assembly half: `classes/priorities.lua`
   holds the bands, `classes/baseClass.lua` merges the common states (Follow) with the
   profile's own, sorts and registers, and `classes/classes.lua` maps short name → module.
   All sixteen classes have a profile; each lists what it cannot do yet and says so at
   startup. Verified under LuaJIT and Lua 5.1 by a `scratchpad/test_classes.lua`-style harness
   with the states stubbed out (chain order, common-state merge and override, tie-break,
   melee/caster split, idempotent Init, malformed profiles); **in-game smoke still pending**.
   Still open: per-entry **constraints**, and **runtime** priority modifiers by role and group
   makeup (no cleric → hybrid heals tighten) — both want states that do not exist yet.
6. ~~Movement service seam~~ — **done**, and it went straight to the Lua implementation
   rather than wrapping the plugins first (see Phase 2). States call
   `utils.Movement.Movement`; no state issues `/stick`, `/moveto` or `/afollow`.
7. Split `commandConfig.lua` (store / bridge / UI; spec-table editor).
8. Channel known at dispatch: the capture patterns stay (they extract speaker/args from
   chat); pass the originating channel through from event registration instead of
   reverse-regexing the line for replies (`Speak.GetRequestChannel`).
9. UI access rule: panels stay colocated with their domain, but read via public status
   accessors instead of `_` privates.
10. Logger with levels + lazy formatting (replace print/Debug mix; error alerts ride this).
11. mq facade injection + off-client tests for pure logic (fix Debug's top-level `require("mq")`).
12. Style guide (naming, colon-vs-dot, module layout) + mechanical cleanup pass.

## Phase 2 — Plugin independence (reusable movement + transport libs)

Goal: run without MQ2MoveUtils, MQ2AdvPath, or MQ2DanNet. Build as **reusable modules**
(in `utils/` since they're script-agnostic), consumed by cabby through the Phase 1 service
seams.

**Movement: done.** `utils/Movement/` replaced both plugins and `setup.lua` no longer loads
them. Architecture notes are in ARCHITECTURE.md ("Movement"); what landed:

- ~~**Locomotion primitives**~~ — `Locomotion.lua`: `/keypress` hold semantics with key state
  tracked so holds only fire on transitions, `/face fast nolook`, stand, jump, release-all,
  and it is the single owner of the movement keys.
- ~~**GoTo**~~ — `MoveTo.lua`: straight line to a loc or a spawn, arrival radius, timeout,
  stuck detection over wall-clock windows (`StuckDetector.lua`), jump + alternating strafe
  unstick (`Unsticker.lua`), terminal status + reason polled by task id.
- ~~**Stick**~~ — `Stick.lua`: hold range on a spawn id with constant re-facing, back off when
  crowded, `behind` mode strafes into the rear arc, breaks on target gone/dead/self/warp.
- ~~**Breadcrumb follow**~~ — `Follow.lua`: samples the target into a trail, walks the trail
  (so corners and lost LOS work), drops reached waypoints with a lookahead that collapses
  laggy backtracking, invalidates the trail when *we* get moved (summon/port/gate), keeps
  walking after the target zones out, clicks closed doors in the way.
- **Out of scope**: navmesh-grade pathfinding (that's MQ2Nav's whole job; revisit only if
  breadcrumbs + goto prove insufficient in practice on emu zones).
- Verified off-client against a simulated client (arrival, unreachable-destination failure,
  timeout, chase, stick converge/back-off/rear-arc, pause gate, follow around a corner and
  through a door, task hand-off between owners). **In-game smoke test still pending**; the
  behaviors most worth watching there are stuck thresholds and door clicking.

Still open in this phase:

- **Transport**: tell/group/raid channels already work plugin-free through Speak. Add an MQ
  Lua **actors** backend for structured client-to-client messages (the launcher post office
  routes between clients on one machine — matches the wine setup). EQBC remains optional
  for bc/bct until actors/tells cover those uses (open decision, see Verify).

## Phase 3 — Caster foundation

**Casting service: done.** `utils/Casting/` is the reusable half (service, sequencer, subject,
immobilizer, outcomes) and `cabby/casting.lua` the wiring; architecture notes are in
ARCHITECTURE.md ("Casting"). What landed:

- ~~**The service**~~ — one cast at a time, requested and polled by id, never blocking. Priority
  decides who gets it and a stronger request preempts a weaker one.
- ~~**Priority integration**~~ — `StateMachine:RegisterPriorityGate` plus priorities kept at
  registration (`Register(state, priority)`, `GetPriority`). A cast owned by priority P starves
  every state weaker than P for as long as it is preparing or in the air, which is what stops
  follow from walking off mid-heal. `Frame()` was split out of `Start()` so the loop is testable.
- ~~**Standing still**~~ — settle window on top of "the client says we stopped", standing up out
  of sit/duck/feign, an autorun-cancelling key tap, and arbitration over the movement task by
  priority (cancel it if we outrank its owner, otherwise wait). Bards and instant casts skip it.
- ~~**Targeting, mana, reagents, range, line of sight**~~ — checked before committing, since a
  refusal here costs nothing and one from the client costs a gem timer.
- ~~**Gem memorization**~~ — `/memspell` into the configured gem (last gem by default) when a
  spell is not memorized, with its own timeout.
- ~~**Outcome detection**~~ — `Me.Casting` for the shape of the cast, ~40 registered chat lines
  for the reason -- 37 of them (fizzle, interrupt, resist, immune, out of range, silenced, components...).
  Late "resisted"/"did not take hold" lines refine a result already reported as a success.
- ~~**By hand**~~ — `/ccast <name> [item | alt | gem<#>] [targetid|<#>]`, plus a Casting config
  page showing live status.
- **Deliberately not done**: retries. A fizzle is reported to the caller, which decides whether
  casting again still makes sense — a macro loops because it has nowhere else to put that
  decision; a state machine does.
- Verified off-client against a simulated client (104 checks: the happy path, waiting to stand
  still and giving up, movement arbitration both ways, fizzle, interrupt, preemption and refusal
  by priority, the queued-request case, no mana, no target, out of range, no line of sight,
  targeting first, memorizing, item clicks, AA activation, late resist refinement, stray lines
  while preparing, bard songs, `StopFor`, and the state machine's gate) under LuaJIT and Lua 5.1.
  **In-game smoke test still pending** — see Verify.

Still open in this phase:

- Implement `ActionType` for **Spell / AA / Item** over the service (`Actions.Get` resolves them;
  ActionUI already has the slots but the name picker has nothing to offer for those types).
- Extend `character.lua` discovery: spellbook/memmed gems, AAs, clickies, songs; refresh
  triggers (level/skill-up events, gear swap, respec) instead of load-time-only snapshot.
- Buff-stacking model (`Spell.Stacks`, existing-buff checks) shared by buff/heal logic.

## Phase 4 — The planned states

Per priority band: **Passive** (global pause; also a /cpause slash + comm command),
**Heal** (self + group + role targets, HP thresholds, emergency vs topping),
**Cure** (detrimental scan → cure actions), **Pull** (target selection, pathing, leash,
camp radius), **Mez** (add control, in-combat priority above dps), **Tank** (taunt/hate
action lists already modeled in MeleeStateConfig; needs aggro-loss detection for "as
needed" usage), **DPS** (melee exists; add caster rotations + assist-at-% rules),
**Loot** (corpse scan, loot rules per item, master-loot coordination),
**Buff** (self/group maintenance with stacking + rebuff timers).
Each new state = state module + config section + UI panel + comm commands, which is why
the Phase 1 module contract comes first. Landing one is also a sweep over `classes/*.lua`:
the per-class view of this list is each profile's `unimplemented` lines, and a state that
exists moves from that list into the profile's `states` at its band.

Two of these are already half-written elsewhere and only need the state around them:
**Tank** (MeleeState's taunt/hate lists run on a timer; what is missing is aggro-loss
detection, and the plate classes then gain an entry at `Priorities.tank`) and **DPS at
range** (`utils/Movement/Stick.lua` already strafes into the rear arc, which is a rogue's
backstab positioning; nothing asks for it).

## Phase 5 — Group/raid coordination

- Assist protocol: MA/marks broadcast, `attack <id>` exists — add assist-percent, target
  dedup, anti-summon distance rules, leash/give-up timers.
- Role model: main tank / main assist / puller / healer assignments in config + comms;
  feeds the runtime priority modifiers from the class-profile design (group makeup changes
  who heals/tanks at what priority).
- Structured coordination messages ride the Phase 2 transport (actors preferred, chat
  channels as universal fallback).
- Fleet UX: broadcast config changes ("everyone set camp here"), status dashboards.

## Cross-cutting gaps (no owner yet)

- **Lifecycle events**: zoning, death/rez handling, camp/disconnect detection, GM detect →
  a global interrupt that resets states safely (states currently keep stale targets/actions
  across zone lines; only FollowState notices zone changes, and only for click-zoning).
- **Leash/give-up timers** on engage (attackTarget can hold "busy" forever on an unreachable
  target, starving Follow below it).
- **Config migration** when schemas change (version key exists, no mechanism).
- ~~**Hotbar buttons do nothing yet**~~ — **done**. A button holds an ordered list of command
  lines, run through the `CommandQueue` service on the next main-loop frame.
  `ui/hotbarButtonEditor.lua` picks comm commands (with the channel to speak them on, including
  the new local "self" channel) and slash commands out of the live registries and writes them
  into a line; lines stay editable text afterwards. Still open here: **action slots** (the
  `actions/` ActionType instances — fire a specific disc or skill from a button, which needs a
  slash-command or comm entry point first) and **lua snippet** lines. In-game smoke test
  pending: TLO expansion at press time (`/g attack ${Target.ID}`), and self-dispatch of every
  comm command.
- **Performance**: per-frame spawn-search dedup/caching (several functions repeat identical
  `Spawn(...)` queries 2–3× per frame), XTarget scan throttling.
- **Docs for users**: /chelp exists; needs a README quickstart (install, plugins, first-run
  config, command tour).
- **Tests for cabby layer**: none today. Highest-value first targets: command parsing
  (slash arg paths — several Phase 0 bugs live there), Owners ACL, config init/migration,
  follow stuck-detection math.

## Verify (assumptions to test in-game)

1. **MQ event multi-match**: does a line matching two registered events (command tell +
   tellToMe catchall) fire both callbacks? The `reregister`/"add last" hack implies ordering
   matters; confirm actual semantics and either dedupe in a single dispatcher or filter
   command phrases out of tellToMe.
2. `Switch("nearest")` behavior when no switch in zone (click-zone chain).
3. `/stick loose` + `MaxRangeTo` interaction on emu client vs live-era plugin builds
   (relevant only until the Phase 2 stick replacement lands).
4. Wall-clock timers through zoning (ability cooldown timers keep running — acceptable?).
5. MQ Lua **actors** between clients on the wine/emu setup: the launcher post office must
   route messages across the injected clients in the prefix (launcher already runs for
   injection). Validates the Phase 2 transport backend before building on it.
6. **EQBC fate** (decision): keep the plugin for bc/bct channels, or retire it once
   actors + tell/group/raid cover command traffic.
7. **SPA 199 = taunt** on emu spell data: `disciplines.lua` now buckets discs with SPA 199
   into `Disciplines.taunt` — confirm a warrior taunt disc (and no non-taunt disc) lands
   there (the commented HasSPA probe loop in that file helps).
8. **Local channel**: `/cself <command>` for each registered comm command — nothing should
   appear in any chat window, and behavior should match the same command spoken by a group-mate.
   Related: `Owners:HasPermission` now always says yes to our own name, so confirm our own
   outgoing chat cannot re-trigger a command on ourselves (EQ renders our own group/raid lines
   as "You tell your party, ...", which no registered pattern matches, and EQBC runs with
   localecho off — verify both still hold).
9. **Class profiles on a live character**: startup on a class that was never reachable before
   (a rogue, and any caster) — the notice should list its states and what it cannot do, the
   melee-less classes should register Follow alone, and `/state` should list the chain in
   priority order. MeleeStateConfig now initializes from MeleeState rather than from Setup, so
   a caster's config file should come up with no `MeleeState` section at all — worth confirming
   on a fresh config, and that a melee character's config is unchanged.
10. **Casting, in game** (nothing here has touched a client yet). In rough order: `/ccast` a
   long heal on a group member while running, and watch it stop, cast, and report; `/ccast` a
   spell that is not memorized and confirm `/memspell` lands in the configured gem and the cast
   follows; force a fizzle and an interrupt (move mid-cast) and confirm the reported outcome;
   `/ccast off` mid-cast; a clicky and an AA, neither of which shows a cast bar; and a bard song
   while following. Specific things to watch, since they are guesses until then: that
   `Me.Casting.ID()` is nil for item clicks and AAs on this emu client (the sequencer assumes it
   and falls back to a timed grace window), that the outcome lines match verbatim on emu (the
   resist wording differs between live and emu builds, and MQ2Cast carries both), that
   `Spell.MyCastTime` reads as milliseconds through `tonumber`, and that `/keypress back` cancels
   autorun without upsetting the movement service's own key bookkeeping.
11. In-game smoke of the 2026-07-18 Phase 0 fixes: fresh-config startup on a taunt-less
   class, follow/stuck detection, add-new-action UI flow, `/activechannels <cmd> reset`,
   and the Cabby Alerts window (force an error to see alert + log + pause/resume).
