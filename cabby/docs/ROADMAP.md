# Cabby Roadmap

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Origin: design review 2026-07-18.
Vision: one script that bots any class/race — states for every band in the priority table
(commands, passive, cure, heal, pull, mez, tank, dps, loot, anchor, follow, buff).

Current coverage: Follow/Anchor/ClickZone, Melee, Spell DPS, Heal, Buff, Rest and Flee states, over
a shared engagement (`combat.lua`); all sixteen classes load as profiles over those (the nine melee
classes melee, eleven cast damage, the three priests and three hybrids heal, the twelve with a
spellbook buff, and everyone follows, rests and flees). The casting service and all five action
types exist (Phase 3), so an action list can hold a spell, clicky or AA and `/ccast` can fire
anything by hand. Everything else below.

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

0. ~~**States decide every pass**~~ — **done**, and audited across all four: `Go()` reads the
   world, decides, acts, releases, and no state carries a mode as a substitute for deciding.
   MeleeState, SpellDpsState and HealState were restructured onto it; FollowState followed, where
   `_.currentAction` had been doing three jobs at once (which order is in force, a sub-decision
   that was derivable from `Movement.IsFollowing`, and genuine click-zone progress). Splitting
   them turned up two bugs the shape had been hiding: a failed click-zone was restarted on the
   very next pass forever, and `anchor off` left the state pointing at the anchor it had just
   dropped. Following and anchoring now cancel each other outright, as the contradictory orders
   they are, which removed the last piece of remembered "which am I doing" — with only one order
   ever standing, that is something to read again. Held state is now only the orders we were given
   and progress through a procedure the world cannot describe. This is what makes the missing give-up paths safe: a state that
   re-derives its own answer every pass cannot be wedged by one that failed.
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
- **Deliberately not done**: retrying a cast that was *spent*. A fizzle or a resist is reported to
  the caller, which decides whether casting again still makes sense — a macro loops because it has
  nowhere else to put that decision; a state machine does. Waiting, on the other hand, is not
  giving up: preparation (targeting, standing still, memorizing, waiting out a hand cast) retries
  indefinitely, since each of those is a wait for something that changes. The five second
  preparation ceiling that shipped first was removed outright once it was clear it bought churn
  rather than the freed priority chain it was meant to buy — the callers re-requested immediately
  anyway, so it was a setting that was wrong whenever it was used. The `notStill` and `busy`
  outcomes went with it, and old configs have the key taken back out on init.
- Verified off-client against a simulated client (104 checks: the happy path, waiting to stand
  still and giving up, movement arbitration both ways, fizzle, interrupt, preemption and refusal
  by priority, the queued-request case, no mana, no target, out of range, no line of sight,
  targeting first, memorizing, item clicks, AA activation, late resist refinement, stray lines
  while preparing, bard songs, `StopFor`, and the state machine's gate) under LuaJIT and Lua 5.1.
  **In-game smoke test still pending** — see Verify.

**Discovery and the cast action types: done.** An action slot can hold a spell, a clicky or an
AA, and what it can be set to is read off the client rather than declared. What landed:

- ~~**`ActionType` for Spell / Item / AA**~~ — one module (`actions/castAction.lua`), since the
  three differ only in what `CastSubject` already knows. `DoAction(request)` asks the casting
  service and returns; `request` carries `{ owner, priority, targetId }`, and `BaseClass` now
  writes each state's band onto the state so it has a priority to pass.
- ~~**Discovery**~~ — `actions/spells.lua` (the 720-slot book, holes and all, bucketed
  beneficial/detrimental, sorted newest rank first), `actions/aas.lua` (walks the AA group id
  space, activated only, bucketed taunt/hate by the AA's own spell SPAs), `actions/items.lua`
  (clickies in worn slots and bags). `Actions.Get` resolves all five types through these, so a
  slot naming something the character no longer has comes back nil rather than misfiring.
- ~~**Refresh triggers**~~ — `character.lua` is a service now: a cheap signature (level, AA
  points spent, free inventory) checked every five seconds, re-reading only the registry that
  moved, plus `/crefresh` for what a signature cannot see (an even item swap, a spell scribed
  over another). Discovery still happens once at require time, which is where the config
  sections read it from.
- ~~**Offering them**~~ — the melee action lists offer this character's spells, AAs and clickies
  (and the tanking lists its taunt/hate AAs, alongside the discs they already had). The picker
  grew a filter box for lists past a dozen entries and marks spells that are not memorized,
  since an action slot only fires what is on the bar.
- ~~**The stick that would ruin the cast**~~ — `Casting.IsHoldingStill(priority)` plus a guard in
  `MeleeState.StickToCurrentTarget`. The priority floor starves everything *weaker* than a cast,
  but the rotation that asked for it keeps its turn, and walking back into melee range is
  exactly what loses it.
- Verified off-client (54 checks: sparse-book scanning and sort order, activated-only AA scanning
  and SPA buckets, clickies in gear and bags with duplicates collapsed, `Actions.Get` for every
  type including the stale-config case, the readiness gates one at a time, a fired action
  reaching the service with its owner and band, `IsHoldingStill` in all three directions,
  signature-driven partial refresh, the five-second throttle, and the even-swap case a full
  refresh exists for) under LuaJIT and Lua 5.1. **In-game smoke test still pending.**

Still open in this phase:

- ~~Buff-stacking model (`Spell.Stacks`, existing-buff checks)~~ — **done**, and it landed inside
  the buff state rather than as a shared layer (see Phase 4), because heal has no use for it:
  `Stacks`/`StacksPet`/`StacksSpawn` plus the three duration reads answer "would it land" and "has
  it nearly gone", which is a buff question start to finish. If cures or HoT tracking end up
  wanting the same reads, that is when it earns being lifted out.
- Songs: a bard's action list works, but nothing twists.
- A rotation cannot memorize. `CastAction:IsReady` requires the gem, deliberately (see
  ARCHITECTURE.md); an action slot for a spell that is not on the bar therefore idles. Revisit
  if configuring one turns out to be a common mistake rather than a rare one.

## Phase 4 — The planned states

**Heal: done** (`states/healState.lua`, `configs/healStateConfig.lua`,
`ui/states/healStateMenu.lua`; the model is described in ARCHITECTURE.md, "Heal state"). What
landed:

- ~~**The state**~~ — one ordered list of heal slots, each an action plus the health it is for and
  who it is for (anyone / the tank / myself / anyone else). An order first, then a group heal when
  enough of the group is hurt, then whoever is worst off; group heals stand down while anyone is
  below the emergency point.
- ~~**Reconsidering a heal in the air**~~ — called off when the target dies or leaves, climbs back
  above the threshold that triggered it, or somebody else drops into an emergency.
- ~~**Commands**~~ — `healnow <id | off>` and `healme` (which acts on whoever said it, the "patch me"
  of the old cleric macros) as orders; `healing`, `healgroup` and `healpets` as switches;
  `healaction` over the configured slots; `/cheal` for status. All of them are hotbar-bindable
  because they are ordinary registered commands: `healnow` offers the target, self and call-off as
  argument choices, and the switches read their own state back so a button carrying one is drawn
  as that switch.
- ~~**The page**~~ — status, who is being watched and their health, the switches, the emergency
  point, and the slot list with its per-slot threshold and scope. `ActionUI.ActionControl` grew an
  `extras` hook for the per-slot controls that belong to the state rather than to the action.
- ~~**The command factory**~~ — the `action` command moved out of MeleeState into
  `commands/actionCommand.lua`, so both states register the same thing instead of one copying the
  other.
- ~~**Class profiles**~~ — CLR/DRU/SHM at the heal band (druid and shaman one step lower until
  runtime priority adjustment exists), PAL/RNG/BST at `Priorities.heal + 5`, with the matching
  `unimplemented` lines removed.
- Verified off-client (54 checks: a healthy group left alone, worst-off-first selection, scope
  filtering in both directions, group heals with and without enough hurt, emergency standing down
  a group heal, called-off heals for all three reasons, the settle window and its emergency
  exemption, orders ahead of the state's own judgment, `healme` resolving the speaker, an order
  for a healthy target refused, the switches and the shared action command reaching the config)
  under LuaJIT and Lua 5.1. **In-game smoke test still pending** — see Verify.

**Spell DPS: done** (`states/spellDpsState.lua`, its config and page), and with it the split the
dps band always implied. What landed:

- ~~**The engagement came out of the melee state**~~ — `combat.lua` holds what we are fighting,
  because `attack <id>` has to mean the same thing to a warrior and a wizard and only one of them
  has a melee state. It owns the `attack` order, the `autoengage` switch and `/cattack`, drops a
  target that dies or leaves, and sweeps the extended target window (throttled) to pick one up.
  It runs no game commands, which fixed a latent crash hazard: the Attack button used to run
  `/mqtarget` from inside the ImGui render callback.
- ~~**A rotation state**~~ — an ordered list like the melee one, with three restraints that are
  all about not making a fight worse: `start below %` (let the tank land something first),
  `stop below %` (no four second cast on a mob that dies in two) and a mana floor. It registers at
  `dps - 1`, above melee, because the melee state reports busy for as long as it is engaged.
- ~~**Spells left the melee list**~~ — that list offers skills, discs, AAs and clickies, which is
  what the MQ2Melee lines it replaced actually did.
- ~~**`Casting.CanPreempt`**~~ — the split surfaced a real bug: `CastAction:IsReady` refused
  whenever *anything* was casting, so a stronger state could never take a weaker cast over
  through the action layer, and a heal could not interrupt a nuke. Callers now pass their band to
  `IsReady` as well as to `DoAction`.
- ~~**auto_engage moved**~~ to the combat config, taken across automatically from the melee
  section for characters that already had it set.

**Buff: done** (`states/buffState.lua`, `configs/buffStateConfig.lua`,
`ui/states/buffStateMenu.lua`; the model is described in ARCHITECTURE.md, "Buff state"). What
landed:

- ~~**The state**~~ — one ordered list of buff slots, each an action plus who it is for (anyone /
  myself / anyone else) and which classes are worth spending it on. Where the spell can be aimed
  (me, a pet, the group in one cast, one person at a time) and how long it lasts are read off the
  spell rather than configured, so a pet buff is for pets whatever the slot says and a heal that
  ends up in the list is caught rather than cast on a loop.
- ~~**Knowing what is missing**~~ — duration first (`Me.Buff`, `Me.Pet.BuffDuration`,
  `Spawn.CachedBuff`, all in milliseconds) against one `rebuff_secs` dial, then stacking
  (`Stacks` / `StacksPet` / `StacksSpawn`, plus `BlockedBuff` for ourselves), which also answers
  "a better buff is already there" and "too powerful for them" without spending a cast.
- ~~**How long an answer is good for**~~ — the part healing did not need. Another player's buffs
  are only visible once the client has cached them (targeting does it) and an empty cache reads as
  a clean one, so each (slot, spawn) pairing carries a retry window: the buff's duration less the
  rebuff window after one lands, seconds after one fails. Dropped wholesale by `/cbuff refresh`.
- ~~**Restraint**~~ — not during a fight (and a fight starting calls off the buff in the air), not
  while running, bards excepted. Buffing gets its frames because follow yields the moment it has
  caught up, which is what makes `Priorities.buff` work without the `- 1` juggling the dps split
  needed.
- ~~**Commands**~~ — `buffnow <id | off>` and `buffme` as orders (an order is "everything they are
  missing", so it stays open until the casts go quiet); `buffing`, `buffgroup`, `buffpets` and
  `buffcombat` as switches; `buffaction` over the slots; `/cbuff` for status, `/cbuff refresh` to
  forget what was worked out.
- ~~**The page**~~ — status, the switches, the rebuff window and a Check Everybody Now button, the
  slot list with its scope and class picker, and what each slot amounts to (where it aims, how long
  it lasts, or why it will never fire).
- ~~**Class profiles**~~ — the twelve classes with a spellbook at `Priorities.buff`, with the
  matching `unimplemented` lines removed.
- Verified off-client (85 checks: a buffed group left alone, list order deciding, scope and class
  filtering both ways, group/pet/self aims and what each refuses, the rebuff window at both ends,
  cached durations for other people, everything the stacking checks refuse, the retry window after
  a landed and a failed cast and `Recheck` clearing it, the combat and moving holds with the bard
  exemption, calling off for a fight and for a death, orders for somebody outside the group and
  their expiry, and the config accessors) under LuaJIT and Lua 5.1. **In-game smoke test still
  pending** — see Verify.

Buff's own leftovers: other people's pets, buffs cast *because* of a moment rather than to keep
them up (paragon, a group heal-over-time), twisting for bards, and any awareness of what the other
buffers in the group have already cast.

**Rest: done** (`states/restState.lua`, `configs/restStateConfig.lua`,
`ui/states/restStateMenu.lua`; the model is described in ARCHITECTURE.md, "Rest state"). The first
state at the misc band, and the first one whose whole design is *where* it sits rather than what it
does. What landed:

- ~~**The state**~~ — sit while health, mana or stamina is below the sit point, stand once all of
  them are at or above the stand point. Which pools this character has is read (`MaxMana` of zero
  is what says there is no mana bar) rather than configured, and "should I be sitting right now" is
  asked from the world every pass and answers both directions.
- ~~**Whose posture it is**~~ — the one thing remembered, because no TLO reports it: a sit is ours
  only if it landed while our own `/sit on` was outstanding. A sit somebody else chose is never
  stood out of, nor is our own while the spellbook is open, and a stand we did not order buys a
  grace window before we sit again. Everything that really needs the character upright stands it up
  itself, so the state never has to win that argument with the person playing.
- ~~**Restraint**~~ — never while engaged, never with a cast in the air, and during a fight this
  character has not joined only while `restcombat` is on *and* melee is off (a character that walks
  into melee is one that is about to be on its feet anyway). A settle window keeps a group's
  stop-and-go from turning into a sit per step.
- ~~**A common state**~~ — registered for every class by `BaseClass`, like follow, at
  `Priorities.misc`. It gets its frames because everything above it yields: parked on an anchor,
  caught up behind whoever we follow, or standing around after a fight.
- ~~**Commands**~~ — `resting` and `restcombat` as switches, `/crest` for status. Switching resting
  off stands the character up through the command queue rather than from the caller's frame.
- Verified off-client (68 checks: sitting for each pool and not for a mana bar that does not exist,
  the two thresholds and the hysteresis between them, standing back up for full pools and for each
  reason to be up, every posture it refuses to touch, the settle window, the command throttle, the
  config guards on the threshold pair, and the switch standing the character up) under LuaJIT, and
  the posture-ownership rules the same way afterwards (37 checks: a sit of somebody else's left
  alone at full pools and through a fight, the spellbook holding down even a sit of our own, the
  grace after a stand we did not order against no grace after one we did, and the switch leaving a
  user's sit where it is). **In-game smoke test still pending** — see Verify.

Rest's own leftovers are the rest of the misc band, and they are the MQ2Melee chores that have
nowhere else to live: out-of-combat regen discs (Breather and friends), auto-food and drink,
dropping illusions and mounts, and the AA-on/off management at the bottom of `meleeState.lua`.

**Flee: done** (`states/fleeState.lua`, `configs/fleeStateConfig.lua`, `ui/states/fleeStateMenu.lua`;
the model is described in ARCHITECTURE.md, "Flee state"). Travel mode, at the passive band: follow
and nothing else, so a long run does not stop for aggro, healing, buffing or resting on the way.
What landed:

- ~~**Suppression by gate, not by config**~~ — `RegisterPriorityGate` grew an optional second
  return, a set of state keys exempt from that gate's floor, and flee holds the chain at
  `Priorities.passive` exempting FollowState. A floor alone could not say it: what has to go is two
  disjoint ranges, above follow and below it. A state must satisfy every gate, so an exemption is
  never a way past somebody else's floor — a cast in the air still starves follow. Nothing is
  written onto the other states, so `flee off` needs no restoring and a crash mid-run cannot leave a
  cleric that has quietly stopped healing.
- ~~**Letting go**~~ — turning it on interrupts the cast in the air, drops the engagement, and stops
  a movement task follow does not own (a melee stick would go on holding range on what we are
  running from). Auto attack is dropped every pass instead, since `/attack on` is the one commitment
  nothing else takes back, and `Combat.Pulse` skips the auto-engage sweep while fleeing.
- ~~**A common state**~~ — registered for every class by `BaseClass`, like follow and rest. It is
  the one state handed the state machine at `Init`, because a gate has to be registered with the
  machine that consults it.
- ~~**Commands**~~ — `flee` as a switch (so `/state flee` and a hotbar button that draws itself as
  the setting come free), `/cflee` for status and for `on`/`off`. It rides on top of a follow order
  rather than replacing one, and says so when turned on with nothing to follow.
- Verified off-client (12 gate checks: the ungated chain, a busy state ending the pass, a floor on
  its own, flee leaving only itself and follow, flee off restoring the chain, flee together with a
  cast in the air in both registration orders, a floor weaker than the exempt state, an unranked
  state never starved, a gate that errors holding nothing back, and an exempt set with no floor;
  plus the wiring: the module graph loading, the default, the switch and what `Status` reads back
  from it, `Describe` both ways, `Go` never holding the frame, the letting-go on the transition only,
  the follow task kept where a stick is dropped, and flee first in an assembled class chain) under
  LuaJIT. **In-game smoke test still pending** — see Verify.

Flee's own leftovers: the **pet**, which goes on fighting whatever it was told to and trails the run
— `/pet back off` belongs here, but cabby issues no pet commands anywhere yet and half a pet
behavior (what it was fighting, whether to put it back afterwards) is worse than none, so it waits
for a pet domain to live in; nothing decides on its *own* to flee (low health, a named spawning, a
wipe), which is a trigger to hang off it once there is anything watching for those; and there is no
group "everybody run" beyond saying `flee on` to a channel, which is Phase 5's coordination.

Still to come, per priority band: **Passive** (global pause; the same shape as flee with an empty
exemption set, plus a /cpause slash + comm command),
**Cure** (detrimental scan → cure actions), **Pull** (target selection, pathing, leash,
camp radius), **Mez** (add control, in-combat priority above dps), **Tank** (taunt/hate
action lists already modeled in MeleeStateConfig; needs aggro-loss detection for "as
needed" usage), **assist rules** (both dps states fight what `Combat` says; nothing yet says
"fight what the main assist is fighting"),
**Loot** (corpse scan, loot rules per item, master-loot coordination).
Each new state = state module + config section + UI panel + comm commands, which is why
the Phase 1 module contract comes first. Landing one is also a sweep over `classes/*.lua`:
the per-class view of this list is each profile's `unimplemented` lines, and a state that
exists moves from that list into the profile's `states` at its band.

Heal's own leftovers, for when the bands around it exist: heal-over-time management (a HoT is
wasted on someone about to be topped off; the duration reads the buff state uses are the half of
that which now exists), rezzing, curing at the cure
band, and any awareness of what *other* healers are doing — two clerics on one tank both cast, and
only the group coordination in Phase 5 can fix that.

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
- **Tests for cabby layer**: off-client harnesses now cover casting, discovery and the action
  types, the heal state, the follow state (including its stuck detection and the click-zone
  procedure), and the wiring. Still uncovered and worth doing next: command parsing (slash arg
  paths — several Phase 0 bugs live there), the Owners ACL, and config init/migration.

## Verify (assumptions to test in-game)

1. **MQ event multi-match**: does a line matching two registered events (command tell +
   tellToMe catchall) fire both callbacks? The `reregister`/"add last" hack implies ordering
   matters; confirm actual semantics and either dedupe in a single dispatcher or filter
   command phrases out of tellToMe. **Now load-bearing**: the timestamp handling below assumes
   two matching patterns *would* fire twice, and is built to make sure no line can ever match
   two. If it turns out MQ fires only the first, that assumption is merely conservative; if it
   fires both, this is the thing keeping commands from running twice.
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
   (a rogue, and any caster) — the notice should list its states and what it cannot do, and
   `/state` should list the chain in priority order. Every class registers MeleeState now, so
   the thing to confirm is the *band*: a caster's notice should show Melee below SpellDps
   (`dps + 5` against `dps - 1`), a melee class's should still show it at `dps`, and every
   character should get a `MeleeState` config section where casters previously got none. A melee
   character's config should be unchanged.
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
11. **Discovery, in game.** `/crefresh` on a caster and a melee: do the counts look right, and
   how long does it take (the AA scan walks 5000 group ids — if that is slow enough to notice,
   the bound or the approach needs revisiting, and if a known AA is *missing* the bound is too
   low). Then: does `Me.AltAbility[groupId].Passive` filter what it should on emu, does
   `item.Clicky.SpellID` find clickies in bags as well as worn gear, and does `Me.Book` return
   the sparse book this assumes rather than a packed list. After that, configure a spell in a
   melee action list on a hybrid and watch a fight: the rotation should cast when the spell is
   memorized and idle when it is not, the stick should pause for the cast rather than fighting
   it, and melee should resume the frame the cast ends. Finally, gain a level and buy an AA and
   confirm the service picks both up within five seconds without a `/crefresh`.
12. **Healing, in game.** On a cleric with a couple of slots configured: does the state pick the
   person you would have picked, and the heal you would have used? Watch the reported reasons on
   `/cheal` while a fight goes badly. Specifically worth confirming, since they are the parts a
   simulated client cannot answer: that `Group.Member[#].Spawn.PctHPs` tracks fast enough that the
   settle window is the right length (too short and heals double up, too long and a tank dies
   waiting), that `MainTank` is set the way the group actually plays, that a called-off heal
   really does free the priority chain the same frame, and that a heal on a member out of line of
   sight is refused by the slot rather than by the client. Then the orders: `healnow ${Target.ID}`
   from a hotbar button, and `healme` spoken by a tank in another window — and while you are
   there, confirm the prefix rule the naming assumes (a phrase also matching longer lines that
   start with it) actually holds, since Verify item 1 has never been answered.
13. **The dps split, in game.** On a hybrid (a paladin is the clearest): does `attack <id>` start
   both the swinging and the casting, does `melee off` leave the spells running, and does `nuke
   off` leave the swinging? Then the ordering that the split depends on — the rotation should get
   its cast in without the melee state starving it, and a heal should interrupt a nuke rather
   than waiting for it. On a wizard: `attack ${Target.ID}` with melee left off should nuke and
   never close, and `start below %` should hold fire until the tank has aggro; then `melee on`
   and confirm the weaker band does what it claims — swings only with the frames the rotation
   passes on, and never in place of a nuke that was ready. Also confirm the auto_engage
   migration: a character with an existing config should keep whatever it had set, and its
   `MeleeState` section should come back without the key.
14. **Buffing, in game — and cached buffs above all.** The whole "what is missing" model rests on
   reads a simulated client cannot answer, and the load-bearing one is
   `Spawn[id].CachedBuff[name]`: does it return anything at all on this emu client, and does a
   group member's cache populate without our targeting them (the group window may or may not do
   it)? If it never populates, `StacksSpawn` says yes to everybody — MQ's own implementation
   returns "it stacks" for a spawn it has no buffs for — and the only thing stopping a rebuff loop
   is the retry window, which means every group buff gets recast once per duration whether it
   needed it or not. Worth watching for over a couple of hours before deciding whether the state
   should target people to refresh their cache. Then, in rough order: `Me.Buff[x].Duration` and
   `Me.Pet.BuffDuration[x]` really are milliseconds (both are timestamps in the source, but
   `CachedBuff.Duration` is documented as ticks and is not); `Spell.MyDuration.TotalSeconds` reads
   through `tonumber`; `Stacks` is false for a buff we already hold at full duration and true for
   one that has faded; `Me.BlockedBuff` on a client that may have no blocked-buff window at all;
   and a group v2 buff cast with nothing targeted. After that the behaviour: a cleric buffing a
   fresh group from nothing (does it work down the list, does it stop, does `/cbuff` read right),
   `buffme` from another window, `buffnow ${Target.ID}` on a stranger, and that a fight starting
   really does call off the buff in the air.
15. **Chat timestamps** (found in game 2026-07-26, fixed; see ARCHITECTURE.md "Chat timestamps").
   A client that stamps every chat line broke the ACL on every command and killed the `bc`
   channel outright. What to confirm now: an owner's command over each active channel, a
   `bc` command specifically (it needed the second pattern), that no command runs *twice* on a
   stamped line (a toggle is the giveaway — two flips look like nothing happening), and a group
   invite from an owner being accepted rather than `/disband`ed. Raw events now expand through the
   same helper as comm patterns (`Speak.GetListenPatterns`), so a literal-leading event pattern is
   registered twice and heard either way; neither event registered today needs it, so there is
   nothing new to confirm in game beyond the invite still being accepted. Also worth pasting one raw
   stamped line of each channel into `scratchpad/test_chatpatterns.lua`, since the harness
   currently assumes the `[...]` prefix shape rather than a captured sample.
16. In-game smoke of the 2026-07-18 Phase 0 fixes: fresh-config startup on a taunt-less
   class, follow/stuck detection, add-new-action UI flow, `/activechannels <cmd> reset`,
   and the Cabby Alerts window (force an error to see alert + log + pause/resume).
17. **Resting, in game.** The client reads it leans on, first: does `Me.State` return `SIT` and
   `STAND` on this emu client (and `FEIGN` for a feigning monk), does `/sit on` sit rather than
   toggle, and does `Me.CombatState` say `COMBAT` for a character standing next to a fight it has
   not joined — that last one decides whether `restcombat` means anything at all. Then the
   behaviour: med a caster to full on an anchor and watch it stand up; start following and confirm
   the movement service stands it up on its own rather than the two fighting over the posture; let
   a heal go out mid-rest (the priority floor should starve this state, and the cast's own
   stand-up should not read as a reason to sit again the moment it lands); and watch a stop-and-go
   run to see whether two seconds of settling is the right length. On a melee: `melee off` should
   let it med through a fight it is not in, and `melee on` should stop it. Then the posture the
   script does not own: sit down by hand at full pools and confirm nothing stands you back up, open
   the spellbook from a rest and watch it hold the sit rather than close the book on a memorize,
   and stand up by hand to see whether five seconds is long enough a grace to feel like being left
   alone rather than long enough to feel like the resting stopped working.
