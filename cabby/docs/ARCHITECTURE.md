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
       ├─ CabbyGiving.Init   — registers the giving service + /cgive
       ├─ Character.Init     — registers the discovery service + /crefresh
       ├─ Roles.Init         — registers /croles (who holds which job in the group)
       ├─ Combat.Init        — registers the engagement service, /cattack + the attack order
       ├─ ClassSetup         — this character's class module assembles + registers its states
       ├─ HotbarsUI.Init()   — ImGui shell for the hotbar windows
       └─ Menu.Init()        — ImGui shell (must be last)
  └─ "Online"                — announced on the default speak channels: setup is done, orders can
                               be taken. Silent when no speak channels are configured
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
requesting state to get another turn. Nine exist: **Movement**, which has to release its keys
on the frame its task ends rather than whenever FollowState next runs; **Casting**, whose whole
point is that the caster is starving everything below it while the cast runs, so the cast has to
progress without a turn of its own; **CommandQueue** (`commandQueue.lua`), which runs command
lines pushed to it by callers that must not run commands themselves — every ImGui callback,
hotbar buttons above all; **Character** (`character.lua`), which watches for the character
gaining a level, an AA or a bag of clickies and re-reads what it can do; **Combat**
(`combat.lua`), which holds what we are fighting for the several states that fight it; **Mobs**
(`mobs.lua`), which holds what is *in* the fight — a wider question than Combat's and one several
jobs need the same answer to, assembled from four angles including a sweep that has to be paced;
**Giving** (`utils/Giving`, wired by `giving.lua`), which walks the four commands and three
waits that put an item in somebody else's hands, because a state that walked them itself would
leave a give window standing open with an item in it the first time a fight took the frame away;
**Curing** (`curing.lua`), which holds what is on *this* character that a cure would take off and
who has said so, for the healer that does the casting; **Consent** (`consent.lua`), which
watches for this character's own death and consents the group, raid and guild to drag the corpse,
because everything it does happens in the seconds while no state is going to be given a frame for
it and the player is looking at a respawn window; **Rez** (`rez.lua`), the other half of that
window, which takes the resurrection somebody offers -- the client's confirmation box, or the
`Resurrect` line on the respawn window we are still hovering at; and **Rezzing** (`rezzing.lua`),
the opposite end of that same event, which holds whose corpses are worth a rez and which rez to
spend on them, for the healer that does the casting.

This is a **priority-chain cooperative scheduler**: state order = priority; `Go()` returning
`false` yields to lower states. The priority bands live in `classes/priorities.lua`:

| Priority | State | Priority | State |
|---|---|---|---|
| 1 | My commands / Task / DZ | 69 | Tank / grab aggro |
| 19 | Flee (travel mode) / passive | 79 | DPS (melee/spells) |
| 29 | Cure *(reserved, see below)* | 89 | Looting |
| 39 | Heal | 99 | Anchor |
| 49 | Pulling | 109 | Following |
| 59 | Mez (in combat) | 119/129 | Buff / Rest (misc) |

**The cure band is reserved and nothing registers at it.** Curing landed inside the heal state
instead (see Curing below): a cure and a heal are the same character choosing what to cast with one
set of gems, and the choice is made in one place rather than by two states taking the frame off each
other. The band stays in `priorities.lua` because a cure state that acted *without* a healer to
arbitrate against — a bard, a dedicated curebot — would belong there, and moving the job would then
be a registration rather than a rewrite.

A bigger number is weaker. The gaps of ten are room for "the same job, but not as strongly":
`Priorities.heal + 5` is a hybrid healing below the class that heals for a living — and a pet
class keeping its own pet up, which is healing that must beat the nukes without pretending to be
the group's. Classes name a band per state rather than ordering their `Register` calls by hand —
see below.

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
  standing, which one it is went back to being something to read. It follows that ending one ends
  both: `stopfollow` drops the anchor as well, since a character told to stop while parked on one
  has no second order left to be carrying out, and walking back to the spot reads as the order
  having been ignored. Keep *all* of the order, too:
  an anchor is a spot and the zone that spot is in, and the zone was missing until a wipe put a
  camp full of characters at their bind points still holding the old zone's coordinates and
  running at them (2026-07). Coordinates only name a place inside one zone, so leaving the zone
  ends the anchor — a death, a gate and a port are one case — which is the conclusion the follow
  already reached about a remembered sighting from another zone.
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
  mobs.lua            service: what is *in* the fight -- the engagement, the extended target
                      window, the group's defend reports and a sweep for anything in combat
                      stance nearby, merged into one roster that records which angle saw what
  curing.lua          service: what is on *this* character that a cure would take off, said out
                      loud for whoever can answer, plus the queue of everyone who has said it.
                      Every class -- the character standing in a DoT is the only one who can see
                      it and usually the one with nothing to cure it with; HealState does the
                      casting
  consent.lua         service: the consents this character's own death owes -- group, raid and
                      guild, so the people it is already with may drag the corpse it just left.
                      Watches for the death itself and paces the commands past the server's
                      one-every-two-seconds throttle; no order, no frames
  rez.lua             service: taking the resurrection somebody offers -- Yes to the client's rez
                      box on our feet, the Resurrect line on the respawn window while hovering.
                      Reads every confirmation box before answering it (a sacrifice says
                      "Resurrection" while it asks to kill us), and never picks at the respawn
                      window without the client having said a rez is waiting
  rezzing.lua         reader: the giving end of the same event -- whose corpses are lying here
                      worth a rez (group members, ordered by the tank switch and the class list,
                      narrowed in a fight to whoever that list says is worth breaking off for, plus
                      whoever asked), which rez to spend on them, and which corpses have already
                      been offered one. HealState does the casting, because a rez is a gem not
                      spent on a heal; no frames
  cons.lua            reader: the con ladder, weakest to toughest, and whether a spawn is at least
                      a given rung of it. How much of a fight something is, in the one measure the
                      client gives -- so that "not worth the effort" is spelled one way across
                      every list that comes to want it
  roles.lua           reader: main tank / main assist, out of the group and raid windows
  travel.lua          the traveling core: follow/anchor orders, trail-follow, and following
                      through zone lines -- clicking a switch, or walking through after a target
                      that vanished mid-stride where there is none; driven by FollowState
                      (follow band) or FleeState (passive band), whichever the chain gives the
                      frame to
  stateMachine.lua    priority-chain loop + per-frame services + priority gates (instance class)
  movement.lua        wiring only: registers the movement service and /cmove
  casting.lua         wiring only: casting service, its priority gate, movement arbiter, /ccast
  giving.lua          wiring only: registers the giving service and /cgive
  commandQueue.lua    service: runs command lines pushed from ImGui callbacks, a frame later
  character.lua       capability snapshot: which skills exist (primary/secondary/melee lists)
  status.lua          shared predicates (IsFacingTarget)
  pet.lua             what the client will say about this character's pet, and the words it takes
                      back (`/pet attack <id>`, back off, the four toggles); also what *kind* of
                      pet it is (summoned, an enchanter's animation, or charmed) and which of
                      those words it is listening for; no frames
  states/             baseState, fleeState, followState, mezState, meleeState, spellDpsState,
                      petDpsState, healState, buffState, petSetupState, advLootState, corpseState,
                      restState
  classes/            priorities (the bands), baseClass (assembly), classes (the registry),
                      and one profile per EQ class
  commands/           the chat-command bus (see below), incl. the toggle/action command factories
  configs/            per-domain config modules (see below)
  actions/            ActionType interface + implementations + registries, plus buffTypes: the
                      named buffs (`invis`, `lev`, `sow`, ...) a `buff <type>` request is answered
                      from, each defined by the SPA effects its spells carry; cureTypes, the
                      four counters (poison, disease, curse, corruption) that say both what is on
                      somebody and what would take it off, told apart by the sign of one base
                      value; and rezzes, every corpse-aimed cast carrying SPA_RESURRECT, ordered by
                      the experience its base value hands back
  ui/                 ImGui menu shell + per-domain panels (states/, actions/, hotbars)
  utils/ (sibling)    Movement/, Casting/ and Giving/ (see below), Time/Timer/StopWatch, Config,
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
adjustment that does not exist yet. **HealState is also how a pet class keeps its pet up**, so MAG,
NEC and SHD register it at the same `heal + 5` — pet heals are heals, and the heal state already
had the aim model, the settle window and the reconsidering; a second state for them would be the
same state with a smaller list. It is not a claim that a magician heals the group: what those slots
hold is pet heals (the Renewal, Mending and Companion lines) and the empathy line a necromancer or
a shadow knight spends its own health on, and the band puts them above the nukes for the same
reason a paladin's heal is above its swing. A shadow knight has no *pet* heal — that line is
MAG/NEC/BST — and an enchanter has no heal at all, which is why ENC is the one pet class left out:
a page with nothing to put on it is not a capability. The twelve classes with a spellbook register **BuffState** at
the buff band; the four with none (WAR, MNK, ROG, BER) do not, since a buff list holding nothing
but clickies is not enough of a job to be a state. **PetSetupState** goes to the six classes that
keep a pet as a companion — MAG, NEC, BST, ENC, SHD and SHM — at `Priorities.buff - 1`, one band
above buffing so that a pet is here, and holding what it is owed, before any mana goes on buffing
one; a pet buff cast on a pet about to be replaced is a wasted gem timer. Those same six register
**PetDpsState** at `Priorities.dps - 2`, because a pet is two jobs in two bands: keeping one is
work done between fights, and using one is work done in a fight and above the rotation that would
starve it. ENC is in both and out of
the heal list for the same reason each way round: it has a pet to summon and no heal to give it.
Three classes with pet spells are left out — a cleric's hammer, a wizard's sword and the druid's
behest — and the line is what the pet is *for* rather than what the spell is: those are cast into a
fight for the fight, which is a rotation slot, and the setup state does its work between fights by
default. Any of them is one profile line away from having the page. Everything
narrower than "can this class do this at all" — does it have bash, does it have taunt discs —
stays where it already is, in `character.lua` and the action registries.

**MezState is the first state registered at a band above dps that is not about damage at all**, and
only the enchanter has it so far (`Priorities.mez`). It is a class judgment of exactly the kind this
file makes: the state reads its whole list off the spellbook, so registering it costs a class with
no mez nothing but a page it would never fill in — and the two other classes that genuinely mez are
each one profile line away. The bard is deliberately not that line yet: a bard's mez is a song sung
on the move with no cast bar and an instant refresh, which is a different shape of the same job and
wants its own verification rather than an assumption. The necromancer's undead mez is the smaller
gap of the two.

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
`buffpets` and `buffcombat`; MezState registers `mezzing` and the Mobs service registers
`mobsweep`. Switches that have to call off work in progress
rather than only stopping new work go through the *state* rather than the config, so the
checkboxes get the same behavior: `melee off` resets the state, `stick off` releases the stick
Movement is still holding, `healing off` interrupts the heal in the air, and `resting off` stands
the character up (through the command queue, since a checkbox calls the same setter).
RestState registers `resting` and `restcombat`.

**Action lists are commands too** (`commands/actionCommand.lua`). Any state with configured action
slots gets `<phrase> <on | off | toggle> <part of an action's name>` from the same factory —
`action` for the melee lists, `healaction` for the heal list, `nukeaction`, `buffaction` and
`mezaction` for theirs. Exact name wins; failing that every
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
- **Rooted holds a stick without ending it.** A root is the world refusing the run, not a reason
  to give the task up or to lean on the keys against it: `Stick` releases every key, keeps facing
  the target (turning is the one thing a root leaves), and reports `blocked` until the root fades
  — the pulse after it does is the one that runs. Follow and MoveTo still hold their keys through
  a root; their stuck detectors just ignore the rooted stretch, so no unsticker flails.
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
  to `distance` (13 for `followme`/`followtarget`, about melee range: close enough to feel like a
  group) and then holds until the target is `resumeDistance` away (23), rather than re-closing the moment
  they take a step. The two are tuned together — what matters is the room between them, so moving
  one without the other either parks the group on the leader or thins the buffer to nothing. One threshold
  makes a follower a shadow, matching the target's every move to the inch, which is what being
  followed by a bot looked like before. The hysteresis is one bit of task state, so *which*
  threshold applies is only knowable from the task: `Follow:WithinHold` and `IsParked` are the
  readings, and FollowState asks `Movement.IsParked()` rather than measuring the distance itself.
  Nothing else inherits this — `m2m` is a `MoveTo` and still arrives exactly, and `Stick` holds
  its engage range for melee, where a buffer would be a swing missed.
- **How much room a follow keeps is a setting, and a fight moves it.** The pair above is what
  `TravelConfig` hands `travel.lua`: **Follow distance** (13) is what a quiet group holds, and the
  buffer is derived from it at three quarters again (so 13 → 22.75, and a distance moved to 40
  takes its buffer with it) — one knob, because moving one of the two alone is the mistake the
  bullet above describes. Beside it is **Give the fight room** and a **Fighting distance** (40),
  which is the same pair re-derived: while `Combat.IsGroupFighting` is true the follow holds out
  there instead, and `travel.lua` pushes the change into the follow already running
  (`Movement.SetFollowHold` → `Follow:SetHold`) rather than restarting it, because a fresh task
  starts with no trail and a straight line through whatever is between us. The trail, the task id
  and the hysteresis all survive the retune — which threshold is in force is about what we were
  doing a moment ago, and that did not change because the numbers did. Two things it buys: a caster
  is not parked in the melee ring for every ae and rampage, and a follower that is standing still is
  a follow band that is *not busy*, so buffing and resting (below follow in the chain) get frames
  for as long as the fight walks around. It can only ever reach a character with nothing to do in
  the fight — anything with a job in it is busy at a band above follow and never drives the travel
  core at all — which is why it is on by default. A run is not a fight: `Status.IsFleeing` holds the
  base distance whatever the setting says, since the follower that spread out on the way to the zone
  line is the one that did not make it. The Follow State page shows the distance **in force**
  alongside the two settings, which is how the relax is seen doing anything.
- **Parking stops the walking, not the recording.** The target's route while we sit is precisely the
  part that is *not* history yet, so a parked follow keeps banking it and walks it when they move
  off. All that being parked retires is a warp seam — standing with them is proof that a jump in
  their past is behind us, and nothing else in the task can clear one. Retiring the whole trail on
  every parked pulse is what this used to do, and it meant a group that keeps catching up (a leader
  on foot, boxes at the same speed or better) had nothing left to steer at on unpark but wherever
  the leader had already got to: a blind straight line of up to `resumeDistance` through whatever
  was in between, which is a wall at every corner the leader walked around (2026-07 — it was the
  single largest source of followers stuck on corners, ahead of the reached-radius above).
- **The trail is the route, and the route is walked exactly** (2026-07, replacing beeline-on-sight
  at the user's direction — the `/afollow` model from MQ2AdvPath). `Follow` samples where the
  target has been into breadcrumbs and replays them corner for corner whether or not the target is
  visible, because line of sight is not walkability: a leader visible below a ledge, across a
  chasm railing or down a switchback is one confident straight line away over a drop. The route
  they walked is the one route known walkable, so it is the only thing we steer at; the spawn's
  own position is used for arrival (the hold buffer above ends the replay wherever the trail
  happens to be) and as the destination once the trail runs out, nothing else. What keeps the
  replay from being the drunk walk that beelining was invented to avoid: every pulse the trail is
  dropped through the furthest breadcrumb we are *standing on*, wherever in the trail it is — so it
  drains as it is walked, and a stale head reconnects the moment the target comes back to us or
  their route crosses ours; a route that comes back to itself has the loop cut out of it, so a
  target circling a parked follower stockpiles about one lap and never more (`PruneLoop`, which can
  only ever leave a stretch the target actually walked — the join it makes is a breadcrumb wide, so
  unlike a retire it cannot invent a shortcut); a backward jog recorded off a rubber-banding
  target is skipped by arc (MQ2AdvPath's ClearLag); and the head breadcrumb also counts as reached
  once it is *behind* us, within the ground one pulse of running covers, so background frame rates
  do not orbit a waypoint they stepped over (the `leadPulses` actuation-lag reasoning applied to
  waypoints). That overshoot test used to be a radius widened by per-pulse travel instead, and at
  background frame rates it reached tens of units: the breadcrumb sitting on a corner was retired
  while the follower was still short of it, the aim moved to the breadcrumb around the corner, and
  the follower drove into the wall between them — which is what "my followers keep getting stuck on
  corners" turned out to be (2026-07). Distance was never the question; a waypoint dead ahead is not
  reached however close it is. Breadcrumb spacing came down to 3 in the same pass, and the radius
  that counts as standing on one is **scaled to the ground covered in a pulse** — 0.75 of it, floored
  at 3 for a standstill — because a fixed radius means one thing to a walker and another to a
  Sow'd bard, and per-pulse travel is the honest measure of which (it has the frame rate, the lag
  and the wall you are pressed against already folded in, which `Me.Speed` does not). Both edges of
  the scale are failure modes and the swept optimum sits between them: above 1.0 the radius reaches
  the far side of a corner apex and clips it (1.5 is the wedging reach again), below 0.5 the pop
  scan cannot keep up with the ground covered, so breadcrumbs are stepped over unretired and the
  follower ends up steering at ones it passed long ago. A jump in
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
  ReagentNames.lua  what the items spells ask for are called (generated)
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
- **The bar closing is not the answer, only the question.** A cast bar goes down the same way
  whether the spell went off or the cast was lost, and a fizzle is decided at the *server's* end of
  the cast — half a ping behind the bar our own client has already finished drawing, with the line
  saying so spending the other half getting back. Finishing on the spot therefore reports every
  fizzle as a landed spell, which is the one mistake a buff cannot survive: the caller believes it
  is on somebody and stops asking for the next half hour. So a completed cast waits a round trip to
  be contradicted (`CastTask.ConfirmLanded`) before it is called a success. An evidence window, not
  a give-up timer — running out *is* the answer — and nothing is held hostage by it: the character
  may move throughout, since there is no bar left to lose, and the wait is shorter than the spell
  recovery that follows every cast anyway. Calling the cast off during it is ignored for the same
  reason there is nothing to interrupt: the mana is spent either way, and cutting the wait short
  would only throw away the answer.
- **Resists arrive late too, and mean the opposite.** "Your target resisted" is not a reason the
  cast ended — it is what the spell did once it landed, so hearing one is proof the cast completed.
  Arriving inside the window above it settles the cast as the success it is, carrying the resist as
  its outcome; arriving after, it refines the recorded result for a couple of seconds. Which is why
  a caller that cares about resists reads `GetResult` on the frame *after* it first goes terminal.
  A *broken* line that outruns the window gets the same treatment in reverse, flipping the recorded
  success to the failure it really was, so nothing that says a cast was lost is ever simply
  dropped.
- **A behavior level with the cast still has to be asked.** The floor starves everything
  *weaker*, but the state that asked — a melee rotation firing a spell out of its own action
  list — keeps its turn, and re-sticking to the mob is exactly what loses the cast it just
  requested. `Casting.IsHoldingStill(priority)` is the question anything that moves the
  character asks first; MeleeState's stick goes through it. A cast weaker than the asker does
  not hold it back, because a buff that cannot be cast while the group is running is a buff that
  fails and says so, not a reason to stop following.
- **A missing component is named, not numbered.** A cast whose expendable reagents are not in the
  bags is refused before anything is spent, which matches what the server does with them (bank
  copies do not count there either). Saying *which* item is harder than it sounds: a component is
  an id in the spell data, and nothing in the client maps an id to a name on its own — `FindItem`
  answers only for what we are carrying and `FindItemBank` only for what is in the bank, so the one
  moment the name is needed is the one moment the client cannot supply it. Both are still asked
  first, since between them they also say *where* the item is; behind them sits `ReagentNames`, a
  generated id → name table covering every component id in the client's own spell file, and an id
  is the last resort. "missing item 10015" is a puzzle; "missing Malachite" is a trip to a vendor.
- **A fear refuses a spell rather than waiting it out.** While `Me.Feared` the character runs where
  the server points them, so the stillness a cast bar needs is never coming — and a cast already
  waiting to settle would wait out the whole fear with its caller's priority floor up, over a cast
  that was never going to happen. `CastTask` asks at each of the three points a fear can reach a
  cast (validate, hold-still, fire) rather than once, because the seconds spent targeting and
  memorizing are exactly when it lands; `CastAction:IsReady` says the same up front, so a rotation
  stops asking instead of burning a refused cast every frame. Items and AAs are not gated, as they
  are not for a silence: an instant clicky or AA has no bar to lose, and one of them may be the way
  out of the fear. Melee skills answer the same question for themselves, in `Skill:IsReady`.
- **It never retries.** A fizzle or an interrupt is reported and the caller decides whether
  casting again is still the right thing to do; by then the mob may be dead or the heal no longer
  needed. MQ2Cast loops internally because a macro has nowhere else to put that decision. A state
  machine does.
- Preparation runs as far as it can in one frame (the steps chain until one has to wait on the
  client), so a character standing still with the spell memorized casts on the frame it was asked
  to.
- **A spell that is not memorized gets memorized, into an empty gem where there is one.** Which
  gem is decided at the moment of memorizing rather than when the cast was asked for, because
  seconds pass in between — targeting, standing still — and the bar is the player's to change in
  them. The order is: the gem the caller named (`/ccast … gem4` means gem 4, whatever is in it),
  then any empty gem, then the configured one. Preferring an empty gem is not a nicety: the whole
  cost of memorizing is what it replaces, and it is what makes the behaviour settle — each spell a
  rotation is short of claims an empty gem once and stays there, where a single fixed gem would
  have two unmemorized slots casting over each other for the whole fight. Once the bar is genuinely
  full that is what happens, and the configured gem is the user's say in which one pays for it.
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

  Three things that look like give-ups are not: `notReady` after a short grace is the answer to
  "the gem is on cooldown", which is a real no rather than a not-yet; `feared` above is the answer
  to a wait that cannot end in a cast; and the in-flight timeouts below are faults rather than
  waits.
- What *is* bounded is everything after the command goes out, because those are faults rather than
  waits: a cast that never appears on the client is `didNotStart`, and a cast bar that never
  closes is `timedOut`.

`/ccast <name> [item | alt | gem<#>] [targetid|<#>]` drives it by hand, at the commands band, and
reports the outcome when it lands; `/ccast` alone reports what casting is doing and `/ccast off`
cancels it. Settings (memorize gem, settle window, preparation budget) live in
`configs/castingConfig.lua`, whose menu page also shows the live status.

Callers today are `/ccast`, any configured action slot holding a spell, clicky or AA (see Action
system below), and the five states that ask for casts directly: heal, spell dps, buff, pet and
mez. Cures and rezzes are the heal state asking as well — a cure, a rez and a heal are one character
choosing what to spend a gem on, so all three go through one caller rather than three (see Curing
and Rezzing).

**Mez is the caller that reads a result twice**, and it is worth knowing why before writing
another one: a resist arrives *after* the cast bar closes, so the service reports the cast a
success and refines that a beat later — which is what the note about reading `GetResult` on the
frame after it first goes terminal is for. For every other caller the refinement is a nicety. For
mez it is the whole of a feature: "it resisted" is the only way that state ever learns a mob needs
a tash before a mez will stick, so it writes down what it thinks landed on the first terminal pass
and takes the answer on the next, undoing the optimism if the answer changed.

## Giving (`utils/Giving/`, wired by `cabby/giving.lua`)

Putting an item into somebody else's hands, as a task requested and polled the way a cast is. It
is the smallest of the three services and it exists for the same reason as the other two: the
sequence is not one action, it is four commands with a wait on the client after each — get the
item onto the cursor, get on the target, click on them, answer the window that opens — and a
caller that walked it inside its own `Go()` would leave a give window standing open with an item
in it the first time something above it took the frame away mid-sequence.

```
Giving.lua          the service: one hand-off at a time, request + poll by id
  GiveTask.lua      the sequencer: validate → pick up → target → offer → hand over
GiveStatus.lua      idle | preparing | giving | succeeded | failed
```

Rules that matter when adding a caller:

- **One hand-off at a time, and the one in flight keeps it.** There is no priority to arbitrate
  by here and an item halfway into a window is not something to interrupt for somebody else's, so
  a second request is refused with a reason rather than queued. `StopFor(owner)` is how the caller
  that owns one takes it back; `Stop()` is unconditional.
- **Requests never touch the client; only `Pulse()` does** — the pick-up, the `/mqtarget`, the
  click, the notify. Same rule as movement and casting, same reason.
- **Every step is answered by the world, not by a delay.** The cursor either holds the item, the
  target either took, the window is either open. What each step keeps is an *evidence window*: a
  command that produced no visible change in a second and a half did not take, and the client has
  nothing else to say about it. Those windows are the only clocks in here, and none of them runs
  while something is actually happening.
- **Both shapes of a give are handled.** On this client, clicking a spawn with an item on the
  cursor opens `GiveWnd` and the Give button hands it over; a client that instead takes the item
  straight off the cursor has simply finished early, and the offer step reads that as the success
  it is.
- **What the player put on the cursor is theirs.** A hand-off asked for while the cursor is loaded
  with something else is refused rather than stowing it. A hand-off that *fails* puts back what it
  moved, and in two parts, because the client answers on its own clock: the window is cancelled in
  the frame it ends, and the item it gives back a frame or two later is watched for and
  `/autoinventory`'d over the next few. An `/autoinventory` fired alongside the cancel would find
  the cursor still empty and leave the item there — which is the mess this exists to avoid, since
  a loaded cursor blocks looting and every later hand-off. A hand-off that *lands* stows nothing:
  the item is with them, so anything of that id on the cursor afterwards is the player's.
- **It decides nothing.** Whether the pet already has one of these, and whether handing one over
  is worth doing, are the caller's questions and the caller's records — see the pet state. This
  service knows about one item and one spawn.

`/cgive <item name> [targetid|<#>]` drives it by hand and reports the outcome when it lands;
`/cgive` alone reports what giving is doing and `/cgive off` cancels it. Callers today are `/cgive`
and the pet state.

## Action system (`actions/`)

`ActionType` is the interface for "a thing the character can activate":
`Name / ActionType / HasAction / EndCost / IsReady / DoAction`. Implementations:

- **Skill** (`skill.lua`): melee skills via `/doability`; static registry `skills.lua` tags
  each skill with attributes (facing, targeted, primary, secondary, melee, …) and builds
  ordered category lists. Per-instance 500 ms wall-clock cooldown timer. `IsReady` is false
  while `Me.Feared`: a feared character is pointed where the server points them, so the ability
  is spent on whatever is in front of us and comes back on its reuse timer regardless. The
  facing attribute does not cover it — the sweep past the target reads as facing it — and it is
  answered here rather than by each caller because it is a fact about the character.
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
  the states below, and then fail: not without the mana, and not without a target in range. The
  request matters twice over: `targetId` is who the range and line of sight are judged against (a
  heal is chosen for a group member nobody has targeted yet), and `priority` is what decides
  whether a cast already in flight means "not now". A cast in flight normally does — but a caller
  that outranks whoever is casting is exactly who should take it over (`Casting.CanPreempt`), and
  answering "not now" to them would put the priority chain's whole point out of reach: a heal
  could never interrupt a nuke.

  **Not being memorized is not one of the reasons.** It was once, on the grounds that a rotation
  stopping to memorize mid-fight stops for eight seconds — but what that bought was a slot the
  user had configured, that the page marked ready, that never fired and never said why. A spell
  not on the bar is a memorize away and the service does it (into an empty gem where there is
  one, so the usual case costs only the seconds), once per spell rather than once per cast, with
  everything stronger than the rotation free to preempt it meanwhile. The one thing `IsReady`
  still has to be careful about is the gem timer: `CastSubject:IsReady` reads false for an
  unmemorized spell too, so it is asked only of a spell that has a gem — otherwise a slot holding
  one would be never ready, therefore never memorized, therefore never ready. The picker still
  marks which spells are off the bar, now as a cost to know about rather than a slot that will
  not work.

**Action** (`action.lua`) is the *persisted config shape* for a user-configured action slot:
`{ name, actionType, enabled, luaEnabled, lua, end_type, end_threshold }`. `luaEnabled`
actions gate on a user-authored Lua predicate evaluated with `loadstring` each use — this is
the replacement for MQ2Melee downshit/holyshit lines (originals kept as reference comments at
the bottom of `meleeState.lua`). `EditAction` + `ActionUI` implement staged edit/save/cancel
editing of these slots; `MeleeStateConfig` stores three lists (actions, taunt_actions,
hate_actions) with usage modes (always / as-needed / off), reachable as one set through
`GetActionLists()`.

The state's own per-slot controls (`ActionUI`'s `extras` hook: a heal's threshold and scope, a
buff's rebuff point and classes) sit outside the staging in both directions. They **write** to the
live action, like `enabled` below and for the same reason. They **read the chosen spell** from
whichever action the row is currently showing — the staged edit while one is open, the live action
otherwise — which is what `extras.draw(liveAction, shownAction)` hands them. Reading the live
action for that was a real defect: picking a pet heal left the scope dial offering "the tank" until
Save was pressed, so the control that exists to say what a spell can do was describing the spell it
replaced.

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
| `spells.lua` | `Me.Book(1..720)` | beneficial, detrimental, then heals/buffs/damage by category, and control, pet summons and item summons by effect; sorted by level, newest rank first |
| `aas.lua` | `Me.AltAbility(groupId)` over the id space | taunt, hate, by the AA's own spell SPAs |
| `items.lua` | worn slots 0-22 and bags 23-34 | clickies only (`Clicky`, not `Spell`) |

Four things about this are worth knowing before changing it:

- **The spellbook has holes.** A spell sits on the page the player put it on, so an empty slot
  says nothing about the ones after it — the whole 720-slot array is read every time.
- **Spell categories are the game's filing, not a promise.** `spells.lua` narrows the book into
  heals, buffs and damage by `CategoryID`/`SubcategoryID` — the numbers of EverQuest's own
  `eEQSPELLCAT`, matched by number rather than by the name the client prints, because that name
  comes out of the server's string table and a server that rewords a heading would silently empty
  a list. A spell qualifies on either field, since the two share one table and the game is not
  consistent about which carries the meaning (an invulnerability is a heading of its own on one
  line and a subheading on the next). The sets lean wide for the same reason: a list missing a
  spell the character has is a puzzle with no way out of it from the menu, so the heal set carries
  Health as well as Heals — which is where the client files most pet heals — and a few pet buffs
  filed the same way turn up beside them. Which *half* of the book it is stays the outer question:
  the heal and buff lists are drawn from the beneficial half, so no miscategorisation can offer a
  nuke as a heal. The damage list is the one that is drawn from both, and only through one
  heading — Damage Shield, which is damage cast on a friend. It is a separate set (`damageBuffs`)
  from the harmful one for exactly that reason: the half a spell is in decides who it gets pointed
  at, so the two cannot be one list of numbers. The **control** set is the exception to this whole
  paragraph: it consults no heading at all, because all three jobs in it — mez, stun, resist debuff
  — have an exact answer in the effect data, and every heading tried was wrong in its own direction
  (see "Mez state"). Where a category *is* only a coarse label, an effect is the thing itself.
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

A spell picker that narrows by category also carries the list it narrowed *from*
(`availableActions.allSpells`), behind a **Show every spell** switch that also prints what each
spell is filed under and lets the filter box match on it. A category is data rather than a
promise, and a spell the filing put somewhere unexpected would otherwise be unreachable from the
menu with no way to see that that was what happened. For the same reason the *type* dropdown
decides whether to offer "Spell" at all from the wider list, never the narrowed one — an empty
category list must not hide the switch that widens it.

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
- **Picks one up** (throttled to 250 ms; every pulse while seeking): for the main tank a live
  `defend` report it can reach first, under its own `answerdefend` switch, and then — with
  `autoengage` on — the main assist's target, then an extended-target sweep. See Assisting and
  Defending below. `Auto Hater` is the client's own word for "this is fighting you", which beats
  anything we could work out ourselves.
- **Defends the group.** The mob eating the healer is invisible to the tank's client — the
  extended target window only lists what hates *you* — so the fact is spoken from where it is
  knowable: any character something is actually coming for (`PctAggro` 100, the same reading
  `IsUnderAttack` is built on) says `defend <ids>` out loud, once per NPC group-wide, and the
  main tank keeps the heard reports as standing facts and engages one the moment its hands are
  free and it is close enough to reach it. Every character keeps that same table, which is what
  makes the dedup group-wide: it is the tank's radar and everyone else's record of what has
  already been called. An engaged tank never switches targets off a report — the reports are the
  memory, and the fight's own end is when they are read. See Defending below.
- **Honors a fight started by hand**, above the `autoengage` gate: the player's attack being on
  while the client says real combat has begun engages the client's target as an order. The combat
  flag is asked as well as the toggle because the toggle alone is not intent — autoattack survives
  a kill, and a leftover toggle plus a curious click must not order a charge. The `engageonattack`
  switch (off by default) reads the *press itself* as the order instead: the moment the toggle
  turns on, the target under it is engaged with no wait for the swing or the aggro, so pressing
  attack at range is a charge. Only the turning-on reads that way — what a leftover toggle may do
  is unchanged — and Combat watches the toggle every pulse without exception, so a press consumed
  while engaged is never saved up to fire late. Cabby's own toggles go through
  `Combat.SetAutoAttack`, which marks each one so the edge it makes is excused by name: the
  script's hand on the toggle is never read as the player's.
- **Honors calling it off by hand**, behind two switches (both off by default). With
  `disengageonattackoff`, the player switching auto attack off closes the fight the way the Back
  Off button does, seek and all — edge-read like the press, so only the act itself orders
  anything, and a toggle *taken* rather than chosen (a mez, a charm or a stun dropping auto
  attack) orders nothing. Neither does one the script flipped itself: melee holding the swing off
  out of melee range goes through `SetAutoAttack`, and its marked edge is swallowed before either
  switch reads it — stepping out of reach must not close the fight, or call a group off it from
  a tank. With `disengageontargetclear`, the player clearing the client's target
  while it sits on the fight's own, still-standing mob does the same — a clear of anything else
  (the group member a heal targeted, a mob being inspected) is not an order, and the world taking
  the target (the death, the poofed corpse) is the seek's business, not this switch's. Neither
  reads while flee is on: travel drops auto attack every pass as bookkeeping, and the flee order
  has already said everything there is to say about the fight.
- **Remembers being called off**, which is what makes any of the above stick. Disengaging alone
  does not: every automatic way of picking a fight up is *memory that outlives the engagement*, so
  a bare disengage is undone on the next pulse — a standing `defend` report re-engages the same mob
  (and does it above the `autoengage` gate, so that switch is no answer), the hater sweep picks the
  thing beating on us straight back up, and the client's own attack toggle left on from that fight
  reads as a hand-started one. `Combat.CallOff` is the deliberate end — `attack off`, an `assist
  off` call, `/cattack off`, the Back Off buttons, and the two switches above — and it records the
  mob as **refused**: the defend pickup, the assist-target read, the hater sweep and the leftover
  toggle all step over that id, and the Back Off button finally means what it says because the
  swing is dropped too (from `Pulse`, not from the button — `SetAutoAttack` runs a game command).
  Bounded by the world and never by a clock: a refusal dies with the mob, the zone or a flee,
  swept on the same 250 ms cadence as the reports and the heard calls, or the moment a person names
  the mob again — `Combat.Engage` is where that happens, and every route in from somebody's word
  (`attack <id>`, an `assist` call, the Attack button, a *press* of the attack key) goes through
  it. A fight ending by itself refuses nothing: dying, an empty seek and a flee are plain
  `Disengage`, because a mob that killed us is not one we are being kept off when we come back for
  it. `/cattack` lists what is standing.
- **Says what is coming for us, and not only that something is.** `IsUnderAttack` in detail is
  `GetUnderAttackIds`, and the *leaving* of that list is a fact too: a mob somebody else has taken
  is one we are no longer most hated by, which is how the pet dps state knows a peel took without
  timing anything.
- **Publishes each angle separately as well as merged.** `GetHaterIds` is the whole extended target
  window rather than the most-hated subset, and `GetDefendIds` is the standing reports on their own.
  Both existed as private facts and are published because a merged list cannot say *which* angle
  saw what, and that is precisely what `cabby.mobs` is built to record — "the client told us" and
  "we found it ourselves" are different levels of confidence and a reader has to be able to tell
  them apart.
- **Says what the whole fight is, not just what is being killed.** `GetFightIds` is the engagement
  first, then every `Auto Hater` on the extended target window whatever its aggro, then the
  standing defend reports — the adds beating on group members, which our own window cannot see
  because it lists only what hates *us*. All three are already this service's facts, already swept
  for death, zone and flee, and nothing here sweeps the room: a mob nobody is fighting can never
  appear in it. One sweep of the window fills this and `GetUnderAttackIds` both, because both are
  twenty TLO reads off the same list. It is what a debuff spread across the fight is aimed by (see
  Damage: melee and spells), and it says nothing about whether any of them can be *reached* —
  that is the caller's question, asked of the world every pass.
- **Says whether there is a fight on at all, ours or not.** `IsGroupFighting` is `IsEngaged` for
  the character that has no part in the fight it is standing in — a healer between casts, a caster
  out of mana, anybody with auto-engage off — and it is every angle this client is handed, merged:
  our own engagement (continuity and all, so it does not blink between two mobs of one fight),
  anything on the extended target window, the standing defend reports, and a heard `assist` call.
  The last three are the tables `GetFightIds` reads, already swept for death, zone and flee, which
  is what keeps it from standing true over a camp that stopped fighting ten minutes ago. What it
  cannot see is a fight nobody here is part of and nobody announced, and that silence is the honest
  answer — there is no reading another player's combat state. `travel.lua` is what reads it: the
  follow relaxes its hold distance while it is true (see Movement).
- **Says what the group's main tank is fighting**, which is the one thing a client is ever told
  about another character's target — `Combat.GetTankTargetId`, assembled from the tank being us,
  the tank's own heard `assist` call, or the client's assist record when the tank holds that role
  too. Nil is "nobody here can say", not "the tank is on nothing"; see Assisting below.
- **Says when we have taken the mob off the tank**, which is the two facts above read together:
  `ShouldEaseOff` is true while the mob we are hurting is at the top of *our* hate list and holding
  it is somebody else's job. Answered here rather than in both dps states, because it is one
  question about the fight and two states hurting things would otherwise answer it twice and drift.
  Four things say no: the `easeoff` switch being off, being the main tank ourselves (that aggro is
  the job), no tank named at all (nobody to hand it back to), or the tank being on something else —
  an add that picked us is not a mob we pulled off anybody, and `defend` is what is already being
  said about it. Not knowing what the tank is on reads as *the tank has this one*, the same way the
  pet state reads it for its taunt and for the same reason. What each state does about it is its
  own (see The two dps states).
- **Owns the `attack` order**, the `assist` call, the `defend` report, the `autoengage`,
  `callassist`, `calldefend`, `answerdefend`, `easeoff`, `engageonattack`, `assistonengage`,
  `disengageonattackoff` and `disengageontargetclear` switches, and reports on `/cattack`.

**It runs no game command that decides anything**, which is what makes `Combat.Engage` safe to call
from an ImGui button. The Attack button used to call `MeleeState.EngageTargetId`, which ran
`/mqtarget` from inside the render callback — the crash-to-desktop hazard the movement service is
built around. Targeting is now the melee state's business, done from its own pulse, because
swinging is what needs the client's target; a cast targets through the casting service. The one
thing Combat says out loud — the tank calling the assist — is said from `Pulse` and nowhere else,
for that same reason. `SetAutoAttack` is the one function here that runs a game command for its
caller — it lives in Combat because the edge watcher has to know whose hand flipped the toggle —
and it carries the corresponding warning: states and services only, never a render callback.

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
| `rescue` | a `defend` report, picked up by the main tank | no, while it lives |

The table is about what may *replace* an engagement. What ends one without replacing it is the
other half of the same question, and only `order` has an answer there: a fight that ends by itself
(an empty seek, a death, a flee) leaves nothing behind, while one somebody **called off** leaves a
standing refusal of that mob that the three automatic sources all step over — see
`Combat.CallOff` above. Without it the strongest source is the weakest in practice: the three that
this character works out for itself are all backed by memory that outlives the engagement, so they
re-decide on the next pulse, and the order — which has no memory at all — loses.

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

**A heard call is also a record of what that character is on**, kept per speaker and read back for
one question: what is the main tank fighting (`Combat.GetTankTargetId`, above). It is the only
answer to it that does not depend on the server keeping assist targets current, because it is a
character saying out loud what its own client knows. The record is a live fact rather than the last
thing anybody shouted: `assist off` takes the speaker's back, a zone or a flee empties the table
(an id means nothing across a zone line, and what the tank was on before a run is not what it is on
now), and the 250 ms sweep drops a call whose mob the world has taken — which is what stops a tank
that quietly stopped calling from leaving a statement standing forever. Whether the answer is
knowable at all is the reader's problem, and the readers differ: the pet dps state's automatic taunt
treats "cannot say" as "the tank has it".

`callassist` is the switch on the calling side, on by default and silent on every character that is
not the tank; the call goes out on that command's own speak channels (`/speak assist`). `/cattack`
reports all of it: the roles, what the assist is on, what the main tank is on, and where calls are
being spoken.

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

### Defending — how the tank finds the mob on the healer

A mob that jumped the healer and has never touched the tank is invisible to the tank's client:
the extended target window only lists what hates *you*, and no local read fixes that (a group
member's XTarget slot shows what they *target*, which for a healer under attack is a friendly).
So the fact is spoken from where it is knowable, and the two halves are deliberately asymmetric:

- **Whoever is being beaten says so — once per mob, group-wide.** Any character something is
  actually coming for — the top of a mob's hate list, `PctAggro` 100, the same reading
  `IsUnderAttack` is built on, combat-flag gate included — says `defend <ids>`, one line per NPC
  for as long as it lives in this zone. Saying it is what puts the mob on the tank's radar, the
  tank keeps it there until the world takes it back, and **every character hears the same lines
  the tank does**, so the standing reports double as the group's shared record of what has
  already been called, whoever called it. That is what makes the dedup group-wide rather than
  per-reporter: a mob bouncing tank → healer → tank → wizard is announced by the first victim
  and by nobody after. What clears its entry is what would clear the tank's radar of it — its
  death, a zone, a flee — and only then is it news again. A reporter records its own spoken ids
  at the mouth as well as at the ear, because a character's own broadcast coming back through
  localecho is owner-gated and may never reach its own handler.

  Two silences are deliberate: the **main tank never reports** (everything coming for the tank
  is its own hater sweep's business), and the **fight the group was put on is not reported** (an
  engagement from an assist call or the assist's target is the group already knowing) — though a
  fight the reporter picked up for *itself*, its own hater sweep, is reported even while it
  fights back, because that is exactly the unattended beating the report exists for; and a
  filtered mob is left off the record rather than marked, so a beating that outlives the group's
  fight is announced the moment it becomes unattended. `calldefend` is the switch, on by default.
- **The main tank picks one up when its hands are free — never sooner.** A heard report is a
  standing fact that lives until the world takes it back: re-verified at the moment of acting —
  dead, gone, or not fightable drops the entry for good — and the whole table is dropped by a
  **zone** (spawn ids do not survive one, so a kept id is meaningless at best and a collision
  with a fresh spawn at worst) or a **flee** (a run is the player taking the fight back; kept, a
  report would charge the tank across ten zones the moment the run ends — new ones are refused
  meanwhile, exactly as `assist` calls are). An unengaged tank engages the longest-standing live
  report it can reach — the group's attackers before even the group's target, for the one
  character whose job is protecting it — as source `rescue`, named for its victim ("it is
  attacking Lieph"), and `callassist` then announces it so the whole group converges. An engaged
  tank never switches targets off a report: the reports are the memory, and the fight's own end
  is when they are read — a fight whose target just died reads them from inside its seek, so a
  pull's add is the same continuous fight and `IsEngaged` never blinks. That wait is the point,
  not a limitation of it: a tank that switched the moment a report landed would drop a mob at 5%,
  walk its hate list back to nothing, and drag the group's damage across the camp — and a group
  whose mez is holding because the tank is standing still would watch the tank run through the
  mezzed pile to get somewhere. The pickup sits deliberately above the tank's own `CombatState`
  gate, because the tank is precisely *not* in combat while the add is only on the healer; the
  reporter already asked the combat-flag question on the client where the fact lives.

  **`answerdefend` is the switch, on by default, and it is deliberately not a corner of
  `autoengage`**: answering the group's call for help is a different choice from picking fights up
  unbidden, and a tank the player is driving by hand — auto-engage off, taking `attack` orders
  only — still wants the add that went for the healer. Only the main tank role acts on it, so
  every other character carries it unused until the day it is handed the role.

  **A report is answered only from where it can be answered**: closer than 100 (`Distance3D`) and
  in sight, the same reach the melee state's engage distance defaults to. A report is heard from
  anywhere in the zone — bc reaches every connected character — and answering one blind is a
  charge across the camp through everything in between. Out of reach is *not* stale, and the two
  are answered differently: the world taking a mob back drops its entry for good, while distance
  or a wall only skips it, leaving it standing to be picked up the beat the group closes on it.
  A mob the tank was **called off** by hand is skipped on that same footing and for the same
  reason — the report is still true, somebody is still being eaten, and it is the tank that is
  being kept off it. This is the standing report meeting the standing refusal, and the refusal
  wins: the report is this client working something out, the refusal is a person's word. Put the
  tank back on the mob by name and the report is answered on that pass.
  Unreadable line of sight reads as visible, the way it does everywhere else in cabby — the client
  declining to answer is not a wall, and a group member is being eaten. Sight and distance are
  asked only of a report that would win on age, so the usual pulse pays for one reachability read
  rather than one per entry.

The listener's ACL is the usual owner list **widened by the group**: reports are machine-spoken
by whichever characters happen to be grouped with the tank, and a group assembled fresh would
otherwise need every member added to the tank's owner list before the tank would defend any of
them. The invitation is the trust that matters here; a speaker outside the group still needs the
owner list, and costs nothing without it. Spoken by hand, `defend <id>` is a request to peel —
`defend ${Target.ID}` on a hotbar button asks the tank to come take your target off you. The
report falls back to **bc** rather than the group channel: it is as load-bearing as the assist
call (an unheard report is a healer eaten in silence), but it is machine-to-machine traffic for
one listener, not something the group reads; `/speak defend <channel>` sends it elsewhere.
What this deliberately does not cover: a mob beating on a *pet* is on nobody's extended target
window, and a group member not running cabby reports nothing.

## Mob roster (`mobs.lua`) — what is in the fight

`combat.lua` answers *what we are killing*. This answers *what is here*, and they are different
questions: the mob nobody has hit yet is invisible to the first and is precisely what crowd control
exists for. It is a service rather than a table inside the one state that needed it first, because
"which mobs are in this fight" is a fact a puller's leash and a tank's add sweep will want the same
answer to, and a second copy of it assembled from scratch is a second copy to be wrong.

**Four angles, merged, and each entry records which of them saw it** — because *how* we know is
what says how far a reader may lean on it:

| Source | Where it comes from | Can it be wrong? |
|---|---|---|
| `engaged` | `Combat.GetTargetId` | no — somebody chose it |
| `hater` | the extended target window's `Auto Hater` entries (`Combat.GetHaterIds`) | no — the client saying "this is fighting you" |
| `defend` | the standing `defend` reports (`Combat.GetDefendIds`) | no, but it needs somebody else running cabby |
| `nearby` | a sweep for NPCs in combat stance within reach | **yes** — see below |

The first three are free (Combat has already paid for them) and are re-read every pulse; only the
sweep is throttled, at the same 250 ms Combat sweeps the target window at, with its last answer
folded in until the next replaces it — so a mob that walked out of radius lingers for a quarter
second rather than flickering out of the list under a state that is acting on it.

**The sweep is the angle that needed designing.** `playerstate 4|8` is the search — the client's
own "this thing is in combat stance", the bits `Spawn.Aggressive` reads — which is why merchants,
guards at a post and wandering critters never enter the list to be filtered out of it. What the
search cannot express is the other half of friendly, so that is asked per spawn: an NPC, a pet or a
destructible object; alive; targetable; and **not something a player owns** (`Master.Type()`),
which is the one a naive sweep gets wrong — a group member's warder and our own charmed pet are
both NPCs in combat stance standing right next to us.

What is left over is the one way the sweep is loose: it says the mob is in combat with *somebody*,
and that somebody is usually us and occasionally the guards across the room. `Mobs.IsConfirmed(id)`
is the question a reader asks when being wrong is expensive — an AE mez aimed into a group of
unconfirmed mobs is the classic way a camp pulls the room, so that is exactly what MezState's AE
safety switch is built on, while a single-target mez spent on a mob that was not coming for us
anyway just reads off `GetIds`.

**It also samples where each mob is and which way it is facing**, every 250 ms, and publishes when
each last moved (`Mobs.LastMovedMs`, `Mobs.StillForMs`). That lives here rather than in the state
that wanted it for a reason worth generalising: a *sample over time* only means anything if
somebody takes it at a steady cadence, and a state being starved by the fight above it cannot
promise one. Position and heading together, because turning is movement for this purpose — a mob
handed back its own will faces its victim before it takes a step, and a rooted one may never take
one at all.

**It decides nothing and says nothing** — no engaging, no targeting, no chat — which is also what
makes it safe to read from an ImGui callback. Zoning empties it (spawn ids do not survive one) and
so does a flee (the fight the group ran from is not a fight). `mobsweep` is the switch, its reach is
two numbers on the Mez page, and `/cmobs` reports every mob with the angles that saw it.

## Mez state (`states/mezState.lua`)

Holding the fight still: mezzing the adds, keeping them mezzed, and stunning whatever has turned
around and reached us. **This is the state the priority chain was drawn for.** A mez that waits its
turn behind a damage rotation is a mez that lands after the add has already killed somebody, so it
sits at `Priorities.mez` — above tanking, above both dps states, below healing and the passive band
— and everything below it is starved for exactly as long as a mez is in the air and not one frame
longer, which the casting priority floor does without this state holding anything.

**What is in the fight is not this state's question** (see Mob roster above). That split is the
reason the roster exists at all: crowd control acting on a list it assembled privately is crowd
control nobody else can audit, and `/cmobs` and `/cmez` answering out of the same reading is what
makes "why is that add loose" a question with an answer.

**What a slot in the list is for is read off the spell.** One ordered list, walked in order, first
slot with something to do wins — and which of three jobs a slot does comes off its effects, never
out of a dropdown:

| Role | Read from | What it does |
|---|---|---|
| mez | `SPA_ENTHRALL` (31) | holds a mob still; the job |
| stun | `SPA_STUN` (21) **or `SPA_SPIN_STUN` (64)**, nothing damaging | buys the seconds a mez needs to be cast at all |
| soften | a resist debuff (`SPA_RESIST_*` with a negative base) | the tash cast at a mob so the mez after it takes |

Both stun effects, because an enchanter's Whirl Till You Hurl and Dyn's Dizzying Draught carry
`SPA_SPIN_STUN` and nothing else at all — a stun read that knows only about `SPA_STUN` silently
loses a line the class has had since level nine. Deliberately not `SPA_FEARSTUN` (502), which stuns
and *fears*: a feared mob runs, which is the opposite of holding one still.

**Those three and nothing else** — there is no default role, and a spell that does none of them is
refused with that written on its row. A slow, a cripple, a snare, a root and a lull are all useful
spells that hold nothing still and make no mez land; each one belongs in the damage rotation, where
`dps_timing` and `dps_spread` already say when and how widely to cast it. Letting anything unmatched
fall through to "softener" was a real defect: an enchanter's Languid Pace, an attack-speed slow, was
being offered by the picker and would have been cast at every mob before every mez as though it made
them land.

**The stun's place in the list is the strategy, not a convenience.** A mez is a long cast and a mob
that has reached this character interrupts it — so the mob swinging at us is stunned first and
mezzed during the seconds that buys. That is why a stun is here rather than in the damage rotation:
it is not damage and it is not crowd control on its own, it is what makes the crowd control
castable. And it is never aimed at a mob that is already mezzed, because **a stun landing on a
mezzed mob breaks the mez** — not "adds nothing", but actively undoes the three seconds just spent.

The mez read is the same one the client uses to fill in `Target.Mezzed`, so cabby and the client
agree about what is on a mob by construction rather than by coincidence. It matters that this is
the *effect* and not the Enthrall heading: that heading also holds calms and lulls, and a lull cast
at an add is a pull rather than a lockdown.

**Nothing in this list may do damage, and that rule does more work than it looks like.** Damage is
precisely what breaks a mez, so a slot holding a nuke works against every other slot — but the rule
is also the *only* thing that tells a stun from a nuke. An enchanter's Anarchy is a two hundred
point AE that stuns, and it carries the identical `SPA_STUN` that Color Shift, which stuns and does
nothing else, carries. Read by the stun effect alone the two are the same spell. So `Spells.Damages`
reads the *sign* of the base value on the three hit-point effects (`SPA_HP`, `SPA_INSTANT_HP`,
`SPA_HP_NPC_ONLY` — the same numbers heal when the base is positive), and anything damaging is
refused by the list, kept out of the picker, and told why on its row.

**This list consults no heading at all** (`Spells.Controls`), which makes it the second set after
the pet and item summons to be read purely off effects — and it got there the hard way. Every
heading tried was wrong in its own direction: *Slow* put Languid Pace in a mez list, *Enthrall*
holds lulls beside the mezzes, *Utility Detrimental* is the catch-all the damage list already leans
on and made the two near-copies, and *Root*/*Snare* are already first-class in the damage rotation,
where offering them a second time with different meanings is how a root gets configured twice and
cast neither time. All three jobs have an exact answer in the effect data, so nothing is left for a
heading to get wrong.

**Is it still under? Four readings, strongest first — and the third is the one every other mez
script leaves out.**

1. **We just landed one.** For the couple of seconds it takes the server to tell the client, what
   we did is the only record there is. It answers "held" rather than "two seconds left": the
   window bridges a round trip, it is not the mez's duration, and reading it as one would make
   every mez read as nearly-out against the refresh margin and be cast twice.
2. **The world said it woke up.** The awakened line (`%1 has been awakened by %2.`); the mob having
   **moved or turned since the mez we put on it landed**; and the mob's animation showing it doing
   something other than standing there.
3. **The client's cached reading**, `Spawn[id].CachedBuff[^mezzed].Duration` — the same
   `SPA_ENTHRALL` search, filled in whenever the mob was last targeted (which for a mob we mez is
   every time we mez it) and ageing by itself from there, so a stale cache decays into "it needs
   one" rather than lying about it.

Reading 2 exists because **nothing tells a cached buff about a break.** A mez ended by a backstab
sits in the cache counting down the two minutes it had left, and a state that trusted the cache
alone would leave that add loose for two minutes. So the cache answers *how long has it got* and
the break signals answer *is it still under*, and it is the second question a mez state exists for.
Three signals carry it, and they are deliberately different in kind:

- **Movement since the mez landed** is the strongest and needs no window and no threshold: the mez
  landed at one instant, the mob moved at another, and which came second is the whole answer. A
  mezzed mob is *perfectly* still — the same coordinates and the same heading, sample after sample
  — so anything else is the mez not holding. Heading is half of it and the half position alone
  misses: a mob handed back its own will faces whoever it is about to hit before it takes a step,
  and one that is rooted or snared may never take one. `mobs.lua` samples the pair every 250 ms
  (`Mobs.LastMovedMs`), which is where it belongs — a sample over time only means anything if
  somebody takes it at a steady cadence, and a state being starved by the fight above it cannot
  promise one. This is `MobMoved` from `macros/bots/enchanterBot.mac`, which is also where the
  argument for heading comes from.
- **The awakened line** is the instant one: it arrives at the moment of the break, before the mob
  has physically done anything about it. See below.
- **The passive animation list** is carried over from `macros/bots/mez.mac`, where it has been the
  break test on this server for years. It is the weakest of the three — a lookup table that can be
  incomplete, where "it is somewhere else now" cannot be — and worth noting that
  `enchanterBot.mac`'s equivalent check is commented out in its own source, so the two public
  macros disagree about it. It is kept because one of them is field evidence for *this* server, and
  all three err the same way: any of them calling the mob active makes it active. Silence is read
  as "standing there" rather than as "loose", since calling every mob we cannot see loose would
  mean re-mezzing the camp on the strength of not knowing.

**Which mob woke is a question the line cannot answer, and the mobs answer it themselves.** The
line carries a name, and two of a kind mezzed side by side is the ordinary case in a camp — so it
is treated as what it actually is, a prompt to look harder:

- **One mob of that name held** — that settles it, and it is marked loose outright.
- **Several** — all of them are suspected, and the first to move or turn since the line arrived is
  the one that woke; the rest are then cleared, because **one line is exactly one mob**. Two waking
  is two lines.
- **A name we are holding nothing of** — somebody else's business, ignored.

An unsettled suspicion costs nothing in the ordinary case, and the reason is the chain: **only one
mez can be in the air at a time**, so the order the loose list is walked in *is* which mob gets the
cast. Anything that has provably moved sorts first, so the single cast this pass goes at the right
mob, and by the time a three-second cast has finished the others have given themselves away or been
cleared. A suspicion nothing ever resolves simply stands — the worst it can do is buy that mob a mez
it may not have needed — and it is dropped by the mob dying, by a mez of ours landing, or by a zone.

**"Still mezzed" is never the question — "will it still be mezzed when the next one could land" is.**
The margin is the cast time plus a configured lead, which is arithmetic rather than a timer: a mez
with four seconds left that takes three to cast has to be started *now* or it wears off with the
caster stood still mid-cast, which is the worst moment in the fight to hand an add back.

**Is it worth mezzing?** Not what the group is killing (`Combat.GetTargetId` — mezzing that is
mezzing the tank's mob out from under the damage). **Not something we cannot see** — nothing in
this list reaches through a wall, so a mob out of line of sight is neither mezzed, nor counted
toward an AE being worth casting, nor waited for; it comes back on the pass it rounds the corner,
and the page says *unseen* rather than leaving it silently absent. Not something the world has said
cannot be mesmerized, which is the `immune` outcome the casting service already reports and is
remembered against the spawn until it dies. Not something above the mez's own level, read off the mesmerize
effect's `Max` rather than off `Spell.MaxLevel` (which reads the first effect slot whatever is in
it) — and an unreadable level is not a refusal, since the cast is the cheapest way to find out and
the answer comes back as the immune line. And not something already hurt past `stop_pct`, which
reads backwards until you have watched it go wrong: a mob *below* the line is not too healthy to
mez, it is too nearly dead — somebody has been killing it, there is damage in the air aimed at it,
and a mez landing takes it out of reach of all of that so the group starts again on a full-health
add instead. **Range** is not asked here: a slot's `IsReady` is judged against the mob the cast
would be aimed at, so the casting service answers it per slot, because a mob out of reach of one mez
is in reach of another. **Line of sight is**, and the difference is worth the paragraph below.

**Line of sight is read once per mob per pass and shared by every slot**, rather than left to the
casting service's own check. Every cast in cabby is LOS-gated already — `CastAction:IsReady`
raycasts against the request's `targetId`, and the `CastTask` sequencer checks again before the
spell goes out, so no cast anywhere reaches a mob through a wall. But being *refused* is not the
same as being able to *decide*: an AE mez is worth casting because of how many mobs it will catch,
and counting one on the far side of a wall toward that is how a blast goes off for two mobs when it
was judged worth casting for four. So this state asks the question itself, which also turns a
raycast per slot per mob into one per mob. A wall is a wall — the answer is the same for every
spell in the list. Both macros this state is built from filter mez targets the same way. Unreadable
is read as visible, since the client declining to answer is not a refusal and the cast will be
refused for real if it turns out to be blocked.

**Softening is what "sometimes we have to tash it first" turns into.** A softener slot's default
is *once it resists a mez*, which is the honest one: we find out that a mob resists by having a mez
bounce off it, and that record is what the world said rather than something guessed. *Before every
mez* is the zone where they all resist, and is a real answer — it just costs a cast and a gem timer
per add to find out nothing when they do not. The one piece of coordination between slots in this
list is that a mob waiting on a softener is left out of the mez slots' candidates entirely, and it
earns the exception: without it a mez slot above the tash keeps choosing the mob we already know it
bounces off and the softener below never gets a turn. The deferral only holds while a softener that
could actually act on the mob is enabled and in the list, so a character with no tash configured
goes on trying the mez, which is the only thing it has.

**AE mez is read off the spell's reach, not off its target type string.** `AERange` above zero is
what makes it an AE at all, and whether it needs a target is what says whether the blast is centred
on the mob or on us. It waits for `ae_min` loose mobs — one is never worth it, since an AE wakes
what it does not land on and a single-target mez covers one mob anyway — and it is aimed at
whichever mob has the most loose neighbours inside the radius. Nothing is credited to a mob from an
AE's immune or resist line, because those cannot be pinned on any one of the several it went off
around; the mobs it failed on show up loose on the next pass, which costs a pass and is the honest
answer.

**Two things this deliberately does not do.** It never runs a game command of its own — targeting
is the casting service's, so a mez aimed at an add borrows the client's target for exactly as long
as the cast takes, the way a spread debuff does. And it does not touch auto attack: the melee state
swings at what `Combat` is on, which is never what this state mezzes, so the ordering already
answers what every other mez script answers with an `/attack off` before each cast.

`mezzing` is the switch, `mezaction` switches slots on the list, and `/cmez` reports what every mob
in the fight is doing — held, loose, immune, or the one being killed — with the reason and the
roster angles beside it. The phrase is `mezzing` rather than `mez` because no registered phrase may
be a prefix of another and `mezaction` sits inside the shorter name.

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
| Actions offered | skills, discs, AAs, clickies | damage spells and damage shields, AAs, clickies |
| Holds back for | a mob pulled off the main tank (`easeoff`) — otherwise nothing, swinging is free | the same, plus target above `start below %` (shields excepted), below `stop below %`, mana under the floor, a slot's own moment, a slot's own con floor |
| Switch | `melee` | `nuke` |
| Action command | `action` | `nukeaction` |

The swing itself is range-gated both ways: auto attack goes on inside melee range (facing
checked), and is held off past the spawn's true reach (`MaxRangeTo`) until we are back inside it
— the on-ring sits a few units inside the off-line, so a mob dancing on one boundary cannot flap
the toggle. Both toggles go through `Combat.SetAutoAttack`, so the bookkeeping is never read as
the player's hand on the attack key (see Combat). Rooted, the stick lets the movement keys go and
keeps facing: the run resumes the pulse after the root fades, and a mob dragged into reach
meanwhile finds us already square to it, swinging.

The restraints on the spell side are all the same idea: a caster with none pulls the mob off the
tank, runs itself out of mana, and spends a four second cast on something that dies in two.
`start below %` is the cheapest aggro management there is — wait for the tank to land something.
Anything more specific than those three numbers goes in a slot's Lua predicate, which is the
escape hatch the action list already had.

**`easeoff` is the same aggro management arriving late** — after the mob has already turned around
— and it is the one restraint both states share, because pulling the tank's mob onto a caster and
onto a rogue is the same mistake. Combat answers it (`Combat.ShouldEaseOff`, see Combat above)
and each state decides what to do about it: melee drops the swing through `SetAutoAttack` and skips
the whole offense — abilities, taunts and hate included, since taunting the mob the main tank should
be holding is the state pulling one way and the group the other — while the rotation holds
everything aimed at the mob and lets a damage shield through, exactly as `start below %` does and
for the same reason. Melee keeps a stick already running and starts no new one: hate is not shed by
walking away — it is shed by the tank building more while we add none — so standing off would only
mean crossing that ground again, while a mob already coming for us needs no ground crossed. Both
resume on the pass the tank is back on top of that hate list, with nothing remembered in between and
no timer anywhere — "it has been a while, start again" would be starting again into a mob that is
still coming for us. The switch is on by default, and a group that has named no main tank never sees
it.

**Every slot also carries a con floor** (`dps_con`), which is the one dial on this page both
halves of the list get. The three numbers above are restraint *within* a fight — when to start,
when to stop, what mana to keep back — and none of them says which fights are worth the effort in
the first place. That is what a floor says: how much of a fight the mob has to be before what this
slot costs (a four second cast, an item on a long timer, the mana in a damage shield) is worth
spending rather than kept for the next pull. It is a ladder, weakest to toughest — *any con* (the
default, and what every slot does until it is told otherwise), then green, light blue, blue, white
and yellow, each including everything above it, then *red only* at the top. A floor at the bottom
rung is answered without reading the world at all, so a rotation that never asked the question pays
nothing for it and behaves exactly as it did before the setting existed.

Which mob is being conned falls out of what the slot is: one aimed at the mob is judged against
what it would be cast at, and a slot spread across the fight judges each mob on its own, exactly as
timing is asked per mob. A slot cast on a *friend* is judged against **what we are fighting** — how
much trouble we are in is a fact about the mob and not about whoever ends up wearing the shield —
and that is the half the setting was wanted for: a damage shield is the most expensive thing in a
rotation and the least needed on something that dies in two swings, so "put it on the tank when
this is actually a fight" is a con floor and nothing else. A mob the client will not con counts as
*not* tough enough rather than as tough enough, the same reading an unreadable health gets, so
nothing expensive goes out on a guess.

The ladder itself lives in `cons.lua` rather than in this state, because the question is the same
wherever it turns up next — the grey mob not worth a damage shield is not worth a discipline, a mez
or a summoned pet either — and one spelling of "light blue" for all of them is the point.

**A slot aimed at the mob also carries its own moment** (`dps_timing`), because the numbers above
are one answer for the whole rotation and a debuff is the case where that is not enough. The same
root is three different orders — put it up at the top of the fight, save it for the mob that is
about to run, or wait until it has actually turned and gone — and which one it is cannot be read
off the spell. So it is a dial: *right away* (the default, and what every nuke stays on), *once it
is hurt* at a health of the slot's own (`dps_timing_pct`), or *once it runs*. It only ever narrows:
the slot still has to come up in the order and get past the three numbers. Two slots may hold the
same spell with different answers, and the first whose moment has come is the one that fires, which
is how "root it now, and again if it runs later" is expressed without an and/or in the config.

Nothing here says "and reapply it if it fades", because nothing has to. A spell that leaves an
effect behind is already left alone for as long as that effect is on the mob — the same
`alreadyWorking` reading the damage shields use, answered from the client's cached buffs for
whatever is targeted — so a root that breaks goes back up on the next pass the gate is still open
for, and one that holds is never cast twice. The fade is the world's to report; the dial only says
when we are interested in the first place.

**A slot aimed at the mob can also say *how many*** (`dps_spread`), which is the one thing the
order in the list cannot express. A slow, a tash or a snare belongs on everything in the fight
before a second nuke belongs on the one being killed — so a slot switched to *every mob* is not
finished while any mob in the fight still lacks its effect, and a rotation walked strongest-first
never reaches what is under it until they all have it. Nothing enforces that: the slot simply
still has something to do, which is the same answer `alreadyWorking` gives for one mob, asked of
each of them. Nothing is remembered between passes either, so an add that arrives late is picked
up on the pass it arrives, and the moment they are all covered the slot yields and the nukes
resume.

Which mobs those are is `Combat.GetFightIds` and never this state's own guess — what we are
killing first, then the extended target window, then what the group has called a `defend` on. Each
is asked its own timing question, because *when* is a fact about the mob the cast is aimed at:
*once it runs*, spread, is a snare on each mob as it turns. One that cannot be cast at right now —
out of range, out of sight, on the far side of a wall from the group member it is beating on — is
passed over rather than waited for, exactly as a friend out of range is in the shield half; it says
nothing about the next mob, and the next pass asks again anyway.

The switch is offered only where it means something: aimed at the mob (a shield's slot already
says who it is for) and holding a spell that leaves an effect behind, since a nuke has nothing to
be finished with. It also changes what a landed cast is trusted on: a spread slot borrows the
client's target for exactly as long as each cast takes and moves on, so those mobs are recorded the
way a group member's buff bar is — for as long as the spell lasts — rather than for the couple of
seconds a mob we keep looking at is. `readable` is that question and nothing else.

*Once it runs* is the one fact here the client does not keep. `Spawn.Fleeing` is pure geometry —
is the mob *facing* away from me — which reads yes for the whole of every fight a caster stands
behind the tank for, so it is asked together with `Spawn.Moving`: a mob in melee with anybody
stands still, and one that is moving and pointed away from us is going somewhere that is not us.
Honest rather than perfect, and wrong in the cheap direction — a mob running past us at somebody
behind reads as running, and rooting that is not a bad thing to have done.

**Not every slot in a rotation is aimed at the mob.** A damage shield is damage by the only
measure that matters here and a buff by every other one — beneficial, cast on a person, sitting on
their bar — and this is the band it belongs in: below the melee state nothing gets a frame while a
fight is on, so a shield only the buff state could cast would go up *after* the fight rather than
for it. A slot holding one carries `dps_scope` (anyone, the tank, myself, anyone else, my pet) and
reads exactly like a heal slot's: scope only narrows a spell that could go to more than one
person, and where the spell can be aimed is the spell's own business and outranks it — a self
shield lands on us and a pet shield on the pet whatever the slot says, so the page offers those
the one scope they can have. Which half a slot is in is read off the spell (`Beneficial`), never
configured. Two consequences follow from that half:

- **`start below %` does not hold it back.** That number is aggro management for damage *we* do to
  the mob, and a shield put on somebody else is not that; held back by it, it would go up a fifth
  of the way into every fight. `stop below %` and the mana floor still apply to everything.
- **A landed shield is remembered by name, for as long as it lasts.** Another player's buffs are
  visible only once the client has cached them, which happens when they are targeted — and what
  we target in a fight is the mob, so their cache reads empty and every pass would otherwise cast
  again. Our own bar and our pet's are read back for real after the usual couple of seconds. It is
  the same domain TTL the buff state keeps, and an observed death voids it, so a rezzed tank is
  shielded again rather than left bare until the record ran out.

Both states fight whatever `Combat` says, so `attack <id>` starts both, `attack off` ends both, an
`assist` call from the tank starts both, and `melee off` on a paladin stops the swinging while the
spells carry on.

A third state stacks above the pair on the same reading: **PetDpsState** at `dps - 2`, which fights
with something that is neither a weapon nor a spell (see Pet dps state). The ladder reads
`dps - 2` / `dps - 1` / `dps` in order of how little of the frame each one takes: the pet state
speaks only when the pet is on the wrong thing, the rotation only when it starts a cast, and the
melee state for as long as the fight lasts.

## Heal state (`states/healState.lua`)

The first state built on the casting service, and the first one whose job is a *choice* rather
than a sequence: who is worst off, which heal suits them, and whether the heal already in the air
is still the right one. The casting does not belong to it — it asks the casting service and polls
the result — and neither does holding the rest of the chain back, which the priority floor does
for it.

**One ordered list of heal slots decides everything.** A slot is an action (a spell, an AA or a
clicky) plus the health it is *for* (`hp_threshold` — use it on someone at or below this) and who
it is for (`heal_scope`: anyone, the tank, myself, anyone else, my pet). Walking that list in order
and taking the first slot that fits is how every heal macro since AFCleric has chosen a heal; what
is different is that one mechanism covers what those macros spelled out one setting at a time. A
slot at 85% scoped to the tank is TankHealPoint. A slot at 50% scoped to yourself is SelfHealPoint.
A group heal at 60% is DivArbPoint. There is no separate setting for any of them, and a class the
author never thought about needs no new setting either.

**Where a heal can be aimed is read off the spell, not configured** — the same `aims` model the
buff state uses, and the reason one list serves a cleric keeping six people up and a magician
keeping one pet up. A spell is *self*, *pet*, *group* or *single*, taken from its target type, and
that decision outranks scope: a pet heal is for the pet whatever the slot says, a self heal is for
us, and only a single-target heal has anybody to choose between. The page offers accordingly — a
pet heal's scope dial holds "My pet" and nothing else and is not editable, a self heal's holds
"Myself", and a group heal has no dial at all. Showing the answer rather than hiding the control is
deliberate: an absent dial reads as "this heal is for nobody", and a dial listing four scopes that
cannot apply is how a pet heal comes to be scoped to the tank and its owner to be waiting for a
heal that was never going to be chosen for one. Self and pet heals are cast at nobody, since EQ aims
them itself and targeting for one would drop whatever we were looking at; the state still records
*who* the heal was for, so the settle window and the abandon check work the same for a pet as for a
person. This is not cosmetic: `NeedsTarget` is false for a pet heal exactly as it is for a group
heal, so before the aims model a magician's only heal was chosen for the group and cast because
three people were scuffed.

The order things are decided in, every pulse:

1. **A cure, unless somebody is in real trouble** (see Curing below). Above every heal because the
   two are not the same kind of cost — a heal gives back what has been taken, a cure stops the
   taking, and what it stops is finite. Below anyone at or under the emergency point, judged the
   careful way (is there somebody in trouble this state *would* cast at, not merely somebody with a
   low number), so a rezzed group-mate parked at 15% cannot block curing forever.
2. **An order** (`healnow <id>`, `healme`). Someone asking outranks the state's own judgment —
   that is the point of being able to ask — so the slots are read only for *which* heal suits
   them: scope still applies, the health the slot was written for does not. A target already at
   full health is refused out loud rather than healed, and an order that cannot be acted on within
   ten seconds is dropped rather than landing long after it mattered.
3. **A group heal**, when enough of the group is at or below the slot's threshold (`group_min`).
   Whether a slot *is* a group heal is the spell's aim, not a setting — a group heal is what it is,
   and asking the user to say so is one more thing to get wrong. Skipped entirely while anyone is
   below the emergency point: three people at 60% is what a group heal is for, and one person at
   15% is not, however many others are scuffed.
4. **Whoever is worst off**, with the first slot whose aim, scope and threshold fit them.
5. **A rez** (see Rezzing below). Dead last, because everybody alive comes first: somebody dead is
   not getting any worse, and the corpse will still be lying there in three seconds. So this is the
   frame nothing else in the state wanted — out of a fight that is every frame, and in one it is
   the gap between two heals.

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
- **A heal that is not on the spell bar is memorized first**, like every other action slot (see
  Action system) — into an empty gem where there is one. It costs seconds the first time that heal
  is wanted and nothing afterwards, which is the trade that was worth making: the alternative was
  a configured heal that silently never went out.

**Who is watched is what the two switches decide**, and it is worth saying plainly because the
names invite the other reading: `healgroup` is whether group members are somebody this character
heals *at all*, not whether group heal *spells* are used. A heal is only ever chosen for somebody
being watched, so switching it off leaves this character and its pet and hands a group-mate at 10%
to whoever else is healing — and a group heal, which is cast because enough of the people being
watched are hurt, is then judged against a much smaller count rather than taken out of the list.
The Watching tab is the honest answer to what either switch is currently doing.

Who is watched: this character, the group (`healgroup`), and this character's pet (`healpets`, off
by default — a pet is cheaper to summon than the mana spent keeping it up; a pet class keeping its
own pet up turns it on, and the page says so in the row of any pet heal while it is off, which is
otherwise a slot that never fires for no visible reason). Members who are out of
zone or offline are skipped rather than counted as healthy, since a missing member counted as a
full one is a quiet way to get the group-heal count wrong. The tank is whoever `roles.lua` says
holds the role, which is also how a hybrid holding it is tank-scoped to *itself* — reading the flag
per group member could never say so, since we are not one of our own group members. A group with no
Main Tank set has no tank-scoped heals firing, and the Heal State page says so.

`/cheal` reports what it is doing and everyone it is watching; `/cheal off` calls off the heal in
progress. The order is `healnow` rather than `heal` because a registered phrase also matches every
longer line starting with it — a plain `heal` would fire on `healme`, `healing off` and every other
switch in the family, complaining about spawn ids nobody typed. Worth knowing before naming the
commands for the next state: **no registered phrase may be a prefix of another** — and where a name
is worth the collision anyway (`petgear` inside `petgearing`, see Pet setup state), the handler has
to drop lines whose next character is not a space, which only a command with no arguments can do.

There is one way out of that for a command whose arguments are *mandatory*: **register the phrase
with a trailing space**. The phrase is substituted into the pattern as literal text, so `"buff "`
listens for `<#1#> buff #2#` — text `buffme` and `buffgroup` do not contain and every real
`buff <type>` line does. It buys a name that would otherwise be unusable, and it costs nothing
anywhere else, because every consumer reads a phrase as `Split(...)[1]`. It is only correct when the
command cannot be spoken bare: `buff` on its own would no longer be heard at all. See Buff state
requests below, which is the one command that does this.

### Curing (`curing.lua` + `actions/cureTypes.lua`)

Curing is **two jobs owned by two different characters**, and that is the whole shape of it. The
asking runs on every class as a service; the answering rides in the heal state.

**Why it has to split that way.** Another player's debuffs are not readable — the client caches a
spawn's buffs only when it is targeted, and nothing targets a group-mate mid-fight to check. So the
fact "there is a two-minute poison on me" exists *only* where it is suffered, and the character
suffering it is usually a warrior with nothing to cure it with. A healer that tried to discover
afflictions would be a healer target-swapping around the group every few seconds. So the afflicted
character says so, and whoever can answer, answers.

**The counter is the whole model** (`actions/cureTypes.lua`). EverQuest gives every curable
affliction a number of counters of one of four kinds — poison, disease, curse, corruption — and a
cure removes some of them. The affliction carries the counter effect at a *positive* base ("Increase
Disease Counter by 9"); the cure carries the same effect at a *negative* one. That sign is the only
difference between the two, and it is what lets one table answer both halves: what is on somebody,
and what would take it off. No spell name and no heading is consulted, the same standard
`buffTypes.lua` and `Spells.Controls` are held to. It also means **"best" has an exact answer**:
the most counters stripped, read straight off the effect — which is where this departs from
`BuffTypes.Best`, whose "best" is the highest rank of a line. Cure ranks are not reliably in level
order, and an old one-counter cure and a new nine-counter one are the same spell to a level sort.

**The asking** (`curing.lua`, a service, every class). Twice a second the buff and short-duration
windows are walked, one `Spell.CounterType` per occupied slot — "None" for everything a cure cannot
touch, which is nearly every buff on nearly every bar — and only a slot that answers otherwise is
read properly. There is deliberately no character-level gate in front of that walk:
`Me.TotalCounters` is the obvious one and is **a lie on an emu server**, because the client sums it
out of per-buff slot data that EQEmu never sends (`// TODO: implement slot_data stuff`, RoF2
encoder). It reads zero on a character visibly dissolving, so gating on it did not make curing cheap
— it turned curing off everywhere, silently. The rule it leaves behind: **anything read off a
buff's instance rather than its spell is suspect here**; the spell file is local, complete and the
same on every server. Duration is fine — it is what the icon counts down. Anything with **more than
a minute left** is said out loud as `cure <type>`, once, and again every twenty seconds while it
lasts. The minute is the line between "this will keep hurting" and "this is nearly over": a cure has
to be chosen, aimed, cast and land, and a DoT with twenty seconds left will have faded through all
of it. It is read against what is *left*, not the spell's length, so the same three-minute DoT is
worth asking about in its first two minutes and not in its last. Off with `callcure off`; the
fallback channel is bc, like the defend report, because it is machine-to-machine traffic rather than
something the group reads.

**The repetition is load-bearing, not chatter.** It is what keeps the queue honest across everything
no client can see — a cure that fizzled, a curer that zoned, a request that arrived while nobody
could answer. It is also what a request's TTL is measured against: an entry nobody has repeated in
three windows has stopped meaning anything (a **domain TTL on the meaning of an order**, not a
give-up timer — the affliction has gone, or its owner has).

**Keeping a request and casting on one are measured differently**, and the gap between them is what
stops cures landing on people who are already clean. Keeping is a bet that a line went missing, so
it tolerates three silent windows. Casting is a claim about the world *right now*, and the only
character who can make that claim is the one afflicted — who says so every twenty seconds for
exactly as long as it stays true and goes quiet the moment it does not. So a request nobody has
repeated in one window and a half is **held rather than dropped**: it stays queued in case the line
was lost, and one repeat makes it live again. Without that gap the queue happily casts on a
minute-old statement — a DoT that had a minute left when it was said and seconds left when the cure
lands, and then a second cure after it is gone entirely.

**The queue** lives in the service, because "who has said they need a cure" is a fact a curer reads
rather than a state's private bookkeeping — the same relationship every state has with Combat's
engagement. Requests are keyed by *person and kind*, so saying it again refreshes rather than
stacks, and a queue cannot grow for as long as somebody is poisoned. Nothing is queued that this
character cannot answer (`CureTypes.Best` comes back empty), so a warrior hears every request and
holds none. Our own afflictions take a place in the same queue, put there and taken out by the scan
rather than by chat — which is what makes a solo cleric cure itself, and what makes hearing our own
line on an echoing channel a no-op rather than a duplicate.

**The answering** (heal state). One setting, `curing` — Disabled / out of combat / in battle too —
because the second question only means anything when the first is on; two checkboxes would offer a
fourth state that stands for nothing. There is **no slot list**, and that is the point: the person
afflicted has no idea what anybody hearing them can cast, so the answer is discovered rather than
configured. The state walks the whole queue rather than only its head — a cure is aimed at a person,
and holding everybody up for one who is out of range while somebody reachable asks again every
twenty seconds would be a healer doing nothing — but takes the first it *can* cast, so a reachable
queue is still answered oldest first.

**A cure that landed is not a job that is done.** A cure strips a fixed number of counters and an
affliction can carry more than one cast's worth, so the request stays queued and what finishes it is
the counters actually being gone. That is read back off the target's buff cache — which the cure's
own targeting is what populated — with the three answers kept apart: still on them, off them, and
*no way to tell*, which must never be read as the second. An empty cache and a clean bar are
identical from here. Being unable to see is exactly what the repetition from the other end covers,
and a cast budget bounds the case where neither ever resolves.

**That read-back gates the cure itself, not only the drop.** A queue that has been held up — the
asker around a corner, out of range, a fight this character will not cure during — is precisely a
queue full of answers nobody has checked, and a blockage lifting then discharges it as a burst of
cures at people who no longer need them. So a request's bar is read *before* the cast as well as
after, and what makes the reading trustworthy is **having looked at them**, tracked as its own thing
rather than inferred from having cured them. Looking means targeting: another player's bar arrives
in one complete packet when the client targets them and never otherwise. Any target counts — the
cure's own, a heal at the same person, the player clicking them — and crucially **a cast that failed
counts too**, because a cure targets first and checks line of sight second, so somebody behind a
wall is targeted by every attempt and cured by none. Hanging it off successful casts is exactly what
let that queue build up. The stamp waits for the cache to have something in it, since the buff
packet follows the target by a round trip and that gap would otherwise read as a clean bar.

A look is believed for one ask window. The client **counts the snapshot down by itself** — an entry
whose duration runs out is dropped without re-targeting — so a look stays exactly right about an
affliction *ending*, which is the question, and can only go wrong about one *arriving* since. That
is why it is trusted at all and the only reason it expires; being wrong costs one refused cure and
then a cast that re-targets them and settles it.

### Rezzing (`rezzing.lua` + `actions/rezzes.lua`)

The third job riding in the heal state, and it is here for the reason curing is: a rez is a gem and
a large piece of the mana bar, so choosing to spend them on a corpse is choosing not to heal with
them, and that choice belongs where the healing is arbitrated. `rezzing.lua` is the choosing;
HealState is the hands. Not to be confused with `rez.lua`, which is the *other* end of the same
event — that one takes the resurrection somebody offers us.

**Everything is discovered, and everything is overridable.** The discovery is what makes it work on
a character nobody configured; the overrides are because a group that knows which rez it wants spent,
and on whom, should not have to argue with a heuristic. Three settings, all on the page's Rezzes tab
plus the `rezzing` switch: **when** (`off` / `on` / `combat`, the same three answers in the same
words the cure mode takes, defaulting to out-of-combat for the same reason), **which rez** (two
pickers, below), and **who first** (the class order, below).

**A rez is the one beneficial cast aimed at a corpse**, and both halves of what makes one worth
choosing are numbers sitting in the data: `SPA_RESURRECT` (81) carries the percentage of the lost
experience it hands back in its base value, and the cast time says whether it could survive a fight.
So `actions/rezzes.lua` is every corpse-aimed cast in the book and the AA list carrying that effect,
ordered by experience returned with a shorter cast breaking ties. The corpse-aimed read is asked
first and costs one member per spell, which is what keeps a refresh off the effect slots of the other
seven hundred — and it is also what tells a rez from Summon Corpse, which aims at a corpse, is
routed through the same server call, and brings nobody back.

**Two rez settings, not one, because it is not one question.** Out of a fight the only thing that
matters is the experience handed back; in one it is whether the cast bar survives at all. A cleric
owning both a ten second Resurrection and an instant AA wants each of them in its own circumstance,
and no single dial says that. Each setting defaults to the worked-out answer — *best I have* out of
a fight, *quickest I have* in one — and either can name a spell instead. A name this character does
not own falls back to the worked-out answer rather than casting nothing, since a settings file
written on the cleric and read on the druid should not silently stop rezzing, and both `/cheal` and
the page call the missing name out.

**One rez is chosen for the pass, and waited for rather than substituted.** If it is a few seconds
from ready, that is what standing over a corpse is for: quietly dropping to a weaker rank to save the
wait would spend the group's experience to buy nothing, and a corpse is not in a hurry.

**Group members' corpses, plus whoever asked.** The corpse is found by name — `<name>'s corpse`, the
same reading CorpseState makes of its own, with the apostrophe telling `Cabby` from `Cabbyx` —
searched per group member out to 100 with a plain `corpse` search rather than `pccorpse`, for the
reason CorpseState gives (MQ tells a player corpse from an NPC one by whether the spawn carries a
deity, and there is no promise this server sends one). It walks nobody anywhere. The real range check
is the casting service's, measured against the corpse, so one behind a wall is stepped over rather
than started and refused.

**Who first is an ordered class list**, and it is one list read twice, the way the heal slots are one
list read for several things: where a class sits is who is gone to first, and its flag is whether a
fight is *interrupted* for them.

**The flag is about when, never about whether.** There is deliberately no "rez this class at all"
switch — a corpse left lying there forever is not a setting anybody reached for, and `rezzing off`
already answers it for the whole character. So every class on the list is rezzed once the fighting
stops, and the flag buys the judgment that actually differs between the two situations: out of a
fight a rez costs time nobody is using, during one it costs a cast somebody alive may need, so a
group that will break off for its cleric and nobody else says exactly that by clearing the rest. All
on to start with, since rezzing in battle is already behind its own mode switch and already waits for
everybody alive — the column narrows, it is not a second opt-in. Which is also why the tank rules
above it cannot be undercut by a class nobody thought to tick: out of a fight the list gates nothing,
and in one the tank's own row is the only thing that would.

The order ships with an opinion rather than blank — whoever can put the rest of the group back on its
feet leads it (CLR, DRU, SHM, PAL, NEC), then the people the fight cannot restart without, then
everybody else. The whole list is repaired rather than trusted on load, because it is sixteen rows of
hand-editable config deciding who gets picked up mid-fight: known rows keep their order, junk and
duplicates go, any class missing is appended switched on (which is also how a list written by an
older version picks up a class it never knew about), and a row carrying the `enabled` spelling this
flag had before it was about *when* is read as the same flag. That read is spelled out rather than
written with `and`/`or`, which cannot express it: `written ~= nil and written or fallback` hands back
the fallback whenever `written` is *false* — which is precisely the value being asked about, so a
class deliberately switched off would come back on.

The full order is: whoever asked, then the main tank while that switch is on (the role is the job, not
the class holding it), then the class list, then whoever is nearest — a tie-break and never a reason,
broken finally by spawn id so the list cannot reshuffle between passes.

**The class comes off the corpse, not the group window.** `Group.Member` has no `Class` member at all
— only its `Spawn` does, and a member who released to bind is standing in another zone with no spawn
here, which is precisely the corpse this is most often asked about. The corpse always knows: the
server builds one from the client it came off and copies the class straight across (`Corpse::Corpse`,
passing `c->GetClass()`), and MQ reads `Spawn.Class` off a corpse like any other spawn. It also
answers for somebody outside the group, which the group window could never do. A corpse that will not
name a class ranks last and is still rezzed — a failed read is not a reason to leave somebody there.

**The scan is cached; the judgment is not.** Finding corpses is a spawn search per group member and
is paced at a second; deciding what to do about them is reading a few settings and happens every
pass. Keeping them apart is load-bearing rather than tidy — a class switched off, a class moved up
the order, the tank switch flipped are all decisions the user just made on the page, and baking them
into the cached reading meant every one of them went on being ignored until the next scan. It is also
what makes the in-fight flag honest: whether it applies at all is decided by whether there is a fight
on right now, so a pull narrows the list to whoever is worth breaking off for on the pass it happens
rather than up to a second later. That is the "decide every pass" rule with only the expensive half
cached, the same shape the heal state reads the group's health in.

**A rez waits for the living, with one exception.** Nothing is cast at a corpse while somebody this
state *would* heal is below the emergency point — the same guard curing is held to, asked the same
careful way. The exception is the **tank's** corpse with a rez that has *no cast bar at all*: that
spends a global cooldown, which is what a heal would have spent anyway, and hands the group back the
person it is built around, so holding it for a second person at 30% is a trade nobody wants made for
them. Anything with a cast bar spends seconds that person needs, however short it is, so the line is
drawn at zero rather than at a number somebody has to choose — it is a property of the spell, it
cannot be set wrong, and it is exactly the battle-rez AA this is for. (There *was* a "longest cast to
start in a fight" dial doing this job and choosing the in-fight rez as well; it was removed as
confusing, and both of its jobs are now said outright.) The exemption is carried on the pick rather
than recomputed, so a rez allowed to start in front of an emergency is not thrown away by the next
pass for the very reason it was allowed.

**A rez is an offer, and the world will not say whether it was taken.** This is the one place
rezzing needs memory. The server hands the corpse's owner a box (or a `Resurrect` line on their
respawn window) and nothing comes back to the caster either way; the corpse does not go away when
the offer is accepted, since its owner still has to loot it; and casting at a corpse that has already
been rezzed is not even refused — `Corpse::CastRezz` re-sends the request with the experience zeroed.
So a corpse this character has cast at is left alone for half a minute (a person noticing a box, with
room to spare; a cabby on the far end answers in half a second), and after three unanswered offers it
is left alone entirely. That bound is the same shape as curing's cast budget and exists for the same
reason: the ordinary end of an offer is somebody accepting it, and nothing here can see that happen,
so without one a linkdead corpse is cast at until the world intervenes. It is not a give-up on the
person — `rezme` clears it and starts again, which is somebody saying they are at the keyboard to
answer this time. A cast that was *refused* is a three second backoff instead, not counted against
the budget, because a cast that never happened put nothing on anybody.

**Orders remember the person, not the corpse.** `rezme` and `reznow <id | name>` reach somebody
outside the group and put them ahead of everybody in it. What is stored is the character's name,
which is what a corpse carries — and that is what makes an order worth giving at all, since the
corpse is very often not in reach when it is spoken, so it is looked for every pass until it is. An
order does not override the `rezzing` setting: a character with rezzing off, or set to stay out of
fights, answers back rather than taking it on and expiring in silence. `rezme` takes no spawn search,
unlike `healme`, because the character it is *for* is exactly the one a search would fail on — one
who released and is standing at a bind point in another zone while their corpse lies here. An order
nobody could act on within a minute is dropped; the last look at the ground is invalidated whenever
the order changes, since the order is what put a non-group corpse in it.

Everything held — the offers, the order, the last look — is dropped on a zone line, where spawn ids
stop meaning anything.

**A rez put in a heal slot is recognised and refused**, rather than treated as an ordinary
single-target heal: `NeedsTarget` is true for one exactly as it is for a Complete Heal, so before
this the first slot holding one would have been chosen for whoever was worst off and cast at a living
person. The aims model gained a `corpse` answer, `appliesTo` refuses it for everybody, and the page
says what the slot is and where rezzing actually lives. That is the same failure the pet aim exists
to prevent, one target type over.

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
lasts, and a slot whose spell has *no* duration is not a buff at all: the picker narrows to buff
headings, but the game's filing is not a promise and the narrowing can be switched off, so a heal
ending up in a buff list is a mistake worth catching rather than one worth casting on a loop. The
page says so on the row.

**Three questions decide every pairing**, cheapest first:

1. **Is it on them, and how long has it got?** `Me.Buff[x].Duration` (or `Me.Song` — a short
   buff sits in the song window and is no less on us for it) for ourselves,
   `Me.Pet.BuffDuration[x]` for the pet, `Spawn[id].CachedBuff[x].Duration` for anybody else —
   all three in milliseconds. Under the slot's own `buff_rebuff_secs` (default three minutes,
   set on the row), it is worth recasting; over, it is not. Per slot because a two-hour buff and
   a ten-minute one have nothing in common about "nearly gone", and clamped to half of what the
   buff actually lasts, so a buff shorter than the headroom is not recast the moment it lands.
   The escape hatch for anything more specific is the slot's own Lua expression, as it is
   everywhere else.
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
   seconds after one fails. It is not a give-up timer, and a record is dropped the moment the
   world contradicts it rather than waited out. Dying strips every buff at once, so an observed
   death — the scan seeing a member down, `Me.State` reading DEAD/HOVER, or the world's slain
   line arriving mid-fight, when the scan cannot look — voids every window held for that name,
   and they are rebuffed the moment they are back on their feet. Ourselves and our pet, who can
   be read back, only ever get a short window (the hand-removal grace), after which the buff
   itself is consulted again. And everybody else is *verified* about once a minute while there is
   nothing to cast: the state borrows the target long enough for the server to send what is
   actually on them (a status re-checked each pass — never a held frame, called off by a fight,
   timing out inconclusive after a second), squares every window against the answer, and puts the
   target back. Borrowing means *changing* the target, including looking away first when it is
   already on them: the client asks the server for a bar when the target changes and at no other
   time, so a swap that is not a swap sends nothing and the reading never moves. Only for somebody in line of sight and inside the reach
   of a spell whose window is live — the reach read off the spell (`MyRange`/`Range`/`AERange`),
   the same way the cast checks it. Borrowing the player's target is an intrusion, and the answer
   buys nothing when the recast it might call for would be refused for range or sight anyway; the
   skipped keep their unread mark, so they are read on walking back into reach rather than a
   minute later. All of it is dropped wholesale by `/cbuff refresh` or
   the Check Everybody Now button. A cached entry ages by itself (it reports what is left *now*),
   so a stale cache decays into "they need it" rather than lying about it.

4. **Did it actually land?** A cast aimed at one person is not believed until the buff has been
   *seen* on them (`startConfirm`/`progressConfirm`). The casting service reports a cast the client
   stopped showing as a success, and the client is not the authority on that: a fizzle is rolled at
   the server's end and its line can arrive after the cast has already been called a success — for
   a buff, the one mistake nothing else catches, since the person is crossed off and nothing asks
   about them again until a buff that was never cast would have run out. So the state looks. Three
   answers: **seen** (it landed, and what is really left on it replaces the estimate in the
   window), **a fresh reading without it** (it did not land, so the caller retries — a request at
   the same person, the upkeep list on its five-second failure window), and **no fresh reading at
   all** (the world said nothing, so the cast's own account stands, which is what happened before
   any of this existed). What makes this a *look* rather than a watch is that the buff landing on
   somebody already targeted is never seen: the reading held is the snapshot taken when the cast
   targeted them, from before it was fired, and the partial update carrying the new buff is
   discarded by MQ on purpose — so freshness is read off the cache entries' own timestamps
   (`CachedBuff.Staleness`) and a newer reading has to be provoked by looking away and back. Two
   things are deliberately never confirmed: a cast that already reported failure (it is about to be
   retried anyway, and a target swap between the failure and the retry buys nothing), and anything
   landing in the song window, which cannot be read on anybody else at any price — the client sends
   songs down with the rest of a target's bar and the reader throws that part away, so confirming
   one would fail every bard song ever cast. A pairing whose sighting has contradicted a cast is
   taken at the cast's word again for five minutes, a backstop against anything else that turns out
   to land invisibly.

The order things are decided in, every pass that looks:

1. **Reasons to hold.** Not during a fight (`in_combat`, off by default — buffing mid-fight spends
   the mana the healing wants and holds the target away from what is being fought; a fight starting
   also calls off the buff in the air), and not while running. The second is a choice rather than a
   necessity: the casting service would happily wait to stand still, but it would wait holding a
   target and a gem, and a state at the bottom of the chain can afford to ask again later. Bards
   are exempt, since they sing on the move and the casting service knows it.
2. **Anything somebody asked for by name** — see Requests below.
3. **The first slot somebody is missing.** List order is the whole priority — unlike healing there
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

### Requests — `buff <type>` (`actions/buffTypes.lua`)

The other kind of buffing, and the opposite question to everything above. A slot says *keep this on
these people forever* and is answered from configuration; a request says *hand me one of these,
now* and is answered from the book. `buff invis` reaches a group of six and the two characters with
an invisibility spell cast it on whoever asked; the other four say nothing at all.

**A type is defined by the effect its spells carry, never by a name or a heading** — the same
standard the mez list is held to, for the same reasons. `invis` is `SPA_INVISIBILITY` (12), `sow` is
`SPA_MOVEMENT_RATE` (3) *with a positive base* (a negative one is a snare), `haste` is SPA 11 **or
98**, the bard-only effect a haste read would otherwise miss a whole class over. That is what lets
one typed word land on whichever of Invisibility, Superior Camouflage or Improved Invisibility each
character hearing it happens to own. The catalogue is data: a type nobody has asked for yet is one
row, and it holds the buffs people shout for (invis/ivu/iva, seeinvis, lev, sow, eb, haste, ds, hp,
regen, mana, rune, shrink, vision, resists) rather than the stat lines, which are upkeep and belong
in the slot list. Names are matched with case and punctuation dropped, so `See-Invis` and
`see invis` are `seeinvis`, and each type carries aliases — including the short ones people
actually type: `si` for seeinvis, `c` for mana (the Clarity line, which is SPA 15 over a duration:
an instant mana gift carries the same effect with no duration and is dropped, and a bigger mana
*pool* is SPA 97 and a different buff), `uv` for vision, `camo`, `kei`, `stoneskin`.

**Best means the highest rank of the line**, read out of `Spells.beneficial` — which is sorted
level-first, so the first match wins — rather than out of the buff list, because that list narrows
by heading and shrink and enduring breath are filed elsewhere. The narrowing buys nothing when the
effect match is exact, and the duration check does the job the heading was really doing: what
separates a buff from a heal is that a buff lasts. Self-only and pet-only spells are never chosen —
neither can be handed to anybody, and both are already upkeep.

**Where a single-target spell is used, the caster is cast on last.** This is the ordering, not a
nicety: casting drops invisibility, so a character that invises itself first has nothing left to
hand out and would have to re-cast on itself afterwards — a cast spent undoing a cast. It costs
nothing for the buffs that do not work that way, so it is unconditional. Whoever asked comes first
(they are usually not in the group at all — that is what a buff bot is), then the group window's
order, then this character.

`buff group <type>` prefers a group version when there is one — one gem timer for six people, cast
at nobody — and falls back to one at a time when there is not. Going the other way, a request for
one person uses the group spell only when they are actually in this character's group, since that
is the only case where it reaches them.

**Whoever asked has to be standing here, and that is as true of `group` as it is of one name.**
Every other request in the family resolves the speaker to a spawn in this zone and declines when it
cannot, and `group` used to be the exception: the line reaches every character, so one parked
somewhere else would take it and cast on whoever happened to be around *it* — a group version lands
on the group members in the caster's zone, not on the people the line was said to, and the
one-at-a-time fallback walks its own local half of a split group. Out-of-zone group members were
already dropped from that list (they have no spawn to cast at); this is the same fact one level up.
A character elsewhere now says nothing rather than complaining, unlike the single-name case: the
line went to everybody, the characters in the zone are answering it, and a request that was never
this character's to take is not an error worth six copies of.

**Nothing is remembered afterwards.** A request leaves no rebuff window and no verification mark: it
is a buff handed over, not a record of what is on anybody, and the upkeep reading squares it with
the world on its own schedule.

**A failed cast is tried again, and the cast's status is the whole of the reading.** The casting
service reports a landed cast as `succeeded` and refines it afterwards if it turned out to be
resisted or unnecessary — so `succeeded` means the spell went off and there is nothing more to do at
that person, since casting again would have the same no effect. `failed` means the opposite: a
fizzle or an interrupt spent the mana and lost it, a refusal never left the ground, and in every one
of those the buff is not on them. This is the one case the service deliberately leaves to the caller
— it will not retry a cast that was *spent*, and says so, because only the caller knows whether
casting again is still right — and for an order somebody typed it is, since the commonest failure is
a fizzle, which is chance and says nothing about the next one. Bounded at four tries against the
name at the front of the queue, three seconds apart so the retry is not spent on the recast the
fizzle just started; past that the name is dropped with the reason said out loud, because one person
behind a wall must not hold up everybody queued behind them.

(This was a real defect, not a hypothetical: the first version moved on after any non-success, so a
single fizzle on the last name — the caster's own — meant the character that answered the request
was the one that ended up without the buff.)

(And a second one underneath it, 2026-07: none of the above ran for the case it was written for,
because the casting service was reporting fizzles as successes. Our cast bar closes before the
server's does, so the line saying the spell fizzled arrived after the cast had already been called a
landed one — and a buff believed landed is not asked about again for the length of its duration. The
fix was the verdict window in `CastTask`, at the service that owns the fact; nothing in this state
changed, because the reading here was right all along. Same shape as the warrior sitting down
mid-fight: when a state misbehaves on a signal, audit the signal first.)

A cast *we* called off (a fight starting mid-order) is not a failure at all: it costs no attempt and
keeps its place until the holding stops. A target who has zoned or died is dropped where they stand,
which is what finishes an order without a timer. Asking twice replaces the queued order rather than
stacking a second one.

**The registered phrase is `"buff "`, with the trailing space, and that is load-bearing.** A phrase
goes into the channel pattern as literal text (`<#1#> buff #2#`), and a bare `buff` would therefore
also fire on `buffme`, `buffgroup`, `buffing off` and every other switch in this family — which is
exactly why the order command is called `buffnow`. The space is text those lines do not contain and
every `buff <type>` line does, since a type has to follow it. Everything downstream reads a phrase
as `Split(...)[1]`, so the space never leaves the registration: `/chelp buff`, `/cself buff invis`
and a hotbar button all see `buff`.

`/cbuff` reports what it is doing, what has been asked for and how many buffs each person is missing
(worked out on demand; it is a whole pass over the list per person). `/cbuff off` calls off the buff
in progress and every outstanding request, `/cbuff refresh` forgets what was worked out about who
has what.

## Pet setup state (`states/petSetupState.lua`)

Keeping the pet: summoning it, conjuring what it should be holding, and handing that over. One job
in three steps, and the order between them is most of the logic — there is nothing to conjure a
weapon for while there is no pet, and nothing to hand one to that is about to be replaced. So each
pass asks *is there a pet*, then *has this pet been given what the list says*, and starts at most
one thing.

**A charmed pet is not a pet this state keeps.** There is nothing to summon while one is standing
there — the client allows one pet and the charm *is* that pet — and nothing is conjured for it or
handed to it, because what a charmed mob is given leaves with it the moment the charm breaks. So the
gear list is walked only for pets this character made, and `gearpet` answers with why rather than
going quiet. `pet.lua` is what says the pet is charmed (see Pet dps state); using one is that
state's half.

**Two ordered lists, and almost nothing configured.** The pet list is what summons a pet, first
ready one wins, so its order is which pet this character would rather have and its Enabled switches
are how a magician picks today's elemental without deleting the others. The gear list is what gets
conjured and handed over, in order. What each slot *is* comes off the spell's own effects rather
than off a heading or a setting: a pet slot summons a pet because the spell carries the effect that
does (`SPA_SUMMON_PET` and the four related lines, never the swarm effect — a swarm is several pets
for a few seconds, which is a rotation slot), and a gear slot conjures an item because the spell
carries `SPA_CREATE_ITEM`, whose base value *is the item's id*. So nothing has to be told which item
a spell makes, and the pickers on the page are narrowed by the same reading (`spells.lua` holds
both, beside the category-based lists the other states use). The one dial a gear slot carries is
how many of that item the pet should end up with — one for a hand, two for a pet that dual wields —
because no spell can answer that.

**What a pet has been handed is remembered, because nothing else can say.** A pet's inventory is
not readable; the client will say what it is *wielding* (the weapon models in its equipment slots)
and nothing more. So the record of what we handed to *this* pet is the only answer there is, and it
is the "progress through a procedure the world cannot describe" the base state's contract allows.
It is kept honest the only way such a record can be: it belongs to one pet by spawn id, and a pet
that is replaced takes it with it — the new one is kitted out from nothing, without anything
needing to be cleared.

**A pet we did not summon is left as we found it**, and there are two of those with two different
answers. The pet standing here **when the script started** is left alone outright, hands unread: it
may have been fighting all evening with everything it is owed, nothing in the client can say
(`Equipment` is a weapon model, silent about anything a pet does not wield), and re-arming one on
every reload is a bar of mana and a pair of daggers spent on a pet that had them already — which is
what a crash, a `/lua restart` or an evening of reloads used to cost. A pet that turns up unsummoned
**while we are watching** is one the player just cast by hand, so it is plainly new and the hands
are worth reading: wielding something it is left alone, since a second weapon into a full pair of
hands is mana spent for nothing; holding nothing at all it is kitted out. `gearpet` (and the page's
button) overrules either way of being wrong and hands over the whole list again, which is also how
the record is reset deliberately.

**Nothing is cast more than the pet is owed.** A summon that lands and produces no item is the one
failure a retry cannot fix, so the count of casts made for a slot is bounded by the count of items
that pet should end up with. A failed cast or a refused hand-off is paced by the usual five second
window instead; the row and `/cpet` say which of the two happened.

**Why a slot did not fire is kept per slot**, and it is two different questions. What is wrong with
the slot as configured — a spell that summons nothing — is read off the spell and shown on the row.
What the *world* said the last time it was tried is remembered from the attempt itself and shown
the same way, because that is the half no amount of reading can predict: no mana, no line of sight,
and above all **a missing component**. Most pet spells eat one every cast (malachite for a
magician's elementals, a bone chip for the undead lines), the casting service refuses a cast whose
reagents are not in the bags — matching the server, which enforces the same thing unless
`Character:PetsUseReagents` is turned off — and a page where everything looks configured and
nothing happens is exactly what that refusal used to look like. The component is named rather than
numbered (see Casting), which is the difference between a puzzle and a trip to a vendor.

Three things hold everything: being dead, a fight (`petsetupcombat`, off by default — a summon is a
long cast and a bar of mana, and an item cannot be handed to a pet that is off fighting), and moving. A
fight starting also calls off the cast or the hand-off in the air. Like buffing, this state gets its
frames because follow yields the moment it has caught up; unlike buffing it sits one band above, at
`Priorities.buff - 1`, so a pet buff is never cast on a pet that is about to be replaced.

**A pet that vanished gets a moment before it is replaced.** The world does not say whether it died
or was let go, and re-summoning on the next frame would undo `/pet get lost` before the player had
finished typing it — the same courtesy the rest state pays a stand it did not order. Five seconds,
because the common case is a pet that died; anybody who means to play without one has the
`petsummoning` switch, and `summonpet` is the order that skips both the grace and the switch.

Handing an item over is not this state's own work: `utils/Giving` owns that sequence and runs it on
the service pulse (see Giving). The state asks for one hand-off and polls it, and holds the frame
while it runs — the sequence owns the target and the cursor, and anything below that targets
somebody else would take them out from under it.

**`petgear` is the same work for somebody else's pet.** Every other class's pet arrives bare and a
magician is the one carrying the spell that fixes it, so the group says `petgear` and whoever has a
gear list walks it once for the asker's pet: same list, same per-slot counts, same conjure-then-hand
sequence, and a record of the same shape keyed to that pet's spawn id. It is a **request** and not a
switch — it ends when there is nothing left to hand over and forgets the pet, because arming
somebody's warder is a favour asked for once rather than a standing arrangement with every pet in
the group — and a character with **nothing on its gear list says nothing at all**, which is what
keeps one spoken line from being six characters all answering. The asker's pet is found through
their spawn (`Spawn.Pet`), so the only thing they have to do is stand next to the magician; being
out of reach is the giving service's own report.

That name is the one deliberate exception to the prefix rule below: `petgear` sits inside
`petgearing` and therefore hears every line that switch does. It is the word a group would actually
say, so the collision is handled in the handler instead — a line whose next character is not a
space (`petgearing off` arrives as this phrase plus `ing off`) is somebody else's command and is
dropped. That works only because this one takes no arguments; a command that did could not be named
this way.

`petkeeping`, `petsummoning`, `petgearing` and `petsetupcombat` are the switches, `summonpet`,
`gearpet` and `petgear` the orders, `petaction` switches slots on either list, and `/cpet` reports
what the pet has been given (`/cpet off`, `/cpet gear`, `/cpet summon` as well). The names are the
ones this state had when it was the only pet state; `petsetupcombat` is the one that changed, because
"pet" and "combat" in one word now reads like the other state's master switch and is not it.

**An order does not go stale while the state is held.** The TTLs on `summonpet`, `gearpet` and
`petgear` mean "this ask has stopped meaning anything", and being in a fight for twenty seconds is
not that — so their clocks only run across the passes where the work could have been started.
Without it a `gearpet` said as a fight starts is dropped in silence and the first pass afterwards
reports it as finished having done nothing.

What it deliberately leaves out: telling the pet what to do. That is PetDpsState, below.

## Pet dps state (`states/petDpsState.lua`)

The other half of a pet, and the half that belongs in the fight: sending it at what this character
is fighting — or at what is fighting *us*, if that is the job it has been given — calling it back
when the fight ends, and keeping the four switches the client holds for a pet where the page says
they should be.

**Two states rather than one, because they are two bands.** Keeping a pet is a long cast and a
hand-off that needs it standing next to us, which is work for the gaps between fights at
`buff - 1`; using one is four words said inside a fight, and a word that waits for the rotation to
finish is a pet arriving after the mob has picked somebody. So this registers at
`Priorities.dps - 2`, above SpellDpsState for the same reason SpellDpsState is above MeleeState:
the melee state reports busy for the whole fight, so anything below it is starved, and a state
above it costs one frame on the pass where it actually says something.

**Not every pet is listening, and which one this is gets read before anything is said.** Three of
these words go to a pet that hears them; an enchanter's *animation* hears none of them. It is a pet
in every other way — it fights, it follows, the client keeps a pet window and the four switches for
it — but the pet commands are not among the things it answers to, and the only thing that changes
that is `Animation Empathy`, the alternate ability whose whole purpose is buying an enchanter the
right to talk to one. Its ranks say which words: guard and follow at one (neither of which this
script ever says), attack at two, back off and the toggles at three. A **charmed** pet is the
opposite — a mob held by a spell, and an ordinary pet as far as the commands go — which is what
makes an enchanter with one a character this state can fight with in full.

`pet.lua` answers both questions and nothing downstream carries a second copy of them:

- **What kind of pet it is** is one reading and one fact about the character, in that order. A charm
  effect (`SPA_CHARM`, read off the pet's own buffs — the client shows a *pet's* buffs in full,
  which it will not do for anything else in the zone) says charmed whatever class we are; everything
  else is ours, and an enchanter's own pet is an animation because nobody else summons one. The
  reading comes first because it is the one that can be wrong in the direction that matters: an
  enchanter's charmed pet mistaken for an animation is a pet this script would refuse to fight with.
- **It is asked once per pet and then remembered**, because a pet cannot change kind — a charm that
  breaks does not leave a summoned pet behind, it leaves no pet at all, and the id goes with it. The
  answer is keyed by spawn id and dies with the pet. A new pet is given a moment for the client to
  fill its buff list in before "nothing is holding it" is written down; during that moment the
  answer is the one a pet of ours would have, so nothing waits on it.
- **Nothing is concluded from silence.** There is no counting of orders that went unanswered and no
  window after which a pet is written off as deaf. Refusals here are not observed, they are read:
  what kind of pet this is, and what this character has bought the right to say to one.

So this state simply never says what cannot be heard — no order, no flip, no peel worked out for a
pet that cannot be sent anywhere — and the page and `/cpetdps` say which pet it is and what is
missing rather than showing four dials that do nothing. The same read gates the flee state's
`/pet back off`, and the setup state uses the charmed half of it (a charmed pet is never geared).

**It decides nothing about what is fought.** `cabby.combat` holds the engagement, so `attack <id>`,
the tank's assist call and auto-engage move the pet exactly as they move the swing — this state
adds only the pet's side of it. Every pass reads three things: who the pet is, what Combat is on,
and what the pet is on. Nothing else is held.

**The pet is sent by id.** `/pet attack <spawnid>` is MacroQuest's own extension of the client
command (`MQCommands.cpp`, `PetCmd`), which is why nothing here touches the client's target — the
client's own `/pet attack` sends the pet at whatever *we* are looking at, so without the id this
state would have to snap the target first and would fight the heal state for it. The order is
repeated every second and a half for as long as the pet is not on what the fight is on, which is
also what re-sends it at the successor mob of a fight without anything having to notice a
successor. No count, no window after which it stops asking.

**It only calls the pet off what this fight put it on.** The one number held between passes is the
mob the fight last put the pet on, and it is dropped the moment the pet is not on it. A pet that
has moved to something else picked that up for itself — an add on the healer, something that turned
on the pet — and calling it off *that* is calling it off a fight nobody else is having. A pet that
went in on its own on the mob Combat is on is adopted, since that is this fight whoever started it,
and it is called off with the rest of it. `/pet back off` is repeated on the same pacing until the
world shows it took.

**The one dial about this fight is `send in below %`**, the pet's version of the rotation's `start
below %` and the same aggro management: a pet in before the tank has a hold of the mob is a pet
with the mob on it. It ships at 100 — in as soon as there is a fight, which is what the classes
that carry a pet expect — and an order (the page's button, `/cpetdps in`) outranks it. It answers
one question — when to join a fight the group is having — so anything that is not that question
skips it: an order, and a mob already beating on us, which has no aggro left to manage.

**The job dial says what the pet is *for*.** It ships as **fight what we fight**, which is all of
the above and is what a pet has always done here. Set to **protect me first**, one thing outranks
the fight: a mob actually coming for this character is taken off it. That is a setting rather than
something this state works out, because it is a trade nobody else can make — a pet peeling adds is a
pet not killing what the group is killing, and a magician stood in the open wants that trade where a
beastlord in melee beside a tank usually does not.

The whole cycle is `Combat.GetUnderAttackIds` read fresh every pass, and nothing else:

- **What is on us** is the extended target window's `Auto Hater` entries at 100% aggro — the client
  saying "this one is coming for *you*", the same reading the `defend` report is built on.
- **A peel is done when the mob leaves that list**, because a mob the pet has pulled off us is one
  we are no longer most hated by. There is no timer, no "did it work" window and no record of what
  was peeled: the world stops saying it, and the pet is free on the next pass.
- **Then the next one on us, or back to the fight.** Which is chosen is three rules, all about not
  making things worse: the one the pet already has while it is still on us (moving a pet between two
  mobs that are both on us throws away the aggro it just built and leaves us holding both); anything
  the group is *not* already on, first (the mob nobody else is answering is what a pet is worth);
  and what the fight is on only if that is all that is on us — then the pet is already there and the
  peel is the taunt.
- **It does not wait on there being a fight.** With `autoengage` off a beating is a beating nobody
  agreed to, and the pet is the answer to it this state has.

While the pet is peeling, **the job outranks the dials on two switches**: taunt on, because taunt is
the only thing a pet does that takes a mob off somebody and a peel that will not hold what it takes
is a mob walking straight back to us; and focus off, because focus is a standing order to stay on
what it was sent at and ignore everything else, which is precisely the switching this job is made
of. Hold and greater hold are deliberately untouched — they gate what a pet picks up *unbidden* and
every target in this job is bidden, so flipping them would be flipping a switch for a reason this
state cannot name. A switch the player set to "leave alone" is **borrowed, not taken**: where it
stood is written down and put back when the peel ends, because otherwise "leave alone" would quietly
mean "leave alone until the first add" — a switch changed once and never changed back is how you
break somebody's pet without them ever seeing it happen. A dial that has an opinion of its own needs
no loan: it restores the switch itself.

**The four switches are dials, not checkboxes.** Taunt, hold, greater hold and focus are kept by
the client per *pet*, which means a new pet arrives with all four off whatever the last one was
set to — so they cannot be set once and forgotten, and something has to keep putting them back.
Each ships as "leave alone", which is this script having no opinion rather than an opinion that the
switch should be off. On or off is a standing order: the state reads where the switch stands, flips
it if it disagrees, and reads back again. It flips rather than sets because this client's pet
command list (`ePetCommandType` in eqlib) carries only the toggle forms — there is no way to *say*
"taunt off", which makes the read the only way to know anything. A switch flipped by hand after
having stood where it was asked to gets fifteen seconds before the dial wins again: the grace the
doctrine pays a deliberate act, not a surrender.

**Taunt has a fourth position, because it is the one of the four whose right answer is not a
setting.** Hold, greater hold and focus are a player's standing preference about how their pet
fights. Taunt is a question about the group — *is anybody else holding what the pet is on* — and it
changes inside one fight: the add the pet was sent to hold becomes the tank's the moment the tank
picks it up, which cabby's own `defend` machinery exists to make happen. So the dial offers
**Automatic**, answered every pass from two facts and nothing else:

- **No main tank in the group → on.** Nobody else is holding anything, so the pet holds what it has.
  This is the duo and the solo pull, where the pet *is* the tank.
- **A main tank on what the pet is on → off.** A taunting pet standing next to a warrior is a pet
  pulling the mob off the character built to hold it.
- **A main tank on something else → on.** The pet is on its own mob — an add, a second pull — and
  the alternative is handing that mob to whoever is softest, usually the character whose pet it is.
- **A main tank whose target cannot be seen → off.** `Combat.GetTankTargetId` returning nil is
  "nobody here can say", and the two ways of being wrong cost differently: ripping a mob off a
  warrior is how a group wipes, while a pet that fails to hold an add is what the defend report and
  the tank's own pickup already answer.

What the pet is on is read first and what Combat is on second, because taunt decides the first swing
as much as the tenth and a pet held back by the health dial is one pass from being sent. Mid-fight
with neither readable — the beat between two mobs — the **last answer stands** rather than falling
back to the resting one: taunt off between two mobs of one fight and on again afterwards is two
commands that changed nothing. And when the automatic answer *moves*, the marks that make a
disagreement "somebody's hand" are dropped with it, or a switch that agreed with "off" and now wants
"on" would read as a deliberate flip and sit out its fifteen seconds — a pet not taunting the add it
was just sent to hold. Everything else is unchanged: the answer is enforced by the same read, the
same flip and the same hand grace as a dial set by hand, and it ships as "leave alone" like the rest.
The position is offered only for switches an answer exists for (`PetDpsStateConfig.autoSwitches`),
and a stored `auto` on any other switch reads as "leave alone" rather than as something to act on.

`petattack` is the switch — off calls the pet off and stops sending it, which is also how to get a
pet back mid-fight without calling the fight off — and `/cpetdps` reports what the pet is on, what
its job is, where each switch stands, and takes `in`, `on`, `off` and `job fight|protect`.

Two silences are deliberate. There is **no action list**: a pet is not a rotation, and the pet AAs
and discs a class fires at a fight are ordinary damage the spell dps rotation already casts. And
nothing here reacts to the pet's *health* — keeping it alive is healing, and the heal state does it
with `healpets`.

**Fleeing is the one case this state cannot cover.** `flee` is busy at the passive band, so the
whole dps band is starved and the pet would keep chewing on what the group is running from. So the
flee state drops the pet the same way and for the same reason it drops auto attack: read
`Pet.IsFighting()` every pass, say `/pet back off` when it is true, pace it at a second and a half.
The verbs and the reads both come from `pet.lua`, so the two states are not carrying separate
ideas of what the client answers to.

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

## Corpse state (`states/corpseState.lua`)

The other half of looting: getting *our own gear* back off the ground after a death. `lootcorpse`
said to a group of characters standing on their own corpses, and every one of them empties its own.

**It does nothing until it is told to.** There is no habit here, nothing watching for deaths and
nothing that happens on its own — looting is the one job where acting unasked is how a script loots
the wrong corpse. And the order is a *job*, not a mode: every corpse of ours in reach is emptied,
one after another, and when there is none left the order is over. `lootcorpse` again is how it
happens again; `lootcorpse off` calls it off.

**It walks nowhere.** Only corpses within **50** are looted, which is "we are standing on the pile"
with room for a group spread around it. Getting the group back to where it died is the player's job
today — a corpse-*walk* state is the neighbour still missing (see ROADMAP) — so "there is nothing of
mine lying here" is answered the moment the order is given, on the channel it was given on, rather
than left to stand as a silent nothing.

**The corpse comes the rest of the way itself.** Each one is targeted (`/mqtarget id`), pulled to
our feet (`/corpse`) and then opened, one command per pass, so the click that opens it is a click on
something in arm's reach — finding a corpse reaches 50, looting one reaches a great deal less. The
pull is fired once per corpse and is the one command here with no answer of its own, which is
exactly right: the server allows it out to 100 (`Corpse::Summon`, which `GMMove`s the corpse to
where we are standing without remaking the entity, so the spawn id survives), and that is twice as
far as this state ever looks. Nothing of ours in reach can be refused the pull, and if one somehow
does not move, the open below is fired and watched the way it always was.

**Three actions, three answers.** Opening a corpse (`/click right target` on it), looting an item
(`/itemnotify loot<slot> rightmouseup`) and closing the window (`/notify LootWnd LW_DoneButton
leftmouseup`) are each fired once and then watched for their evidence, because **the client refuses
in chat and nowhere else**: too far to reach it, bags full, a lore item already carried, a corpse
somebody else is looting. A window that never opens leaves that corpse; an item that never leaves
its slot is left on it; a window that will not close ends the order. Those are evidence windows on
actions we fired — the world answering no — and not give-up timers; what they buy is a job at this
band that cannot wedge the chain underneath it.

**What it keeps is progress, not decisions**: which corpse is being worked, that a click is out and
waiting on a window, which slot was last asked for and what was in it. None of that is re-readable
— a loot window cannot say who opened it or what was asked of it a moment ago — and every piece is
confirmed or dropped on the next pass, which is exactly the exception `baseState` carves out for a
procedure the world cannot reconstruct.

**A window on somebody else's corpse is somebody else's**: not emptied, not closed, and ours waits
behind it (there is only ever one loot window) — said once when it starts, since waiting is the one
thing this state does silently and silence is what "broken" looks like. A window already open on a
corpse *of ours* is the opposite case and is taken over — it is the very thing the order named, and
who clicked it changes nothing. Anything on the cursor is put away first, because the client hands
nothing over while it is full.

**`LootWnd` is asked before `${Corpse}`**, and it is the one that decides whether anything is being
looted at all. `${Corpse}` is the client's active-corpse pointer, and a pointer left over from a
loot that has already ended reads exactly like one in progress — which would park the order behind
an imaginary window for the rest of the session.

Where it sits: `Priorities.loot + 5`, registered for every class by `BaseClass` — everyone dies the
same way. One step below AdvLootState, because a roll nobody has answered is a roll the whole group
is waiting on while our own gear is waiting on nobody; above follow and rest, so a character told to
loot does that rather than trotting off after the group with its gear still on the floor.

`lootcorpse` is the order, the Corpse State page has the same two buttons for a character being
played by hand, and `/ccorpse` reports what it is doing and how far away the nearest corpse of ours
is. A clean run is reported in our own console; anything left behind is said back to whoever asked.

## Consent on death (`consent.lua`)

The half of death recovery that has to happen *while* we are dead: letting the people we are
already with drag the corpse. Consent is what the server checks before anybody but us may summon
one (`Corpse::Summon` — the same `/corpse` CorpseState pulls its own over with), and a corpse
carries three ids that grant it. `/consent group`, `raid` and `guild` stamp the id we hold **right
now** onto every corpse of ours the server can find (`Client::ConsentCorpses` → world → every
zone), which is why this is a service and not a setting said once: a consent given while alive
names corpses we do not have yet.

**It starts on the first frame `Me.State` reads DEAD or HOVER**, which is a frame with a corpse —
the corpse is made in the same server tick that tells the client it died, and our answer travels
back behind it. That is also the last comfortable moment: the consent has to *find* the corpse in
a loaded zone, and the release to a bind point is what starts emptying the one we died in.

**One consent every two and a half seconds.** The server allows one every two
(`consent_throttle_timer`) and refuses a faster one with a red "You must wait 2 seconds between
consents." and nothing else — the consent is lost, and nothing reads back as "that one did not
take". The pacing is kept across deaths rather than per death, because the throttle it dodges is.
Group and raid go first (both are stamped on the corpse where it lies, so both want that zone
still loaded); guild last, since consenting a guild also writes the id onto every corpse of ours
in the database, buried ones included.

**Only the ties we actually have** are consented — a group we are not in stamps a zero, which is
what no consent already is, and saying it anyway would spend a two-second slot the real ties are
waiting for. Nothing goes out while `GameState` is not `INGAME`: a command typed into a loading
screen is one nobody hears, and the release lands in the middle of this.

What it holds is the one thing the world cannot answer — whether this death has been consented yet
— which is the `baseState` exception for a procedure the world cannot reconstruct. A script that
comes up next to a corpse it never watched being made consents nothing: that is a death nobody
observed, not a reason to act. The switch is `consentondeath` (chat, hotbar button, or the General
page), on by default, and turning it off drops whatever the current death still owed.

## Taking a rez (`rez.lua`)

The other half of the respawn window, and the receiving end of what the Rezzing section above
describes: `rezzing.lua` offers a rez to somebody else's corpse, this takes the one offered to ours.
A rez arrives as one of two things, and which one depends on whether we are still hovering over our
own corpse when it lands.

**On our feet** — released to bind, or dragged back and standing there — and the client puts up its
confirmation box (`%1 wants to RESURRECT you. Do you wish this?`, eqstr 9046). Yes is the whole
answer; the server does the rest (`Client::OPRezzAnswer`).

**Still hovering dead**, and there is no box to answer: the offer is the `Resurrect` line on the
respawn window, which the server puts there at death and always last (`Client::SendRespawnBinds`).
Picking it *is* accepting — `Client::HandleRespawnFromHover` answers the rez itself rather than
asking again — so the row is selected and Respawn clicked.

**Every confirmation box is read before it is answered.** `ConfirmationDialogBox` is the client's one
box and it asks about everything: destroying an item, deleting a character, and — the one that
matters — `%1 wants to SACRIFICE you. You get NO experience back with Resurrection, even GM. Die &
lose exp?` (eqstr 9054), which is a request to *kill* us and which says "Resurrection" while it asks.
Only "wants to resurrect you" is answered Yes, and anything mentioning a sacrifice is the player's to
answer whatever else it says.

**The hover pick waits for evidence that a rez is really pending**, and that evidence is the client
saying so ("You have been offered a resurrection.", the `rezoffered` event) or a rez box appearing
while we are dead. The `Resurrect` row is on the respawn window from the moment we die, offer or no
offer, and picking it with nothing behind it is not a harmless miss: `HandleRespawnFromHover` disables
the respawn timer *before* it finds out there is no rez to give, so a blind click leaves the character
hovering with the clock that would have released it switched off.

What it holds is that offer — the one thing the world cannot answer, since a respawn window with a rez
waiting behind it and one without look exactly alike. It is dropped the moment we read as alive, so an
offer can never carry into the next death, and a script that comes up next to a corpse it never
watched being made knows of no offer at all. Nothing goes out while `GameState` is not `INGAME`:
taking a rez is what starts one of those loading screens. The switch is `acceptrez` (chat, hotbar
button, or the General page), on by default, and turning it off drops the standing offer with it.

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

Three things are read every pass instead of being done once. Auto attack, because `/attack on` is the
one commitment nothing else takes back — the melee state issues it, and its range gate, the one
thing that ever takes it back, is not getting another turn — so `Go()` reads `Me.Combat` and drops it
whenever it finds it on, which also covers the player switching it back on by hand. The pet, for
exactly the same reason: PetDpsState would have called it off when the fight closed and is starved
at the dps band, so `Go()` reads `Pet.IsFighting()` and says `/pet back off` when it finds it true,
paced at a second and a half so a client that is a beat behind is not told twice a frame — and only
to a pet that takes the word at all (`Pet.TakesOrders`), since an enchanter's animation would
otherwise be told for the length of the run by something that cannot be heard. And the
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
- **A setting belongs to whoever carries it out, not to the page it is edited on.** The follow
  distances are `TravelConfig`'s (section `Travel`), because `travel.lua` does the following and
  travel mode drives that same core from the flee state — a service reading a state's section would
  be the same mistake as a state reading another state's. They are edited on the Follow State page
  all the same, the way the mez page edits `MobsConfig`'s sweep radius.
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
