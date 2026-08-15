# CLAUDE.md

MQ Lua scripts; `cabby/` is the main script (do-everything botting: state machine + command bus).
The full design contract lives in `cabby/states/baseState.lua` and `cabby/docs/ARCHITECTURE.md`
(Runtime model section) — **read both before changing any state, service, or the state machine.**
This file is the enforcement summary of a doctrine that predates most of the code: if a change
conflicts with it, the change is wrong or the doctrine discussion happens first — do not ship a
workaround.

## The cabby doctrine (non-negotiable)

- **Priority chain, re-arbitrated every pass.** The machine walks states strongest-first every
  frame; the first busy state ends the pass. `Go()` is: quick check from the world → start
  actions via services without waiting → return. No `mq.delay` in states or services, no waiting
  loops, no held frames or lingers in the machine. An order must be able to act on the next pass
  — reprioritization speed is the point of the whole design.
- **States never read states.** A frame you are given is the chain's guarantee that nothing above
  you had business; that is the *entire* inter-state coordination model. Never read, model, or
  compensate for another state — not its module, not its runtime, not its config. Finding
  yourself wanting to is the smell that a busy signal upstream is lying.
- **Busy signals are domain-honest and continuous.** If the underlying fact is continuous ("we
  are in a fight"), the signal built on it must be too. Gaps are fixed at the service that owns
  the fact — e.g. `cabby/combat.lua` holds a lost-target fight open (`IsSeeking`) so `IsEngaged`
  cannot blink between two mobs of one fight — never by teaching a downstream state to distrust
  its frames.
- **Services and the world are the readable surface.** Services act without owning frames, so
  states read their published facts (Combat's engagement, Movement's driving, a persisted order
  like the flee switch) to avoid contradicting them. That is not state-to-state knowledge.
- **Suppression flows through ordering, never around it.** A state suppresses everything below it
  by returning busy; priority gates are floor-only (a service busy at a band) and can only cut a
  contiguous tail — no exemptions, no holes, no out-of-band holding. A job that must keep running
  under somebody's cut belongs at a different band: `cabby/travel.lua` is the worked example —
  flee drives the shared traveling core itself at the passive band instead of gating the chain
  and exempting follow (that exemption mechanism existed and was removed 2026-07 at the user's
  direction; do not reintroduce it).
- **The chain hands out frames; the services arbitrate the character.** Two jobs can want the same
  character at once without either being wrong to ask, and the state holding the frame is not
  necessarily the one holding the character — so casting (one cast) and movement (one task) each
  take the asker's **band** with the request and settle competing claims by comparing bands, in
  both directions: a cast cancels the move it outranks, a move walks out of the cast it outranks
  (`Movement.GetPriority`, `Casting.IsHoldingStill`). A state may therefore hand down the frames
  its own service is already carrying — following yields while the movement service walks, which
  is what lets buffing click an instant clicky on the run — and nothing weaker can take the
  character out from under it, because the band on the request is what stops that, not the frame.
- **No give-up timers.** States re-derive their answer every pass and drop work the moment it
  stops being right, so nothing needs rescuing by clock. The only legitimate timers in a state or
  service: throttling/pacing its *own* commands and expensive reads; an **evidence window**
  verifying a fired action took (a cast bar that never appeared is the world's only way of saying
  no); a **domain TTL** on the meaning of an order ("heal me" ten seconds stale is not an order
  anymore); a **grace** before undoing something the player did by hand. Never time derived from
  the scheduler, and never "it's been a while, stop trying".
- **Don't fight the player.** A posture or action the player chose is not undone on the next
  frame; act only for the intended reason.
- **No game commands in render callbacks.** Anything ImGui triggers goes through `CommandQueue`
  (crash-to-desktop hazard otherwise).

## History that must not repeat

A warrior sat down mid-fight (2026-07). Two fixes were attempted and **rejected as doctrine
violations** before the real one landed: a hate-list read in RestState (a lower state defending
itself against upper activity), then a machine `OnResume` hook telling starved states how long
the chain looked away (scheduler time leaking into states). The actual bug was Combat closing
the fight for a beat between mobs — a lying busy signal — and the actual fix was fight
continuity in Combat. When a lower state misbehaves during upper-state activity, audit the
upper signal first; do not add defenses downstream.

Followers stopped to buff and lost the group (2026-08). The cast/movement arbiter ranked a move by
looking its **owner key** up among the registered states, and since the 2026-07 travel split the
follow is owned by `cabby/travel.lua`, which is a core and not a state: the lookup answered `nil`,
`nil` was read as "unranked, overrule it", and every cast there was — a buff two bands weaker
included — cancelled the follow, stood the character still and let the group walk off. The fix was
the band travelling with the request (`Travel.Drive(priority)` → the movement task → both sides of
the arbitration). The smell to notice: a priority comparison that resolves to `nil` and treats that
as the weakest thing there is, when what it actually means is "I could not find out".

## Verifying changes

- Syntax: `luac -p <files>`.
- The machine and services are testable headless: `StateMachine:Frame()` exists precisely so a
  harness can drive frames, and modules load under plain `lua`/`luajit` with `package.preload`
  stubs for `mq`, `utils.Time.Time` (fake clock), and peers. See git history of
  `cabby/combat.lua` fight-continuity work for the pattern.
- Behavior that touches the game (posture, movement, casting) gets verified in game before being
  called done — the harness proves scheduling, not EverQuest.
