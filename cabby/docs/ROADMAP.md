# Cabby Roadmap

Companion to [ARCHITECTURE.md](ARCHITECTURE.md). Origin: design review 2026-07-18.
Vision: one script that bots any class/race — states for every band in the priority table
(commands, passive, cure, heal, pull, mez, tank, dps, loot, anchor, follow, buff).

Current coverage: Follow/Anchor/ClickZone, Melee, Spell DPS, Pet DPS, Heal, Buff, Pet Setup,
AdvLoot, Corpse, Rest and Flee states, over
a shared engagement (`combat.lua`) that the group's main tank and main assist steer (`roles.lua`);
all sixteen classes load as profiles over those (the nine melee
classes melee, eleven cast damage, the three priests and three hybrids heal — as do MAG, NEC and
SHD, whose heal lists are how a pet is kept up and how the empathy line is spent — the twelve with
a spellbook buff, the six with a companion pet summon it, gear it and send it in, and everyone
follows, rests, flees, minds the loot window and loots its own corpse when told to). The casting and giving services and all five action
types exist (Phase 3), so an action list can hold a spell, clicky or AA, `/ccast` can fire
anything by hand and `/cgive` can hand anything over. Everything else below.

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
  stuck detection over wall-clock windows (`StuckDetector.lua`), escalating strafe-then-jump
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
- ~~**Gem memorization**~~ — `/memspell` when a spell is not memorized, with its own retry. Into a
  gem the caller named if it named one, otherwise an empty gem, otherwise the configured gem (last
  gem by default). Which one is decided at the moment of memorizing, not when the cast was asked
  for, since the bar is the player's to change in the seconds in between.
- ~~**Outcome detection**~~ — `Me.Casting` for the shape of the cast, ~40 registered chat lines
  for the reason -- 37 of them (fizzle, interrupt, resist, immune, out of range, silenced, components...).
  A closing cast bar is not an answer on its own: it looks the same whether the spell went off or
  the cast was lost, and a fizzle is decided at the server's end of the cast, so it arrives a round
  trip behind. A completed cast therefore waits that long to be contradicted before it is called a
  success. Late "resisted"/"did not take hold" lines settle it the other way — they are proof the
  spell went off — and refine a result already reported as a success.
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
- ~~A rotation cannot memorize.~~ It was a common mistake rather than a rare one — a spell dps slot
  configured with a spell that was not on the bar, correctly set up, marked ready, silently never
  firing. `CastAction:IsReady` no longer requires the gem; the service memorizes, into an empty gem
  where there is one (see ARCHITECTURE.md, Casting and Action system). The remaining rough edge is
  a **full spell bar**: two unmemorized slots then share the one configured gem and cast over each
  other for as long as both are wanted. Better than idling silently, and visible when it happens
  rather than silent, but if it turns out to bite, the answer is probably to let the rotation pick
  the gem holding whichever of *its own* spells is furthest from being wanted.

## Phase 4 — The planned states

**Heal: done** (`states/healState.lua`, `configs/healStateConfig.lua`,
`ui/states/healStateMenu.lua`; the model is described in ARCHITECTURE.md, "Heal state"). What
landed:

- ~~**The state**~~ — one ordered list of heal slots, each an action plus the health it is for and
  who it is for (anyone / the tank / myself / anyone else / my pet). An order first, then a group
  heal when enough of the group is hurt, then whoever is worst off; group heals stand down while
  anyone is below the emergency point.
- ~~**Where a heal can be aimed**~~ — self, pet, group or single, read off the spell rather than
  configured (the buff state's `aims` model, arrived at second here). It outranks scope, so a pet
  heal is for the pet whatever the slot says, and self and pet heals are cast at nobody while the
  state still records who they were for. This is what let the pet classes in: before it,
  `NeedsTarget` was false for a pet heal exactly as for a group heal, so a magician's only heal
  would have been cast because three *people* were hurt.
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
  `extras` hook for the per-slot controls that belong to the state rather than to the action. Each
  row reports what its spell can be aimed at, offers only the scopes that spell can actually be
  given (a pet heal's dial reads "My pet" and is not editable; a group heal has none), and says why
  a slot will never fire when it will not — a pet heal with `healpets` off being the one that would
  otherwise be silent.
- ~~**The command factory**~~ — the `action` command moved out of MeleeState into
  `commands/actionCommand.lua`, so both states register the same thing instead of one copying the
  other.
- ~~**Class profiles**~~ — CLR/DRU/SHM at the heal band (druid and shaman one step lower until
  runtime priority adjustment exists), PAL/RNG/BST at `Priorities.heal + 5`, with the matching
  `unimplemented` lines removed. The pet classes joined them at `heal + 5` (2026-07-30): MAG and
  NEC for their pet heals, NEC and SHD for the empathy line they spend their own health on. ENC
  stayed out — it has a pet and no heal for it or for anybody, so its page would be empty.
- Verified off-client (54 checks: a healthy group left alone, worst-off-first selection, scope
  filtering in both directions, group heals with and without enough hurt, emergency standing down
  a group heal, called-off heals for all three reasons, the settle window and its emergency
  exemption, orders ahead of the state's own judgment, `healme` resolving the speaker, an order
  for a healthy target refused, the switches and the shared action command reaching the config)
  under LuaJIT and Lua 5.1, and 32 more for the aims model (a pet heal cast for a hurt pet and
  aimed at nobody, the same slot idle with `healpets` off, a pet heal *not* fired because three
  people are hurt, group and single heals unchanged, self heals only for us, "anyone else"
  skipping the pet, the pet scope picking it out, the settle window held against the pet, and what
  the page is told about each kind of slot). **In-game smoke test still pending** — see Verify.

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
- ~~**Damage shields joined the rotation**~~ — the one kind of damage that is cast on a friend, and
  the band it belongs in is this one: below the melee state nothing gets a frame while a fight is
  on, so a shield left to the buff state goes up after the fight rather than for it. A slot holding
  one carries `dps_scope` and reads like a heal slot (anyone / the tank / myself / anyone else / my
  pet), with where the spell can be aimed read off the spell and outranking it. `start below %`
  does not hold one back — that number is aggro management for damage aimed at the mob — and a
  landed shield is remembered by name for as long as it lasts, because the people wearing it are
  not who we have targeted and their buff cache reads empty. Covered headless (a plain rotation
  unchanged, a shield going to the tank instead of the mob, no recast while it is up, a death
  voiding the record, the start point holding the nuke but not the shield, each scope, a self-only
  spell keeping the one scope it can have, a group shield remembering everyone it covered, and
  what the page is told about each kind of slot). **In-game smoke test still pending** — see
  Verify.
- ~~**Easing off what we pull off the tank**~~ (2026-07-30) — the restraint both dps states share,
  because a rogue and a wizard ripping the tank's mob is one mistake. `Combat.ShouldEaseOff` reads
  the two facts the service already keeps — the mob we are hurting is at the top of *our* hate list,
  and holding it is the main tank's job — and each state acts on it its own way: melee drops the
  swing and its ability, taunt and hate lists (the stick stays), the rotation holds everything aimed
  at the mob and lets a damage shield through. Nothing is remembered and nothing is timed; the pass
  the tank is back on top is the pass the damage resumes. Not knowing what the tank is on reads as
  *the tank has this one*, matching the pet state's taunt. The `easeoff` switch is on by default and
  never fires for the main tank itself, or for a group with no tank named, or for an add the tank is
  not on — that one is ours to kill, and `defend` is what is said about it. Covered headless (the
  whole decision table, melee's silence including the taunt lists, the shield exemption, and the
  resume on both sides). **In-game smoke test still pending** — see Verify.

**Buff: done** (`states/buffState.lua`, `configs/buffStateConfig.lua`,
`ui/states/buffStateMenu.lua`; the model is described in ARCHITECTURE.md, "Buff state"). What
landed:

- ~~**The state**~~ — one ordered list of buff slots, each an action plus who it is for (anyone /
  myself / anyone else) and which classes are worth spending it on. Where the spell can be aimed
  (me, a pet, the group in one cast, one person at a time) and how long it lasts are read off the
  spell rather than configured, so a pet buff is for pets whatever the slot says and a heal that
  ends up in the list is caught rather than cast on a loop.
- ~~**Knowing what is missing**~~ — duration first (`Me.Buff`, `Me.Pet.BuffDuration`,
  `Spawn.CachedBuff`, all in milliseconds) against the slot's own rebuff dial (default three
  minutes, clamped to half the buff's duration so short buffs are not churned), then stacking
  (`Stacks` / `StacksPet` / `StacksSpawn`, plus `BlockedBuff` for ourselves), which also answers
  "a better buff is already there" and "too powerful for them" without spending a cast.
- ~~**How long an answer is good for**~~ — the part healing did not need. Another player's buffs
  are only visible once the client has cached them (targeting does it) and an empty cache reads as
  a clean one, so each (slot, spawn) pairing carries a retry window: the buff's duration less the
  rebuff window after one lands, seconds after one fails. Dropped wholesale by `/cbuff refresh` —
  and voided early by the world (2026-07-29): an observed death (scan or slain line) drops every
  window held for that name, readable people (us, the pet) only ever get a short window before the
  buff itself is consulted again, and everybody else is verified about once an idle minute by
  borrowing the target until `Target.BuffsPopulated` (a status per pass, never a held frame) and
  squaring their windows against the fresh cache.
- ~~**Restraint**~~ — not during a fight (and a fight starting calls off the buff in the air), not
  while running, bards excepted. Buffing gets its frames because follow yields the moment it has
  caught up, which is what makes `Priorities.buff` work without the `- 1` juggling the dps split
  needed.
- ~~**Commands**~~ — `buffnow <id | off>` and `buffme` as orders (an order is "everything they are
  missing", so it stays open until the casts go quiet); `buffing`, `buffgroup`, `buffpets` and
  `buffcombat` as switches; `buffaction` over the slots; `/cbuff` for status, `/cbuff refresh` to
  forget what was worked out.
- ~~**The page**~~ — status, the switches and a Check Everybody Now button, the slot list with its
  scope, class picker and per-slot rebuff dial, and what each slot amounts to (where it aims, how
  long it lasts, or why it will never fire).
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

**Pet setup: done** (`states/petSetupState.lua`, `configs/petSetupStateConfig.lua`,
`ui/states/petSetupStateMenu.lua`, plus the giving service below; the model is described in
ARCHITECTURE.md, "Pet setup state"). Named `PetState` when it landed and renamed the same day, when
the fighting half of a pet became its own state: an old `PetState` config section is moved across on
first load, so nobody's pet list or gear counts are lost to the rename. What landed (2026-07-30):

- ~~**The state**~~ — two ordered lists at `Priorities.buff - 1`: what summons a pet (first ready
  one wins, so its order is the preference and its Enabled switches pick today's elemental) and
  what gets conjured and handed to it. Each pass asks *is there a pet* and then *has this pet been
  given what the list says*, and starts at most one thing.
- ~~**What a slot is, read off the spell**~~ — a pet slot summons a pet because the spell carries
  the effect that does (SPA 33/71/106/108/151, never the swarm effect 152), and a gear slot
  conjures an item because it carries SPA 32/109, whose base value is the item's own id. So nothing
  is told which item a spell makes, the pickers narrow by the same reading (`Spells.petSummons`,
  `Spells.itemSummons`), and a slot holding the wrong kind of spell says so on its row instead of
  being cast on a loop. The one dial is `pet_gear_count`, which no spell can answer.
- ~~**What the pet was given**~~ — a pet's inventory is not readable (the client says only what it
  is *wielding*), so the record of what we handed it is the only answer there is. It belongs to one
  pet by spawn id and dies with it, so a replacement is kitted out from nothing with nothing to
  clear. A pet we did not summon is left as we found it unless it is empty-handed, and `gearpet`
  overrules that guess.
- ~~**Handing it over**~~ — `utils/Giving`, a service for the same reason casting is one: four
  commands and three waits on the client, so a state walking them itself would leave a give window
  open with an item in it the first time a fight took the frame. Evidence windows answer each step,
  both give shapes are handled (the window, or a client that takes it off the cursor), the player's
  own cursor is never taken, and an abandoned hand-off cancels the window and stows what it moved.
  `/cgive` drives it by hand.
- ~~**Restraint**~~ — dead, in a fight (`petsetupcombat`, off by default) or moving holds everything,
  and a fight starting calls off what is in the air. A vanished pet gets a five second grace before
  it is replaced, because the world does not say whether it died or was let go and `/pet get lost`
  must not be undone on the next frame. Casts for a gear slot are bounded by what the pet is owed,
  so a summon that lands and conjures nothing is not repeated forever.
- ~~**Commands**~~ — `summonpet` and `gearpet` as orders (both outrank the switches and the grace),
  `petkeeping`, `petsummoning`, `petgearing` and `petsetupcombat` as switches, `petaction` over both
  lists, `/cpet` for status and for `off`/`gear`/`summon`. Only `petsetupcombat` changed name with
  the split, because "pet" and "combat" in one word now reads like the pet dps master switch. An
  order's clock stops while the state is held (2026-07-30): a fight is not the same thing as an ask
  that has stopped meaning anything, and a `gearpet` said as a pull lands used to be dropped in
  silence fifteen seconds later.
- ~~**Somebody else's pet** (`petgear`, 2026-07-30)~~ — the group says it, and whoever has a gear
  list walks that list once for the asker's pet: same slots, same counts, same conjure-then-hand
  sequence, and a record of the same shape keyed to their pet's spawn id. A request rather than a
  switch — it ends when there is nothing left to hand over and forgets the pet — and a character
  with nothing on its gear list answers with silence, so one spoken line is one magician moving
  rather than six characters explaining themselves. It is also the one deliberate breach of the
  no-phrase-is-a-prefix rule (`petgear` inside `petgearing`), handled in the handler: a line whose
  next character is not a space is somebody else's command.
- ~~**Class profiles**~~ — MAG, NEC, BST, ENC, SHD and SHM at `buff - 1`.
  CLR, WIZ and DRU have pet spells and are deliberately out: a hammer, a sword and the behest are
  cast into a fight for the fight, and this state works between them.
- Verified off-client (54 checks: the grace before a re-summon and an order skipping it, a summon
  cast and the pet adopted from it, conjure-then-hand-over end to end with the four client commands
  in order, an adopted pet with something in hand left alone and `gearpet` overruling it, an
  empty-handed one geared, a fight holding everything and calling off the cast, two of an item over
  two rounds, the cast bound on a summon that conjures nothing, a dead pet taking its record with
  it, a slot holding a nuke reporting why, the moving hold, a pet too far away failing with a
  reason and leaving nothing on the cursor, a client with no give window, calling a hand-off off
  mid-window putting the item back, and a loaded cursor refusing the hand-off outright), plus 25
  more for the startup rule and `petgear` (2026-07-30, Lua 5.4 and LuaJIT: a pet that was here at
  startup left alone with daggers in the bags and `gearpet` overruling it, an unsummoned pet that
  turned up mid-session still geared when empty-handed and left alone when not, the ask handed to
  the asker's pet id rather than ours and bounded by the slot's count, the conjure credited to the
  ask rather than to our own pet, the `petgearing` prefix line dropped, an asker with no pet and one
  we cannot see both told, silence from a character with no gear list, an ask ending when the pet is
  gone, and a fight not timing an ask out).
  **In-game smoke test still pending** — see Verify.

Pet setup's own leftovers: summoning for anybody but the pet (mod rods, food and drink on request).
A charmed pet is no longer one of them — since 2026-07-30 it is recognised and deliberately left
alone here (nothing conjured, nothing handed over, `gearpet` saying why), because what a charmed mob
is given leaves with it when the charm breaks.

**Pet dps: done** (`states/petDpsState.lua`, `configs/petDpsStateConfig.lua`,
`ui/states/petDpsStateMenu.lua`, plus `pet.lua`; the model is described in ARCHITECTURE.md, "Pet dps
state"). The other half of a pet, split off from the setup state the day it landed because the two
halves belong in two bands. What landed (2026-07-30):

- ~~**The state**~~ — at `Priorities.dps - 2`, above both rotations for the reason SpellDpsState is
  above MeleeState: the melee state is busy for the whole fight, and a pet order that waits for the
  rotation is a pet arriving after the mob has picked somebody. Each pass reads who the pet is,
  what `combat.lua` is on and what the pet is on, says at most one thing, and yields.
- ~~**Sending it in**~~ — `/pet attack <spawnid>`, MacroQuest's own extension of the client
  command, so nothing here touches the client's target (the bare command sends the pet at whatever
  *we* are looking at, which a heal cast mid-fight would turn into a pet sent at a group member).
  Repeated on a pacing window for as long as the pet is not on what the fight is on, which is also
  what moves it to the successor mob without anything having to notice a successor.
- ~~**Calling it off**~~ — only ever off the mob this fight put the pet on, which is the one number
  held between passes and is dropped the moment the pet is not on it. A pet that has moved to
  something else picked that up itself and is left alone; a pet that went in on its own on what we
  are fighting is adopted and called off with the rest of the fight.
- ~~**The aggro gate**~~ — `send in below %`, the rotation's `start below %` for a pet, shipped at
  100 (in as soon as there is a fight) with the page's button and `/cpetdps in` as the order that
  outranks it.
- ~~**The four switches**~~ — taunt, hold, greater hold and focus as three-way dials (leave alone /
  on / off), enforced by reading where each stands and flipping what disagrees, because this
  client's pet commands are toggles with no on/off form. They are kept per pet by the client, so a
  new pet arrives with all four off and something has to keep putting them back. A switch flipped
  by hand gets fifteen seconds before the dial wins again.
- ~~**Taunt answered from the group**~~ (2026-07-30) — a fourth dial position, `Automatic`, offered
  for taunt alone because taunt is the one of the four whose right answer is not a setting: off
  while the group's main tank is on what the pet is on, on when there is no main tank at all or the
  tank is demonstrably on something else, and off when a named tank's target cannot be seen from
  here (ripping a mob off a warrior being the expensive way to be wrong). What the tank is on comes
  from `Combat.GetTankTargetId` — us, the tank's own heard `assist` call, or the client's assist
  record when the tank holds that role too — which is also new, and is the first thing in cabby to
  read a heard call as a *record* rather than only as an order. Between two mobs of one fight the
  last answer stands rather than flapping, and the state's own answer moving drops the marks that
  would otherwise read it as a hand flip and grace it for fifteen seconds.
- ~~**The protect job**~~ (2026-07-30) — a dial for what the pet is *for*: `fight` (what it has
  always done, and the default) or `protect`, which puts a mob actually coming for this character
  above the fight. The pet is sent at it with taunt on, moves to the next thing on us when that one
  has turned round, and goes back to the fight when nothing is. The whole cycle is
  `Combat.GetUnderAttackIds` (also new) read fresh every pass — a peeled mob leaves that list on its
  own, because we are no longer the one it is coming for, so nothing is timed and no peel is
  remembered. It does not wait on there being a fight (a beating with `autoengage` off is still a
  beating) and it skips the send-in gate (a mob already on us has no aggro left to manage). While
  peeling, the job outranks the dials on taunt (on) and focus (off) and leaves hold and greater hold
  alone — those gate what a pet picks up unbidden, and everything here is bidden. A switch set to
  "leave alone" is borrowed rather than taken: where it stood is written down and put back when the
  peel ends, so the job cannot quietly change somebody's pet for good.
- ~~**Commands**~~ — `petattack` as the switch (off calls the pet off and stops sending it, which
  is also how to get a pet back mid-fight without calling the fight off), `/cpetdps` for status and
  for `in`/`on`/`off`/`job fight|protect`. Deliberately no chat verb per client command: what the
  pet fights follows the engagement, so `attack <id>` and `attack off` already move it.
- ~~**Class profiles**~~ — the same six as pet setup, at `dps - 2`, with the "sending the pet in
  and calling it off" lines gone from their `unimplemented`.
- Verified off-client (44 checks under Lua 5.4 and LuaJIT: no pet and dead saying nothing, the send
  by id, the pacing window and the re-send, the successor mob, the seek beat leaving the pet where
  it is, the call-off and its repeat until the world agrees, a pet that moved to an add left alone,
  a pet adopted from its own charge and called off at the end, a replaced pet taking the record
  with it, the gate holding and releasing and an order overruling it, an order lapsing, a dead
  target not sent at, a switch flipped and not flipped twice inside its window, a hand flip graced
  and then put back, "leave alone" never touched, a new pet's switches set at once, the settle
  after a pet appears, the fight outranking the switches, switching the state off calling the pet
  off through the command queue and not otherwise, and the flee hand-off with its pacing and its
  "a pet following its owner is not fighting" guard), and 26 more for the automatic taunt dial
  under Lua 5.5 and LuaJIT (the tank's target from each of its three sources and from none of them,
  a call by somebody who is not the tank ignored, our own engagement when we hold the role and
  nothing mid-seek; then no tank taunting on, a tank picking the mob up taunting off, the tank
  leaving it taunting straight back on with no hand grace in the way, an unreadable tank target
  taunting off, the beat between two mobs saying nothing at all, a hand flip still graced and then
  put back, `auto` on a switch nothing answers reading as leave alone, and a replacement pet
  re-derived from nothing), and 26 more again for the protect job (the fighting job ignoring a mob
  on us, the peel outranking the fight, taunt taken from a left-alone dial and put back when the
  peel ends, a second mob taken once the first has turned round, the pet keeping the one it has
  while that one is still on us, the fight's own target being what is on us, a peel with no fight at
  all, the send-in gate skipped, and focus taken against a dial that says on and restored by that
  dial rather than by a loan). **In-game smoke test still pending** — see Verify.

**What kind of pet it is: done** (`pet.lua`, read by both pet states and the flee state; the model is
described in ARCHITECTURE.md, "Pet dps state"). An enchanter's animation takes no pet commands at
all, which made every dial on the pet dps page a lie for the one class that most needed the page to
be honest. What landed (2026-07-30): the kind of pet read from the world rather than assumed -- a
charm effect on the pet's own buffs says charmed, an enchanter's own pet is an animation, everything
else is summoned -- and `Animation Empathy` read for which words an animation is listening for
(attack at rank 2, back off and the four switches at rank 3). The dps state says nothing it cannot
be heard saying: no order, no back off, no switch flipped, no peel worked out for a pet that cannot
be sent, `/cpetdps in` answering instead of holding an order nobody will carry out, and the page
naming the pet's kind and what is missing rather than showing dials that do nothing. Flee's `/pet
back off` is gated by the same read, and the setup state uses the charmed half of it. 59 headless
checks (Lua 5.4 and LuaJIT: no pet, an elemental answered at once, the animation at rank 0, 1, 2, 3
and 17, a charmed pet taking everything with no AA at all, a charm the client fills in a beat late,
the answer settling and then standing, a new pet re-derived from nothing, an unreadable class
answering nothing, and one buff scan across ten passes).
**In-game smoke test still pending** — see Verify.

Pet dps's own leftovers: nothing reacts to the pet's *health* (keeping it alive is the heal state's
`healpets`, and a pet backed off because it is dying would be this state's call to make); pet
disciplines and AAs are ordinary damage in the spell dps rotation rather than something aimed at
the pet's own timers; and swarm pets are still a rotation slot and not a pet.

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

Flee's own leftovers: ~~the **pet**, which goes on fighting whatever it was told to and trails the
run~~ — **done** (2026-07-30): `Go()` reads `Pet.IsFighting()` and says `/pet back off` every pass
it finds it true, paced at a second and a half, exactly as it drops auto attack and for the same
reason — PetDpsState would have done it and is starved at the dps band. Nothing decides on its *own* to flee (low health, a named spawning, a
wipe), which is a trigger to hang off it once there is anything watching for those; and there is no
group "everybody run" beyond saying `flee on` to a channel, which is Phase 5's coordination.

**Mez landed 2026-07-30** — add control at `Priorities.mez`, the first state above the dps bands
that is not about damage, and the enchanter is the first class to register one. It came with a
service under it: `cabby/mobs.lua`, the shared roster of what is *in* the fight, merged from four
angles (the engagement, the extended target window, the group's `defend` reports, and a sweep for
NPCs in combat stance nearby) with each entry recording which angles saw it. That split was
deliberate — "which mobs are here" is a fact a puller's leash and a tank's add sweep will want the
same answer to, and crowd control acting on a list it assembled privately is crowd control nobody
can audit. See ARCHITECTURE.md, "Mob roster" and "Mez state". 35 headless checks pass over the
state's decisions (kill target never mezzed, refresh before the wear-off, the break signals beating
the cache, immune and resist remembered, the softener deferral, AE count and centring, the AE safety
switch, zone reset). **In-game verification still pending** — see Verify.

**Curing landed 2026-07-31**, and it did *not* take the cure band. It is two halves: `cabby/curing.lua`
is a service on every class that reads this character's own counters (poison, disease, curse,
corruption), says `cure <type>` for anything with more than a minute left, and holds the queue of
everyone who has said it; the heal state is the half that casts, ahead of every heal and behind
anybody below the emergency point. `actions/cureTypes.lua` is the data — an affliction and its cure
carry the same counter effect and differ only in the sign of the base, which is what makes "the best
cure I have" an exact reading (most counters stripped) rather than a guess at spell rank. One
setting, on the Heal State page: Disabled / out of combat / in battle too. 133 headless checks pass
over the scan, the ask pacing, queue dedup and TTL, the cached-buff read-back, and where a cure sits
in the heal state's pass. **In-game verification still pending** — see Verify. The cure band stays
reserved in `priorities.lua` for a curer with no healer to arbitrate against; see ARCHITECTURE.md,
"Curing".

Still to come, per priority band: **Passive** (global pause; the same shape as flee with an empty
exemption set, plus a /cpause slash + comm command),
**Pull** (target selection, pathing, leash,
camp radius), **Tank** (taunt/hate
action lists already modeled in MeleeStateConfig; needs aggro-loss detection for "as
needed" usage),
**Loot** (two of the three halves exist: `AdvLootState` answers the akk-stack loot window's
rolls with *Pass* for everyone but whoever controls the loot, and `CorpseState` empties this
character's own corpses on the `lootcorpse` order — within 50, walking nowhere. Still to come
are the corpse-*walk* that gets a character back to a corpse it cannot reach (and with it
looting NPC corpses on the ground), and the controller's own side — per-item rules, give-to
routing, lock/unlock automation).
Each new state = state module + config section + UI panel + comm commands, which is why
the Phase 1 module contract comes first. Landing one is also a sweep over `classes/*.lua`:
the per-class view of this list is each profile's `unimplemented` lines, and a state that
exists moves from that list into the profile's `states` at its band.

Heal's own leftovers, for when the bands around it exist: heal-over-time management (a HoT is
wasted on someone about to be topped off; the duration reads the buff state uses are the half of
that which now exists), rezzing, and any awareness of what *other* healers are doing — two clerics
on one tank both cast, and only the group coordination in Phase 5 can fix that. Curing has the same
gap and it is more visible there, because a cure request goes to everybody at once: two clerics hear
one `cure poison` and both answer it. The queue is per-listener by design, so the fix is the same
Phase 5 coordination rather than anything in `curing.lua`.

Two of these are already half-written elsewhere and only need the state around them:
**Tank** (MeleeState's taunt/hate lists run on a timer; what is missing is aggro-loss
detection, and the plate classes then gain an entry at `Priorities.tank`) and **DPS at
range** (`utils/Movement/Stick.lua` already strafes into the rear arc, which is a rogue's
backstab positioning; nothing asks for it).

## Phase 5 — Group/raid coordination

- ~~Assist protocol~~ — **the first half has landed** (see the Assisting section of
  ARCHITECTURE.md): `roles.lua` reads main tank and main assist out of the group and raid
  windows, auto-engage takes the assist's target before anything that is merely hitting us,
  and the tank calls `assist <id>` / `assist off` out to the group as its own engagement
  changes. Still open: **marks** (`Group.MarkNpc`, `Raid.MarkNPC` — a called target that is
  not the assist's current one), target dedup across the group, anti-summon distance rules,
  and leash/give-up timers.
- Role model: puller and healer assignments; main tank and main assist come from the client
  now, and the rest may want to as well rather than growing a second place to set them. What
  is still missing is the *use*: the runtime priority modifiers from the class-profile design
  (group makeup changes who heals/tanks at what priority), and a tank that does something with
  the role beyond announcing what it is on.
- Structured coordination messages ride the Phase 2 transport (actors preferred, chat
  channels as universal fallback).
- Fleet UX: broadcast config changes ("everyone set camp here"), status dashboards.

## Cross-cutting gaps (no owner yet)

- **Lifecycle events**: zoning, death/rez handling, camp/disconnect detection, GM detect →
  a global interrupt that resets states safely. Zoning is currently noticed a module at a time,
  each polling `Zone.ID` for itself and each drawing its own conclusion — Combat drops defend
  reports and assist calls, MezState its mez records, PetSetupState carries the pet's gear record
  across the line and restarts the grace on replacing a missing pet, FollowState notices only
  click-zoning. Everything not on that list still keeps stale ids across a line, and there is no
  one place that says "we just zoned".
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
   Related: our own outgoing chat *can* come back to us — eqbcs localecho is on by default and
   loops `/bc` lines back, which is how a commander used to anchor itself (2026-07). Own-name
   chat lines are now owner-gated in `protectChatHandler`: verify in game that with ourselves
   off the owner list a `/bc anchor` moves everyone else and not us, that adding ourselves (or
   an open list) makes it include us, and that `/cself` works either way. (EQ renders our own
   group/raid lines as "You tell your party, ...", which no registered pattern matches — that
   half still holds on its own.)
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
   memorized, and memorize it into an empty gem the first time it is wanted when it is not (and
   over the configured gem when the bar is full), the stick should pause for the cast rather than fighting
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

   Then the pet half, on a magician or a necromancer (2026-07-30): with `healpets` on and a pet
   heal configured, does it fire on a hurt pet and *not* while only people are hurt — and does it
   go out with nothing targeted, leaving whatever you were looking at alone? The reads it rests on
   that a simulated client cannot answer: that `Me.Pet.PctHPs` tracks a pet taking damage as
   closely as a group member's does (the settle window is the same length for both), that a
   pet-target spell really is refused at range rather than cast into nothing (the range check is
   skipped for a heal that aims itself), and that the client files this server's pet heals
   somewhere the Heals picker now offers — Health as well as Heals, which is where Renew Elements
   and the Mending line sit in the RoF2 data. Also worth a look: the row's own report ("on my pet")
   and the warning it shows while `healpets` is off.
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

   Then the damage shield half (2026-07-30): put one in the rotation on a magician, scope it to
   the tank, and pull. It should go up *first*, before the mob has dropped to the start point,
   land on the tank rather than on the mob, and then never be cast again while it is up — the last
   of those is the one to watch, because the tank's buff cache is empty from here (we have the mob
   targeted, not them) and a wrong answer looks like a cast every time the gem comes back. Then
   let it fade mid-fight and confirm it goes up again, and kill the tank and rez them and confirm
   they are shielded rather than left bare. Also worth confirming the reads the choosing rests on:
   that this server files its shields under a heading the Damage Shield set actually matches (the
   picker's row says what each spell is filed under with **Show every spell** on), that
   `Spell.Beneficial` is what separates the two halves on this build, and that the cast leaving
   the target on the tank is recovered by the melee state's own re-target rather than stalling the
   swing.
14. **Buffing, in game — and cached buffs above all.** The whole "what is missing" model rests on
   reads a simulated client cannot answer, and the load-bearing one is
   `Spawn[id].CachedBuff[name]`: does it return anything at all on this emu client, and does a
   group member's cache populate without our targeting them (the group window may or may not do
   it)? If it never populates, `StacksSpawn` says yes to everybody — MQ's own implementation
   returns "it stacks" for a spawn it has no buffs for — and the only thing stopping a rebuff loop
   is the retry window, which means every group buff gets recast once per duration whether it
   needed it or not. The state now targets people to refresh their cache itself (2026-07-29
   verification: borrow the target, wait on `Target.BuffsPopulated` a pass at a time, restore),
   which is also what to watch in game: the swap landing, the packet arriving inside its second
   (`/echo ${Target.BuffsPopulated}` while targeting a member), the target going back, and death →
   rez → prompt rebuff without `/cbuff refresh`. Then, in rough order: `Me.Buff[x].Duration` and
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
18. **Assisting, in game — and the client's assist target above all.** One read decides whether
   half of this works: does `Me.GroupAssistTarget.ID()` actually follow the group's main assist
   around on this emu server, or does it only fill in after somebody presses `/assist`? `/croles`
   answers it in one line — set a main assist, have them target something, and see whether "the
   assist is on" names it. If it stays empty the read half is inert (no harm, it simply never picks
   a target up that way) and the tank's `assist` call is carrying the group on its own, which is
   why the two mechanisms exist. Same question again for `Me.RaidAssistTarget[#]` in a raid, and
   worth confirming `Raid.MainAssist` resolves at all on a RoF2 client — the *indexed* form is
   compiled out below CotF, which is why nothing here uses it. Then the behaviour: with the tank
   calling, does a group of four all end up on one mob within a pulse or two, does the tank's Back
   Off button stop all of them (it should go out as `assist off`), and does `flee on` on the tank
   do the same? Watch chat for how noisy one line per target actually is over a real pull chain,
   since that is the tuning knob if it turns out to be too much. Then the parts that are
   judgment rather than plumbing: is "it has taken damage" the right gate for picking the assist's
   target up unasked (too strict and a fight opens a second late, too loose and the group jumps on
   a mob somebody conned), and does a hybrid holding the main tank role want its own heals scoped
   to `tank` — that changed with this work, and a paladin now matches its own tank-scoped slots.
19. **Non-NPC targets, in game** (changed 2026-07-27: pets and destructibles are fightable,
   corpses never). `attack <id>` on a destructible (a spider cocoon cluster) and on an enemy pet:
   everyone should acquire it and swing — the melee retarget used to ask for `npc`, so a character
   that lost the target stood there while the MQ log filled with "There are no spawns matching".
   Watch two judgment calls that came with it: the assist *reading* can now pick up a group
   member's own wounded pet if the main assist parks their target on it (the taken-damage gate is
   all that is left there — decide in game whether that needs a master-is-a-player exclusion), and
   the Attack button now greys out with a corpse targeted, same as `attack` refusing a dead id.
20. **The pet, in game — and the hand-off above all** (2026-07-30). First contact the same day
   got as far as the cast: on a magician with an `Elemental: Earth` slot the state picked it up,
   asked for the cast, and the casting service refused it for a **missing component** — the
   elementals eat a malachite each (item 10015, count 1) and there were none in the bags. So the
   chain, the SPA reading and the cast request all work in game. Two things came out of it. The
   refusal was right: this server's `Character:PetsUseReagents` is on, and the server checks worn
   and personal inventory only, exactly as the pre-check does — so a bank full of malachite is
   still a refused cast, in both places. And the refusal was *illegible*, showing an item id,
   because nothing in the client names an item it has never held; components are now named from a
   generated table (`utils/Casting/ReagentNames.lua`), and every slot keeps why its last attempt
   failed on its own row and in `/cpet`. Still to confirm: that with malachite in the bags the
   summon actually goes off — and worth a look at whether the per-element **no-expend** focus item
   (`NoexpendReagent`, the Ponz line for the elementals) is enforced here too, since nothing checks
   that one and the client would be the first to say so.
   Then the hand-off, which nothing has touched yet and which rests on one guess: does
   `/click left target`, with an item on the cursor and the pet targeted, open **GiveWnd** on this
   client? `/cgive <item> targetid|${Me.Pet.ID}`
   is the one-line answer and the thing to try first. Both shapes are handled — the window with its
   Give button (`GVW_Give_Button`, read out of the client's own `EQUI_GiveWnd.xml`), or a client
   that takes the item straight off the cursor — so what matters is that *one* of them happens
   within the evidence window rather than the click doing nothing at all. Around it: does
   `/nomodkey /itemnotify "<name>" leftmouseup` lift a summoned item out of a **closed** bag; is 20
   units the right reach (the failure to watch for is a hand-off that reports "too far" while the
   pet is stood next to us, or one that waits out the window for a click the client refused); and
   does `/cgive off` mid-window really put the item back rather than leaving it on the cursor.
   Then the state: on a magician, does `Elemental: Fire` plus a `Summon Dagger` slot at count two
   end with a pet holding two daggers, and does `/cpet` name the item rather than "item 7305" —
   which is also the check that `Spell.Base[n]` for SPA 32 is the item id in this server's data,
   the whole reason no item has to be configured. On a necromancer with no bone chips, the summon
   should fail saying which reagent is missing. The reading that decides how an *adopted* pet is
   treated needs a look too: does `Me.Pet.Equipment[primary]` read zero for a freshly summoned
   elemental and non-zero once it has been handed a weapon — and do any pets on this server show a
   weapon model natively, which would make one read as "already equipped" and be left alone (the
   `gearpet` order is the escape hatch either way, and whether five seconds is the right grace
   before a vanished pet is replaced is the other thing only playing can answer). Since 2026-07-30
   that read is not asked at all of the pet standing here when the script starts — that one is
   always left alone — so the thing to confirm on a reload is the quiet: a magician restarted beside
   its armed pet should conjure nothing, and `gearpet` should still arm it on request.
   Then `petgear`, which rests on one read of its own: does `${Spawn[pc radius 300 <name>].Pet.ID}`
   resolve a group-mate's pet on this server (a warder and an animation, not just an elemental), and
   is a pet standing at its owner's back inside the hand-off's twenty units when the owner is next
   to the magician? Worth saying it while somebody also says `petgearing off` in the same minute:
   the switch and the request share a prefix, and only the handler keeps them apart.

21. **Using the pet, in game** (2026-07-30, `PetDpsState`). Four reads and one command carry the
   whole state, and three of them are guesses until a client answers. First the command: does
   `/pet attack <spawnid>` — MacroQuest's extension, not the client's — actually send the pet at
   that spawn on this build, with something *else* targeted? That is the read the whole design
   rests on, and the failure to watch for is a pet that goes at whatever is targeted instead.
   Then `Me.Pet.Target`: it is the client's "who the pet is following", and this state treats it
   as "what the pet is fighting" — so confirm it reads the mob while the pet is on one, reads
   nothing while the pet is idle at our side, and above all that it does **not** read *us* while
   the pet is merely following (there is a guard for that case, but it should never have to fire).
   Then the four switches: does `/pet taunt` with no argument toggle rather than needing `on`/`off`
   (this client's command list says toggle-only), does `Me.Pet.Taunt` read back the flip within the
   three second window, and are the switches really reset for a freshly summoned pet — which is the
   reason the dials exist rather than a one-time setup. Then the shape of it in a real fight, on a
   magician: pet in on the pull with the dial at 100, `/cpetdps` naming what it is on, the pet
   following the fight onto the next mob without a second order, and the pet coming back when the
   mob dies. And `flee on` mid-fight: the pet should let go and follow, which is the flee state's
   own hand-off and the one that matters most for a group actually running.

   Then the automatic taunt dial (2026-07-30), which rests on one question this setup can answer in
   a line: with the taunt dial on **Automatic**, does `/cattack` name what the main tank is on? If
   it says "nothing this client can see" while the tank is plainly fighting something, the group
   has no cabby tank calling assists *and* the tank does not hold the assist role — the two paths
   `Combat.GetTankTargetId` has — and the dial will sit at "off" forever, which is safe but is not
   the feature working. With it reading right: pull with the tank, and taunt should go off (the
   `/pet taunt` line is in the debug log with the reason on it); send the pet at an add the tank is
   not on, and taunt should come on within a pass; let the tank pick that add up and it should go
   back off. Then the two edges worth watching for flapping in real chat latency rather than in a
   harness — a mob dying mid-fight while the pet is between targets (nothing should be said at all)
   and a tank switching targets fast on a multi-mob pull (one flip per real change, not per call) —
   and the courtesy: flip taunt by hand and it should stand for fifteen seconds before the dial
   takes it back. Solo the same magician with no group at all and it should read "no main tank in
   the group" and leave taunt on.

   Then the protect job (2026-07-30), whose every question is about one read: does an
   `Auto Hater` at 100% aggro appear on the extended target window fast enough, and *leave* it once
   the pet has the mob? The leaving is the half nothing else in cabby has depended on — everything
   here rests on a peeled mob dropping off that list on its own, and if this server keeps us listed
   at 100 while the pet tanks it, the pet will sit on the peel and never go back to the fight.
   `/cpetdps` names what it is taking off you, so watch it through one add: pet on the group's mob,
   something jumps you, the pet leaves for it with taunt going on, the add turns round, and the pet
   goes back — and taunt goes back to where you left it, which is the borrow working. Then two adds
   at once (it should take them in turn, not flap between them), an add while the group is *not*
   engaged (auto-engage off — the pet should still come), and the switch that decides how much this
   costs: with focus on by hand, does `/pet attack <id>` retarget the pet at all, or is the job's
   focus-off what makes any of this work? Also worth knowing whether `/pet taunt` on a pet that has
   just arrived at a mob peels it in a reasonable number of seconds, since that is the whole
   mechanism and nothing here can make it faster.

   Then what kind of pet it is (2026-07-30), which is one read on an enchanter and the only thing
   standing between that class and a page full of dials that do nothing. **Does a charmed pet's
   charm show up in the pet's own buff list?** `${Me.Pet.Buff[1]}` through `[30]` after charming
   something — one of them should be the charm, and `/cpetdps` should say the pet is *charmed*
   within a second of it landing. If the list comes back empty on this server the discriminator is
   wrong and needs replacing (`${Me.Pet.IsSummoned}` is the next candidate, and it is worth reading
   on both an animation and a charmed pet while looking), and the symptom to watch for is an
   enchanter refusing to fight with a charmed pet because it has been filed as an animation. The
   other half is the animation itself: with no `Animation Empathy`, `/cpetdps` should say it takes no
   orders and the pet should be left entirely alone — no `/pet attack` in the debug log, no switch
   flipped, and `/cpetdps in` answering rather than going quiet for fifteen seconds. Confirm the
   premise while there: `/pet attack` said by hand at an animation should do nothing at all. Then, if
   the character has the ability, `${Me.AltAbility[Animation Empathy].Rank}` should read the trained
   rank (0 or nothing if untrained), and the rank boundaries are worth one look each — rank 2 sends
   the pet in but leaves the switches alone, rank 3 makes an animation behave like any other pet.
   And on a magician or beastlord, the quiet check that nothing changed: the pet should still be sent
   in on the first pass of a fight, with no extra second's delay while the kind is worked out.

22. **A debuff in the rotation, in game** (2026-07-30, `dps_timing`). Two reads decide whether the
   whole dial is worth having, and a harness cannot answer either. First, **is a root readable back
   off the mob?** The "cast it once, and again when it fades" half rests entirely on
   `Spawn.CachedBuff` reporting the mob's own debuffs while it is our target — our record of having
   cast it is trusted for two seconds and no longer, on the grounds that the world answers after
   that. If this client caches nothing for NPCs, `Stacks` says "it would take" every pass and the
   root goes out every two seconds: the failure is loud and looks like root spam in the log, so
   watch one full root duration on a rooted mob before believing the feature. (If it *is* empty,
   the fix is at the record, not the state — the mob is then no more readable than a group-mate,
   which is the case `witnessFor` already keeps a full-duration record for.)
   Second, **does "once it runs" read false during a normal fight?** It is `Moving` and `Fleeing`
   together because `Fleeing` alone is only "facing away from me", which is where a caster stands.
   Park a caster behind a tanked mob with a root slot on that timing and nothing should be cast for
   the whole fight; then let the mob run and it should go out on the first pass. The false positive
   to watch for is a mob crossing the camp at somebody behind us. Also worth one look: a root slot
   on *once it is hurt* at 20 while `stop below %` sits at its default 5 — the window is 20 down to
   5, and a mob that runs at 4% is one this state deliberately says nothing about.

23. **A debuff spread across the fight, in game** (2026-07-30, `dps_spread`). The rotation half of
   this is settled in a harness -- the slot walks mob, mob, mob and only then lets the nuke under
   it through, passes over what it cannot cast at, and asks each mob its own timing question. What
   a harness cannot answer is the roster it walks. **Does the extended target window list an add
   before we have touched it?** `Auto Hater` fills with what has *us* on its hate list, so a caster
   who has cast nothing at the second mob may not see it at all -- in which case the spread reaches
   it only once it takes a swing at us or somebody calls a `defend` on it, and the honest fix would
   be at the roster in Combat rather than at the state. Pull three, watch a slow slot, and count
   how many get slowed and how long the third takes. Second, **does borrowing the target hurt?**
   Each spread cast targets its mob and leaves the client there; a hybrid meleeing at the same time
   should be re-acquiring the kill target on its next pass, and the thing to watch for is auto
   attack chewing on an add for a beat, or the group's assist reading being confused by what we are
   looking at. Third, **the record**: a spread mob is remembered for the spell's full duration
   rather than the usual two seconds, because we stop looking at it -- so a slow that gets dispelled
   or a snare that breaks early is not noticed until the record runs out, and the cost of getting
   that wrong the other way (trusting `CachedBuff` for a mob we are not targeted on) is the debuff
   going out again every pass. One full duration on a mob left alive is enough to tell which way it
   fails. Also worth one look: a `defend`-reported mob across the camp -- the range and sight check
   should quietly skip it rather than the slot stalling on it.

24. **Mez, in game** (2026-07-30, `states/mezState.lua` + `mobs.lua`). Thirty-five headless checks
   settle the decisions; four readings of the *world* are what they rest on, and every one of them
   is a client question a harness cannot answer.

   First, and it is the one the whole state stands on: **does `Spawn[id].CachedBuff[^mezzed]` fill
   in for an NPC on this client, and does it report a duration?** The MQ source says it is the same
   `SPA_ENTHRALL` search behind `Target.Mezzed`, answered off the buff cache the client fills when
   something is targeted — and we target a mob to mez it, so it should be populated the moment the
   cast lands. If it comes back empty for NPCs, every mez reads as loose the instant the two-second
   just-landed window passes and the symptom is a chanter casting the same mez at the same mob
   forever. Mez one add, then watch `/cmez` for a full mez duration: the row should count down. (If
   it *is* empty, the fix is at the record — the mob is then no more readable than a group-mate, and
   the answer is a full-duration witness the way the spread debuffs keep one, at the cost of not
   noticing a break at all. This is the same question `dps_spread` asks in item 23 and one look
   answers both.)

   Second, **the break signals**, which are the reason this is a state and not a loop. Three of
   them, and the one to test hardest is the **movement read**: `mobs.lua` samples each mob's
   position and heading every 250 ms and the state asks whether it moved *after* the mez we landed.
   The thing to confirm is the premise — **is a mezzed mob perfectly still on this server, heading
   included?** If a mezzed mob drifts, or its heading jitters by more than half a degree between
   samples, every mez reads as broken immediately and the symptom is continuous re-mezzing. Mez one
   add and watch its row in `/cmez` for a full minute: it should stay *mezzed*, never flicking to
   *it has moved since we mezzed it*. (`macros/bots/enchanterBot.mac` compares the same pair with no
   epsilon at all, so this should hold; ours allows 0.01 units and 0.5 degrees.)

   Then the **awakened line**, `#1# has been awakened by #2#.` — eqstr 9037 on this client, so the
   wording should be right, but it has never been registered before. Break a mez deliberately (melee
   an add) and `/cmez` should flip that row to *loose — it woke up*. **The case worth setting up
   deliberately is two mobs of the same name mezzed at once**, since that is what the line cannot
   disambiguate: break one and the rows should briefly read *something called this woke — working
   out which*, then resolve to the right mob once it moves, with the other going back to *mezzed*.
   The failure to watch for is both staying loose (nothing resolving, so the movement sample is not
   registering) or the wrong one resolving.

   Third, the **passive animation list**, carried over from `macros/bots/mez.mac`. Note the two
   public macros disagree here — `enchanterBot.mac` has its equivalent commented out — so this is
   the signal most likely to be wrong, and it fails in the *noisy* direction (a mezzed mob whose
   animation is not on the list reads loose and is re-mezzed forever). If re-mezzing turns out to be
   constant while the movement read says the mob is still, this list is the thing to widen or drop.

   Third, **does the resist line arrive in time to be heard?** The tash half of this rests entirely
   on it: the casting service reports a mez a success when the bar closes and refines it to
   `resisted` when the line turns up, and this state waits exactly one pass for that refinement.
   One pass is what the service's own contract prescribes and the line should be in the same packet
   burst as the cast ending — but if it lands later, the resist is never recorded, the softener
   never fires, and the symptom is a mob being mezzed over and over with a tash sitting unused in
   the list. Find something that resists (or set a softener to *before every mez* to prove that half
   works independently) and watch `/cmez` for *it resisted a mez* on the row.

   Fourth, **the roster's sweep**. `playerstate 4|8` should return NPCs in combat stance and nothing
   else — no merchants, no guards at a post, no wildlife. `/cmobs` is the whole test: pull two mobs
   with a group and every row should read as seen by more than one angle. The two ways it goes wrong
   are both visible there — a group member's pet or our own charmed pet appearing at all (the
   `Master.Type()` filter failing), and a mob across the camp fighting somebody else showing up as
   *in combat nearby* with nothing else beside it. The second is expected and is exactly what the AE
   safety switch is for; the first is a bug. Also confirm the sweep is not expensive: it is one
   `SpawnCount` and a `NearestSpawn` per hit every 250 ms, and `/cmobs` in a busy camp is where that
   would show.

   Finally the ordinary things: an AE mez should centre on the cluster rather than on the nearest
   mob, `stop below %` should leave a mob the group is killing alone (it reads backwards — *below*
   the line is left alone), and a mez should never be aimed at what `/cattack` says we are fighting.
   Worth one look as well: the enchanter is now four states deep above the buff band, so `/state`
   should show Mez, PetDps, SpellDps, Melee in that order.

25. **Easing off, in game** (2026-07-30, `Combat.ShouldEaseOff` + both dps states). Twenty-two
   headless checks settle the decision table and the resume; what a harness cannot answer is
   whether the client says *we are the one it is coming for* fast enough, and stops saying it fast
   enough, for this to feel like anything but a stutter. It rides `GetUnderAttackIds` — the
   extended target window's `Auto Hater` entries at 100% aggro, swept every 250 ms — which is the
   same read the `defend` report and the pet's peel already lean on, so a wrong answer here is a
   wrong answer in three places at once.

   The test is one fight with a real main tank named in the group window and a dps character (the
   melee half and the caster half are worth doing separately). Rip the mob deliberately and watch
   the Melee State page: *Current Action* should read **Easing off — I have it off the main tank**
   within a quarter second, the swing should stop, and `/cattack` should say the same thing beside
   the `easeoff` line. Then let the tank taunt it back: the swing should resume on the pass the
   aggro meter drops off 100, not a beat later and not only after the next mob. The failure to
   watch for is **flapping** — the meter sitting exactly at the boundary and the character
   alternating on and off every quarter second — which would show as auto attack toggling in the
   log. Nothing in the design smooths that (there is deliberately no hysteresis and no timer), so if
   it happens the fix is at the fact, not at either state.

   On the caster: the rotation should say *holding: easing off — …* on its page while the nukes
   stop, and a damage shield slot should still go up during the hold — that exemption is the one
   deliberate hole and it is worth seeing once. Also confirm the two silences: with the character
   holding the group's Main Tank role, nothing eases off ever; and with an add that the tank is *not*
   on beating on a caster, the rotation should keep killing it (the tank's target is visible only
   through its `assist` call, so this is also a test of that call arriving).

18. **Curing, in game**. The whole system rests on three client readings, and each has a cheap test.
   First the **affliction read**: stand in a poison or disease DoT and run `/ccure` — it should name
   the kind and the seconds left. This is the one that has already been wrong once (found in game
   2026-07-31): the scan was gated on `Me.TotalCounters`, which the client sums out of per-buff slot
   data that EQEmu never sends, so it read zero on a visibly afflicted character and no character
   ever asked for anything. The gate is gone and the filter is now `Spell.CounterType`, read out of
   the local spell file. What is left to confirm is the walk itself: "nothing on me" while visibly
   afflicted now means the bar read or the effect read, not a gate. Confirm the short-duration
   window is really covered, or that nothing curable ever lands there, by watching a debuff the
   client files as a song.

   Then the **ask**: a warrior with a two-minute DoT should put one `cure <type>` on bc, and one
   more every twenty seconds until it fades — not per tick, not per DoT. A thirty-second DoT should
   produce silence. `callcure off` should silence it entirely.

   Then the **answer**, and start with the setting: the shipped default is *Curing, out of
   combat*, and a DoT worth curing lands in a fight almost by definition — so the first honest
   experience of curing is a healer that hears every request, queues every one and casts nothing
   (found in game 2026-07-31, and it reads exactly like a broken feature). `/cheal` now names that
   gate and every other live one; `/ccure` on the healer names what it can cure at all and what is
   holding each queued request. Whether the default is the right one is still open — the argument
   for it is in `healStateConfig.lua` and it is not a bad argument, but nobody meets curing out of
   combat. With the setting on, a cleric hearing a call should cast the cure `/ccure` says it would
   (worth confirming the spell it names is the one you would have picked — "best of that kind" is
   the most counters). Watch the Heal State page's *Current Action* read `curing ...`. The one to watch closely is the **read-back**: the request should disappear
   from the Waiting list once the counters are actually off, and *not* before. If cures keep firing
   at somebody already clean, the cached-buff read is coming back stale and the fix is there.

   Then the **held queue**, which is where the wasted cures actually came from: stand the healer
   around a corner from somebody with a DoT so line of sight fails, and leave it. `/ccure` on the
   healer should show the request with `last try:` naming the client's refusal — a queue failing
   over and over must not look like one nobody has touched. Then let the DoT wear off *before*
   walking back into line of sight. The request should be gone, or held with `it is off them`, and
   no cure should go out when the corner is cleared. A burst of cures the moment line of sight
   returns is the failure this is guarding.

   Then the **staleness of the ask**: let
   a DoT run out on the asker without being cured (hold the healer in combat with curing set to out
   of combat, say). Once they stop calling, the healer's Waiting line should read `held: they have
   not asked in a while` within about thirty seconds, and *stay* held until the entry ages out —
   releasing the healer at that point must produce no cast at all. The failure it is guarding is a
   cure aimed at a DoT that had a minute left when it was called and seconds left when it landed,
   followed by another one after the DoT was gone.

   Finally the **ordering**, which is the part with a real cost if it is wrong: with curing set to
   *in battle too*, drop a group-mate below the emergency point while a cure is in the air — the
   cure should be called off on that pass and the heal go out. Then set it to *out of combat* and
   confirm a fight starting does the same. A healer that keeps curing while somebody dies is the
   failure this feature could plausibly introduce, and it is worth provoking once on purpose.

26. **Answering a defend call, in game** (2026-07-31, `answerdefend` + `defendReachDistance`). The
   report half has been in for a while; what changed is that picking one up is now its own switch
   rather than a corner of `autoengage`, and that a report out of reach is skipped instead of
   charged at. Three things to watch, all from the tank.

   First, **the switch**: turn `autoengage` **off** on the main tank, let an add jump the healer,
   and the tank should still go — that is the whole reason the switch was split out, and it is the
   case that used to do nothing at all. `/cattack` names both switches now, says whether this
   character is even the one that answers, and marks each standing report it cannot reach.

   Second, **the wait**, which is the one with a real cost if it is wrong: with the tank on a mob
   at 5% and a report standing, the tank must finish the mob it is on. Nothing should move until
   the corpse drops. The failure to watch for is the tank turning mid-fight — that is a hate list
   walked back to nothing and, in a mez camp, the tank running through the mezzed pile to get
   somewhere.

   Third, **the reach**: a mob called from across the camp or through a wall should be left
   standing (`/cattack` will say so) and picked up the pass the group closes on it — not a charge
   the moment the line lands, and not silence afterwards either. 100 is a guess borrowed from the
   melee engage distance; if a real camp is wider than that and the healer at the far end goes
   unanswered, the fix is to make `defendReachDistance` a setting rather than to raise the
   constant. Worth one look on the lenient line-of-sight read too: `LineOfSight` answering nothing
   counts as visible, so a report that will not resolve at all would show up as the tank charging
   something it cannot actually path to.

27. **Waiting for the kill to be named, in game** (2026-07-31, `namedKill` + `isUnfoughtPull` in
   `states/mezState.lua`). The symptom was an enchanter mezzing the mob on its way in: the roster
   sees an inbound pull from two angles at once (the puller's `defend` report, and the sweep's
   combat stance) long before anybody has picked it up, and to a crowd control state that looked
   exactly like a loose add. The fix is one idea in two rules — **an add is only an add beside
   something being killed** — so a *new* mob is chosen only once something has been named first to
   kill, and a fight of one mob nobody has engaged is the pull rather than an add. Sixteen headless
   checks settle the shape of it.

   What names the kill is `Combat.GetTankTargetId` — the tank being us, the tank's `assist` call, or
   the client's assist record — and **failing that, our own engagement**, which is the fallback that
   keeps the rule from being a silent off switch in a group that never dragged anybody onto the Main
   Tank role. The mob it names is itself never mezzed, which also closes an older hole: a chanter
   with auto-engage off had no `Combat.GetTargetId` of its own and would read the tank's mob as just
   another add.

   The thing a harness cannot answer is where the boundary falls in a real camp. Four to watch.
   **A single pull should arrive untouched** — `/cmez` reads *incoming* the whole way in and flips
   to *killing* when the tank has it. **A two-pull should be held until the tank picks one**, then
   the other mezzed on the very next pass: the wait is the point, and the thing to measure is
   whether "the next pass" is fast enough that the add is still mezzable when it arrives. If a
   two-pull regularly reaches the healer before the mez lands, the tank is naming its target too
   late and the fix is on the tank (`callassist`), not here. **The beat between two mobs of one
   fight must not stall a refresh**: with an add mezzed and the tank's mob dying, the kill is
   unnamed for a beat — the already-mezzed exemption is what covers it, and a mez that lapses right
   as a mob dies is that exemption failing. And **`/cmez` must always explain itself**: *first to
   kill* is on the page and in the command, and a row that reads *waiting* with a named kill above
   it is a bug.

   Left deliberately alone: the **stun** slot, which still fires at a lone inbound mob that has
   turned on this character. A stun does not stop a pull the way a mez does, and the mob beating on
   the enchanter is exactly what it is for. If a camp turns out to want the pull mezzed on purpose
   (a chain-mez pull, an enchanter doing its own pulling), the answer is a switch on the Mez page
   rather than loosening the rule.

28. **Two of a kind, in game** (2026-07-31, `suspicionSettleMs` in `states/mezState.lua`). The
   symptom was an enchanter re-mezzing a mob that was still perfectly mezzed, in a camp holding two
   mobs of the same name. The cause is the one thing the awakened line cannot say: it carries a
   *name*, not an id, so a break in a camp of two identical mobs suspected both — and the old
   answer was to call both loose. That is a coin toss, and losing it spends the mez, the gem timer
   and three seconds of casting on the mob that was already held, while the one that actually woke
   stands free for exactly those three seconds. Now the suspects are *watched* for a beat: the mob
   that turns or steps is the one that woke (`cabby.mobs` samples position and heading four times a
   second, and the animation read catches it too), and nothing is thrown away about the others
   meanwhile — including the trust in a mez of ours that landed a beat ago, which the handler used
   to drop for every mob of the name and which was the second way the same mob got mezzed twice.
   Four headless checks drive the real chat handler; two of them fail against the old code.

   What to watch, and it is one deliberate setup: **hold two mobs of the same name, break one, and
   watch `/cmez`.** The held one should stay *mezzed* with `-- watching: one of these woke` against
   it, the broken one should flip to *loose — it woke up* within a beat, and exactly one mez should
   go out, at the broken one. Two casts is the bug returning.

   The number to question is `suspicionSettleMs` (1 second, four pose samples). Too short and the
   old coin toss is back, because the freed mob has not been seen to move yet. Too long and a real
   break waits on it — though only when the mob is out of sight, since an animation that is not
   *standing there* settles it on the same frame. If a camp on this server shows mezzed mobs whose
   heading jitters, this window is where it will show up first, as an innocent twin being resolved
   as the waker; the fix would be in `movedEpsilon`/`turnedEpsilonDegrees` in `mobs.lua`, not here.

29. **Letting go of a mob, in game** (2026-07-31, `Combat.CallOff` in `combat.lua`). The symptom was
   a main tank that could not be told to let go of a mob at all: the Back Off button, `attack off`
   and `/cattack off` each disengaged for a fraction of a second, and the next pulse put the tank
   straight back on the same target. The cause is that a call-off had no memory while every
   automatic way of picking a fight up does — a standing `defend` report sits above the `autoengage`
   gate and re-engages the same mob within 250 ms (so turning auto-engage off was no answer either),
   the hater sweep picks up whatever is beating on us, and the client's attack toggle left on from
   that same fight reads as a hand-started one. The strongest source, an order, was the only one
   with nothing behind it, so it lost. Downstream that is a tank that cannot move: `MeleeState`
   reports busy for as long as `IsEngaged`, so at the dps band it starves follow, anchor, loot and
   rest, and only `flee` outranks it. Now a deliberate end records the mob as refused and every
   automatic path steps over it; twenty-four headless checks cover the shape, including the leftover
   toggle and each of the four ways a refusal is taken back.

   First, **the thing that was broken**: with a `defend` report standing on a mob the tank is on,
   press Back Off. The tank should stop, drop the swing, and *stay* stopped — and then follow, sit,
   or take a new `attack <id>` like any other idle character. `/cattack` lists what is called off
   and says what takes it back, which is the page to check first if a tank looks idle next to
   something that is eating the group.

   Second, **taking it back**, which is the half with a real cost if it is wrong — a mob nothing
   will ever pick up again is a mob nobody is tanking. Four ways, worth one pass each: kill it (or
   let it despawn), zone, `flee on`, and naming it again with `attack <id>`, an `assist` call, the
   Attack button, or a press of the attack key. That last one is the subtle one: a *press* is a
   person naming the mob, while the toggle merely still being on from the fight that was just
   called off is not, and the difference is what keeps Back Off from being undone by the character's
   own leftover swing.

   Third, **the group**, since `assist off` from the tank now calls the listeners off for keeps
   rather than for a pulse. Back the tank off mid-fight with adds out and watch what the group does
   next: a wizard that had picked up its own add should keep fighting it (the refusal is about the
   tank's mob), but a character the tank had called onto that mob will stand down and stay down
   until the next `assist` call names something. If that reads as too much on a real pull, the
   narrower rule is to refuse only the mob the *listener* was on by its own decision, and leave a
   heard `assist off` a plain disengage.

30. **Looting our own corpse, in game** (2026-07-31, `states/corpseState.lua`). **First contact the
   same day: it loots.** Sixty-three headless checks cover the decisions — the order's life, the
   three evidence windows, the corpse taken over, the stale corpse pointer, the cursor, two corpses
   in one order, zoning and dying mid-order — and the ordinary path has now been seen working on a
   real client. What is left below is the edges nobody has stood in yet.

   The first run looked like a dead state and was not one: **`flee` was on**. It suppresses by
   returning busy at the passive band, which starves every band under it, and looting is near the
   bottom — so the order was taken and then never given a frame. That is the design working, but it
   is invisible from the outside, which is why `/ccorpse` now says how long ago the state last had a
   pass and warns when it has never had one. Worth remembering as the first thing to check whenever
   a character takes an order and then does nothing at all: it is not specific to looting, and the
   state chain has no central "who is holding the frame" report yet.

   Still to see, in rough order of "if this is wrong, it matters":

   - **Finding it** — *works*, with `corpse radius 50 <name>`. Written with `pccorpse` first, which
     is the obvious filter and a trap: MacroQuest tells a PC corpse from an NPC one by whether the
     spawn carries a **deity**, and an emu server need not send one — the search then comes back
     empty and looks exactly like having no corpse. `/ccorpse` lists every corpse in reach and says
     which it reads as ours, so it answers this on its own without dying for it.
   - **Opening it** — *works*: `/click right target` on our own corpse brings the window up, and
     `${Corpse}` names it. This was the assumption with no fallback; it held.
   - **The reach** — *answered by pulling the corpse instead of measuring it* (2026-07-31). 50 is
     the search *radius* and not the client's loot range, and rather than hunt for the real number,
     each corpse is now targeted and pulled to our feet with `/corpse` before it is opened, so the
     open is always a click on something standing on top of us. The server takes that pull out to
     100 (`Corpse::Summon` in `zone/corpse.cpp`, distance-squared against 10000, moving the corpse
     with `GMMove` and keeping its spawn id), which is twice the search radius — so nothing this
     state can see is beyond the pull, and there is no answer to watch for. What is still unseen is
     a *refused* pull, which on our own corpse means a GM lock and nothing else; it reads as an open
     that never produced a window, and is reported as "could not open".
   - **Emptying it** — the ordinary items come off. What has not been seen is a corpse full of our
     own **NO TRADE** gear, which is the case this exists for: does the client pop a confirmation
     for any of them (nothing here answers one — it would read as an item that will not come off,
     and be left and reported)? Worth one run with bags nearly full as well, so the "left N I could
     not pick up" path is seen for real rather than in a harness.
   - **Closing it** — the window goes. What is unconfirmed is what an *emptied* player corpse does
     next: if it poofs, that is what ends the order; if it lingers, confirm the order still ends
     (it should — a corpse this order has finished with is never looked at again — but that is the
     one place a lingering corpse could otherwise loop).
   - **The band.** Die with the group, run back, and say `lootcorpse` to the channel while the group
     is still following somebody: every character should stop where it is, loot, and only then carry
     on following — and if something aggros mid-loot, the fighting bands should take the frame back
     off it.
   - **`${Corpse}` after a loot ends.** It is the client's active-corpse pointer, and the state now
     asks whether `LootWnd` is *shown* before believing it, because a stale pointer would park an
     order behind a window that is not there. Worth confirming which way this client behaves: loot
     something, close the window, and read `${Corpse.Open}` — if it still says TRUE, that is the
     reading the window check exists for, and anything else in the codebase trusting `${Corpse}` on
     its own needs the same treatment.

31. **Consenting on death, in game** (2026-08-01, `consent.lua`). Twenty-one headless checks cover
   the scheduling — the death edge, the pacing across deaths, the ties skipped, the hold through a
   zone, the switch turned off mid-run — and none of them touch EverQuest. What the harness cannot
   answer is whether the client will send the command at all from where this says it.

   - **`/consent` while dead.** The whole design turns on the first DEAD/HOVER frame being a frame
     the command works from — the corpse exists by then (it is made in the same server tick as the
     death packet), and `OP_Consent` is a connected opcode, so nothing in the server says no. What
     is unseen is the *client* side: whether it will process a slash command typed into the death
     screen. Die grouped, watch the console for the "Consenting group, ..." line, and then have a
     group member target the corpse and `/corpse` it. If the drag is refused, the fix is to hold
     the run until the respawn instead of starting at the death — the corpse keeps its consent
     either way, provided the zone it is in still has somebody in it.
   - **The two-second throttle.** Paced at 2500ms on the strength of `consent_throttle_timer` in
     `Client::ConsentCorpses`. The refusal is a red "You must wait 2 seconds between consents." and
     nothing else, so seeing that line in the log after a death is the one sign the pacing is
     wrong — and it is worth one deliberate look, since a consent lost this way is silent.
   - **Releasing mid-run.** Group and raid consent have to find the corpse in a *loaded* zone. Die,
     release immediately, and confirm the second and third consents still land: the run holds
     through the loading screen and resumes on the far side, but the death zone emptying out is the
     case nothing here can do anything about. If it turns out to matter, the answer is to fire all
     three before the release rather than to chase the corpse.
   - **The alternative that may make this unnecessary.** The client has its own Auto Consent
     Group/Raid/Guild checkboxes (`OGP_AutoConsent*Checkbox` in EQUI_OptionsWindow), and they are
     not merely client-side: they set `groupAutoconsent` and friends in the player profile, and
     every corpse made afterwards is consented at creation (`corpse.cpp`), with no throttle and no
     race. Ticking those three once per character would do this job better and permanently. Nothing
     but the checkbox appears to reach them (`/consent group` sends `OP_Consent`, not the
     `SpawnAppearance` those use), so it would mean a `/notify` on the options window at startup —
     which is fighting the player over their own client settings. Worth knowing before this grows.
