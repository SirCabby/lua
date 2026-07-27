---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local CastAction = require("cabby.actions.castAction")

---What is in this character's spellbook.
---
---The book is a fixed array of 720 slots with holes in it — a spell is written to the page the
---player put it on, so an empty slot means nothing about the ones after it. The whole array is
---read, once, and again whenever `Character` decides something has changed.
---
---Nothing here is filtered by "can I cast it now": the gems, the mana and the recast timer are
---all questions for the moment of use (`CastAction:IsReady`). This is the longer-lived answer
---to "what does this character know", which is what a configuration screen needs to offer.
---@class Spells
local Spells = {
    key = "Spells",
    all = {},           -- every spell in the book, strongest (highest level) first
    beneficial = {},    -- heals, buffs, cures -- anything you point at a friend or yourself
    detrimental = {}    -- nukes, debuffs, mez -- anything you point at a mob
}

local bookSlots = 720

---@param str string
local function DebugLog(str)
    Debug.Log(Spells.key, str)
end

---@param name string
---@return CastAction? spell
function Spells.Get(name)
    if name == nil then return nil end
    name = tostring(name):lower()

    for _, spell in ipairs(Spells.all) do
        ---@type CastAction
        spell = spell
        if spell:Name():lower() == name then
            return spell
        end
    end

    return nil
end

---Re-read the spellbook.
---
---Sorted by level, highest first, because that is the order a caster thinks in: the newest
---rank of a line is the one they mean, and it is the one they should not have to scroll past
---sixteen older ranks to find.
function Spells.Refresh()
    Spells.all = {}
    Spells.beneficial = {}
    Spells.detrimental = {}

    local levels = {}

    for slot = 1, bookSlots do
        local book = mq.TLO.Me.Book(slot)
        local name = book.Name()

        -- an empty slot is a hole in the book, not the end of it
        if name ~= nil then
            local spell = CastAction.Spell(name)
            levels[spell] = tonumber(book.Level()) or 0
            Spells.all[#Spells.all+1] = spell

            if book.Beneficial() then
                Spells.beneficial[#Spells.beneficial+1] = spell
            else
                Spells.detrimental[#Spells.detrimental+1] = spell
            end
        end
    end

    local function byLevelThenName(a, b)
        if levels[a] ~= levels[b] then return levels[a] > levels[b] end
        return a:Name() < b:Name()
    end

    table.sort(Spells.all, byLevelThenName)
    table.sort(Spells.beneficial, byLevelThenName)
    table.sort(Spells.detrimental, byLevelThenName)

    DebugLog("Found " .. tostring(#Spells.all) .. " spells in the book")
end

return Spells
