local mq = require("mq")
local ImGui = require("ImGui")

local Debug = require("utils.Debug.Debug")

local CommandQueue = require("cabby.commandQueue")
local HotbarButtonEditor = require("cabby.ui.hotbarButtonEditor")
local HotbarConfig = require("cabby.configs.hotbarConfig")

---Draws every configured hotbar as its own ImGui window. One render callback owns all of
---them so bars can be added and removed at runtime without registering new callbacks.
---
---Layout: buttons flow into as many columns as the window is currently wide, so resizing a
---hotbar window turns it into a horizontal bar, a vertical bar, or any grid in between.
---A bar is packed tight -- see barPadding/buttonGap below -- so it costs no more screen space
---than the buttons on it, and its title is just the bar number.
---
---Pressing a button does not run anything here. Its command lines are pushed to CommandQueue
---and run from the main loop on the next frame, because issuing game commands from inside an
---ImGui render callback is a crash-to-desktop hazard (see ARCHITECTURE.md, Movement).
---@class HotbarsUI
local HotbarsUI = {
    key = "HotbarsUI",
    _ = {
        isInit = false,
        barUiState = {} -- [bar.id] = { confirmRemove = boolean, snapTo = { width, height }? }
    }
}

---A hotbar is meant to take no more room than the buttons it holds, so it draws with its own
---padding and gap rather than the global style's, and every size below is figured from these
---two numbers instead of ImGui.GetStyle().
local barPadding = 1
local buttonGap = 1

---@param str string
local function DebugLog(str)
    Debug.Log(HotbarsUI.key, str)
end

---@param bar table
---@return table state transient (unsaved) per-bar ui state
local function GetBarState(bar)
    local state = HotbarsUI._.barUiState[bar.id]
    if state == nil then
        state = { confirmRemove = false }
        HotbarsUI._.barUiState[bar.id] = state
    end
    return state
end

---Drop ui state belonging to bars that no longer exist. Bar numbers are recycled, so state
---left behind by a removed bar would be inherited by the next bar handed that number.
---@param bars table
local function ForgetRemovedBarState(bars)
    local live = {}
    for _, bar in ipairs(bars) do
        live[bar.id] = true
    end

    for id in pairs(HotbarsUI._.barUiState) do
        if not live[id] then
            HotbarsUI._.barUiState[id] = nil
        end
    end
end

---How many buttons fit across the content region we are about to draw into
---@param buttonWidth number
---@return integer columns at least 1, so a window squeezed narrow becomes a vertical bar
local function ColumnsThatFit(buttonWidth)
    local availableWidth = ImGui.GetContentRegionAvail()
    return math.max(1, math.floor((availableWidth + buttonGap) / (buttonWidth + buttonGap)))
end

---Outer window size that holds a grid of this shape and nothing more. The inverse of
---ColumnsThatFit: a window this wide leaves exactly enough room for `columns` buttons, so
---snapping to it cannot shift the layout it was measured from.
---@param bar table
---@param columns integer
---@param rows integer
---@return number width
---@return number height counting the title bar, which is all the decoration these windows have
local function GridWindowSize(bar, columns, rows)
    local width = (columns * bar.button_width) + ((columns - 1) * buttonGap) + (barPadding * 2)
    local height = (rows * bar.button_height) + ((rows - 1) * buttonGap) + (barPadding * 2) + ImGui.GetFrameHeight()
    return width, height
end

---Note the size that would square this window off to the grid it just laid out, for the next
---frame to apply. The grid is never re-flowed to do it: the column count is whatever the width
---the user dragged to asked for, so a bar pulled into a row stays a row and one pulled into a
---column stays a column, and a shape with a hole in it -- three buttons in a 2x2 -- keeps the
---empty slot instead of collapsing into a line.
---@param bar table
---@param state table
---@param columns integer the layout that was just drawn
local function RequestSnap(bar, state, columns)
    -- an empty bar has no grid to square off to, and trimming it to nothing would clip the
    -- hint that says how to get a button back
    if #bar.buttons < 1 then
        state.snapTo = nil
        return
    end

    local width, height = GridWindowSize(bar, columns, math.ceil(#bar.buttons / columns))
    local currentWidth, currentHeight = ImGui.GetWindowSize()

    -- under a pixel out is ImGui having truncated a fractional title bar, not slack to trim.
    -- Asking for that difference every frame would never close it.
    if math.abs(currentWidth - width) < 1 and math.abs(currentHeight - height) < 1 then
        state.snapTo = nil
        return
    end

    state.snapTo = { width = width, height = height }
end

---Confirmation gate for destroying a hotbar. Drawn before the context menus that can request
---it, so OpenPopup always lands on the frame after the context menu closed -- opening a popup
---from inside another popup puts it at the wrong level of the popup stack and it vanishes.
---@param bar table
---@param state table
---@param pending function[]
local function DrawRemoveHotbarConfirm(bar, state, pending)
    local popupName = "Remove Hotbar?###cabbyRemoveHotbar" .. tostring(bar.id)

    if state.confirmRemove then
        ImGui.OpenPopup(popupName)
        state.confirmRemove = false
    end

    if ImGui.BeginPopupModal(popupName) then
        ImGui.Text("Remove hotbar [" .. bar.name .. "] and its " .. tostring(#bar.buttons) .. " button(s)?")
        ImGui.TextDisabled("This cannot be undone.")
        ImGui.Separator()

        if ImGui.Button("Remove", 90, 24) then
            pending[#pending+1] = function() HotbarConfig.RemoveBar(bar) end
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()
        if ImGui.Button("Cancel", 90, 24) then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

---Press a button: hand its lines to the main loop
---@param bar table
---@param index number
local function PressButton(bar, index)
    local button = bar.buttons[index]
    local lines = HotbarConfig.GetButtonLines(button)

    if #lines < 1 then
        print("(Cabby) Hotbar button [" .. button.label .. "] has no commands. Right-click it to edit.")
        return
    end

    DebugLog("Hotbar [" .. bar.name .. "] button [" .. button.label .. "] pressed, queueing " .. tostring(#lines) .. " line(s)")
    CommandQueue.PushAll(lines)
end

---Hover text listing what a button will run, so a bar of short labels is still readable.
---Delayed, so dragging the mouse across a bar does not flash a tooltip per button.
---@param button table
local function DrawButtonTooltip(button)
    if not ImGui.IsItemHovered(ImGuiHoveredFlags.DelayNormal) then return end

    local lines = HotbarConfig.GetButtonLines(button)

    ImGui.BeginTooltip()
    if #lines < 1 then
        ImGui.TextDisabled("No commands. Right-click to edit.")
    else
        for _, line in ipairs(lines) do
            ImGui.Text(line)
        end
    end
    ImGui.EndTooltip()
end

---Right-click menu of a single button
---@param bar table
---@param index number
---@param state table
---@param pending function[]
local function DrawButtonContextMenu(bar, index, state, pending)
    if not ImGui.BeginPopupContextItem("buttonContext") then return end

    local button = bar.buttons[index]

    ImGui.Text("Button " .. tostring(index) .. " of " .. bar.name)
    ImGui.Separator()

    ImGui.SetNextItemWidth(140)
    local label, changed = ImGui.InputText("Label", button.label)
    if changed then
        button.label = label
    end
    if ImGui.IsItemDeactivatedAfterEdit() then
        HotbarConfig.Save()
    end

    -- the editor is a window rather than a popup, so opening it from in here is safe: it is
    -- drawn at the end of this same pass, outside the popup stack this menu lives on
    if ImGui.MenuItem("Edit Commands...") then
        HotbarButtonEditor.Open(bar, index)
    end

    if ImGui.MenuItem("Add Button") then
        pending[#pending+1] = function() HotbarConfig.AddButton(bar, index + 1) end
    end
    if ImGui.MenuItem("Remove Button") then
        pending[#pending+1] = function() HotbarConfig.RemoveButton(bar, index) end
    end

    ImGui.Separator()
    if ImGui.MenuItem("Remove Hotbar...") then
        state.confirmRemove = true
    end

    ImGui.EndPopup()
end

---Right-click menu of the hotbar window itself (empty space, not over a button)
---@param bar table
---@param state table
---@param pending function[]
local function DrawHotbarContextMenu(bar, state, pending)
    local popupFlags = bit32.bor(ImGuiPopupFlags.MouseButtonRight, ImGuiPopupFlags.NoOpenOverItems)
    if not ImGui.BeginPopupContextWindow("hotbarContext", popupFlags) then return end

    ImGui.SetNextItemWidth(140)
    local name, nameChanged = ImGui.InputText("Name", bar.name)
    if nameChanged then
        bar.name = name
    end
    if ImGui.IsItemDeactivatedAfterEdit() then
        if bar.name == "" then
            bar.name = "Hotbar " .. tostring(bar.id)
        end
        HotbarConfig.Save()
    end

    ImGui.SetNextItemWidth(140)
    local width, widthChanged = ImGui.DragInt("Button Width", bar.button_width, 1, HotbarConfig.limits.minButtonWidth, HotbarConfig.limits.maxButtonWidth)
    if widthChanged then
        bar.button_width = HotbarConfig.ClampButtonWidth(width)
    end
    if ImGui.IsItemDeactivatedAfterEdit() then
        HotbarConfig.Save()
    end

    ImGui.SetNextItemWidth(140)
    local height, heightChanged = ImGui.DragInt("Button Height", bar.button_height, 1, HotbarConfig.limits.minButtonHeight, HotbarConfig.limits.maxButtonHeight)
    if heightChanged then
        bar.button_height = HotbarConfig.ClampButtonHeight(height)
    end
    if ImGui.IsItemDeactivatedAfterEdit() then
        HotbarConfig.Save()
    end

    ImGui.Separator()
    if ImGui.MenuItem("Add Button") then
        pending[#pending+1] = function() HotbarConfig.AddButton(bar) end
    end
    if ImGui.MenuItem("Remove Hotbar...") then
        state.confirmRemove = true
    end

    ImGui.EndPopup()
end

---@param bar table
---@param pending function[] mutations to run once the draw pass is done, so bars and buttons
---                          are never removed out from under the loops walking them
local function DrawHotbar(bar, pending)
    local state = GetBarState(bar)

    -- WindowMinSize is a floor ImGui applies after our own constraints, so a bar could not be
    -- squeezed down to one small button while it sits at its default 32x32
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, ImVec2(barPadding, barPadding))
    ImGui.PushStyleVar(ImGuiStyleVar.WindowMinSize, ImVec2(1, 1))

    -- never let the window shrink below a single button, or there would be nothing to
    -- right-click to get the hotbar back
    local minWidth, minHeight = GridWindowSize(bar, 1, 1)
    ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, 10000, 10000)

    -- a bar seen for the first time opens as a row of up to four, already squared off to its
    -- grid so that it does not appear at one size and snap to another a frame later
    local buttonCount = math.max(1, #bar.buttons)
    local defaultColumns = math.min(4, buttonCount)
    local defaultWidth, defaultHeight = GridWindowSize(bar, defaultColumns, math.ceil(buttonCount / defaultColumns))
    ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)

    -- Square the window off to the grid the last frame laid out. Held until the mouse is up,
    -- because resizing a window out from under the drag that is still sizing it fights the
    -- user for the edge; and applied here rather than where it was measured, because by then
    -- Begin has already settled this frame's size. Last SetNextWindowSize wins, so this one
    -- has to come after the default above.
    if state.snapTo ~= nil and not ImGui.IsMouseDown(ImGuiMouseButton.Left) then
        ImGui.SetNextWindowSize(state.snapTo.width, state.snapTo.height)
        state.snapTo = nil
    end

    -- the ### id keeps window geometry attached to the bar's id, so renaming it does not
    -- reset its position and size. Only the bar number is shown: at these sizes a title long
    -- enough to hold the name would set the width of the whole bar. NoScrollbar for the same
    -- reason -- a scrollbar appearing would eat a fifth of a one-button-wide window.
    local open, show = ImGui.Begin("HB" .. tostring(bar.id) .. "###cabbyHotbar" .. tostring(bar.id), true, ImGuiWindowFlags.NoScrollbar)
    ImGui.PopStyleVar(2)

    if not open then
        pending[#pending+1] = function() HotbarConfig.SetBarVisible(bar, false) end
    end

    if show then
        DrawRemoveHotbarConfirm(bar, state, pending)

        -- room for more columns than there are buttons lays out the same as room for exactly
        -- as many, but it is trailing space the snap below would otherwise preserve
        local columns = math.min(ColumnsThatFit(bar.button_width), math.max(1, #bar.buttons))

        for index, button in ipairs(bar.buttons) do
            -- only the buttons pack tight: the tooltip and menus drawn below are ordinary
            -- windows, and a one pixel gap between their rows would be unreadable
            ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing, ImVec2(buttonGap, buttonGap))
            if index > 1 and ((index - 1) % columns) ~= 0 then
                ImGui.SameLine()
            end

            ImGui.PushID(index)
            local pressed = ImGui.Button(button.label, bar.button_width, bar.button_height)
            ImGui.PopStyleVar()

            if pressed then
                PressButton(bar, index)
            end
            DrawButtonTooltip(button)
            DrawButtonContextMenu(bar, index, state, pending)
            ImGui.PopID()
        end

        if #bar.buttons < 1 then
            ImGui.TextDisabled("Right-click to add a button")
        end

        RequestSnap(bar, state, columns)
        DrawHotbarContextMenu(bar, state, pending)
    end
    ImGui.End()
end

local function DrawHotbars()
    local bars = HotbarConfig.GetBars()

    local pending = {}
    for _, bar in ipairs(bars) do
        if bar.visible then
            DrawHotbar(bar, pending)
        end
    end

    -- drawn outside the bar loop: the editor stays up while its bar is hidden or scrolled
    -- away, and it must not be nested inside a bar's window
    HotbarButtonEditor.Draw()

    if #pending > 0 then
        for _, apply in ipairs(pending) do
            apply()
        end
        ForgetRemovedBarState(bars)
    end
end

function HotbarsUI.Init()
    if not HotbarsUI._.isInit then
        local ftkey = Global.tracing.open("HotbarsUI Setup")

        mq.imgui.init("Cabby Hotbars", DrawHotbars)

        HotbarsUI._.isInit = true
        Global.tracing.close(ftkey)
    end
end

return HotbarsUI
