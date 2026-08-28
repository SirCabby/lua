---@diagnostic disable: undefined-field
local mq = require("mq")

local Time = require("utils.Time.Time")

---Getting at an item that is inside a bag.
---
---**Why this exists at all, and why it is shared rather than a helper inside one caller.** Telling
---the client to pick an item up makes it look for that item's own inventory-slot *window* and click
---it; only when it cannot find one does it fall back to moving the item directly. On this client
---that fallback **faults**, and a client fault is not a lua error -- it unwinds past every `pcall`
---in the script and stops it dead, with no traceback and nothing in the error log. A shut bag has
---no slot windows. So a shut bag turns an ordinary pick-up into a script-killer, and any code
---anywhere that picks an item up out of a bag has to open it first.
---
---Established by hand on 2026-08-24 after five script deaths: the identical pick-up command works
---with the bag open and kills the script with it shut. Two callers had the same latent bug --
---`utils/Swapping`, which was new, and `utils/Giving`, which had had it since it was written and
---only ever survived because a summoned item arrives on the cursor and needs no pick-up. The retry
---after a give that did not land is the path that finally reached it.
---@class Bags
local Bags = {
    key = "Bags"
}

---Top-level inventory slots 23 and up are the bag slots, `pack1` through `pack12`.
local firstBagSlot = 23

---How long after opening a bag before anything in it can be clicked.
---
---**A reading that cannot be taken yet, not a courtesy.** The item's `Open` flag flips in the
---frame the command is sent, but the slot *windows* the click needs are built by the client's own
---next UI pass -- so a click sent on the flag alone lands on nothing, silently, and the pick-up
---simply never happens. Seen exactly once in the wild and then again on the retry that worked: a
---click 10ms after the open did nothing, the same click 300ms after it worked.
---
---Only ever waited out for a bag *we* opened. One that was already open has had its windows for
---as long as it has been open.
local bagSettleMs = 300

---Which bag an item is sitting inside, if it is inside one.
---
---`ItemSlot` is the top-level inventory slot the item lives in and `ItemSlot2` its place within
---that slot's container -- so a negative second reading is an item sitting loose in a top-level
---slot rather than inside a bag, and there is nothing to open for it.
---@param item any mq item TLO
---@return number|nil pack the bag's number, 1-12
function Bags.PackHolding(item)
    if item == nil or item.ID() == nil then return nil end

    local top = tonumber(item.ItemSlot())
    local sub = tonumber(item.ItemSlot2())
    if top == nil or sub == nil or sub < 0 then return nil end
    if top < firstBagSlot then return nil end

    return top - firstBagSlot + 1
end

---@param pack number
---@return boolean isOpen
function Bags.IsOpen(pack)
    return (tonumber(mq.TLO.Me.Inventory("pack" .. tostring(pack)).Open()) or 0) > 0
end

---@param pack number
---@return string command the notify that toggles this bag open or shut
function Bags.ToggleCommand(pack)
    return "/nomodkey /itemnotify pack" .. tostring(pack) .. " rightmouseup"
end

---One step of "get this bag open and settled", for a caller running its own step machine.
---
---Callers differ in how they issue commands and what they log, so this does not issue anything: it
---answers what the caller should do next and leaves the doing to them. `openedAtMs` is the caller's
---own record of when it sent the toggle -- nil until it has.
---@param pack number|nil the bag to open; nil when the item is not in one
---@param openedAtMs number|nil when this caller sent the toggle, nil if it has not
---@return string action one of "ready" (go ahead and click), "open" (send `ToggleCommand`),
---"waiting" (the bag is open but its windows are not built yet)
function Bags.Progress(pack, openedAtMs)
    if pack == nil then return "ready" end

    if not Bags.IsOpen(pack) then
        -- the toggle is only ever sent while the bag reads shut, so a bag that has gone shut again
        -- under us is one to open again rather than one to give up on
        return "open"
    end

    -- open, and we are not the ones who opened it: its windows have been there all along
    if openedAtMs == nil then return "ready" end

    if Time.current_time() - openedAtMs < bagSettleMs then return "waiting" end
    return "ready"
end

return Bags
