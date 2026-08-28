---The priority chain, as data.
---
---The state machine walks registered states in registration order and the first enabled one
---whose `Go()` returns true owns the frame, so registration order *is* priority. Classes
---declare a band per state instead of ordering their `Register` calls by hand
---(`cabby.classes.baseClass` sorts by these before registering), which is what makes the
---ordering comparable across classes: a paladin's heal has to land below a cleric's, and that
---is only checkable if both name the same band.
---
---**A bigger number is weaker** -- it sits later in the chain and is starved by everything
---above it. The gaps of ten are room to say "the same job, but not as strongly":
---`Priorities.heal + 5` is a hybrid healing below the class that heals for a living, and
---`Priorities.dps - 1` is a state that must get its swing in before the rest of the rotation.
---
---@class Priorities
local Priorities = {
    -- Above everything the chain does: a job the player switched on by hand -- a whole activity
    -- the character has been sent off to carry out rather than a responsibility it weighs against
    -- its others (see `cabby/jobs/job.lua`). A job is not registered as a state at all; it holds
    -- the chain from outside it with a floor, and this is the floor, so nothing in the chain runs
    -- while one is working. Standing at a forge is not something to be interrupted by a follow
    -- order or a sit-down: the player asked for the combines, and the combines are what happens
    -- until a limit trips or they say stop
    job = 0,

    -- orders given to this character, and anything the client itself is waiting on
    commands = 1,

    -- the global pause: everything below it is starved while it is on
    passive = 19,

    -- Where to stand when a mob cannot come to you. Above every job that answers being hit, because
    -- standing out of a rooted mob's reach is what decides whether there is anything to answer: a
    -- body in there takes a beating for as long as it stands there, and no amount of healing it is
    -- a substitute for the step backward that ends it.
    --
    -- It sat below the rotations once, on the reasoning that only a character with nothing in hand
    -- should ever be walked anywhere -- and the character that reasoning starved was the healer, the
    -- one it was written for. A cast in flight cut the band off (the casting floor) *and* outranked
    -- the walk already running, so every retreat a healer began was cancelled by their own next
    -- heal; a walk that ends short marks the spot as one with no room left, so the pass after that
    -- would not even try. Up here the step back is what outranks the cast, and the heal waits out
    -- the second or two of walking instead of ending it. Who "everybody else" is stopped being the
    -- chain's answer with that move and became a reading of the world -- see `standoffState.lua`
    standoff = 24,

    cure = 29,
    heal = 39,

    pull = 49,

    -- in combat --
    mez = 59,        -- add control, above dps so a new add is handled before the next swing
    tank = 69,       -- taunt / grab aggro
    -- Trading health for mana: a shaman's cannibalize, the rods a magician summons, a manastone.
    -- Above the rotations deliberately, because mana is what everything below this band is spent
    -- out of -- a beat spent filling the bar buys back every cast that would otherwise not happen,
    -- and a caster that nukes down to empty and then stands there is the failure this band exists
    -- to prevent. Below every job that *is* the fight, equally deliberately: a heal, a mez or a
    -- taunt is never worth trading for mana, and each of them is somebody about to die if it waits.
    -- It is self-limiting in a way its neighbours are not, which is what makes it safe up here: the
    -- mana ceiling stops it, so it takes frames from the rotation only until the bar is full again
    canni = 74,

    -- The buffs a fight does not pay for: an instant clicky or AA aimed at nobody, which is over
    -- in the frame it is fired and never takes the client's target off what is being fought. The
    -- buff job proper sits at `buff`, far below, and is starved for whole fights by the states
    -- that *are* one -- correctly, because a bar cast mid-fight spends the mana the healing wanted
    -- and holds the target away while it runs. A free one costs neither, and a warrior whose whole
    -- buff list is instant clickies would otherwise never keep one up in a fight at all.
    --
    -- The driver here is **never busy**, which is what makes this band safe: it suppresses
    -- nothing, so what it actually buys is a turn above the rotations and a cast floor that
    -- starves it while anything stronger is casting. See `BuffState.InFight`
    upkeep = 75,

    -- melee and spell rotations. SpellDpsState registers at `dps - 1`, the melee classes declare
    -- MeleeState at `dps`, and every other class picks melee up from the common states at
    -- `dps + 5`: the melee state reports busy for as long as it is engaged, so a rotation below it
    -- would never get a frame, while a rotation above it only takes one when it actually casts.
    -- That is also why a caster's melee sits below `dps` rather than at it
    dps = 79,

    -- out of combat --
    -- what corpses dropped: AdvLootState answers the loot window's rolls here, and CorpseState
    -- empties this character's own corpse a step weaker at `loot + 5`. A corpse-*walk* state --
    -- one that goes and gets a corpse rather than looting what is already underfoot -- is the
    -- neighbour still missing
    loot = 89,

    anchor = 99,     -- hold a spot
    follow = 109,    -- stay with someone

    buff = 119,

    -- what a character does with the frames nothing else wants. RestState is here: sitting to get
    -- the pools back is worth doing only when everything above has passed on the frame
    misc = 129
}

return Priorities
