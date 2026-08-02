---@diagnostic disable: undefined-field
local Debug = require("utils.Debug.Debug")

local AAs = require("cabby.actions.aas")
local Spells = require("cabby.actions.spells")

---What this character can bring somebody back with.
---
---A rez is the one beneficial cast aimed at a **corpse**, and both halves of what makes one worth
---choosing are exact numbers sitting in the spell data: `SPA_RESURRECT` carries the percentage of
---the lost experience it hands back in its base value, and the cast time says whether it could
---survive a fight. This is the registry of both, discovered the same way
---`cabby.actions.cureTypes` discovers cures -- and the two numbers are why the heal state has two
---rez settings rather than one: a cure has a single dimension to be best on, and a rez has two,
---and which of them matters is decided by whether anybody is swinging at us.
---
---**Ordered by experience returned, most first**, a shorter cast breaking a tie. That order is
---`Best`; `Quickest` is the same list read for the other number. Between them they are what those
---two settings mean when nobody has named a spell -- and naming one is `Get`, which answers nil for
---a rez this character does not own rather than pretending.
---
---Read out of the *whole* book and the AA list rather than out of a heading or the beneficial half.
---The target type is an exact answer and costs one member per spell to ask, so narrowing buys
---nothing and could only lose a rez the client happened to file somewhere unexpected. Clickies are
---not consulted, exactly as they are not for cures.
---@class Rezzes
local Rezzes = {
    key = "Rezzes",
    ---@type table every rez this character owns, most experience returned first
    all = {}
}

---SPA_RESURRECT (81). Its base value is the percentage of the experience lost on death that the
---rez hands back -- 96 for a cleric's Resurrection, 90 for the ranks under it -- which is exactly
---what "the best rez I own" means, in the data, with no spell names anywhere.
local spaResurrect = 81

---What the client calls the target type every rez carries (`TargetType_TargetCorpse`). Asked before
---anything else because it is one member read and it is false for all but a handful of spells in
---any book, which is what keeps a refresh from walking the effect slots of the other seven hundred.
local corpseTargetType = "corpse"

---@param str string
local function DebugLog(str)
    Debug.Log(Rezzes.key, str)
end

---@class Rez
---@field action CastAction what to cast
---@field expPct number percentage of the lost experience it hands back
---@field castMs number how long the cast bar will be up; 0 for an instant AA

---@param action CastAction
---@return Rez? rez nil for anything that is not a rez
local function read(action)
    local subject = action:Subject()
    if subject:TargetType() ~= corpseTargetType then return nil end

    local spell = subject:Spelldata()
    if spell == nil then return nil end

    -- a corpse-aimed spell that does not carry the effect is not a rez: `Summon Corpse` is the one
    -- that matters, and dragging a corpse over is not bringing anybody back
    local expPct = Spells.EffectBase(spell, { spaResurrect })
    if expPct == nil then return nil end

    return { action = action, expPct = expPct, castMs = subject:CastTimeMs() }
end

---Re-read what this character can rez with. Called by `cabby.character` whenever the book or the
---AA list moves, the same way the registries this is built out of are.
function Rezzes.Refresh()
    Rezzes.all = {}

    ---@param action CastAction
    local function consider(action)
        local rez = read(action)
        if rez ~= nil then Rezzes.all[#Rezzes.all+1] = rez end
    end

    for _, action in ipairs(Spells.all) do consider(action) end
    for _, action in ipairs(AAs.all) do consider(action) end

    table.sort(Rezzes.all, function(a, b)
        if a.expPct ~= b.expPct then return a.expPct > b.expPct end
        -- a tie on experience goes to the one that spends less of the group's time standing still
        if a.castMs ~= b.castMs then return a.castMs < b.castMs end
        return a.action:Name() < b.action:Name()
    end)

    DebugLog("Found " .. tostring(#Rezzes.all) .. " rez" .. (#Rezzes.all == 1 and "" or "zes"))
end

---The one that hands back the most experience. What "best" means with nobody swinging at us.
---@return Rez? rez
function Rezzes.Best()
    return Rezzes.all[1]
end

---The one with the shortest cast bar. What "best" means in a fight, where the question is not how
---much experience it hands back but whether the cast survives at all -- a ten second bar in the
---middle of a fight is a cast thrown away the moment anybody drops.
---
---Ties go to the most experience, which the list order already settles.
---@return Rez? rez
function Rezzes.Quickest()
    local quickest = nil
    for _, rez in ipairs(Rezzes.all) do
        if quickest == nil or rez.castMs < quickest.castMs then quickest = rez end
    end
    return quickest
end

---@param name string|nil
---@return Rez? rez nil for a name this character does not own, which is how a setting written on
---one character and read on another is caught rather than acted on
function Rezzes.Get(name)
    if name == nil or name == "" then return nil end
    name = tostring(name):lower()

    for _, rez in ipairs(Rezzes.all) do
        if rez.action:Name():lower() == name then return rez end
    end
    return nil
end

---@return boolean any whether this character can rez at all
function Rezzes.Any()
    return #Rezzes.all > 0
end

---@param rez Rez|nil
---@return string description for /cheal and the Heal State page
function Rezzes.Describe(rez)
    if rez == nil then return "nothing" end
    return rez.action:Name() .. " (" .. tostring(math.floor(rez.expPct)) .. "% experience, " ..
        (rez.castMs <= 0 and "instant" or (string.format("%.1f", rez.castMs / 1000) .. "s")) .. ")"
end

return Rezzes
