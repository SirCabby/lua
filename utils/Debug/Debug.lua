---@type Mq
local mq = require("mq")

---@class Debug
local Debug = { author = "judged", writeFile = false, _ = { toggles = { all = false }, file = nil } }

---The toggle that sends logging to the file instead of the console, so it can be turned on from
---`/debug file 1` and survives a reload like every other toggle. `Debug.writeFile` still works and
---is what a script sets in code.
local fileToggle = "file"

---@return file*|nil handle held open rather than reopened per line: a loop worth debugging writes
---faster than open-write-close can keep up with, and paying that per line is how logging becomes
---the thing being measured
local function logFile()
    if Debug._.file == nil then
        local filePath = mq.luaDir .. package.config:sub(1,1) .. "Debug.log"
        Debug._.file = io.open(filePath, "a")
        assert(Debug._.file ~= nil, "Unable to create file: " .. filePath)
    end
    return Debug._.file
end

---@return string stamp wall clock to the millisecond -- anything happening once a frame is
---unreadable without it.
---
---The milliseconds come from `Time`, which is a luasocket away, and this is the one module in the
---script that everything else loads: an error raised in here would surface as a fault in whatever
---was being logged, which is the last thing a debugging aid should do. So the second is what is
---promised and the millisecond is what is offered.
local function stamp()
    local ok, ms = pcall(function()
        return string.format(".%03d", require("utils.Time.Time").current_time() % 1000)
    end)
    return os.date("%H:%M:%S") .. (ok and ms or "")
end

---@param toggleKey string
---@param content string
local function writeFile(toggleKey, content)
    local file = logFile()
    file:write(stamp(), " [", toggleKey, "] ", content, "\n")
    -- flushed rather than buffered: the point of the file is watching it while the thing being
    -- logged is still happening
    file:flush()
end

---Print if Debug enabled
---@param toggleKey string
---@param str string
function Debug.Log(toggleKey, str)
    if Debug.GetToggle(toggleKey) or Debug.GetToggle("all") then
        if Debug.writeFile or Debug.GetToggle(fileToggle) then
            writeFile(toggleKey, str)
        else
            print(str)
        end
    end
end

---@param toggleKey string
function Debug.ExistsOrDefault(toggleKey)
    toggleKey = toggleKey:lower()
    if Debug._.toggles[toggleKey] == nil then
        Debug._.toggles[toggleKey] = false
    end
end

---@param toggleKey string
---@return boolean isEnabled
function Debug.GetToggle(toggleKey)
    Debug.ExistsOrDefault(toggleKey)
    return Debug._.toggles[toggleKey:lower()]
end

---@param toggleKey string
---@param toggleValue boolean
function Debug.SetToggle(toggleKey, toggleValue)
    Debug._.toggles[toggleKey:lower()] = toggleValue
end

---@param toggleKey string
function Debug.Toggle(toggleKey)
    Debug.SetToggle(toggleKey, not Debug.GetToggle(toggleKey))
end

return Debug
