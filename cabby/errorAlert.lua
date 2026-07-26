local mq = require("mq")
local ImGui = require("ImGui")

---Collects script errors so they are never lost in chat scroll: each unique
---(source, error) signature becomes one alert with a running count, is appended
---to a log file, and is shown in a dedicated "Cabby Alerts" ImGui window until
---dismissed. Paused states expose a Resume button instead of Dismiss.
---@class ErrorAlert
local ErrorAlert = {
    key = "ErrorAlert",
    _ = {
        isInit = false,
        logFilePath = nil,
        alerts = {}, -- { [signature] = alert }
        order = {},  -- signatures, oldest first
        copiedLabel = nil, -- what the last Copy button grabbed, shown as feedback
        copiedAt = 0
    }
}

-- how long the "Copied ..." confirmation stays up, in seconds
local copiedFeedbackSeconds = 3

local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

local function writeLog(text)
    if ErrorAlert._.logFilePath == nil then return end
    local file = io.open(ErrorAlert._.logFilePath, "a")
    if file == nil then return end
    file:write(text .. "\n")
    file:close()
end

---@param sourceKey string origin of the error, e.g. "state:MeleeState" or "command:attack"
---@param err any error value (traceback string when recorded via xpcall)
---@return table alert
function ErrorAlert.Record(sourceKey, err)
    local message = tostring(err)
    -- key on the first line (the raise site) so the same error counts up even when the
    -- call path below it (and so the traceback body) differs
    local signature = sourceKey .. "|" .. (message:match("^[^\n]*") or message)
    local alert = ErrorAlert._.alerts[signature]
    if alert == nil then
        alert = {
            source = sourceKey,
            message = message,
            count = 0,
            firstSeen = timestamp(),
            lastSeen = "",
            paused = false,
            onResume = nil
        }
        ErrorAlert._.alerts[signature] = alert
        ErrorAlert._.order[#ErrorAlert._.order+1] = signature
        writeLog("[" .. alert.firstSeen .. "] [" .. sourceKey .. "]")
        writeLog(message)
        print("\arCabby error in [" .. sourceKey .. "], see Cabby Alerts window\ax")
    end
    alert.count = alert.count + 1
    alert.lastSeen = timestamp()
    return alert
end

---@param signature string
local function dismiss(signature)
    local alert = ErrorAlert._.alerts[signature]
    if alert == nil then return end
    writeLog("[" .. timestamp() .. "] [" .. alert.source .. "] dismissed after " .. tostring(alert.count) .. " occurrence(s) (first: " .. alert.firstSeen .. ")")
    ErrorAlert._.alerts[signature] = nil
    for index, value in ipairs(ErrorAlert._.order) do
        if value == signature then
            table.remove(ErrorAlert._.order, index)
            break
        end
    end
end

---@param alert table
---@return string text full detail of one alert, suitable for pasting elsewhere
local function alertToText(alert)
    return "[" .. alert.source .. "] x" .. tostring(alert.count)
        .. "\nfirst: " .. alert.firstSeen .. "   last: " .. alert.lastSeen
        .. "\n" .. alert.message
end

---@return string text every open alert, plus the log path for context
local function allAlertsToText()
    local parts = { "Cabby Alerts (" .. tostring(#ErrorAlert._.order) .. " error(s))",
                    "Log: " .. tostring(ErrorAlert._.logFilePath) }
    for _, signature in ipairs(ErrorAlert._.order) do
        parts[#parts+1] = ""
        parts[#parts+1] = alertToText(ErrorAlert._.alerts[signature])
    end
    return table.concat(parts, "\n")
end

---@param label string what was copied, echoed back to the user
---@param text string
local function copyToClipboard(label, text)
    ImGui.SetClipboardText(text)
    ErrorAlert._.copiedLabel = label
    ErrorAlert._.copiedAt = os.time()
end

local function DrawCopiedFeedback()
    if ErrorAlert._.copiedLabel == nil then return end
    if os.difftime(os.time(), ErrorAlert._.copiedAt) > copiedFeedbackSeconds then
        ErrorAlert._.copiedLabel = nil
        return
    end
    ImGui.SameLine()
    ImGui.TextColored(0.4, 1, 0.4, 1, "Copied " .. ErrorAlert._.copiedLabel)
end

---@param text string
---@return number lines
local function countLines(text)
    local lines = 1
    for _ in text:gmatch("\n") do lines = lines + 1 end
    return lines
end

---Read-only multiline input so the text can be drag-selected and Ctrl+C'd by hand.
---@param text string
local function DrawSelectableText(text)
    local lines = math.max(3, math.min(countLines(text), 14))
    local height = lines * ImGui.GetTextLineHeight() + 8
    ImGui.InputTextMultiline("##selectable", text, -1, height, ImGuiInputTextFlags.ReadOnly)
end

local function DrawAlertsWindow()
    if #ErrorAlert._.order < 1 then return end

    ImGui.SetNextWindowSize(720, 420, ImGuiCond.FirstUseEver)
    local show = ImGui.Begin("Cabby Alerts")
    if show then
        ImGui.TextColored(1, 0.4, 0.4, 1, tostring(#ErrorAlert._.order) .. " error(s)")
        ImGui.Text("Log: " .. tostring(ErrorAlert._.logFilePath))

        if ImGui.Button("Copy All") then
            copyToClipboard("all errors", allAlertsToText())
        end
        ImGui.SameLine()
        if ImGui.Button("Copy Log Path") then
            copyToClipboard("log path", tostring(ErrorAlert._.logFilePath))
        end
        DrawCopiedFeedback()

        ImGui.TextDisabled("Drag to select text below, Ctrl+C to copy the selection")
        ImGui.Separator()

        local toDismiss = nil
        for _, signature in ipairs(ErrorAlert._.order) do
            local alert = ErrorAlert._.alerts[signature]
            ImGui.PushID(signature)

            ImGui.TextColored(1, 0.4, 0.4, 1, alert.source .. " (x" .. tostring(alert.count) .. ")")
            ImGui.Text("first: " .. alert.firstSeen .. "   last: " .. alert.lastSeen)

            if alert.paused then
                ImGui.TextColored(1, 0.8, 0.2, 1, "This state is PAUSED until resumed")
                if alert.onResume ~= nil and ImGui.Button("Resume") then
                    alert.paused = false
                    alert.onResume()
                end
            else
                if ImGui.Button("Dismiss") then
                    toDismiss = signature
                end
            end
            ImGui.SameLine()
            if ImGui.Button("Copy Error") then
                copyToClipboard("[" .. alert.source .. "]", alertToText(alert))
            end

            DrawSelectableText(alert.message)
            ImGui.Separator()
            ImGui.PopID()
        end
        if toDismiss ~= nil then
            dismiss(toDismiss)
        end
    end
    ImGui.End()
end

---@param logFilePath string file that error details are appended to
function ErrorAlert.Init(logFilePath)
    if not ErrorAlert._.isInit then
        ErrorAlert._.logFilePath = logFilePath
        mq.imgui.init("Cabby Alerts", DrawAlertsWindow)
        ErrorAlert._.isInit = true
    end
end

return ErrorAlert
