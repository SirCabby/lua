---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local Combat = require("cabby.combat")
local HealStateConfig = require("cabby.configs.healStateConfig")
local Rezzes = require("cabby.actions.rezzes")
local Roles = require("cabby.roles")

---How far a corpse may be to be worth considering.
---
---A hundred is the reach of the rez spells themselves, so this is "everything a rez could possibly
---land on" and not a policy of its own -- what actually decides is `CastAction:IsReady`, which
---measures the real range and the line of sight against the corpse. Nothing here walks anybody
---anywhere: getting the group back to where it died is the player's job, exactly as it is for
---`cabby.states.corpseState`.
local lookRadius = 100

---How often the ground is looked at. A corpse does not move and nobody dies inside a second, and
---the walk below is a spawn search per group member -- so this is paced rather than run per frame,
---with the last answer cached for the page to read.
local scanIntervalMs = 1000

---How long a rez we cast is assumed to still be waiting for an answer.
---
---**The one thing about rezzing the world will not tell us.** A rez is an offer: the server hands
---the corpse's owner a box (or a `Resurrect` line on their respawn window) and nothing comes back
---to the caster either way. The corpse does not go away when the offer is accepted -- it stays put
---so its owner can loot it -- and casting at one that has already been rezzed is not even refused:
---`Corpse::CastRezz` re-sends the request with the experience zeroed. So "have I already offered
---this corpse a rez" is ours to remember, and this is how long the answer stays yes.
---
---Half a minute is a person noticing a box and clicking it, with room to spare. A cabby on the far
---end answers it in half a second (see `cabby.rez`, which is the other half of this).
local offerStandsMs = 30000

---How many rezzes one corpse is worth before it is left alone.
---
---Bounded for the same reason a cure is (`cabby.curing`): the ordinary end of an offer is somebody
---accepting it, and nothing here can see that happen, so without a bound a corpse whose owner is
---linkdead, gone from the keyboard, or simply not taking rezzes would be cast at until the world
---intervened -- at a full rez's mana every half minute. Three is generous: one is normally the
---whole story.
---
---It is not a give-up on the person, only on offering unprompted. `rezme` (or `reznow`) clears it
---and starts again, which is the same escape a cure request has -- somebody saying it again is
---somebody saying they are there to answer this time.
local maxOffers = 3

---How long a corpse is left alone after a rez at it did not go out.
---
---A refusal costs nothing to make, which is exactly the problem: without this, a corpse the client
---will not take a rez on is asked again on the very next pass and every pass after it. Deliberately
---not counted against the budget above -- that one bounds rezzes that *landed* and were never
---answered, and a cast that never happened put nothing on anybody.
local retryAfterFailureMs = 3000

---How long an ordered rez outlives being asked for.
---
---A domain TTL on the meaning of the order rather than a give-up: "rez me" is a statement about
---being dead right now, and a minute is long enough to cover the walk back and the fight finishing.
---Longer than a heal order's ten seconds because it has to be: a heal ten seconds late is not a
---heal, and a rez a minute late is exactly what everybody was waiting for.
local orderTimeoutMs = 60000

---Whose corpses are rezzed, and with what.
---
---Rezzing is the third job that rides in the heal state, and it is there for the reason curing is:
---casting a rez is choosing not to cast a heal, and that choice belongs where the healing is
---arbitrated. This module is the *choosing* -- which corpses are worth a rez, which rez, and
---whether one has already been offered -- and `cabby.states.healState` is the hands.
---
---**Not to be confused with `cabby.rez`**, which is the opposite end of the same event: that one
---takes the resurrection somebody offers *us*. This one offers them.
---
---**Everything is discovered and everything is overridable.** What this character can rez with is
---read off the spell data (see `cabby.actions.rezzes`) and what to use is worked out from it -- the
---most experience out of a fight, the shortest cast in one -- but both are settings that can name a
---spell instead, because a group that knows which rez it wants spent should not have to argue with
---a heuristic. Same for who: the corpse says whose it is and what class they were, the class order
---decides who goes first, and it ships with an opinion rather than as a blank.
---
---**The order, top to bottom.** Whoever asked (`rezme`); then the main tank, while that switch is
---on, because the role is the job and not the class holding it; then the class order; then whoever
---is nearest, which is only ever a tie-break. The tank is also the one corpse allowed past somebody
---in real trouble, and only with a rez that has no cast bar -- see `GetTargets`.
---
---What it holds between passes is the offer above, an order somebody gave, and the last look at the
---ground. All three are dropped on a zone line, where spawn ids stop meaning anything.
---@class Rezzing
local Rezzing = {
    key = "Rezzing",
    _ = {
        ---the last look at the ground: RezCandidates, best first
        corpses = {},
        lastScanMs = 0,
        zoneId = nil,
        ---{ [corpse spawn id] = { name, casts, untilMs, lastFailure } }
        offers = {},
        ---{ name, expiresMs } from a `reznow <id>` or `rezme`
        order = nil
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Rezzing.key, str)
end

---------------- Reading the ground --------------------

---Whether a spawn's name is the corpse of *that* character rather than of somebody whose name
---starts the same way.
---
---The spawn search matches a name in part, so `Cabby` finds `Cabbyx`'s corpse as well. What follows
---the name settles it: a corpse is `<name>'s corpse`, and nothing else can start with the whole name
---and carry on with an apostrophe. The same reading `cabby.states.corpseState` makes of its own.
---@param spawnName string spawn name, lowercased
---@param ownerName string the character's clean name, lowercased
---@return boolean isTheirs
local function corpseBelongsTo(spawnName, ownerName)
    if ownerName == "" then return false end
    if spawnName:sub(1, #ownerName) ~= ownerName then return false end
    return spawnName:sub(#ownerName + 1, #ownerName + 1) == "'"
end

---The character a corpse belongs to, from the corpse's own name.
---@param spawnName string|nil
---@return string|nil ownerName nil for a name that is not a corpse's
local function ownerOf(spawnName)
    local name = tostring(spawnName or "")
    local apostrophe = name:find("'", 1, true)
    if apostrophe == nil or apostrophe < 2 then return nil end
    return name:sub(1, apostrophe - 1)
end

---@class RezCorpse what the ground says: cached between scans, and nothing but the world
---@field id number the corpse's spawn id, which is what a rez is aimed at
---@field name string the character it belongs to
---@field class string|nil their class, as the corpse itself reports it
---@field distance number

---@class RezCandidate a corpse with this pass's judgment applied; worked out fresh every time
---@field id number
---@field name string
---@field class string|nil
---@field distance number
---@field isTank boolean the group's main tank, by the role assigned in the group window
---@field isOrdered boolean somebody asked for this one by name
---@field rank number where their class sits in the configured order
---@field enabled boolean whether that class is rezzed at all

---What class the person whose corpse this is was.
---
---**Read off the corpse rather than out of the group window**, which is not the obvious choice and
---is the right one. `Group.Member` has no `Class` member at all -- only its `Spawn` does, and a
---member who released to bind is standing in another zone with no spawn here, which is precisely
---the corpse this is most often asked about. The corpse itself always knows: the server builds one
---from the client it came off and copies the class straight across (`Corpse::Corpse`, passing
---`c->GetClass()`), and MQ reads `Spawn.Class` off a corpse like any other spawn.
---
---It also answers for somebody who is not in the group at all, which the group window could never
---do -- so an ordered rez is ranked by the same list as everybody else.
---@param spawn any mq spawn TLO for the corpse
---@return string|nil shortName nil when the client will not say, which is never read as a reason to
---leave somebody on the ground
local function classOf(spawn)
    local shortName = spawn.Class.ShortName()
    if shortName == nil then return nil end

    shortName = tostring(shortName):upper()
    if shortName == "" or shortName == "UNKNOWN" then return nil end
    return shortName
end

---@param found table
---@param seen table corpse ids already in `found`
---@param ownerName string
local function addCorpsesOf(found, seen, ownerName)
    if ownerName == "" then return end

    -- **`corpse` rather than `pccorpse`**, for the reason `cabby.states.corpseState` gives: MQ tells
    -- a player corpse from an NPC one by whether the spawn carries a deity, and there is no promise
    -- this server sends one. A `pccorpse` search that comes back empty reads exactly like having no
    -- corpse, which is a silent nothing rather than a bug anybody can see. The name is what makes it
    -- theirs anyway, and no NPC is named after a group member.
    local search = "corpse radius " .. tostring(lookRadius) .. " " .. ownerName
    local count = tonumber(mq.TLO.SpawnCount(search)()) or 0
    local lowered = ownerName:lower()

    for index = 1, count do
        local spawn = mq.TLO.NearestSpawn(index, search)
        local id = tonumber(spawn.ID())

        if id ~= nil and id > 0 and seen[id] == nil
            and corpseBelongsTo(tostring(spawn.CleanName() or ""):lower(), lowered) then
            seen[id] = true
            found[#found+1] = {
                id = id,
                name = ownerName,
                class = classOf(spawn),
                distance = tonumber(spawn.Distance()) or 0
            }
        end
    end
end

---Every corpse of ours lying within reach -- the reading, with no judgment in it.
---
---Group members, because that is who this character is here for, plus whoever an order named -- an
---order is somebody saying they are outside the group and asking anyway, which is the whole reason
---to be able to give one.
---@return table corpses RezCorpse array, in no particular order
local function scanCorpses()
    local found, seen = {}, {}
    local myName = tostring(mq.TLO.Me.CleanName() or ""):lower()

    local order = Rezzing._.order
    if order ~= nil then
        addCorpsesOf(found, seen, order.name)
    end

    for index = 1, (tonumber(mq.TLO.Group.Members()) or 0) do
        -- the member's *name* rather than their spawn: a group member who released to bind is
        -- standing in another zone, and their corpse is the thing lying here
        local name = mq.TLO.Group.Member(index).Name()
        if name ~= nil and tostring(name):lower() ~= myName then
            addCorpsesOf(found, seen, tostring(name))
        end
    end

    return found
end

---Have the ground looked at again on the next pass rather than up to a second from now.
---
---Called wherever the order changes, because the last look is *derived* from it: an order puts
---somebody outside the group into the list, and a cached list outliving the order that added them
---is a corpse still being rezzed after `reznow off` said to stop.
local function forgetLook()
    Rezzing._.lastScanMs = 0
end

---Forget everything about this zone's corpses. Spawn ids mean nothing across a zone line, and
---neither does an offer made or an order given on the other side of one.
---@param zoneId number
local function enterZone(zoneId)
    Rezzing._.zoneId = zoneId
    Rezzing._.corpses = {}
    Rezzing._.lastScanMs = 0
    Rezzing._.offers = {}
    Rezzing._.order = nil
end

---@return table corpses the reading, cached between scans
local function getCorpses()
    local zoneId = tonumber(mq.TLO.Zone.ID()) or 0
    if zoneId ~= Rezzing._.zoneId then enterZone(zoneId) end

    local now = Time.current_time()
    if now - Rezzing._.lastScanMs >= scanIntervalMs then
        Rezzing._.lastScanMs = now
        Rezzing._.corpses = scanCorpses()
    end
    return Rezzing._.corpses
end

---What this character makes of what is lying there, worked out fresh and put in order.
---
---**Kept apart from the scan on purpose.** Finding corpses is a spawn search per group member and is
---paced; deciding what to do about them is reading a few settings and is not. Baking the judgment
---into the cached reading is the bug that separating them prevents: a class switched off, a class
---moved up the order, the tank switch flipped -- every one of those is a decision the user just
---made on the page, and every one of them would have gone on being ignored until the next scan.
---That is the "decide every pass" rule with the expensive half cached, which is the same shape
---`healState` reads the group's health in.
---@return table candidates RezCandidate array, best first
local function rankCorpses()
    local mainTank = Roles.GetMainTank()
    local order = Rezzing._.order
    -- whether the class list's flag applies at all, asked from the world every time for the reason
    -- every other read here is: a fight starting changes the answer on the pass it starts, and out
    -- of one the list is only an order
    local inCombat = Combat.IsEngaged()
    local ranked = {}

    for _, corpse in ipairs(getCorpses()) do
        local rank, enabled = HealStateConfig.GetRezClassRank(corpse.class, inCombat)
        local isOrdered = order ~= nil and order.name:lower() == corpse.name:lower()

        ranked[#ranked+1] = {
            id = corpse.id,
            name = corpse.name,
            class = corpse.class,
            distance = corpse.distance,
            -- by name rather than by id: the id we have is the corpse's, and the role is held by
            -- the person. A tank who released to bind has no spawn here at all
            isTank = Roles.Matches(mainTank, nil, corpse.name),
            isOrdered = isOrdered,
            rank = rank,
            -- somebody who asked is rezzed whatever the class list says: that list is this
            -- character's own judgment about who to go to first, and an order is not that
            enabled = enabled or isOrdered
        }
    end

    -- **The whole of the ordering, in four lines and in this order.** Somebody asking outranks this
    -- character's own judgment, the same way a heal order does. The tank outranks the class list
    -- when that switch is on, because the role is the job and not the class holding it. Then the
    -- class list, which is the judgment. Then the nearest, which is only ever a tie-break and never
    -- a reason -- corpses at one pile are all in reach and the walk between them is nothing.
    local tankFirst = HealStateConfig.GetRezTankFirst()

    table.sort(ranked, function(a, b)
        if a.isOrdered ~= b.isOrdered then return a.isOrdered end
        if tankFirst and a.isTank ~= b.isTank then return a.isTank end
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.distance ~= b.distance then return a.distance < b.distance end
        -- a total order, so the sort cannot depend on which spawn the search happened to hand back
        -- first: two corpses of one person at one spot is a real thing, and a list that reshuffles
        -- them between passes is a rez started and abandoned every pass
        return a.id < b.id
    end)

    return ranked
end

---@return table candidates what is lying there and what this character makes of it, best first
function Rezzing.GetCorpses()
    return rankCorpses()
end

---@param corpseId number
---@return boolean isThere whether the corpse a rez is aimed at is still in the zone
function Rezzing.CorpseIsThere(corpseId)
    return mq.TLO.Spawn("id " .. tostring(corpseId)).ID() ~= nil
end

---------------- Whether to rez at all --------------------

---Why rezzing is not something this character should be doing right now, if it is not.
---
---Read from the world every pass rather than latched, like everything else in this state's family:
---a fight starting is what switches rezzing off for a character set to stay out of them, and it has
---to switch off on the pass the fight starts.
---
---A reason rather than a boolean because **this is the gate that looks like a broken healer**. The
---shipped default is out of combat only, so the ordinary first experience of a battle rez is a
---cleric standing over a corpse doing nothing and saying nothing about why. `/cheal` and the Heal
---State page both quote this now.
---@return string|nil reason nil when corpses are being rezzed
function Rezzing.ReasonNotRezzing()
    -- first because it is the cheapest and the commonest: most characters cannot rez at all, and
    -- this is what keeps the spawn searches below off their frames entirely
    if not Rezzes.Any() then return "nothing here brings anybody back" end
    if not HealStateConfig.IsRezzing() then return "switched off on the Heal State page" end
    if Combat.IsEngaged() and not HealStateConfig.GetRezInCombat() then
        return "in a fight, and this is set to rez out of combat only"
    end
    return nil
end

---The rez this character would cast in a fight, or out of one -- named, or worked out.
---
---**Two settings rather than one**, because the question is not the same question. Out of a fight
---the only thing that matters is the experience handed back; in one it is whether the cast bar
---survives at all. A cleric owning both a ten second Resurrection and an instant AA wants each of
---them in its own circumstance, and that is not something one dial can say.
---
---A name that this character does not own falls back to the worked-out answer rather than casting
---nothing -- a setting written on the cleric and read on the druid should not silently stop
---rezzing -- and the page says so against the setting.
---@param inCombat boolean
---@return Rez? rez
---@return boolean isNamed whether a configured name answered, rather than the fallback
---@return string? missing the name that was configured and is not in this character's book
function Rezzing.RezFor(inCombat)
    local name = inCombat and HealStateConfig.GetBattleRezSpell() or HealStateConfig.GetRezSpell()

    if name ~= HealStateConfig.AutoRez() then
        local named = Rezzes.Get(name)
        if named ~= nil then return named, true, nil end
        return (inCombat and Rezzes.Quickest() or Rezzes.Best()), false, name
    end

    return (inCombat and Rezzes.Quickest() or Rezzes.Best()), false, nil
end

---The rez to cast right now, and why there is none when there is none.
---
---One rez is chosen for the pass rather than one per corpse, because nothing about which one it
---should be varies from corpse to corpse -- only whether there is a fight on.
---
---**The chosen one is waited for rather than substituted.** If it is a few seconds from ready, that
---is what standing over a corpse is for -- quietly dropping to a weaker rank to save the wait would
---spend the group's experience to buy nothing, and a corpse is not in a hurry.
---@return Rez? rez
---@return string? reason why nothing was chosen, when nothing was
function Rezzing.ChooseRez()
    local notRezzing = Rezzing.ReasonNotRezzing()
    if notRezzing ~= nil then return nil, notRezzing end

    return (Rezzing.RezFor(Combat.IsEngaged())), nil
end

---------------- Who to rez --------------------

---@param corpseId number
---@return boolean isHeld whether a rez already offered to this corpse is still standing
local function isHeldOff(corpseId)
    local offer = Rezzing._.offers[corpseId]
    if offer == nil then return false end
    if offer.casts >= maxOffers then return true end
    return Time.current_time() < offer.untilMs
end

---Drop an order nobody could act on before it stopped meaning anything.
local function pruneOrder()
    local order = Rezzing._.order
    if order == nil then return end
    if Time.current_time() <= order.expiresMs then return end

    print("(rez) Too late to rez " .. order.name .. "; dropping the request")
    Rezzing._.order = nil
    forgetLook()
end

---@class RezTarget
---@field id number the corpse's spawn id
---@field name string who it belongs to
---@field isTank boolean
---@field isOrdered boolean
---@field beatsEmergency boolean whether this one is worth stepping in front of somebody in trouble

---The corpses worth offering a rez to this pass, best first.
---
---**A rez waits for the living, with one exception.** Nothing is cast at a corpse while somebody
---this character would actually heal is below the emergency mark -- the same guard curing is held
---to, asked the same careful way.
---
---The exception is the **tank's** corpse with a rez that has *no cast bar at all*. That one spends
---a global cooldown -- which is what a heal would have spent anyway -- and hands the group back the
---person it is built around, so holding it for a second person at 30% is a trade nobody wants made
---for them. Anything with a cast bar spends seconds the person at 30% needs, however short it is,
---so the line is drawn at zero rather than at a number somebody has to choose: it is a property of
---the spell, it cannot be set wrong, and it is exactly the battle-rez AA this is for.
---@param rez Rez|nil the rez chosen for this pass, which is what says whether it has a bar
---@param emergencyPending boolean whether somebody this state would heal is in real trouble
---@return table targets
function Rezzing.GetTargets(rez, emergencyPending)
    pruneOrder()

    local instant = rez ~= nil and rez.castMs <= 0 and HealStateConfig.GetRezTankFirst()
    local targets = {}

    for _, corpse in ipairs(rankCorpses()) do
        local beatsEmergency = corpse.isTank and instant

        if corpse.enabled and not isHeldOff(corpse.id)
            and (beatsEmergency or not emergencyPending) then
            targets[#targets+1] = {
                id = corpse.id,
                name = corpse.name,
                class = corpse.class,
                isTank = corpse.isTank,
                isOrdered = corpse.isOrdered,
                beatsEmergency = beatsEmergency
            }
        end
    end

    return targets
end

---------------- What has been offered --------------------

---A rez has gone out at this corpse. The offer stands from here: nothing that comes back says
---whether it was taken, so what is written down is that one is outstanding rather than that the job
---is done.
---@param corpseId number
---@param name string
function Rezzing.NoteCast(corpseId, name)
    local offer = Rezzing._.offers[corpseId] or { casts = 0 }
    offer.name = name
    offer.casts = offer.casts + 1
    offer.untilMs = Time.current_time() + offerStandsMs
    offer.lastFailure = nil
    Rezzing._.offers[corpseId] = offer

    -- an order is answered by the rez going out, not by anybody accepting it: what was asked for
    -- was a rez, and one has been cast
    local order = Rezzing._.order
    if order ~= nil and order.name:lower() == tostring(name):lower() then
        Rezzing._.order = nil
        forgetLook()
    end

    DebugLog("Rezzed [" .. tostring(name) .. "] (" .. tostring(offer.casts) .. " of " ..
        tostring(maxOffers) .. ")")
end

---A rez that did not go out. Kept rather than only logged, because this is the one thing standing
---between a corpse nothing is happening to and the person looking at it: a missing reagent, a wall
---between us and the corpse, a corpse out of range.
---@param corpseId number
---@param reason string|nil
function Rezzing.NoteFailure(corpseId, reason)
    local offer = Rezzing._.offers[corpseId] or { casts = 0 }
    offer.untilMs = Time.current_time() + retryAfterFailureMs
    offer.lastFailure = reason ~= nil and tostring(reason) or nil
    Rezzing._.offers[corpseId] = offer

    DebugLog("Rez of corpse [" .. tostring(corpseId) .. "] failed: " .. tostring(reason))
end

---@param corpseId number
---@return table? offer { name, casts, untilMs, lastFailure }
function Rezzing.GetOffer(corpseId)
    return Rezzing._.offers[corpseId]
end

---Why this corpse is not being rezzed, in words, for the page and `/cheal`.
---
---Every no about a corpse is otherwise silent -- it simply lies there while the healer stands over
---it -- and the two reasons look identical from outside: a class switched off in the list, and an
---offer already made that nobody has answered.
---@param corpse RezCandidate
---@return string|nil held nil when nothing is holding it
function Rezzing.ReasonHeld(corpse)
    -- only ever true during a fight -- the class list gates fights and nothing else -- so the line
    -- says so rather than reading as "this class is never rezzed", which is not a setting there is
    if not corpse.enabled then
        return (corpse.class or "that class") .. " is not worth breaking off a fight for"
    end

    local offer = Rezzing._.offers[corpse.id]
    if offer == nil then return nil end

    if offer.casts >= maxOffers then
        return "rezzed " .. tostring(offer.casts) .. " times with no answer -- say rezme to try again"
    end
    if Time.current_time() < offer.untilMs then
        if offer.lastFailure ~= nil then return "last try: " .. offer.lastFailure end
        return "waiting for them to take the rez already offered"
    end
    return nil
end

---------------- Orders --------------------

---@return table? order { name, expiresMs }
function Rezzing.GetOrder()
    return Rezzing._.order
end

---Take an order to rez somebody, by the name their corpse carries.
---
---The *person* is what is remembered rather than the corpse spawn, and that is what makes an order
---worth giving at all: the corpse is very often not in reach when the order is spoken, and looking
---for it every pass is what lets somebody say `rezme` while the group is still walking back.
---
---Safe to call from a render callback -- it reads the world and writes this module's own
---bookkeeping, and the cast that comes of it is issued from the heal state's pass.
---@param name string the character to rez
---@return string? refusal why nothing was taken on, when nothing was
function Rezzing.TakeOrder(name)
    name = tostring(name or "")
    if name == "" then return "I do not know who to rez" end

    local notRezzing = Rezzing.ReasonNotRezzing()
    -- answered now rather than left to stand and expire in silence, which is the difference between
    -- "my rezzing is off" and a healer that looks like it never heard
    if notRezzing ~= nil then return "I am not rezzing: " .. notRezzing end

    Rezzing._.order = { name = name, expiresMs = Time.current_time() + orderTimeoutMs }

    -- asking clears whatever this character had already offered that corpse and given up on: being
    -- asked is somebody saying they are at the keyboard to answer it this time
    for corpseId, offer in pairs(Rezzing._.offers) do
        if tostring(offer.name or ""):lower() == name:lower() then
            Rezzing._.offers[corpseId] = nil
        end
    end

    forgetLook()

    DebugLog("Rez ordered for [" .. name .. "]")
    return nil
end

---The character an order names, worked out from whatever spawn id was given: a corpse names its
---owner, and anybody else is the person themselves.
---@param spawnId number
---@return string? name nil when nothing here has that id
function Rezzing.NameForOrder(spawnId)
    local spawn = mq.TLO.Spawn("id " .. tostring(spawnId))
    if spawn.ID() == nil then return nil end

    local spawnName = tostring(spawn.CleanName() or "")
    return ownerOf(spawnName) or spawnName
end

---Forget the standing order. What `reznow off` is for; a rez already in the air is the heal state's
---to call off, since it is the one that asked for it.
---@return boolean dropped false when nothing was standing
function Rezzing.CallOff()
    if Rezzing._.order == nil then return false end
    Rezzing._.order = nil
    forgetLook()
    return true
end

---------------- Status --------------------

---@return string description of what rezzing amounts to right now, for /cheal and the page
function Rezzing.Describe()
    local notRezzing = Rezzing.ReasonNotRezzing()
    if notRezzing ~= nil then return "not rezzing: " .. notRezzing end

    local corpses = #Rezzing.GetCorpses()
    if corpses < 1 then return "no corpses of ours in reach" end
    return tostring(corpses) .. (corpses == 1 and " corpse" or " corpses") .. " in reach"
end

---@return number radius how far a corpse may be to be looked at at all
function Rezzing.GetRadius()
    return lookRadius
end

return Rezzing
