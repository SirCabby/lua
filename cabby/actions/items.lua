---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local CastAction = require("cabby.actions.castAction")
local Spells = require("cabby.actions.spells")

---The clickies this character is carrying: worn gear and bag contents with an activatable
---spell effect on them.
---
---Only `Clicky` counts. An item's `Spell` is whatever spell is attached to it, which for most
---gear is a proc or a worn effect that clicking does nothing for; `Clicky` is the one the
---client will actually let us use.
---
---This is the shortest-lived of the three registries — a bag swap changes it — so `Character`
---watches free inventory space and re-scans when it moves.
---
---A second question about the same inventory — which of these carry a **pet focus** — is answered
---by `PetFocusItems` below, and deliberately **not** on this walk. It is a list one picker wants
---and nothing else reads, so scanning for it here would spend the whole inventory on it every time
---the bags change and, worse, put it on the path every character walks at login. It is scanned the
---first time somebody looks and thrown away when the bags move.
---@class Items
local Items = {
    key = "Items",
    all = {},
    ---nil until somebody asks; see `PetFocusItems`
    petFocus = nil
}

---Worn slots are 0-22 and bags are 23-34 (pack1 through pack12).
local firstSlot, lastSlot = 0, 34

---@param str string
local function DebugLog(str)
    Debug.Log(Items.key, str)
end

---@param name string
---@return CastAction? item
function Items.Get(name)
    if name == nil then return nil end
    name = tostring(name):lower()

    for _, item in ipairs(Items.all) do
        ---@type CastAction
        item = item
        if item:Name():lower() == name then
            return item
        end
    end

    return nil
end

---@param item any mq item TLO
---@param found table names already taken, so a stack of six mod rods is one entry
local function collectClicky(item, found)
    local name = item.Name()
    if name == nil or found[name] then return end

    -- Clicky is the activatable effect specifically; Spell would also match procs and worn
    -- effects, which cannot be clicked
    local spellId = tonumber(item.Clicky.SpellID())
    if spellId == nil or spellId < 1 then return end

    found[name] = true
    Items.all[#Items.all+1] = CastAction.Item(name)
end

---@param effect any mq itemspell TLO, one of an item's two focus slots
---@return string|nil focusName what the focus is called, nil when this slot carries none that
---makes a pet stronger
local function petFocusInSlot(effect)
    if (tonumber(effect.SpellID()) or 0) < 1 then return nil end
    if not Spells.FocusesPet(effect.Spell) then return nil end
    return effect.Spell.Name() or "a pet focus"
end

---What pet focus this item carries, if any.
---
---Exported because the question is asked twice for different reasons: once by the scan below, to
---build the list a picker offers, and once live off a *configured* item, since a list built when
---the bags last changed cannot answer for something bought since. An augment is never an answer to
---either — its focus counts for the item it is in, and there is no wearing one on its own.
---@param item any mq item TLO
---@return string|nil focusName
function Items.PetFocusName(item)
    if item == nil or item.ID() == nil then return nil end
    if (tonumber(item.AugType()) or 0) > 0 then return nil end

    -- the two focus slots, which is where a pet focus lives. Not `Clicky`, `Proc` or `Worn`:
    -- those are the other three things a spell can be attached to an item for, and none of them
    -- is what a magician's pet focus is
    return petFocusInSlot(item.Focus) or petFocusInSlot(item.Focus2)
end

---@param item any mq item TLO
---@param found table names already taken
---@param into table the list being built
local function collectPetFocus(item, found, into)
    local name = item.Name()
    if name == nil or found[name] then return end

    local focus = Items.PetFocusName(item)
    if focus == nil then return end

    found[name] = true
    into[#into+1] = {
        name = name,
        id = tonumber(item.ID()),
        focus = focus
    }
end

---@param each fun(item: any) called with every item worn or in a bag
local function walkInventory(each)
    for slot = firstSlot, lastSlot do
        local item = mq.TLO.Me.Inventory(slot)

        if item.ID() ~= nil then
            each(item)

            -- a bag: its own effects (rare, but a few exist) plus everything inside it
            local containerSlots = tonumber(item.Container()) or 0
            for containerSlot = 1, containerSlots do
                local contained = item.Item(containerSlot)
                if contained.ID() ~= nil then
                    each(contained)
                end
            end
        end
    end
end

---Re-read worn gear and bag contents.
function Items.Refresh()
    Items.all = {}
    -- thrown away rather than rebuilt: it is one picker's list, and the picker will ask again
    Items.petFocus = nil

    local found = {}
    walkInventory(function(item) collectClicky(item, found) end)

    table.sort(Items.all, function(a, b) return a:Name() < b:Name() end)

    DebugLog("Found " .. tostring(#Items.all) .. " clickies")
end

---The items carried that would make a summoned pet a stronger one, for whoever is offering a
---choice of them.
---
---**Scanned when somebody asks and not before.** Unlike the clicky list, nothing in the running
---script reads this -- it exists so a picker has something to show -- so a scan on every bag
---change would be the whole inventory walked for a page nobody has open, and a scan in `Refresh`
---would put it on the path every character walks at login. Held until the bags move, which is
---when `Refresh` drops it.
---@return table items array of `{ name, id, focus }`
function Items.PetFocusItems()
    if Items.petFocus ~= nil then return Items.petFocus end

    local list = {}
    local found = {}
    walkInventory(function(item) collectPetFocus(item, found, list) end)

    table.sort(list, function(a, b) return a.name < b.name end)
    Items.petFocus = list

    DebugLog("Found " .. tostring(#list) .. " pet focus items")
    return list
end

return Items
