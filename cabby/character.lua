---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local Time = require("utils.Time.Time")

local AAs = require("cabby.actions.aas")
local ChelpDocs = require("cabby.commands.chelpDocs")
local Commands = require("cabby.commands.commands")
local Disciplines = require("cabby.actions.disciplines")
local Items = require("cabby.actions.items")
local Rezzes = require("cabby.actions.rezzes")
local Skills = require("cabby.actions.skills")
local SlashCmd = require("cabby.commands.slashcmd")
local Spells = require("cabby.actions.spells")

---What this character can do, as opposed to what its class can do.
---
---Everything a character *has* — skills, disciplines, spells, AAs, clickies — is discovered
---from the client rather than declared anywhere, because none of it is knowable in advance:
---the same shadowknight has different discs at 45 and at 70, and a different bag of clickies
---after every trip to the bazaar.
---
---Discovery is not free (the spellbook is 720 slots and the AA scan walks an id space), so it
---is not repeated per frame. Instead this runs as a service with a cheap signature — level, AA
---points spent, free inventory, a fingerprint of the book — checked a few times a minute, and
---re-reads only the registry that signature says has moved. `/crefresh` re-reads everything,
---for the cases the signature cannot see (an even item swap).
---@class Character
local Character = {
    key = "Character",
    primaryMeleeAbilities = {},
    secondaryMeleeAbilities = {},
    meleeAbilities = {},
    _ = {
        isInit = false,
        signature = nil,
        lastCheckMs = 0
    }
}

---How often the signature is looked at. Nothing here changes in the middle of a fight except
---by the player's own hand, so this is deliberately lazy -- and the book fingerprint means the
---check is no longer free either, so paying for it a few times a minute is the point.
local checkIntervalMs = 5000

---@param str string
local function DebugLog(str)
    Debug.Log(Character.key, str)
end

local function loadAbilities()
    -- Primary Melee Abilities
    Character.primaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.primary) do
        if skill:HasAction() then
            Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = skill
        end
    end
    Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = Skills.none

    -- Secondary Melee Abilities (Monk)
    Character.secondaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.secondary) do
        if skill:HasAction() then
            Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = skill
        end
    end
    Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = Skills.none

    -- Melee Abilities
    Character.meleeAbilities = {}
    for _, skill in ipairs(Skills.melee) do
        if skill:HasAction() then
            Character.meleeAbilities[#Character.meleeAbilities+1] = skill
        end
    end
end

---What each part of the signature stands for, and what re-reading it costs.
---@return table signature
local function readSignature()
    return {
        -- gaining a level opens up skills and discs
        level = tonumber(mq.TLO.Me.Level()) or 0,
        -- the only way an AA appears
        aaSpent = tonumber(mq.TLO.Me.AAPointsSpent()) or 0,
        -- the book answers for itself rather than being inferred from a level or a consumed
        -- scroll: a spell is scribed whenever the player feels like it, and the lists a caster
        -- picks a heal or a nuke from are wrong from that moment until this notices
        book = Spells.Fingerprint(),
        -- a stand-in for "the bags changed": it moves when anything is picked up or put down,
        -- and misses a swap that trades one item for another, which is what /crefresh is for
        freeInventory = tonumber(mq.TLO.Me.FreeInventory()) or 0
    }
end

---Re-read what this character has.
---@param parts? table which registries to re-read; nil means all of them
function Character.Refresh(parts)
    parts = parts or { abilities = true, spells = true, aas = true, items = true }

    if parts.abilities then
        Disciplines.Refresh()
        loadAbilities()
    end
    if parts.spells then Spells.Refresh() end
    if parts.aas then AAs.Refresh() end
    if parts.items then Items.Refresh() end

    -- built out of the two above rather than read on its own, so it is re-derived whenever either
    -- of them moves. A scribed rez and a bought rez AA are the same answer to "what can I bring
    -- somebody back with", and both arrive this way
    if parts.spells or parts.aas then Rezzes.Refresh() end

    Character._.signature = readSignature()
end

---@return string description of what was found, for /crefresh and status output
function Character.Describe()
    return "skills: " .. tostring(#Character.meleeAbilities) ..
        ", discs: " .. tostring(#Disciplines.all) ..
        ", spells: " .. tostring(#Spells.all) ..
        ", AAs: " .. tostring(#AAs.all) ..
        ", clickies: " .. tostring(#Items.all) ..
        ", rezzes: " .. tostring(#Rezzes.all)
end

---Service contract: watch the signature and re-read what moved.
function Character.Pulse()
    local now = Time.current_time()
    if now - Character._.lastCheckMs < checkIntervalMs then return end
    Character._.lastCheckMs = now

    local previous = Character._.signature
    local current = readSignature()
    if previous == nil then
        Character._.signature = current
        return
    end

    local parts = {}
    if current.level ~= previous.level then
        -- a level brings new discs with it, and can bring a skill
        parts.abilities = true
    end
    if current.book ~= previous.book then parts.spells = true end
    if current.aaSpent ~= previous.aaSpent then parts.aas = true end
    if current.freeInventory ~= previous.freeInventory then parts.items = true end

    if next(parts) == nil then
        Character._.signature = current
        return
    end

    DebugLog("Character changed, re-reading: " .. table.concat((function()
        local names = {}
        for part in pairs(parts) do names[#names+1] = part end
        table.sort(names)
        return names
    end)(), ", "))

    Character.Refresh(parts)
end

---@param stateMachine StateMachine
function Character.Init(stateMachine)
    if Character._.isInit then return end

    local ftkey = Global.tracing.open("Character Setup")

    stateMachine:RegisterService(Character)

    local refreshDocs = ChelpDocs.new(function() return {
        "(/crefresh) Re-read what this character has: skills, discs, spells, AAs and clickies",
        " -- Usage: /crefresh",
        " -- This happens on its own after a level, an AA purchase, a change in bag space, or",
        "    anything written to or erased from the spellbook.",
        "    Use this after anything else that changes what you can do -- swapping one clicky",
        "    for another of the same size.",
        " -- Currently: " .. Character.Describe()
    } end )
    local function Bind_CRefresh(...)
        local args = {...} or {}
        if #args > 0 and args[1]:lower() == "help" then
            refreshDocs:Print()
            return
        end

        Character.Refresh()
        print("(crefresh) " .. Character.Describe())
    end
    Commands.RegisterSlashCommand(SlashCmd.new("crefresh", Bind_CRefresh, refreshDocs))

    Character._.isInit = true
    Global.tracing.close(ftkey)
end

Character.HasTaunts = function()
    return Skills.taunt:HasAction() or #Disciplines.taunt > 0 or #AAs.taunt > 0
end

Character.HasHates = function()
    return #Disciplines.hate > 0 or #AAs.hate > 0
end

Character.HasSecondaryAbilities = function()
    return #Skills.secondary > 0
end

---@return boolean canCast whether this character has anything worth casting
Character.CanCast = function()
    return #Spells.all > 0 or #AAs.all > 0 or #Items.all > 0
end

-- Discovered at load: the config sections written during setup ask what this character has
-- before anything else runs.
Character.Refresh()

return Character
