local mq = require("mq")
local ImGui = require("ImGui")

local Debug = require("utils.Debug.Debug")

local CommandQueue = require("cabby.commandQueue")
local Commands = require("cabby.commands.commands")
local HotbarButtonEditor = require("cabby.ui.hotbarButtonEditor")
local HotbarConfig = require("cabby.configs.hotbarConfig")

---Draws every configured hotbar as its own ImGui window. One render callback owns all of
---them so bars can be added and removed at runtime without registering new callbacks.
---
---Layout: buttons flow into as many columns as the window is currently wide, so resizing a
---hotbar window turns it into a horizontal bar, a vertical bar, or any grid in between.
---A bar is packed tight -- see barPadding/buttonGap below -- so it costs no more screen space
---than the buttons on it, and its title is just the bar number. Once a bar sits where it is
---wanted, Lock Position on either right-click menu pins it there.
---
---Buttons are dragged into whatever order is wanted, on their own bar or across onto another
---one, for as long as the bar is unlocked -- locking is what says a bar is done being arranged.
---
---Pressing a button does not run anything here. Its command lines are pushed to CommandQueue
---and run from the main loop on the next frame, because issuing game commands from inside an
---ImGui render callback is a crash-to-desktop hazard (see ARCHITECTURE.md, Movement).
---
---A button whose lines flip a switch is drawn as that switch -- lit while it is on, dimmed while
---it is off -- read fresh every frame from the setting itself, so it also follows a flip that came
---from the menu checkbox or from another character's order.
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

---A switch a button carries is drawn as itself: the accent means the setting is on, the dim means
---it is off. A button that carries no switch keeps the theme's own look -- an ordinary button must
---not read as one that is switched off.
local switchColors = {
    on = {
        button = { 0.19, 0.49, 0.24, 0.90 },
        hovered = { 0.25, 0.62, 0.31, 1.00 },
        active = { 0.14, 0.38, 0.18, 1.00 }
    },
    off = {
        button = { 0.16, 0.16, 0.16, 0.90 },
        hovered = { 0.27, 0.27, 0.27, 1.00 },
        active = { 0.12, 0.12, 0.12, 1.00 },
        -- dimmed lettering as well: at hotbar sizes the fill alone is a subtle difference
        text = { 0.62, 0.62, 0.62, 1.00 }
    }
}

---What state a button is drawn in: the switches its lines flip, when they have one state between
---them. Lines are plain text and nothing is stored about where they came from, so this is read
---back out of the text every frame (`Commands.ReadLineState`) -- which is also what keeps it
---honest when the same setting is flipped from somewhere else entirely.
---@param button table
---@return boolean? state nil when the button carries no switch, or carries several that disagree
---@return table phrases the switches it carries, for the tooltip to name
function HotbarsUI.ButtonState(button)
    local state = nil
    local phrases = {}

    for _, line in ipairs(HotbarConfig.GetButtonLines(button)) do
        local lineState, phrase = Commands.ReadLineState(line)
        if lineState ~= nil then
            -- a button that flips two settings at once only has a state while they agree
            if state ~= nil and state ~= lineState then return nil, {} end
            state = lineState
            phrases[#phrases+1] = phrase
        end
    end

    return state, phrases
end

---@param styleColor integer
---@param color table? { r, g, b, a }
---@return integer pushed 1 when there was a colour to push, 0 when there was not
local function PushColor(styleColor, color)
    if color == nil then return 0 end

    ImGui.PushStyleColor(styleColor, color[1], color[2], color[3], color[4])
    return 1
end

---@param state boolean? as returned by ButtonState
---@return integer pushed how many style colors to pop once the button is drawn
local function PushSwitchColors(state)
    if state == nil then return 0 end

    local colors = state and switchColors.on or switchColors.off
    return PushColor(ImGuiCol.Button, colors.button)
        + PushColor(ImGuiCol.ButtonHovered, colors.hovered)
        + PushColor(ImGuiCol.ButtonActive, colors.active)
        + PushColor(ImGuiCol.Text, colors.text)
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

---What a button being dragged carries: which bar it came off and which slot it sat in. The bar
---is named rather than handed over because a payload can only hold plain data -- and naming it
---is what makes a drop onto a *different* bar unambiguous instead of a move of whatever happens
---to sit at that number over there.
local buttonPayloadType = "CABBY_HOTBAR_BUTTON"

---@param bar table
---@param index number
---@return string payload
local function WriteButtonPayload(bar, index)
    return tostring(bar.id) .. ":" .. tostring(index)
end

---@param data any payload as it comes back off the drop
---@return table? bar nil when the payload is malformed, or names a bar that has since gone away
---@return number? index
local function ReadButtonPayload(data)
    if type(data) ~= "string" then return nil, nil end

    local id, index = data:match("^(%d+):(%d+)$")
    if id == nil then return nil, nil end

    for _, bar in ipairs(HotbarConfig.GetBars()) do
        if bar.id == tonumber(id) then return bar, tonumber(index) end
    end
    return nil, nil
end

---Let the button just drawn be picked up and carried. ImGui only starts a drag once the mouse
---has moved past its own threshold, so an ordinary click still presses the button; and while a
---drag is running the source stops reporting as hovered, so letting go over the button it was
---lifted off does not press it either.
---@param bar table
---@param index number
local function DrawButtonDragSource(bar, index)
    -- a locked bar is one that is finished being arranged: it will not be dragged around the
    -- screen and its buttons will not be dragged around the bar
    if bar.locked then return end
    if not ImGui.BeginDragDropSource(ImGuiDragDropFlags.None) then return end

    ImGui.SetDragDropPayload(buttonPayloadType, WriteButtonPayload(bar, index))
    -- what is being carried, which a bar of three-letter labels does not otherwise make obvious
    ImGui.Text(bar.buttons[index].label)
    ImGui.EndDragDropSource()
end

---Let a dragged button be dropped onto the item just drawn. ImGui outlines it while a payload
---is over it, which is the whole of the drop feedback.
---@param bar table
---@param index number slot the drop would land in
---@param pending function[]
local function DrawButtonDropTarget(bar, index, pending)
    if bar.locked then return end
    if not ImGui.BeginDragDropTarget() then return end

    local payload = ImGui.AcceptDragDropPayload(buttonPayloadType)
    if payload ~= nil then
        local fromBar, fromIndex = ReadButtonPayload(payload.Data)
        if fromBar ~= nil then
            -- deferred like every other mutation: this runs mid-iteration over the very list
            -- it reorders, and the drop can be over a bar that has not been drawn yet
            pending[#pending+1] = function() HotbarConfig.MoveButton(fromBar, fromIndex, bar, index) end
        end
    end

    ImGui.EndDragDropTarget()
end

---Hover text listing what a button will run, so a bar of short labels is still readable.
---Delayed, so dragging the mouse across a bar does not flash a tooltip per button.
---@param bar table
---@param button table
---@param state boolean? the state this button is drawn in
---@param phrases table the switches it carries
local function DrawButtonTooltip(bar, button, state, phrases)
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

    -- in words as well as in colour: what the accent means is obvious on a `toggle` button and
    -- worth spelling out on one that sets a switch to a fixed value
    if state ~= nil then
        ImGui.Separator()
        ImGui.TextDisabled(table.concat(phrases, ", ") .. " is " .. (state and "on" or "off"))
    end

    -- nothing about a button says it can be picked up, and the tooltip is already the place
    -- being looked at. Only while it can be: on a locked bar this would be a lie
    if not bar.locked then
        ImGui.Separator()
        ImGui.TextDisabled("Drag to move")
    end
    ImGui.EndTooltip()
end

---Menu entry that pins a bar where it sits. Offered on both right-click menus, like the other
---bar-wide entries: a packed bar has next to no empty space to right-click, so the button menu is
---often the only one in reach. Locking takes hold on the next frame's Begin -- this frame's window
---flags were settled before the menu was drawn.
---@param bar table
local function DrawLockPositionItem(bar)
    local activated, locked = ImGui.MenuItem("Lock Position", nil, bar.locked == true)
    if activated then
        HotbarConfig.SetBarLocked(bar, locked)
    end
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
    DrawLockPositionItem(bar)
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
    DrawLockPositionItem(bar)
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

    -- a locked bar only refuses to be dragged. It still resizes, still snaps to its grid, and
    -- still opens its right-click menus -- which is how it gets unlocked again.
    local windowFlags = ImGuiWindowFlags.NoScrollbar
    if bar.locked then
        windowFlags = bit32.bor(windowFlags, ImGuiWindowFlags.NoMove)
    end

    -- the ### id keeps window geometry attached to the bar's id, so renaming it does not
    -- reset its position and size. Only the bar number is shown: at these sizes a title long
    -- enough to hold the name would set the width of the whole bar. NoScrollbar for the same
    -- reason -- a scrollbar appearing would eat a fifth of a one-button-wide window.
    local open, show = ImGui.Begin("HB" .. tostring(bar.id) .. "###cabbyHotbar" .. tostring(bar.id), true, windowFlags)
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

            -- popped before the tooltip and the context menu below, which are windows of their
            -- own and have no business inheriting a button's colours
            local switchState, switchPhrases = HotbarsUI.ButtonState(button)
            local pushedColors = PushSwitchColors(switchState)
            local pressed = ImGui.Button(button.label, bar.button_width, bar.button_height)
            if pushedColors > 0 then
                ImGui.PopStyleColor(pushedColors)
            end
            ImGui.PopStyleVar()

            if pressed then
                PressButton(bar, index)
            end

            -- every button is both ends of a rearrange: the one being carried and a slot to
            -- drop onto. Windows of their own -- the drag preview, the tooltip, the menu --
            -- restore the last item when they end, so these four read the same button
            DrawButtonDragSource(bar, index)
            DrawButtonDropTarget(bar, index, pending)
            DrawButtonTooltip(bar, button, switchState, switchPhrases)
            DrawButtonContextMenu(bar, index, state, pending)
            ImGui.PopID()
        end

        if #bar.buttons < 1 then
            ImGui.TextDisabled("Right-click to add a button")
            -- the only thing on an empty bar there is to aim at, and without it a bar emptied
            -- by dragging its last button away could never be dragged back into
            DrawButtonDropTarget(bar, 1, pending)
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
