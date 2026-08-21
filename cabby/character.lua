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
    primaryMeleeBackups = {},
    secondaryMeleeAbilities = {},
    meleeAbilities = {},
    _ = {
        isInit = false,
        signature = nil,
        lastCheckMs = 0,
        baseInnates = {}
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

---Effects that make every reading about a shape we are wearing rather than about us:
---`SPA_CHANGE_FORM` (58) is what an illusion is made of and `SPA_PERM_ILLUSION` (238) is the one
---that outlives death.
local illusionSPAs = { 58, 238 }

---How many short-duration slots are looked at alongside the buff window. The buff window's count
---comes from the client (`MaxBuffSlots`); the short window has no such reading, so this is a
---bound rather than an answer -- the same one `cabby.curing` walks, for the same reason.
local shortBuffSlots = 30

---@param buff any a slot from either window
---@return boolean wearsIt whether this buff is what is putting a shape on us
local function isAShape(buff)
    local spell = buff.Spell
    if spell == nil or spell.ID() == nil then return false end

    for _, spa in ipairs(illusionSPAs) do
        if spell.HasSPA(spa)() == true then return true end
    end
    return false
end

---@return boolean isIllusioned whether the character is wearing some other race right now
---
---Both windows are walked and each occupied slot is asked what its *spell* does, rather than
---handing the client a predicate to search with: reading a buff's spell is the surface the rest
---of cabby already lives on (`cabby.curing`, `cabby.pet`), and it is the one this client is
---known to answer. Paid a few times a minute out of `Pulse`, never per frame.
function Character.IsIllusioned()
    local buffSlots = tonumber(mq.TLO.Me.MaxBuffSlots()) or shortBuffSlots
    for slot = 1, buffSlots do
        local buff = mq.TLO.Me.Buff(slot)
        if buff.ID() ~= nil and isAShape(buff) then return true end
    end

    for slot = 1, shortBuffSlots do
        local song = mq.TLO.Me.Song(slot)
        if song.ID() ~= nil and isAShape(song) then return true end
    end

    return false
end

---What the *character* has, as opposed to what the shape they are wearing has.
---
---An illusion is a race change, and the client rebuilds its innate abilities out of the race it
---is showing -- so a troll wearing a gnoll has no Slam and `Me.Ability` says so, honestly and
---about the gnoll. That reading cannot tell "this character never had it" from "not in this
---shape", which is the same trap as reading an empty buff cache: taken at face value it deletes
---an order nobody withdrew. So the answer is taken while nothing is worn -- where the client is
---describing us -- and held across the stretch where no such view exists. It is un-set by the
---next un-illusioned reading, never by a clock, and never written while a shape is on.
local function updateBaseInnates()
    if Character.IsIllusioned() then return end

    for _, skill in ipairs(Skills.innate) do
        Character._.baseInnates[skill:Name()] = skill:HasAction()
    end
end

---@param skill Skill
---@return boolean belongs whether this ability is the character's rather than the shape's
local function belongsToCharacter(skill)
    if skill:HasAction() then return true end
    if not skill:Innate() then return false end

    -- Innate, absent, and therefore only absent from whatever is being worn. Answer with what an
    -- un-illusioned look found, and if there has never been one -- cabby started under an
    -- illusion -- keep offering it: an unknown is not a no, and being wrong costs one dead entry
    -- in a picker rather than an order silently thrown away.
    return Character._.baseInnates[skill:Name()] ~= false
end

local function loadAbilities()
    -- Primary Melee Abilities
    Character.primaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.primary) do
        if belongsToCharacter(skill) then
            Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = skill
        end
    end
    Character.primaryMeleeAbilities[#Character.primaryMeleeAbilities+1] = Skills.none

    -- What a primary melee ability falls back to while it is not ours to use. Only abilities no
    -- illusion can reach, because an innate going away is the whole reason a backup exists --
    -- one that vanishes with the same shape change is no backup at all.
    Character.primaryMeleeBackups = {}
    for _, skill in ipairs(Skills.primary) do
        if not skill:Innate() and skill:HasAction() then
            Character.primaryMeleeBackups[#Character.primaryMeleeBackups+1] = skill
        end
    end
    Character.primaryMeleeBackups[#Character.primaryMeleeBackups+1] = Skills.none

    -- Secondary Melee Abilities (Monk)
    Character.secondaryMeleeAbilities = {}
    for _, skill in ipairs(Skills.secondary) do
        if belongsToCharacter(skill) then
            Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = skill
        end
    end
    Character.secondaryMeleeAbilities[#Character.secondaryMeleeAbilities+1] = Skills.none

    -- Melee Abilities
    Character.meleeAbilities = {}
    for _, skill in ipairs(Skills.melee) do
        if belongsToCharacter(skill) then
            Character.meleeAbilities[#Character.meleeAbilities+1] = skill
        end
    end
end

---@return string fingerprint of the innate half of the lists, as they would be built right now
local function innatesFingerprint()
    local parts = {}
    for _, skill in ipairs(Skills.innate) do
        parts[#parts+1] = skill:Name() .. "=" .. tostring(belongsToCharacter(skill))
    end
    return table.concat(parts, ",")
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
        freeInventory = tonumber(mq.TLO.Me.FreeInventory()) or 0,
        -- deliberately the *answer* about the innates rather than whether an illusion is on:
        -- a troll's Slam is the troll's whatever shape is over it, so a clicky moves nothing and
        -- nothing churns. What does move it is a human stepping into an ogre and gaining a Slam
        -- they never had -- and stepping back out of it -- and the first un-illusioned look at a
        -- troll that cabby started up already wearing something
        innates = innatesFingerprint()
    }
end

---Re-read what this character has.
---@param parts? table which registries to re-read; nil means all of them
function Character.Refresh(parts)
    parts = parts or { abilities = true, spells = true, aas = true, items = true }

    -- before anything reads an ability, so the lists are built against the freshest answer to
    -- "is this ours or the shape's"
    updateBaseInnates()

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

    updateBaseInnates()

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
    if current.innates ~= previous.innates then
        -- an illusion coming off is the usual way this moves: the client hands the innates back
        -- and we have finally seen the character rather than a costume
        parts.abilities = true
    end

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
