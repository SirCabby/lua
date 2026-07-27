---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")

local CastAction = require("cabby.actions.castAction")

---The clickies this character is carrying: worn gear and bag contents with an activatable
---spell effect on them.
---
---Only `Clicky` counts. An item's `Spell` is whatever spell is attached to it, which for most
---gear is a proc or a worn effect that clicking does nothing for; `Clicky` is the one the
---client will actually let us use.
---
---This is the shortest-lived of the three registries — a bag swap changes it — so `Character`
---watches free inventory space and re-scans when it moves.
---@class Items
local Items = {
    key = "Items",
    all = {}
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

---Re-read worn gear and bag contents.
function Items.Refresh()
    Items.all = {}
    local found = {}

    for slot = firstSlot, lastSlot do
        local item = mq.TLO.Me.Inventory(slot)

        if item.ID() ~= nil then
            collectClicky(item, found)

            -- a bag: its own clicky (rare, but a few exist) plus everything inside it
            local containerSlots = tonumber(item.Container()) or 0
            for containerSlot = 1, containerSlots do
                local contained = item.Item(containerSlot)
                if contained.ID() ~= nil then
                    collectClicky(contained, found)
                end
            end
        end
    end

    table.sort(Items.all, function(a, b) return a:Name() < b:Name() end)

    DebugLog("Found " .. tostring(#Items.all) .. " clickies")
end

return Items
