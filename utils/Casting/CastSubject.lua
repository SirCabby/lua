---@diagnostic disable: undefined-field
local mq = require("mq")

---What is being cast, and the one place that knows how the three kinds differ.
---
---A memmed spell, a clicky and an AA are the same thing to a caller -- something that takes a
---while, needs standing still, and may need a target -- but nothing else about them matches:
---they are readied by different TLOs, fired by different commands, and only one of them has to
---be memorized first. Everything that reads "is it a spell or an item" lives here so the
---sequencer in `CastTask` can be about the sequence.
---@class CastSubject
local CastSubject = {}
CastSubject.__index = CastSubject

CastSubject.kinds = {
    ---something out of the spellbook, cast from a gem
    spell = "spell",
    ---an item with a click effect
    item = "item",
    ---an activated alternate advancement ability
    alt = "alt"
}

setmetatable(CastSubject, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---Target types that aim themselves: self buffs, group spells, point-blank and directional AEs,
---pet spells, hatelist AEs. Everything else is treated as needing a target, because refusing a
---cast we could have made is a visible, recoverable mistake and firing a single-target nuke
---with nothing targeted is a wasted gem timer.
local aimlessTargetTypes = {
    ["self"] = true,
    ["none"] = true,
    ["group v1"] = true,
    ["group v2"] = true,
    ["pb ae"] = true,
    ["caster pb pc"] = true,
    ["caster pb npc"] = true,
    ["ae pc v1"] = true,
    ["ae pc v2"] = true,
    ["directional ae"] = true,
    ["beam"] = true,
    ["free target"] = true,
    ["hatelist"] = true,
    ["hatelist2"] = true,
    ["pet"] = true,
    ["pet2"] = true,
    ["pet owner"] = true
}

---MQ hands timestamps back as either a number or the string form of one depending on the
---member, so read every duration through here.
---@param value any
---@param default number
---@return number
local function asNumber(value, default)
    local number = tonumber(value)
    if number == nil then return default end
    return number
end

---@param kind string one of CastSubject.kinds
---@param name string spell, item or AA name
---@return CastSubject
function CastSubject.new(kind, name)
    local self = setmetatable({}, CastSubject)

---@diagnostic disable-next-line: inject-field
    self._ = {
        kind = kind,
        name = tostring(name or "")
    }

    return self
end

---@param name string
---@return CastSubject
function CastSubject.Spell(name)
    return CastSubject.new(CastSubject.kinds.spell, name)
end

---@param name string
---@return CastSubject
function CastSubject.Item(name)
    return CastSubject.new(CastSubject.kinds.item, name)
end

---@param name string
---@return CastSubject
function CastSubject.Alt(name)
    return CastSubject.new(CastSubject.kinds.alt, name)
end

---@return string kind
function CastSubject:Kind()
    return self._.kind
end

---@return string name
function CastSubject:Name()
    return self._.name
end

---@return boolean isSpell true for gem casts, the only kind that has to be memorized
function CastSubject:IsSpell()
    return self._.kind == CastSubject.kinds.spell
end

---The item this subject is, for the item kind. Exact name first so a bag full of similarly
---named clickies cannot substitute one for another; partial match after, since that is what
---`/useitem` itself accepts.
---@return any item mq item TLO
local function findItem(self)
    local exact = mq.TLO.FindItem("=" .. self._.name)
    if exact.ID() ~= nil then return exact end
    return mq.TLO.FindItem(self._.name)
end

---The spell whose data describes what this cast will do: the spell itself, the item's click
---effect, or the AA's spell.
---@return any|nil spell mq spell TLO, nil when we cannot resolve one
function CastSubject:Spelldata()
    if self._.kind == CastSubject.kinds.spell then
        local spell = mq.TLO.Spell(self._.name)
        if spell.ID() == nil then return nil end
        return spell
    end

    if self._.kind == CastSubject.kinds.item then
        local item = findItem(self)
        if item.ID() == nil then return nil end
        local spell = item.Spell
        if spell == nil or spell.ID() == nil then return nil end
        return spell
    end

    local aa = mq.TLO.Me.AltAbility(self._.name)
    if aa.ID() == nil then return nil end
    local spell = aa.Spell
    if spell == nil or spell.ID() == nil then return nil end
    return spell
end

---Whether this character has the thing at all: the spell scribed in the book, the item in
---inventory, the AA trained. Distinct from readiness -- this one does not change while we play.
---@return boolean isAvailable
function CastSubject:IsAvailable()
    if self._.name == "" then return false end

    if self._.kind == CastSubject.kinds.spell then
        -- the book, not the gems: a spell we know but have not memmed is still castable, it
        -- just costs a memorize first
        return mq.TLO.Me.Book(self._.name)() ~= nil
    end

    if self._.kind == CastSubject.kinds.item then
        return findItem(self).ID() ~= nil
    end

    return mq.TLO.Me.AltAbility(self._.name).ID() ~= nil
end

---@return number|nil gem the gem this spell is memorized in, nil when it is not (or not a spell)
function CastSubject:Gem()
    if self._.kind ~= CastSubject.kinds.spell then return nil end
    return tonumber(mq.TLO.Me.Gem(self._.name)())
end

---@return boolean isMemorized always true for items and AAs, which need no gem
function CastSubject:IsMemorized()
    if self._.kind ~= CastSubject.kinds.spell then return true end
    return self:Gem() ~= nil
end

---Whether the client will let us use it *right now*: gem off cooldown, item timer up, AA timer
---up. False for an unmemorized spell, which is why callers check `IsMemorized` first and
---memorize rather than reporting it as not ready.
---@return boolean isReady
function CastSubject:IsReady()
    if self._.kind == CastSubject.kinds.spell then
        return mq.TLO.Me.SpellReady(self._.name)() == true
    end

    if self._.kind == CastSubject.kinds.item then
        return mq.TLO.Me.ItemReady(self._.name)() == true
    end

    return mq.TLO.Me.AltAbilityReady(self._.name)() == true
end

---How long the cast bar will be up, in milliseconds. Zero for anything instant, which is the
---signal that there will be no cast bar to watch at all.
---@return number castTimeMs
function CastSubject:CastTimeMs()
    local spell = self:Spelldata()
    if spell == nil then return 0 end

    -- MyCastTime carries this character's cast-time focus effects; CastTime is the unmodified
    -- value and the fallback when the client has not resolved the adjusted one. Both are
    -- timestamps, whose string form is the millisecond count, so they read straight through
    -- tonumber without touching .Raw
    local castTime = asNumber(spell.MyCastTime(), 0)
    if castTime <= 0 then castTime = asNumber(spell.CastTime(), 0) end
    return castTime
end

---@return number manaCost 0 for items and AAs, whose costs are not mana
function CastSubject:ManaCost()
    if self._.kind ~= CastSubject.kinds.spell then return 0 end
    local spell = self:Spelldata()
    if spell == nil then return 0 end
    return asNumber(spell.Mana(), 0)
end

---@return string targetType lowercased, "" when it cannot be resolved
function CastSubject:TargetType()
    local spell = self:Spelldata()
    if spell == nil then return "" end
    return tostring(spell.TargetType() or ""):lower()
end

---@return boolean needsTarget whether EQ will refuse this without something targeted
function CastSubject:NeedsTarget()
    local targetType = self:TargetType()
    -- unknown target type: assume it needs one. A spell that turns out not to need a target
    -- still casts fine with one selected; the reverse wastes the cast.
    if targetType == "" then return true end
    return aimlessTargetTypes[targetType] ~= true
end

---How far away the target may be. Group spells carry their reach in AERange rather than Range.
---@return number range 0 when the subject has no range limit worth checking
function CastSubject:Range()
    local spell = self:Spelldata()
    if spell == nil then return 0 end

    -- MyRange includes range-extension focus effects
    local range = asNumber(spell.MyRange(), 0)
    if range <= 0 then range = asNumber(spell.Range(), 0) end
    if range <= 0 then range = asNumber(spell.AERange(), 0) end
    return range
end

---Reagents this cast will consume that we do not have.
---@return string|nil missing name of the first missing reagent, nil when we have them all
function CastSubject:MissingReagent()
    local spell = self:Spelldata()
    if spell == nil then return nil end

    for index = 1, 4 do
        local reagentId = tonumber(spell.ReagentID(index)())
        -- MQ reports "no reagent in this slot" as -1 on some builds and 0 on others
        if reagentId ~= nil and reagentId > 0 then
            local needed = math.max(asNumber(spell.ReagentCount(index)(), 1), 1)
            if asNumber(mq.TLO.FindItemCount(reagentId)(), 0) < needed then
                local item = mq.TLO.FindItem(reagentId)
                local itemName = item.Name()
                return itemName or ("item " .. tostring(reagentId))
            end
        end
    end

    return nil
end

---Issue the command that starts the cast.
---
---**Main loop only.** Every path into here runs from the casting service's `Pulse()`, for the
---same reason movement keys do: running a game command from inside an ImGui callback is a
---crash-to-desktop hazard.
---@return boolean issued false when we could not work out what to send
function CastSubject:Fire()
    if self._.kind == CastSubject.kinds.spell then
        local gem = self:Gem()
        if gem == nil then return false end
        -- by gem rather than by name: the gem is what we memorized and checked the timer on,
        -- and /cast by name re-resolves against a partial match
        mq.cmdf("/cast %d", gem)
        return true
    end

    if self._.kind == CastSubject.kinds.item then
        mq.cmdf('/useitem "%s"', self._.name)
        return true
    end

    local aa = mq.TLO.Me.AltAbility(self._.name)
    local id = tonumber(aa.ID())
    if id == nil then return false end
    mq.cmdf("/alt activate %d", id)
    return true
end

---Memorize this spell into a gem. Main loop only, as with Fire.
---@param gem number
function CastSubject:Memorize(gem)
    mq.cmdf('/memspell %d "%s"', gem, self._.name)
end

---@return string description for status output
function CastSubject:Describe()
    return self._.kind .. " " .. self._.name
end

return CastSubject
