local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---Persisted hotbar definitions. A hotbar is a floating ImGui window of buttons whose layout
---flows to whatever shape the user resizes that window into (see ui/hotbarsUI.lua).
---
---A button carries a label and the command lines it runs, in order, when pressed. Lines are
---stored as plain text -- exactly what the user could type -- because the action picker in
---ui/hotbarButtonEditor.lua is only a text generator: it writes "/bc followme" or
---"/cself stopfollow" into a line, and from then on that line is editable like any other
---("/bc attack" becomes "/bc attack ${Target.ID}"). Lines run through CommandQueue, never
---from the render callback.
---
---Config shape:
---  HotbarConfig = {
---      bars = {
---          { id = 1, name = "Hotbar 1", visible = true, locked = false,
---            button_width = 70, button_height = 24,
---            buttons = { { label = "Follow", lines = { "/bc followme" } } } }
---      }
---  }
---
---`locked` pins a bar down: the window refuses to be dragged, so a bar parked over a corner of
---the game window cannot be knocked loose by a misplaced click, and its buttons refuse to be
---dragged into a different order, so a slip of the mouse cannot shuffle a bar that is being
---played off. It is still resizable and still right-clickable, which is what unlocks it again.
---
---Ids are recycled: a new bar takes the lowest number no other bar is using, so deleting
---hotbars 1 and 2 makes the next one "Hotbar 1" again. Because the id also keys the ImGui
---window, a recycled bar opens where the bar of that number last sat.
---@class HotbarConfig : BaseConfig
local HotbarConfig = {
    key = "HotbarConfig",
    defaults = {
        buttonLabel = "New",
        buttonWidth = 70,
        buttonHeight = 24
    },
    limits = {
        minButtonWidth = 24,
        maxButtonWidth = 300,
        minButtonHeight = 16,
        maxButtonHeight = 120
    },
    _ = {
        isInit = false
    }
}

---@param str string
local function DebugLog(str)
    Debug.Log(HotbarConfig.key, str)
end

local function getConfigSection()
    return Global.configStore:GetConfigRoot()[HotbarConfig.key]
end

---@param str string
---@return string trimmed
local function trim(str)
    return (str:match("^%s*(.-)%s*$"))
end

---@param value any
---@return number width clamped to the sizes the layout can work with
function HotbarConfig.ClampButtonWidth(value)
    if type(value) ~= "number" then return HotbarConfig.defaults.buttonWidth end
    return math.max(HotbarConfig.limits.minButtonWidth, math.min(HotbarConfig.limits.maxButtonWidth, math.floor(value)))
end

---@param value any
---@return number height clamped to the sizes the layout can work with
function HotbarConfig.ClampButtonHeight(value)
    if type(value) ~= "number" then return HotbarConfig.defaults.buttonHeight end
    return math.max(HotbarConfig.limits.minButtonHeight, math.min(HotbarConfig.limits.maxButtonHeight, math.floor(value)))
end

---@param id any
---@return boolean isUsable ids must be whole positive numbers: they key window geometry
local function isUsableId(id)
    return type(id) == "number" and id > 0 and id == math.floor(id)
end

---@param bars table
---@return table claimed set of ids already in use
local function claimedIds(bars)
    local claimed = {}
    for _, bar in ipairs(bars) do
        if isUsableId(bar.id) then
            claimed[bar.id] = true
        end
    end
    return claimed
end

---@param claimed table set of ids already in use
---@return number id lowest number free for a new bar, so deleted numbers come back around
local function lowestFreeId(claimed)
    local id = 1
    while claimed[id] do
        id = id + 1
    end
    return id
end

---Hand out ids so that no two bars share one. Duplicates would have the bars share their
---ImGui window (identical ### id) and their transient ui state.
---@param configRoot table
---@return boolean taint true when any id had to be assigned or moved
local function validateBarIds(configRoot)
    local taint = false
    local claimed = {}

    -- first claim what the file already holds, so nothing new can land on top of it
    for _, bar in ipairs(configRoot.bars) do
        if isUsableId(bar.id) and claimed[bar.id] == nil then
            claimed[bar.id] = true
        else
            bar.id = nil
            taint = true
        end
    end

    for _, bar in ipairs(configRoot.bars) do
        if bar.id == nil then
            bar.id = lowestFreeId(claimed)
            claimed[bar.id] = true
        end
    end

    -- ids used to be handed out by a stored counter; recycling replaced it
    if configRoot.next_id ~= nil then
        configRoot.next_id = nil
        taint = true
    end

    return taint
end

---@param bar table
---@return boolean taint true when the bar had to be repaired
local function validateBar(bar)
    local taint = false

    if type(bar.name) ~= "string" or bar.name == "" then
        bar.name = "Hotbar " .. tostring(bar.id)
        taint = true
    end
    if type(bar.visible) ~= "boolean" then
        bar.visible = true
        taint = true
    end
    -- bars saved before locking existed come forward unlocked
    if type(bar.locked) ~= "boolean" then
        bar.locked = false
        taint = true
    end

    local width = HotbarConfig.ClampButtonWidth(bar.button_width)
    if bar.button_width ~= width then
        bar.button_width = width
        taint = true
    end
    local height = HotbarConfig.ClampButtonHeight(bar.button_height)
    if bar.button_height ~= height then
        bar.button_height = height
        taint = true
    end

    if type(bar.buttons) ~= "table" then
        bar.buttons = {}
        taint = true
    end
    -- an empty bar is legal: the user can right-click its window to add buttons back
    for buttonIndex = #bar.buttons, 1, -1 do
        local button = bar.buttons[buttonIndex]
        if type(button) ~= "table" then
            table.remove(bar.buttons, buttonIndex)
            taint = true
        else
            if type(button.label) ~= "string" then
                button.label = HotbarConfig.defaults.buttonLabel
                taint = true
            end
            -- a button with nothing to run is legal: that is what a new button looks like
            -- until it is edited, and it is also how buttons saved before commands existed
            -- come forward
            if type(button.lines) ~= "table" then
                button.lines = {}
                taint = true
            end
            for lineIndex = #button.lines, 1, -1 do
                local line = button.lines[lineIndex]
                if type(line) ~= "string" or trim(line) == "" then
                    table.remove(button.lines, lineIndex)
                    taint = true
                elseif line ~= trim(line) then
                    button.lines[lineIndex] = trim(line)
                    taint = true
                end
            end
        end
    end

    return taint
end

local function initAndValidate()
    local taint = false
    if getConfigSection() == nil then
        DebugLog("HotbarConfig Section was not set, updating...")
        Global.configStore:GetConfigRoot()[HotbarConfig.key] = {}
        taint = true
    end

    local configRoot = getConfigSection()

    if type(configRoot.bars) ~= "table" then
        configRoot.bars = {}
        taint = true
    end

    for barIndex = #configRoot.bars, 1, -1 do
        if type(configRoot.bars[barIndex]) ~= "table" then
            table.remove(configRoot.bars, barIndex)
            taint = true
        end
    end

    if validateBarIds(configRoot) then
        taint = true
    end

    for _, bar in ipairs(configRoot.bars) do
        if validateBar(bar) then
            taint = true
        end
    end

    if taint then
        Global.configStore:SaveConfig()
    end
end

---Initialize the static object, only done once
---@diagnostic disable-next-line: duplicate-set-field
function HotbarConfig.Init()
    if not HotbarConfig._.isInit then
        local ftkey = Global.tracing.open("HotbarConfig Setup")

        initAndValidate()

        HotbarConfig._.isInit = true
        Global.tracing.close(ftkey)
    end
end

---------------- Config Management --------------------

---Persist in-place edits. The UI's text and drag fields mutate the live config table every
---frame they change and call this once the edit is committed, so a file write costs one
---edit instead of one keystroke.
function HotbarConfig.Save()
    Global.configStore:SaveConfig()
end

---@return table bars array of hotbars, empty when none are configured
function HotbarConfig.GetBars()
    local configRoot = getConfigSection()
    if configRoot == nil then return {} end
    return configRoot.bars or {}
end

---Create a hotbar holding a single button, numbered with the lowest number that is free
---@return table bar
function HotbarConfig.AddBar()
    local configRoot = getConfigSection()
    local id = lowestFreeId(claimedIds(configRoot.bars))
    local bar = {
        id = id,
        name = "Hotbar " .. tostring(id),
        visible = true,
        locked = false,
        button_width = HotbarConfig.defaults.buttonWidth,
        button_height = HotbarConfig.defaults.buttonHeight,
        buttons = { { label = HotbarConfig.defaults.buttonLabel, lines = {} } }
    }
    configRoot.bars[#configRoot.bars+1] = bar
    Global.configStore:SaveConfig()
    DebugLog("Added hotbar [" .. bar.name .. "]")
    return bar
end

---@param bar table
function HotbarConfig.RemoveBar(bar)
    local configRoot = getConfigSection()
    local barIndex = TableUtils.ArrayIndexOf(configRoot.bars, bar)
    if barIndex < 1 then return end

    table.remove(configRoot.bars, barIndex)
    Global.configStore:SaveConfig()
    DebugLog("Removed hotbar [" .. tostring(bar.name) .. "]")
end

---@param bar table
---@param visible boolean
function HotbarConfig.SetBarVisible(bar, visible)
    bar.visible = visible == true
    Global.configStore:SaveConfig()
end

---Pin a bar in place, or let it be dragged again
---@param bar table
---@param locked boolean
function HotbarConfig.SetBarLocked(bar, locked)
    bar.locked = locked == true
    Global.configStore:SaveConfig()
    DebugLog("Hotbar [" .. tostring(bar.name) .. "] position " .. (bar.locked and "locked" or "unlocked"))
end

---@param bar table
---@param index? number position to insert at, appends when not given
---@return table button
function HotbarConfig.AddButton(bar, index)
    local button = { label = HotbarConfig.defaults.buttonLabel, lines = {} }
    if index == nil or index > #bar.buttons then
        bar.buttons[#bar.buttons+1] = button
    else
        table.insert(bar.buttons, math.max(1, index), button)
    end
    Global.configStore:SaveConfig()
    return button
end

---@param bar table
---@param index number
function HotbarConfig.RemoveButton(bar, index)
    if bar.buttons[index] == nil then return end

    table.remove(bar.buttons, index)
    Global.configStore:SaveConfig()
end

---Move a button into another slot, on the same bar or on a different one. The button lands *in*
---the slot it was dropped on -- whatever was there, and everything after it, shifts along to make
---room -- which is what lift-then-insert-at-that-same-number does in both directions, so neither
---direction needs the index adjusted.
---@param fromBar table
---@param fromIndex number
---@param toBar table
---@param toIndex number slot to land in, clamped to the bar it is landing on
function HotbarConfig.MoveButton(fromBar, fromIndex, toBar, toIndex)
    local button = fromBar.buttons[fromIndex]
    if button == nil then return end
    if fromBar == toBar and fromIndex == toIndex then return end

    table.remove(fromBar.buttons, fromIndex)
    -- clamped after the lift, not before: moving a button rightwards along its own bar aims at a
    -- slot that is one lower once the button is off it, and a bar can be dropped onto while empty
    toIndex = math.max(1, math.min(math.floor(toIndex), #toBar.buttons + 1))
    table.insert(toBar.buttons, toIndex, button)

    Global.configStore:SaveConfig()
    DebugLog("Moved button [" .. button.label .. "] from " .. tostring(fromBar.name) .. " slot " ..
        tostring(fromIndex) .. " to " .. tostring(toBar.name) .. " slot " .. tostring(toIndex))
end

---@param button table
---@return table lines command lines this button runs, empty when it has none yet
function HotbarConfig.GetButtonLines(button)
    if button == nil or type(button.lines) ~= "table" then return {} end
    return button.lines
end

---Replace what a button runs. Blank lines are dropped rather than stored, so an editor can
---keep a trailing empty row to type into without that row becoming a saved no-op.
---@param button table
---@param label string
---@param lines table array of command lines
function HotbarConfig.SetButton(button, label, lines)
    label = trim(tostring(label or ""))
    if label == "" then
        label = HotbarConfig.defaults.buttonLabel
    end
    button.label = label

    local kept = {}
    for _, line in ipairs(lines or {}) do
        if type(line) == "string" and trim(line) ~= "" then
            kept[#kept+1] = trim(line)
        end
    end
    button.lines = kept

    Global.configStore:SaveConfig()
end

---@diagnostic disable-next-line: duplicate-set-field
function HotbarConfig.Print()
    TableUtils.Print(getConfigSection())
end

return HotbarConfig
