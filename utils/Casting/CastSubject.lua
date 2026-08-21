---@diagnostic disable: undefined-field
local mq = require("mq")

local ReagentNames = require("utils.Casting.ReagentNames")

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

---How long the client says this spell's gem still has to go, in milliseconds.
---
---The number behind a greyed gem. A gem is not castable for a few seconds after a spell is
---memorized into it -- longer than it takes to notice, and longer than any grace worth guessing
---at -- and this is the client counting those seconds down. Zero for a gem that is ready, for a
---spell that is not on the bar, and for items and AAs, which have no gem to wait on.
---@return number ms
function CastSubject:GemCooldownMs()
    if self._.kind ~= CastSubject.kinds.spell then return 0 end
    return tonumber(mq.TLO.Me.GemTimer(self._.name)()) or 0
end

---Is what is stopping this cast a countdown rather than a refusal?
---
---`IsReady` says no for two quite different reasons and cannot tell them apart, which matters
---enormously to a caller: one of them ends on its own in a second or two and the other does not.
---Both of the ending kind are published by the client, so neither has to be guessed at:
---
---- **this gem is coming back** -- from the memorize we just made into it, or from its own
---  recast: `GemCooldownMs` is the countdown;
---- **the bar is recovering** -- the short pause after any cast, during which every gem is
---  greyed at once: `Me.SpellInCooldown`, which is a fact and not a timer of ours.
---
---Anything else -- an item timer, an AA timer, a spell that is simply on a long cooldown -- is a
---real no. A caller in the middle of a cast waits on this the way it waits to stand still: it is
---a wait for something that will change.
---@return boolean isComingBack false for items and AAs, whose timers are answers rather than waits
function CastSubject:IsRecovering()
    if self._.kind ~= CastSubject.kinds.spell then return false end
    if mq.TLO.Me.SpellInCooldown() == true then return true end
    return self:GemCooldownMs() > 0
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
---
---**A clicky's cast time belongs to the item, not to the effect it fires**, and the two disagree
---constantly: a Manastone clicks instantly while the spell behind it is a three second cast. The
---item's number is the one that decides -- it is the field the client draws the bar from and the
---number the server is handed to cast with, where only a negative means "ask the spell" -- so a
---readable zero there is the item saying *instant*, not the item saying nothing.
---
---Read off the effect instead and an instant click is described as a three second cast: the
---character is pinned still for a click that needs no stillness, and everything then waits for a
---bar that was never going to be drawn until its deadline runs out and calls the use lost. A click
---that worked, reported as a failure, once every second and a half -- which is what a health for
---mana trade looked like before this read the item.
---@return number castTimeMs
function CastSubject:CastTimeMs()
    if self._.kind == CastSubject.kinds.item then
        local item = findItem(self)
        -- only an item we cannot read at all falls through to its effect below
        if item.ID() ~= nil then
            local clickTime = asNumber(item.CastTime(), -1)
            if clickTime >= 0 then return clickTime end
        end
    end

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

---Cast times at or below this are instant: no bar is drawn, so there is nothing to interrupt and
---nothing riding on standing still. Not a plain zero, because the client reports some clickies as
---a few tens of milliseconds and a bar that short cannot be walked out of.
local instantCastMs = 100

---Whether this goes off in the frame it is fired, with no bar drawn at all. Most clickies and AAs.
---@return boolean isInstant
function CastSubject:IsInstant()
    return self:CastTimeMs() <= instantCastMs
end

---Whether this cast pins the character down while it runs.
---
---Two things get to move while they cast, and neither has a bar at stake: a bard's song, which is
---what a bard is, and anything instant, which is over in the frame it started. Everything else
---loses the cast the moment the character moves.
---
---A property of the *subject*, not of a cast in flight, because it is asked before there is a cast
---to ask about: a caller choosing between a slow spell and an instant clicky while the group is
---running wants to know which of the two it could actually get off.
---@return boolean requiresStillness
function CastSubject:RequiresStillness()
    -- the class rather than the spell: what makes a song a song is who is singing it. A song still
    -- draws a bar, which is why this is the wider question of the two
    if self:IsSpell() and mq.TLO.Me.Class.ShortName() == "BRD" then return false end
    return not self:IsInstant()
end

---How long what this lands *stays* landed, in milliseconds. Zero for anything that does its whole
---job the moment it lands, which is what separates a direct heal from a heal over time and is the
---only reading either of them offers about which one it is.
---
---Read off the spell rather than off a category, for the reason the aim is: what a spell does is
---what it is, and the client files heals under half a dozen headings that do not agree with each
---other. A duration is unambiguous.
---@return number durationMs
function CastSubject:DurationMs()
    local spell = self:Spelldata()
    if spell == nil then return 0 end

    -- MyDuration carries this character's extension focus effects; Duration is the unmodified
    -- value and the fallback when the client has not resolved the adjusted one. Both are tick
    -- counts, which is a datatype rather than a number -- `TotalSeconds` is the member that
    -- answers in something worth multiplying
    local duration = asNumber(spell.MyDuration.TotalSeconds(), 0)
    if duration <= 0 then duration = asNumber(spell.Duration.TotalSeconds(), 0) end
    return math.max(duration, 0) * 1000
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

---What to call a component we are short of.
---
---The client is asked first, and it answers in two useful ways: `FindItem` names an item whenever
---we hold *some* of a stack, and `FindItemBank` names one sitting in the bank -- which is worth a
---second question, because "there are twenty of them in the bank" is the commonest reason a caster
---is out of the reagent their pet needs, and the bank is not somewhere a cast can reach.
---
---Failing both, the name comes from `ReagentNames`, because an item we have never held has no name
---anywhere in the client -- and that is precisely the case here, since the whole reason we are
---saying anything is that the component is not in the bags. An id is the last resort, for a
---component that table does not know.
---@param reagentId number
---@param needed number
---@param carried number
---@return string description
local function describeReagent(reagentId, needed, carried)
    local name = mq.TLO.FindItem(reagentId).Name()
    local where = ""

    if name == nil then
        local banked = mq.TLO.FindItemBank(reagentId)
        if banked.ID() ~= nil then
            name = banked.Name()
            where = ", and the ones we have are in the bank"
        end
    end

    name = name or ReagentNames.Get(reagentId) or ("item " .. tostring(reagentId))

    if needed > 1 then
        return tostring(needed) .. "x " .. name .. " (carrying " .. tostring(carried) .. ")" .. where
    end
    return name .. where
end

---Reagents this cast will consume that we do not have.
---
---Only the expendable ones (`ReagentID`); a spell's focus item (`NoExpendReagentID`) is not
---consumed and is a different question.
---@return string|nil missing the first missing reagent, named where the client can name it, nil
---when we have them all
function CastSubject:MissingReagent()
    local spell = self:Spelldata()
    if spell == nil then return nil end

    for index = 1, 4 do
        local reagentId = tonumber(spell.ReagentID(index)())
        -- MQ reports "no reagent in this slot" as -1 on some builds and 0 on others
        if reagentId ~= nil and reagentId > 0 then
            local needed = math.max(asNumber(spell.ReagentCount(index)(), 1), 1)
            local carried = asNumber(mq.TLO.FindItemCount(reagentId)(), 0)
            if carried < needed then
                return describeReagent(reagentId, needed, carried)
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
