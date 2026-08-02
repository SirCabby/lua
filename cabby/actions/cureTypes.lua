local AAs = require("cabby.actions.aas")
local Spells = require("cabby.actions.spells")

---What a cure *is*, by the counters it takes off, so somebody can ask for one without knowing
---what the character they are asking has in its book.
---
---`cure poison` is a request made in the words a person uses at the keyboard, and one line of it
---has to land on whichever of Cure Poison, Counteract Poison, Abolish Poison or Radiant Cure each
---character hearing it happens to own. So a type is defined by the **effect** its spells carry --
---the counter it removes -- never by a spell name and never by a heading, the same standard
---`cabby.actions.buffTypes` and `Spells.Controls` are held to, and for the same reasons.
---
---**The counter is the whole model, and it is exact.** EverQuest gives every curable affliction a
---number of counters of one of four kinds, and a cure is a spell that removes some of them: the
---affliction carries the counter effect at a positive base ("Increase Disease Counter by 9") and
---the cure carries the same effect at a negative one ("Decrease Disease Counter by 9"). That sign
---is the only difference between the two, which is why every read here goes through it -- and why
---this file can answer both halves of the job from one table: what is *on* somebody
---(`TypesOf`) and what would take it off (`Best`).
---
---Everything here is data: a type is one row.
---@class CureTypes
local CureTypes = {
    key = "CureTypes",
    _ = {
        byName = nil -- built on first lookup: { <normalized name or alias> = CureType }
    }
}

---@param base number
---@return boolean
local function positive(base) return base > 0 end

---@param base number
---@return boolean
local function negative(base) return base < 0 end

---@class CureType
---@field key string what somebody types, and what this cure is called back to them
---@field summary string what it does, in words, for /chelp and the button picker
---@field spa number the counter effect an affliction of this kind carries, and a cure removes
---@field aliases table other spellings of the same request

---The four kinds of counter, which is the whole of what can be cured.
---
---Not a curated list like the buff types are -- there is nothing to curate. EverQuest has exactly
---these four counters (`IsSpellCountersSPA` in the client's own spell code names the same four),
---so this is the complete set rather than a selection of the ones people shout for.
local types = {
    { key = "poison", summary = "poison", spa = 36,
      aliases = { "poisoned", "psn", "pois" } },

    { key = "disease", summary = "disease", spa = 35,
      aliases = { "diseased", "dis", "disease" } },

    { key = "curse", summary = "a curse", spa = 116,
      aliases = { "cursed", "crs" } },

    { key = "corruption", summary = "corruption", spa = 369,
      aliases = { "corrupted", "corrupt", "corr" } }
}

---Where a cure can be aimed, read off the spell rather than configured -- the same model the heal
---and buff states use, and for the same reason: what a spell can land on is what it is.
local aims = {
    self = "self",     -- only ever lands on the caster
    group = "group",   -- one cast covers the whole group and needs no target
    single = "single"  -- one person at a time
}

local groupTargetTypes = { ["group v1"] = true, ["group v2"] = true }

---A pet cure is left out rather than aimed. Nothing asks for one: the request half of this comes
---from a *player* saying they are afflicted, and a pet does not talk. It would be a job for the
---pet states, which watch the pet, and there is nothing here for it to answer.
local unaimableTargetTypes = {
    ["pet"] = true,
    ["pet2"] = true,
    ["pet owner"] = true
}

---How a typed name is compared: lowercased, with everything that is not a letter or a digit
---dropped, so `Cure Poison`, `cure-poison` and `curepoison` are one word to a person.
---@param name string|nil
---@return string|nil normalized nil for anything with no letters or digits in it at all
local function normalize(name)
    if name == nil then return nil end
    local normalized = tostring(name):lower():gsub("[^%a%d]", "")
    if normalized == "" then return nil end
    return normalized
end

---@return table byName every name and alias, pointing at its type
local function index()
    if CureTypes._.byName ~= nil then return CureTypes._.byName end

    local byName = {}
    for _, cureType in ipairs(types) do
        byName[normalize(cureType.key)] = cureType
        for _, alias in ipairs(cureType.aliases or {}) do
            byName[normalize(alias)] = cureType
        end
    end

    CureTypes._.byName = byName
    return byName
end

---@param name string|nil what somebody typed
---@return CureType? cureType nil when nothing here goes by that name
function CureTypes.Get(name)
    local normalized = normalize(name)
    if normalized == nil then return nil end
    return index()[normalized]
end

---@return table types every cure that can be asked for, in the order they are offered
function CureTypes.All()
    return types
end

---@return table names every canonical name, for /chelp and the button picker
function CureTypes.Names()
    local names = {}
    for _, cureType in ipairs(types) do
        names[#names+1] = cureType.key
    end
    return names
end

---What this affliction needs cured off, by type key.
---
---The other half of the counter model: an affliction carries the counter effect at a *positive*
---base, which is what tells it from the cure that removes the same counter. Beneficial spells are
---refused outright rather than being left to the sign test -- a spell on the friendly half of the
---book is not something anybody is afflicted with, whatever it carries.
---
---An array rather than one answer because a spell may carry two: a few of them are poison and
---disease at once, and curing only the half we happened to notice would leave somebody asking
---again in twenty seconds.
---@param spell any mq spell TLO, or nil
---@return table keys type keys this spell afflicts, empty for anything that afflicts none
function CureTypes.TypesOf(spell)
    local keys = {}
    if spell == nil then return keys end
    if spell.Beneficial() == true then return keys end

    for _, cureType in ipairs(types) do
        if Spells.HasEffect(spell, { cureType.spa }, positive) then
            keys[#keys+1] = cureType.key
        end
    end

    return keys
end

---@param subject CastSubject
---@return string aim one of `aims`
local function aimOf(subject)
    local targetType = subject:TargetType()
    if groupTargetTypes[targetType] then return aims.group end
    if targetType == "self" then return aims.self end
    return aims.single
end

---How many counters of this kind the action takes off, or nil when it takes off none.
---
---The magnitude is what "best" means here, and it is the one place this file departs from
---`BuffTypes.Best`, which takes the highest rank of a line. A buff line gets better with rank and
---nothing else says so in the data; a cure says exactly how much work it does, right there in the
---effect, and the ranks are not always in the order the levels are -- an old single-counter cure
---and a new one that strips nine are the same spell to a level sort and are not remotely the same
---answer to somebody standing in a poison DoT.
---@param action CastAction
---@param spa number
---@return number|nil counters
local function curePower(action, spa)
    local subject = action:Subject()
    local spell = subject:Spelldata()
    if spell == nil then return nil end
    -- the friendly half of the book: an *affliction* carries the same effect the other way up,
    -- and nothing here should ever offer one as a cure
    if spell.Beneficial() ~= true then return nil end

    local base = Spells.EffectBase(spell, { spa }, negative)
    if base == nil then return nil end
    return -base
end

---The best cure this character has of a type, of each aim it can be asked for.
---
---**Best is the most counters removed**, for the reason `curePower` gives. Ties go to whatever
---came first, which is the higher-ranked spell: `Spells.beneficial` is sorted level-first.
---
---**Read out of the beneficial half of the book and the AA list**, rather than out of a heading.
---The effect match is exact, so the narrowing buys nothing -- and it would cost: the client files
---cures under Heals on some lines and under Utility Beneficial on others, and a cleric's Radiant
---Cure is not in the book at all. Clickies are not consulted; an item cure is a slot on an action
---list rather than something to be discovered.
---
---All three aims are returned rather than one, because which is wanted is the caller's question:
---a group cure is one gem timer for six people but only reaches the caller's own group, somebody
---outside it needs the single-target spell, and a self-only cure is the answer to nothing but our
---own affliction.
---@param cureType CureType
---@return CastAction? single the best that lands on one person at a time
---@return CastAction? group the best that covers a whole group in one cast
---@return CastAction? selfOnly the best that can only ever land on us
function CureTypes.Best(cureType)
    if cureType == nil then return nil, nil, nil end

    local best = {}

    ---@param action CastAction
    local function consider(action)
        local subject = action:Subject()
        local targetType = subject:TargetType()
        if unaimableTargetTypes[targetType] then return end

        local counters = curePower(action, cureType.spa)
        if counters == nil then return end

        local aim = aimOf(subject)
        local held = best[aim]
        if held == nil or counters > held.counters then
            best[aim] = { action = action, counters = counters }
        end
    end

    for _, action in ipairs(Spells.beneficial) do consider(action) end
    for _, action in ipairs(AAs.all) do consider(action) end

    ---@param aim string
    ---@return CastAction?
    local function pick(aim)
        local held = best[aim]
        return held ~= nil and held.action or nil
    end

    return pick(aims.single), pick(aims.group), pick(aims.self)
end

---Could this character answer a cure request at all?
---
---Asked before saying "I do not know a cure called that" out loud, and before taking a request on
---at all. The request goes to everybody listening, so a complaint from every character that heard
---it is worse than the typo it is reporting -- and a character with nothing beneficial in its book
---and no AAs was never going to be the one to answer, whatever was asked for.
---@return boolean couldAnswer
function CureTypes.CouldAnswer()
    return #Spells.beneficial > 0 or #AAs.all > 0
end

return CureTypes
