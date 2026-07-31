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
    detrimental = {},   -- nukes, debuffs, mez -- anything you point at a mob
    heals = {},         -- the beneficial half a heal list is picked from
    buffs = {},         -- the beneficial half a buff list is picked from
    damage = {},        -- what a damage rotation is picked from: what is cast at a mob to hurt it,
                        -- and the damage shields cast on a friend that do the same job
    control = {},       -- what a crowd control list is picked from -- see `Spells.Controls`
    petSummons = {},    -- what puts a pet beside us
    itemSummons = {},   -- what conjures an item, which is how a pet gets its gear
    _ = {
        categories = {} -- lowercased spell name -> how its filing reads, for the pickers
    }
}

local bookSlots = 720

---EverQuest's own spell category numbers (`eEQSPELLCAT`), which is also what a *sub*category is
---drawn from — one table serves both fields. Matched by number rather than by the name the
---client prints for it, because that name comes out of the server's string table: a server that
---rewords or translates a heading would quietly empty every list below it.
local cats = {
    aegolism            = 1,
    agility             = 2,
    armorClass          = 6,
    attack              = 7,
    charisma            = 12,
    damageShield        = 21,
    dexterity           = 24,
    directDamage        = 25,
    durationHeals       = 32,
    fizzleRate          = 39,
    haste               = 41,
    heals               = 42,
    health              = 43,
    healthMana          = 44,
    hpBuffs             = 45,
    hpTypeOne           = 46,
    hpTypeTwo           = 47,
    invisibility        = 51,
    invulnerability     = 52,
    levitate            = 55,
    mana                = 59,
    manaFlow            = 61,
    meleeGuard          = 62,
    movement            = 65,
    petHaste            = 70,
    petMiscBuffs        = 71,
    quickHeal           = 77,
    reflection          = 78,
    regen               = 79,
    resistBuff          = 80,
    root                = 83,
    rune                = 84,
    shielding           = 87,
    snare               = 89,
    spellFocus          = 91,
    spellGuard          = 92,
    spellshield         = 93,
    stamina             = 94,
    statisticBuffs      = 95,
    strength            = 96,
    symbol              = 112,
    utilityDetrimental  = 126,
    vision              = 129,
    wisdomIntelligence  = 130,
    auras               = 132,
    endurance           = 133,
    twincast            = 142,
    hasteSpellFocus     = 145
}

---What a spell *does*, as EverQuest's own effect numbers (`eqlib`'s `SPA_*`, read out of the
---spell's effect slots rather than out of its filing). The questions answered here rather than by
---a category are the ones with an exact answer in the data: a spell that summons a pet carries the
---effect that summons one, whatever heading the client files it under; a spell that conjures an
---item carries the item's own id in the base value of that effect; and a mez is a mez because it
---carries the effect that mesmerizes, which is what the client's own `Mezzed` reading is built on
---(`SpellAffect(SPA_ENTHRALL)` in `MQ2SpawnType.cpp`) -- so cabby and the client agree about what
---is on a mob by construction rather than by coincidence.
local spas = {
    ---SPA_CREATE_ITEM (32) and SPA_CREATE_ITEM_IN_BAG (109): the base value of the effect is the
    ---id of the item it makes
    createItem = { 32, 109 },
    ---the pet lines: SPA_SUMMON_PET (33, the animations and elementals), SPA_CREATE_UNDEAD (71,
    ---the necromancer and shadow knight pets), SPA_BEASTLORD_PET (106), SPA_FAMILIAR (108) and
    ---SPA_POCKET_PET (151). Deliberately not SPA_PET_SWARM (152): a swarm is several pets for a
    ---few seconds, which is a rotation slot rather than a companion to keep up
    summonPet = { 33, 71, 106, 108, 151 },
    ---SPA_ENTHRALL (31): a mez. The one effect that holds a mob still and drops off the moment
    ---anything hits it, which is the whole of what a mez state has to manage. Unambiguous in a way
    ---the others here are not -- no spell carries a mez as a side effect of being something else
    mesmerize = { 31 },
    ---The two ways a spell takes a mob's next few seconds off it: SPA_STUN (21) and
    ---**SPA_SPIN_STUN (64)**, the spin line -- an enchanter's Whirl Till You Hurl and Dyn's
    ---Dizzying Draught carry the second and nothing else at all, so a stun read that knows only
    ---about 21 silently loses a whole line of spells the class has had since level nine.
    ---
    ---Deliberately not SPA_FEARSTUN (502), which stuns and *fears*: a feared mob runs, which is
    ---the opposite of holding one still and drags the fight across the zone. No enchanter spell
    ---carries it in any case.
    ---
    ---**Carried by plenty of spells that are really something else.** An enchanter's Anarchy is a
    ---two hundred point AE nuke with a stun rider and reads identically to Color Shift, which is a
    ---stun and nothing else. So this says what a spell *can do* and never on its own what it is
    ---*for*; see `Damages` below, which is what tells the two apart
    stun = { 21, 64 },
    ---SPA_CHARM (22): what a charmed pet is held by. Nothing here casts one yet; the read is what
    ---`cabby.pet` uses to tell a charmed pet from a summoned one
    charm = { 22 },
    ---The three ways a spell changes hit points: SPA_HP (0), SPA_INSTANT_HP (79) and
    ---SPA_HP_NPC_ONLY (84). The *sign* of the base value is what says which way -- negative is
    ---damage, positive is a heal -- so none of these means anything without reading it
    health = { 0, 79, 84 },
    ---The five resist debuffs: fire, cold, poison, disease and magic (46-50), plus SPA_RESIST_ALL
    ---(111). Negative base is the debuff; positive is a resist *buff*, which is a different spell
    ---entirely. A magic resist debuff is what a tash is, and it is what makes a mez land
    resists = { 46, 47, 48, 49, 50, 111 }
}

---@param spell any mq spell TLO
---@param effects table array of SPA numbers
---@return boolean hasOne
local function hasSPA(spell, effects)
    for _, spa in ipairs(effects) do
        if spell.HasSPA(spa)() == true then return true end
    end
    return false
end

---The base value of the first of these effects the spell carries that the test accepts.
---
---`HasSPA` answers whether an effect is present and nothing about it. For half the effects worth
---reading that is not enough: the same number heals or harms, buffs or debuffs, depending only on
---the sign of what is in the slot beside it. So this walks the slots the way `SummonedItemId`
---does, and hands the base to the caller to judge.
---@param spell any mq spell TLO
---@param effects table array of SPA numbers
---@param accept fun(base: number): boolean
---@return number|nil base nil when no effect of these both appears and passes
local function baseOfSPA(spell, effects, accept)
    local wanted = {}
    for _, spa in ipairs(effects) do wanted[spa] = true end

    local slots = tonumber(spell.NumEffects()) or 12
    for index = 1, slots do
        local spa = tonumber(spell.Attrib(index)())
        if spa ~= nil and wanted[spa] then
            local base = tonumber(spell.Base(index)())
            if base ~= nil and accept(base) then return base end
        end
    end

    return nil
end

---Does this spell put a pet beside us?
---@param spell any mq spell TLO, or nil
---@return boolean summonsPet
function Spells.SummonsPet(spell)
    if spell == nil then return false end
    return hasSPA(spell, spas.summonPet)
end

---Does this spell mesmerize?
---
---The one thing a mez state must never be wrong about, so it is read off the effect rather than
---off a heading: the Enthrall category holds mezzes, but it also holds calms and lulls, and a lull
---cast at an add is a pull rather than a lockdown. `HasSPA(31)` is the same question the client
---asks when it fills in `Target.Mezzed`.
---@param spell any mq spell TLO, or nil
---@return boolean mesmerizes
function Spells.Mesmerizes(spell)
    if spell == nil then return false end
    return hasSPA(spell, spas.mesmerize)
end

---Does this spell stun?
---
---True of plenty of spells that are mostly something else -- an enchanter's Anarchy is an AE nuke
---with a stun rider and carries exactly the same effect Color Shift does -- so this says what a
---spell *can* do and never on its own what it is for. Pair it with `Damages`: a spell that stuns
---and does no damage is a stun, and one that does both is a nuke.
---@param spell any mq spell TLO, or nil
---@return boolean stuns
function Spells.Stuns(spell)
    if spell == nil then return false end
    return hasSPA(spell, spas.stun)
end

---Does this spell take hit points off what it lands on?
---
---Read through the *sign* of the effect's base value rather than through the effect number, since
---the same three effects heal when the base is positive. It is the question that separates a stun
---from a nuke with a stun on it, and it is what a crowd control list is filtered on -- damage is
---precisely what breaks a mez, so a spell that does any is one that cannot belong there.
---@param spell any mq spell TLO, or nil
---@return boolean damages
function Spells.Damages(spell)
    if spell == nil then return false end
    return baseOfSPA(spell, spas.health, function(base) return base < 0 end) ~= nil
end

---Does this spell make what it lands on easier to land spells on?
---
---A resist debuff, which is what a tash is: the thing cast at a mob so the mez after it takes. Read
---off the effect because the heading it is filed under is a label -- and because the sign matters
---more than the number here, a resist *buff* carrying the same effect being the opposite spell.
---@param spell any mq spell TLO, or nil
---@return boolean lowersResists
function Spells.LowersResists(spell)
    if spell == nil then return false end
    return baseOfSPA(spell, spas.resists, function(base) return base < 0 end) ~= nil
end

---Does this spell hold a mob still, or make holding one possible?
---
---**The whole of what crowd control is, and it is exactly three jobs**: the mez that holds a mob;
---the stun that holds one for a moment, which is what buys the seconds a long mez needs to be cast
---at something already swinging at us; and the resist debuff that makes the mez land on something
---that shrugged one off. Nothing else qualifies -- a slow, a cripple, a snare, a root and a lull
---are all useful spells that hold nothing still and help no mez land, and every one of them is a
---damage-rotation slot, where `dps_timing` and `dps_spread` already say when and how widely to
---cast it.
---
---**No heading is consulted at all.** All three jobs have an exact answer in the effect data, which
---is the standard this file already holds pet summons and item summons to -- and the headings were
---actively wrong here: Slow put Languid Pace in a mez list, Enthrall holds lulls as well as mezzes,
---and Utility Detrimental is the catch-all the damage list already leans on.
---
---**Nothing that does damage, whatever else it does.** Damage is what breaks a mez, so a nuke in
---this list works against every other slot in it -- and the check is load-bearing for a second
---reason: it is the only thing that tells a stun from a nuke, since half the nukes in an
---enchanter's book carry `SPA_STUN` as a rider and read identically to a real stun without it.
---@param spell any mq spell TLO, or nil
---@return boolean controls
function Spells.Controls(spell)
    if spell == nil then return false end
    if spell.Beneficial() == true then return false end
    if Spells.Damages(spell) then return false end
    return Spells.Mesmerizes(spell) or Spells.Stuns(spell) or Spells.LowersResists(spell)
end

---Does this spell charm?
---@param spell any mq spell TLO, or nil
---@return boolean charms
function Spells.Charms(spell)
    if spell == nil then return false end
    return hasSPA(spell, spas.charm)
end

---The item this spell conjures, by id.
---
---Read off the effect that does the conjuring rather than off the spell's name, which is what
---makes it exact: "Summon Dagger" is a spell, and item 7305 is what a pet ends up holding. Nil
---when the spell makes no item, which is also how "this slot is not a summon" is answered.
---@param spell any mq spell TLO, or nil
---@return number|nil itemId
function Spells.SummonedItemId(spell)
    if spell == nil then return nil end

    local effects = tonumber(spell.NumEffects()) or 12
    for index = 1, effects do
        local spa = tonumber(spell.Attrib(index)())
        if spa ~= nil then
            for _, wanted in ipairs(spas.createItem) do
                if spa == wanted then
                    local itemId = tonumber(spell.Base(index)())
                    if itemId ~= nil and itemId > 0 then return itemId end
                end
            end
        end
    end

    return nil
end

---@param ids table array of category numbers
---@return table set
local function setOf(ids)
    local set = {}
    for _, id in ipairs(ids) do set[id] = true end
    return set
end

---What each kind of action list is offered.
---
---A spell qualifies on its category *or* its subcategory. The two are drawn from one table and
---the game is not consistent about which of them carries the meaning a spell would be picked
---for: an invulnerability is a heading of its own on one line and a subheading of something else
---on the next, and either way it is the button a healer reaches for.
---
---These lean generous. A list missing a spell the character actually has is a puzzle with no way
---out of it from the menu, so the pickers also offer the unfiltered half of the book behind a
---switch and say what a spell is filed under; erring wide here only costs a few extra rows.
local groups = {
    heals = setOf{
        -- `health` is here for the pet heals: the client files most of them under Health rather
        -- than Heals (Renew Elements, Icy Stitches, Healing of Sorsha), and without it a pet
        -- class's only heal is missing from the list it would be picked from. It costs a few pet
        -- buffs filed the same way appearing alongside them
        cats.heals, cats.durationHeals, cats.quickHeal, cats.healthMana, cats.invulnerability,
        cats.health
    },
    buffs = setOf{
        cats.aegolism, cats.agility, cats.armorClass, cats.attack, cats.auras, cats.charisma,
        cats.damageShield, cats.dexterity, cats.endurance, cats.fizzleRate, cats.haste,
        cats.hasteSpellFocus, cats.health, cats.healthMana, cats.hpBuffs, cats.hpTypeOne,
        cats.hpTypeTwo, cats.invisibility, cats.levitate, cats.mana, cats.manaFlow,
        cats.meleeGuard, cats.movement, cats.petHaste, cats.petMiscBuffs, cats.reflection,
        cats.regen, cats.resistBuff, cats.rune, cats.shielding, cats.spellFocus, cats.spellGuard,
        cats.spellshield, cats.stamina, cats.statisticBuffs, cats.strength, cats.symbol,
        cats.twincast, cats.vision, cats.wisdomIntelligence
    },
    ---`root` and `snare` are named alongside the two broad detrimental headings because a rotation
    ---slot is where they are configured -- a root is cast at what we are fighting, on a timing of
    ---its own (see SpellDpsStateConfig), and the client files most of them under Utility
    ---Detrimental with Root or Snare as the subheading. Naming both means the ones filed the other
    ---way round are in the list too.
    damage = setOf{
        cats.directDamage, cats.utilityDetrimental, cats.root, cats.snare
    },
    -- there is no `control` group: the crowd control list is built from effects alone, because
    -- all three jobs in it have an exact answer in the data. See `Spells.Controls`.
    ---The one heading whose spells are damage but are cast on a friend. A damage shield is a buff
    ---by every mechanical measure -- beneficial, aimed at a person, it sits on a buff bar -- and
    ---it is also nothing but damage, so it belongs in a rotation rather than only in the buff
    ---list. It is filed separately from `damage` because it reaches that list from the other half
    ---of the book, and the two halves are what decide who a spell is pointed at.
    damageBuffs = setOf{
        cats.damageShield
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(Spells.key, str)
end

---@param spell any mq spell TLO
---@param group table set of category numbers
---@return boolean
local function inGroup(spell, group)
    return group[tonumber(spell.CategoryID()) or 0] == true
        or group[tonumber(spell.SubcategoryID()) or 0] == true
end

---How a spell's filing reads: "Direct Damage", or "Heals / Quick Heal" where the two differ.
---The client says "Unknown" for a heading a spell does not have.
---@param spell any mq spell TLO
---@return string
local function describeCategory(spell)
    local category = spell.Category() or "Unknown"
    local subcategory = spell.Subcategory() or "Unknown"
    if subcategory == "Unknown" or subcategory == category then return category end
    if category == "Unknown" then return subcategory end
    return category .. " / " .. subcategory
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

---What the book files this spell under, for a picker to show. Empty for anything that is not a
---spell in this character's book, which is how an item click or an AA reads.
---@param name string
---@return string category
function Spells.CategoryOf(name)
    if name == nil then return "" end
    return Spells._.categories[tostring(name):lower()] or ""
end

---A number that moves when the book does.
---
---The book carries no count and no version, so this stands in for one: the same 720 slots, but
---only the spell id off each, which is the cheapest thing a slot holds. Each id is folded in
---with the slot it sits on, so a spell written over another — the same number of spells, a
---different book — reads as a change just as a newly scribed one does.
---
---This is what a watcher polls; `Refresh` is what it calls once the answer has moved.
---@return number fingerprint
function Spells.Fingerprint()
    local fingerprint = 0

    for slot = 1, bookSlots do
        local id = tonumber(mq.TLO.Me.Book(slot).ID())
        if id ~= nil then fingerprint = fingerprint + slot * id end
    end

    return fingerprint
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
    Spells.heals = {}
    Spells.buffs = {}
    Spells.damage = {}
    Spells.control = {}
    Spells.petSummons = {}
    Spells.itemSummons = {}
    Spells._.categories = {}

    local levels = {}

    for slot = 1, bookSlots do
        local book = mq.TLO.Me.Book(slot)
        local name = book.Name()

        -- an empty slot is a hole in the book, not the end of it
        if name ~= nil then
            local spell = CastAction.Spell(name)
            levels[spell] = tonumber(book.Level()) or 0
            Spells.all[#Spells.all+1] = spell
            Spells._.categories[tostring(name):lower()] = describeCategory(book)

            -- which half of the book it is stays the outer question: a category is a label the
            -- data puts on a spell, but who you point it at is what a state actually needs, and
            -- no amount of miscategorisation should offer a nuke as a heal
            if book.Beneficial() then
                Spells.beneficial[#Spells.beneficial+1] = spell
                if inGroup(book, groups.heals) then Spells.heals[#Spells.heals+1] = spell end
                if inGroup(book, groups.buffs) then Spells.buffs[#Spells.buffs+1] = spell end
                -- the two pet lists are read off the effects rather than off a heading: what
                -- summons a pet and what conjures an item both say so exactly, in the data,
                -- and a category never has to be trusted for either
                if Spells.SummonsPet(book) then Spells.petSummons[#Spells.petSummons+1] = spell end
                if Spells.SummonedItemId(book) ~= nil then Spells.itemSummons[#Spells.itemSummons+1] = spell end
                -- in both lists on purpose: a damage shield is a buff worth keeping up out of a
                -- fight and a damage action worth casting in one, and which of those it is for is
                -- the user's decision rather than ours
                if inGroup(book, groups.damageBuffs) then Spells.damage[#Spells.damage+1] = spell end
            else
                Spells.detrimental[#Spells.detrimental+1] = spell
                if inGroup(book, groups.damage) then Spells.damage[#Spells.damage+1] = spell end
                -- read off the effects alone, with no heading consulted: see `Spells.Controls`
                if Spells.Controls(book) then Spells.control[#Spells.control+1] = spell end
            end
        end
    end

    local function byLevelThenName(a, b)
        if levels[a] ~= levels[b] then return levels[a] > levels[b] end
        return a:Name() < b:Name()
    end

    for _, list in ipairs({
        Spells.all, Spells.beneficial, Spells.detrimental,
        Spells.heals, Spells.buffs, Spells.damage, Spells.control,
        Spells.petSummons, Spells.itemSummons
    }) do
        table.sort(list, byLevelThenName)
    end

    DebugLog("Found " .. tostring(#Spells.all) .. " spells in the book" ..
        " (" .. tostring(#Spells.heals) .. " heals, " ..
        tostring(#Spells.buffs) .. " buffs, " ..
        tostring(#Spells.damage) .. " damage, " ..
        tostring(#Spells.control) .. " control, " ..
        tostring(#Spells.petSummons) .. " pet summons, " ..
        tostring(#Spells.itemSummons) .. " item summons)")
end

return Spells
