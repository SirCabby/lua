local Spells = require("cabby.actions.spells")

---What a buff *is*, by name, so somebody can ask for one without knowing what the character they
---are asking has in its book.
---
---`buff invis` is a request made in the words a person uses at the keyboard, and one line of it has
---to land on whichever of Invisibility, Superior Camouflage or Improved Invisibility each character
---hearing it happens to own. So a type is defined by the **effect** its spells carry, never by a
---spell name and never by a heading -- the same standard the crowd control list is held to (see
---`Spells.Controls`), and for the same reasons: a name is a label the server can reword, a heading
---is filing, and an effect is what the spell does.
---
---This is the ad-hoc half of buffing, and it is deliberately not the configured half. A buff slot
---on the Buff State page says "keep this up on these people forever"; a type here answers "hand me
---one of these, now", which is a different question with a different answer -- the *best* one this
---character has, whatever that turns out to be, chosen at the moment of asking.
---
---Everything here is data: a type nobody has asked for yet is one row.
---@class BuffTypes
local BuffTypes = {
    key = "BuffTypes",
    _ = {
        byName = nil -- built on first lookup: { <normalized name or alias> = BuffType }
    }
}

---@param base number
---@return boolean
local function positive(base) return base > 0 end

---@param base number
---@return boolean
local function negative(base) return base < 0 end

---@class BuffType
---@field key string what somebody types, and what this buff is called back to them
---@field summary string what it does, in words, for /chelp and the button picker
---@field spas table SPA numbers; a spell carrying any one of them is of this type
---@field accept fun(base: number): boolean|nil the sign test, for the effects that read both ways
---@field aliases table other spellings of the same request

---The buffs that get shouted for.
---
---Chosen for that and nothing else: these are the ones somebody asks for out loud, in the middle
---of doing something else -- about to sneak past a camp, about to swim, about to run somewhere.
---The stat buffs and the resist lines are not here, because nobody shouts for strength; that is
---upkeep, and upkeep is the configured slot list on the Buff State page.
---
---Where one SPA number does opposite jobs depending on its sign, the sign test is what says which
---job is meant -- SPA 3 is a run speed buff at a positive base and a snare at a negative one, and
---the same is true of haste against slow. The beneficial half of the book rules most of those out
---by itself; the tests are here anyway, because a filter that only works because of another filter
---is one refactor away from not working.
local types = {
    { key = "invis", summary = "invisibility", spas = { 12 },
      aliases = { "invisibility", "ivis", "camo", "camouflage" } },

    { key = "ivu", summary = "invisibility versus undead", spas = { 28 },
      aliases = { "invisvsundead", "invisundead", "undead" } },

    { key = "iva", summary = "invisibility versus animals", spas = { 29 },
      aliases = { "invisvsanimals", "invisanimals", "animals" } },

    { key = "seeinvis", summary = "see invisible", spas = { 13 },
      aliases = { "si", "seeinvisible", "see" } },

    { key = "lev", summary = "levitation", spas = { 57 },
      aliases = { "levitate", "levi", "levitation", "float" } },

    { key = "sow", summary = "run speed", spas = { 3 }, accept = positive,
      aliases = { "speed", "runspeed", "run", "movement", "spiritofwolf" } },

    { key = "eb", summary = "enduring breath", spas = { 14 },
      aliases = { "breath", "breathe", "enduringbreath", "water", "waterbreathing" } },

    -- SPA 98 alongside 11: a bard's haste songs carry the bard-specific effect and nothing else,
    -- so a haste read that knows only about SPA 11 hears no bard at all
    { key = "haste", summary = "melee haste", spas = { 11, 98 }, accept = positive,
      aliases = { "quickness", "celerity", "hastebuff" } },

    { key = "ds", summary = "a damage shield", spas = { 59 },
      aliases = { "damageshield", "thorns" } },

    { key = "hp", summary = "maximum hit points", spas = { 69 }, accept = positive,
      aliases = { "health", "hitpoints", "symbol", "aego", "aegolism", "hitpointbuff" } },

    -- SPA 0 with a positive base is a heal; what makes this one a *regen* is the duration check in
    -- `Best`, which every type goes through and which no instant heal passes
    { key = "regen", summary = "health regeneration", spas = { 0 }, accept = positive,
      aliases = { "regeneration", "hot", "healovertime" } },

    -- the Clarity line, and only that: SPA 15 over a duration is mana coming back, which is what
    -- somebody shouting for `c` wants. An instant mana gift carries the same effect with no
    -- duration and is dropped by the duration check every type goes through, and a bigger mana
    -- *pool* is SPA 97, which is a different buff and not this one
    { key = "mana", summary = "mana regeneration", spas = { 15 }, accept = positive,
      aliases = { "c", "clarity", "kei", "manaregen", "crack" } },

    { key = "rune", summary = "a damage-absorbing rune", spas = { 55 },
      aliases = { "stoneskin", "skin", "absorb" } },

    { key = "shrink", summary = "shrink", spas = { 89 }, accept = negative,
      aliases = { "small", "tiny", "grow" } },

    { key = "vision", summary = "night vision", spas = { 65, 66 },
      aliases = { "ultravision", "infravision", "uv", "nightvision", "darkvision" } },

    { key = "resists", summary = "resistances", spas = { 46, 47, 48, 49, 50, 111 }, accept = positive,
      aliases = { "resist", "resistbuff", "mr", "sr" } }
}

---Where a spell can be aimed, read off the spell the way the buff state's upkeep list reads it.
local groupTargetTypes = { ["group v1"] = true, ["group v2"] = true }

---The aims that are no answer to a request, whatever effect the spell carries. A request names
---somebody to buff, and neither of these can be handed to anybody: a self-only buff lands on the
---caster however it is aimed, and a pet buff lands on the caster's pet. Both are upkeep -- they
---belong in the configured slot list, which is where they already are.
local unaimableTargetTypes = {
    ["self"] = true,
    ["pet"] = true,
    ["pet2"] = true,
    ["pet owner"] = true
}

---How a typed name is compared: lowercased, with everything that is not a letter or a digit
---dropped. `See Invis`, `see-invis` and `seeinvis` are one word to a person, and this is a request
---a person types into a chat window.
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
    if BuffTypes._.byName ~= nil then return BuffTypes._.byName end

    local byName = {}
    for _, buffType in ipairs(types) do
        byName[normalize(buffType.key)] = buffType
        for _, alias in ipairs(buffType.aliases or {}) do
            byName[normalize(alias)] = buffType
        end
    end

    BuffTypes._.byName = byName
    return byName
end

---@param name string|nil what somebody typed
---@return BuffType? buffType nil when nothing here goes by that name
function BuffTypes.Get(name)
    local normalized = normalize(name)
    if normalized == nil then return nil end
    return index()[normalized]
end

---@return table types every buff that can be asked for, in the order they are offered
function BuffTypes.All()
    return types
end

---@return table names every canonical name, for /chelp and the button picker
function BuffTypes.Names()
    local names = {}
    for _, buffType in ipairs(types) do
        names[#names+1] = buffType.key
    end
    return names
end

---The best spell this character has of a type, of each aim it can be asked for.
---
---**Best is the highest rank of the line.** `Spells.beneficial` is already sorted level first, so
---the first match is the newest one scribed -- which is what a caster means when they name a line
---out loud, and what the rest of this script means by "strongest" everywhere else.
---
---**Read out of the beneficial half of the book rather than the buff list.** The buff list narrows
---by heading, and a heading is filing: shrink and enduring breath sit under Utility Beneficial on
---most lines and would simply be missing from an invis-or-lev request that had every right to find
---them. The narrowing buys nothing here, because the effect match is exact -- and the duration
---check does the one job the heading was really doing, since what separates a buff from a heal is
---that a buff lasts.
---
---Both aims are returned rather than one, because which is wanted is the caller's question and not
---this module's: a group cast is one gem timer for six people, but it only reaches the caller's own
---group, and somebody who is not in it needs the single-target spell however many people also
---asked.
---@param buffType BuffType
---@return CastAction? single the best that lands on one person at a time
---@return CastAction? group the best that covers a whole group in one cast
function BuffTypes.Best(buffType)
    if buffType == nil then return nil, nil end

    local single, group

    for _, action in ipairs(Spells.beneficial) do
        ---@type CastAction
        action = action
        local subject = action:Subject()
        local targetType = subject:TargetType()

        if not unaimableTargetTypes[targetType] then
            local spell = subject:Spelldata()
            if spell ~= nil and Spells.DurationMs(spell) > 0
                and Spells.HasEffect(spell, buffType.spas, buffType.accept) then
                if groupTargetTypes[targetType] then
                    group = group or action
                else
                    single = single or action
                end
            end
        end

        -- the list is sorted, so once both aims have an answer nothing further down can beat it
        if single ~= nil and group ~= nil then break end
    end

    return single, group
end

---Could this character answer a buff request at all?
---
---Asked before saying "I do not know a buff called that" out loud. The request goes to everybody
---listening, so a complaint from every character that heard it is worse than the typo it is
---reporting -- and a character with nothing beneficial in its book was never going to be the one
---to answer, whatever was asked for.
---@return boolean couldAnswer
function BuffTypes.CouldAnswer()
    return #Spells.beneficial > 0
end

return BuffTypes
