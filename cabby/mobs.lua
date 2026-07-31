---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Geometry = require("utils.Movement.Geometry")
local Time = require("utils.Time.Time")

local ChelpDocs = require("cabby.commands.chelpDocs")
local Combat = require("cabby.combat")
local Commands = require("cabby.commands.commands")
local MobsConfig = require("cabby.configs.mobsConfig")
local Pet = require("cabby.pet")
local SlashCmd = require("cabby.commands.slashcmd")
local Status = require("cabby.status")
local ToggleCommand = require("cabby.commands.toggleCommand")

---Which mobs are in this fight -- one list, built from every angle this client has.
---
---`cabby.combat` answers *what we are killing*. This answers *what is here*, which is a different
---question and a harder one: crowd control has to act on the mob nobody has hit yet, and the
---narrow answer is exactly the one that leaves an add loose. So this is a service, published for
---whoever needs it, rather than a table inside the one state that happens to need it first --
---a second reader (a pull state's leash, a tank state's add sweep) should be reading the same
---roster rather than assembling its own from scratch.
---
---**Four angles, and no single one of them is trusted alone.** Each entry records which of them
---saw it, because *how* we know is what says how much a reader may lean on it:
---
---- **engaged** -- `Combat.GetTargetId`, what the group is killing. The strongest answer there is:
---  somebody chose it.
---- **hater** -- the extended target window's `Auto Hater` entries, which is the client saying
---  "this is fighting you". Certain, and blind to anything that has never touched us.
---- **defend** -- the standing `defend` reports, which are the mobs beating on group members. The
---  only way this client learns about the add on the healer; it is also the angle that depends on
---  somebody else running cabby and speaking, which is why it is not the only one.
---- **nearby** -- a sweep of the zone for NPCs in combat stance within reach. This is the angle
---  the other three cannot cover: the add pathing in that has not picked anybody yet, the mob
---  chewing on a pet (on nobody's extended target window and nobody's report), and the whole fight
---  of a group that is not running cabby. It is also the only angle that can be *wrong*, so it is
---  the one with the filtering.
---
---**Friendly is what the sweep has to get right**, and it is asked four ways, cheapest first: the
---spawn is an NPC or a pet and not a player, not a corpse, not something a *player* owns (which is
---any groupmate's pet, and our own charm), and targetable. Aggression is what the sweep searches
---on -- `playerstate 4|8`, the client's own "this thing is in combat stance", which is what
---`Spawn.Aggressive` reads -- so a merchant, a guard standing at a post and a wandering critter are
---never in the list to be filtered out in the first place. What that read cannot tell apart is a
---mob fighting *us* from one fighting something else across the room, which is the one way the
---sweep is loose and why `Mobs.Get(id).sources` exists: a reader that must not be wrong about it
---(an AE that would pull the room) asks for a mob one of the other three angles also saw.
---
---**It decides nothing and says nothing.** No engaging, no targeting, no chat -- the roster is a
---fact and what to do about it belongs to whoever reads it. Which is also what makes it safe to
---read from an ImGui callback.
---@class Mobs
local Mobs = {
    key = "Mobs",
    eventIds = {
        mobSweep = "mobsweep"
    },
    ---How a mob came to be in the roster. A mob is usually seen by more than one, and the entry
    ---carries all of them; the order here is how much they are worth, strongest first.
    sources = {
        engaged = "engaged",
        hater = "hater",
        defend = "defend",
        nearby = "nearby"
    },
    _ = {
        isInit = false,
        ids = {},        -- ordered, strongest angle first
        entries = {},    -- [id] = MobEntry
        poses = {},      -- [id] = { x, y, z, heading, lastMovedMs } -- survives a rebuild
        sweptIds = nil,  -- the last sweep's answer, folded in until the next one replaces it
        lastSweepMs = 0,
        lastPoseMs = 0,
        zoneId = 0
    }
}

---How often the zone is swept for mobs in combat stance.
---
---The sweep is the expensive angle -- a `SpawnCount` plus a `NearestSpawn` and a handful of reads
---per hit -- and the other three are free, since Combat has already paid for them. A quarter of a
---second is the same pace Combat sweeps the extended target window at, and it is chosen the same
---way: nothing about a mob walking into the camp changes inside one, and a mez that starts a
---quarter second late is a mez that lands.
local sweepIntervalMs = 250

---What a spawn has to be to be worth fighting at all. The same three the engagement uses: an NPC,
---somebody's pet, or a destructible object. Never a player, and never a corpse.
local fightableTypes = { NPC = true, Pet = true, Object = true }

---The combat-stance bits, as the spawn search reads them: `Aggressive` (0x4) and its forced
---counterpart (0x8), which together are exactly what `Spawn.Aggressive` answers. Passed as one
---number because the search ORs what it is given and then tests with `&`, so `12` matches either.
local aggressiveStates = 12

---How often each mob's position and heading are sampled, for `LastMovedMs`.
---
---The same pace as the sweep and for the same reason: it is a handful of reads per mob and
---nothing that matters happens inside a quarter of a second. It is also the granularity of the
---answer -- "it moved at some point in the last 250 ms" -- which is as fine as any reader needs,
---since what they are asking is whether the mob is *behaving* like something held still.
local poseIntervalMs = 250

---How much a reading has to differ before it counts as having moved.
---
---A stationary spawn's coordinates do not drift -- the client holds what the last server update
---said and nothing touches it -- so an exact comparison would work, which is what
---`macros/bots/enchanterBot.mac` does. These are floats all the same, and a hair of slack costs
---nothing: a mob that has genuinely taken a step has moved further than this, and one that has
---genuinely turned has turned further.
local movedEpsilon = 0.01
local turnedEpsilonDegrees = 0.5

---@param str string
local function DebugLog(str)
    Debug.Log(Mobs.key, str)
end

---@class MobEntry
---@field id number
---@field name string
---@field sources table set of `Mobs.sources` values -- every angle that saw this mob
---@field firstSeenMs number when it first entered the roster, which is the order the sweep
---settles into: a reader walking the list takes them in the order they turned up rather than in
---whatever order the client happened to list them this pass

---Is this spawn something we could be in a fight with?
---
---The half of "friendly" that no search string can express. `Master.Type()` is the one that
---matters and the one a naive sweep gets wrong: a group member's pet is an NPC in combat stance
---standing right next to us, and so is our own charmed pet -- both would be mezzed by anything
---that trusted the search alone.
---@param spawn any mq spawn TLO
---@return boolean isHostile
local function isHostile(spawn)
    if spawn.ID() == nil then return false end
    if spawn.Dead() == true then return false end
    if not fightableTypes[spawn.Type()] then return false end
    -- anything a player owns is on our side of the fight, charm included
    if spawn.Master.Type() == "PC" then return false end
    -- our own pet, for the beat before the client has filled its master in
    if Pet.GetId() == spawn.ID() then return false end
    if spawn.Targetable() == false then return false end
    return true
end

---The sweep: NPCs in combat stance within reach.
---
---`playerstate` is the whole point of the search string. Anything else -- an `npc radius` sweep,
---which is what a mez macro traditionally does -- returns the merchants, the guards and the
---wildlife along with the fight, and then has to guess which is which from con colour and
---faction. The client already knows which of them are swinging at somebody, so it is asked.
---@return number[] ids
local function sweep()
    local ids = {}

    local search = "npc radius " .. tostring(MobsConfig.GetRadius()) ..
        " zradius " .. tostring(MobsConfig.GetZRadius()) ..
        " playerstate " .. tostring(aggressiveStates)

    local count = tonumber(mq.TLO.SpawnCount(search)()) or 0
    for index = 1, count do
        local spawn = mq.TLO.NearestSpawn(index, search)
        if isHostile(spawn) then
            ids[#ids + 1] = spawn.ID()
        end
    end

    return ids
end

---When each mob last moved or turned.
---
---**Position *and heading***, because turning is movement for this purpose and it is the half that
---catches what position alone misses: a mob that has been handed back its own will faces whoever it
---is going to hit before it takes a step, and something rooted or snared may never take one at all.
---`macros/bots/enchanterBot.mac` samples exactly this pair for exactly this reason, and it is a
---better-founded reading than the animation list beside it -- an animation number is a lookup table
---that can be incomplete, while "it is in a different place, or pointing somewhere else" has one
---meaning and no table behind it. (That macro's own animation check is commented out; ours is kept,
---because `macros/bots/mez.mac` is field evidence for this server specifically. They agree in the
---safe direction anyway: either saying the mob is active makes it active.)
---
---This lives here rather than in the state that wanted it because it is a *sample over time* --
---it only means anything if somebody takes it at a steady cadence, and a state that is being
---starved by the fight above it cannot promise one. That is the whole argument for a service.
local function samplePoses()
    local now = Time.current_time()
    local poses = Mobs._.poses

    for _, id in ipairs(Mobs._.ids) do
        local spawn = mq.TLO.Spawn("id " .. tostring(id))
        local x, y, z = tonumber(spawn.X()), tonumber(spawn.Y()), tonumber(spawn.Z())
        local heading = tonumber(spawn.Heading.Degrees())

        if x ~= nil and y ~= nil and z ~= nil then
            local was = poses[id]
            if was == nil then
                -- first sighting: no history, so nothing has been observed to move yet. Recorded as
                -- moving *now* rather than as having been still forever, since a mob we have only
                -- just started watching has told us nothing about whether it is held
                poses[id] = { x = x, y = y, z = z, heading = heading, lastMovedMs = now }
            else
                local moved = math.abs(x - was.x) > movedEpsilon
                    or math.abs(y - was.y) > movedEpsilon
                    or math.abs(z - was.z) > movedEpsilon
                if not moved and heading ~= nil and was.heading ~= nil then
                    local turn = math.abs(Geometry.HeadingDiff(was.heading, heading))
                    moved = turn > turnedEpsilonDegrees
                end

                if moved then
                    was.x, was.y, was.z, was.heading = x, y, z, heading
                    was.lastMovedMs = now
                end
            end
        end
    end

    -- a mob that has left the roster takes its history with it; an id that comes back is a mob we
    -- have to start watching afresh, which is what the nil-history branch above says
    for id in pairs(poses) do
        if Mobs._.entries[id] == nil then poses[id] = nil end
    end
end

---When this mob was last seen to move or turn, in wall-clock ms.
---
---Nil when it has never been sampled. Readers compare it against a moment of their own -- "has it
---moved since the mez we landed on it" is the question `states/mezState.lua` asks, and it needs no
---window and no threshold to ask it: the mez landed at one instant, the mob moved at another, and
---which came second is the whole answer.
---@param id number
---@return number|nil ms
function Mobs.LastMovedMs(id)
    local pose = Mobs._.poses[tonumber(id) or 0]
    return pose ~= nil and pose.lastMovedMs or nil
end

---How long this mob has been standing perfectly still, in ms. Zero when it has never been sampled,
---which reads as "it has told us nothing" rather than as "it has been still forever".
---@param id number
---@return number ms
function Mobs.StillForMs(id)
    local lastMoved = Mobs.LastMovedMs(id)
    if lastMoved == nil then return 0 end
    return Time.current_time() - lastMoved
end

---Rebuild the roster from all four angles.
---
---Order is strongest angle first and, within an angle, the order that angle listed them -- which
---for the sweep is nearest first and for the extended target window is the window's own order,
---both of which are stable across passes. A reader walking the list to pick one mob out of it
---must not be handed a different answer every pass for no reason.
local function rebuild()
    local ids, entries = {}, {}
    local now = Time.current_time()
    local previous = Mobs._.entries

    local function add(id, source)
        id = tonumber(id)
        if id == nil or id < 1 then return end

        local entry = entries[id]
        if entry == nil then
            -- Verified against the world here rather than trusted from the angle that named it:
            -- Combat's own lists are swept on their own clock and a corpse hitting the ground
            -- between one sweep and the next is exactly the mob a mez would be spent on. The
            -- sweep's ids are already filtered, and re-reading one costs nothing next to being
            -- wrong about it.
            local spawn = mq.TLO.Spawn("id " .. tostring(id))
            if not isHostile(spawn) then return end

            local was = previous[id]
            entry = {
                id = id,
                name = spawn.CleanName() or ("spawn " .. tostring(id)),
                sources = {},
                firstSeenMs = was ~= nil and was.firstSeenMs or now
            }
            entries[id] = entry
            ids[#ids + 1] = id
        end
        entry.sources[source] = true
    end

    -- Each angle asked for by name rather than through Combat's merged `GetFightIds`, because the
    -- merge is what the roster is *doing* -- an entry has to carry which angles saw it, and a
    -- pre-merged list cannot say.
    add(Combat.GetTargetId(), Mobs.sources.engaged)

    for _, id in ipairs(Combat.GetHaterIds() or {}) do
        add(id, Mobs.sources.hater)
    end

    for _, id in ipairs(Combat.GetDefendIds()) do
        add(id, Mobs.sources.defend)
    end

    for _, id in ipairs(Mobs._.sweptIds or {}) do
        add(id, Mobs.sources.nearby)
    end

    Mobs._.ids = ids
    Mobs._.entries = entries
end

---Every mob in this fight, strongest angle first.
---
---The private table, which callers read and nobody modifies. Empty is "no fight this client can
---see", which is a real answer rather than a missing one.
---@return number[] ids
function Mobs.GetIds()
    return Mobs._.ids
end

---@param id number
---@return MobEntry|nil entry nil when this mob is not in the fight
function Mobs.Get(id)
    return Mobs._.entries[tonumber(id) or 0]
end

---Was this mob seen by an angle that cannot be wrong about it?
---
---The three angles that come from the client being *told* -- our own engagement, our own extended
---target window, a group member's report -- are certain that the mob is in the fight. The sweep is
---not: it says the mob is in combat stance with somebody, which is usually us and sometimes the
---guards across the room. A reader whose mistake is cheap (a mez spent on a mob that was not
---coming for us anyway) reads `GetIds`; one whose mistake is expensive (an AE that would pull the
---room in) asks this first.
---@param id number
---@return boolean isConfirmed
function Mobs.IsConfirmed(id)
    local entry = Mobs.Get(id)
    if entry == nil then return false end
    return entry.sources[Mobs.sources.engaged] == true
        or entry.sources[Mobs.sources.hater] == true
        or entry.sources[Mobs.sources.defend] == true
end

---@param id number
---@return string description of how this mob came to be in the roster, in words
function Mobs.DescribeSources(id)
    local entry = Mobs.Get(id)
    if entry == nil then return "not in the fight" end

    local words = {}
    if entry.sources[Mobs.sources.engaged] then words[#words + 1] = "what we are killing" end
    if entry.sources[Mobs.sources.hater] then words[#words + 1] = "on our target window" end
    if entry.sources[Mobs.sources.defend] then words[#words + 1] = "called by the group" end
    if entry.sources[Mobs.sources.nearby] then words[#words + 1] = "in combat nearby" end

    if #words == 0 then return "unknown" end
    return table.concat(words, ", ")
end

---@return string description for status output
function Mobs.Describe()
    local count = #Mobs._.ids
    if count == 0 then return "no mobs in the fight" end
    return tostring(count) .. (count == 1 and " mob" or " mobs") .. " in the fight"
end

---Service contract: keep the roster current, at the pace the expensive angle is worth paying for.
---
---The three cheap angles are re-read every pulse because Combat has already paid for them and a
---roster that lagged its own inputs would be a second stale copy of them. Only the sweep is
---throttled, and its last answer is folded in until the next one -- which is what makes a mob that
---walked out of the sweep radius linger for a quarter second rather than flickering out of the
---list between two passes of a state that is acting on it.
function Mobs.Pulse()
    local now = Time.current_time()

    -- Spawn ids do not survive a zone line, so a roster kept across one is meaningless at best and
    -- collides with a fresh spawn wearing the same id at worst -- the same reason Combat drops its
    -- reports. Fleeing empties it for the reason Combat's reports go: the fight the group ran from
    -- is not a fight any more, and nothing should be acting on what was in it.
    local zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    if zoneId ~= 0 and zoneId ~= Mobs._.zoneId then
        Mobs._.zoneId = zoneId
        Mobs._.sweptIds = nil
        Mobs._.entries = {}
        Mobs._.ids = {}
        Mobs._.poses = {}
    end

    if Status.IsFleeing() then
        Mobs._.sweptIds = nil
        Mobs._.entries = {}
        Mobs._.ids = {}
        Mobs._.poses = {}
        return
    end

    if not MobsConfig.GetSweep() then
        -- switched off mid-session: the last answer goes with the switch rather than standing
        -- forever as an angle nobody is refreshing
        Mobs._.sweptIds = nil
    elseif now - Mobs._.lastSweepMs >= sweepIntervalMs then
        Mobs._.lastSweepMs = now
        Mobs._.sweptIds = sweep()
    end

    rebuild()

    -- after the rebuild, so a mob that joined the fight this pulse is sampled from the pulse it
    -- joined rather than from the one after
    if now - Mobs._.lastPoseMs >= poseIntervalMs then
        Mobs._.lastPoseMs = now
        samplePoses()
    end
end

---@param stateMachine StateMachine
function Mobs.Init(stateMachine)
    if Mobs._.isInit then return end

    local ftkey = Global.tracing.open("Mobs Setup")

    MobsConfig.Init()
    stateMachine:RegisterService(Mobs)

    ToggleCommand.Register({
        key = Mobs.key,
        phrase = Mobs.eventIds.mobSweep,
        summary = "Turns the roster's own zone sweep on or off for listener(s)",
        about = {
            "The roster always reads what the client is told -- what we are fighting, the extended",
            "target window, and the group's (defend) reports. This is the fourth angle: a sweep of",
            "the zone for NPCs in combat stance nearby.",
            "It is the only angle that sees a mob nothing has told us about -- an add on its way in,",
            "something chewing on a pet -- and the only one that can be wrong about whether the mob",
            "is fighting *us*. Off leaves the roster to the three certain angles."
        },
        get = MobsConfig.GetSweep,
        set = MobsConfig.SetSweep
    })

    local cmobsDocs = ChelpDocs.new(function() return {
        "(/cmobs) Reports every mob this character believes is in the fight, and how it knows",
        " -- Usage: /cmobs",
        " -- The roster is built from four angles: what we are fighting, the extended target",
        "    window, the group's (defend) reports, and a sweep of the zone for anything in combat",
        "    stance nearby. Each mob lists which of them saw it.",
        " -- A mob only the sweep saw is the loose one: it is in combat with somebody, and the",
        "    client cannot say that somebody is us. Anything crowd control must not get wrong",
        "    waits for one of the other three.",
        " -- The sweep is the (" .. Mobs.eventIds.mobSweep .. ") switch; its reach is on the Mobs page."
    } end )
    local function Bind_CMobs()
        print("Mob roster: " .. Mobs.Describe())
        print(" -- sweeping (" .. Mobs.eventIds.mobSweep .. "): " ..
            (MobsConfig.GetSweep() and
                ("on, " .. tostring(MobsConfig.GetRadius()) .. " out and " ..
                    tostring(MobsConfig.GetZRadius()) .. " up and down")
                or "off"))

        for _, id in ipairs(Mobs.GetIds()) do
            local entry = Mobs.Get(id)
            if entry ~= nil then
                print(" -- " .. entry.name .. " (id " .. tostring(id) .. "): " ..
                    Mobs.DescribeSources(id) ..
                    (Mobs.IsConfirmed(id) and "" or " -- unconfirmed"))
            end
        end

        if Status.IsFleeing() then
            print(" -- flee is on: the roster is held empty until `flee off`")
        end
    end
    Commands.RegisterSlashCommand(SlashCmd.new("cmobs", Bind_CMobs, cmobsDocs))

    Mobs._.isInit = true
    DebugLog("Mob roster service registered")
    Global.tracing.close(ftkey)
end

return Mobs
