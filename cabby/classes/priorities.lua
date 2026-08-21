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
    -- orders given to this character, and anything the client itself is waiting on
    commands = 1,

    -- the global pause: everything below it is starved while it is on
    passive = 19,

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

    -- Where to stand when a mob cannot come to you. Below every job in the fight, deliberately:
    -- anything with work in hand is busy above this, so the only characters that ever reach it are
    -- the ones with nothing to do -- which is exactly the list of people who should not be standing
    -- in a rooted mob's reach. Above follow and anchor, also deliberately, because where to stand is
    -- contested with the traveling core and the chain is what settles that
    standoff = 84,

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
