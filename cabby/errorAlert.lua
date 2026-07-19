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
        order = {}   -- signatures, oldest first
    }
}

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

local function DrawAlertsWindow()
    if #ErrorAlert._.order < 1 then return end

    ImGui.SetNextWindowSize(560, 320, ImGuiCond.FirstUseEver)
    local show = ImGui.Begin("Cabby Alerts")
    if show then
        ImGui.TextColored(1, 0.4, 0.4, 1, tostring(#ErrorAlert._.order) .. " error(s)")
        ImGui.Text("Log: " .. tostring(ErrorAlert._.logFilePath))
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

            ImGui.TextWrapped(alert.message)
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
