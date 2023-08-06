---@type Mq
local mq = require("mq")

---@class Debug
local Debug = { author = "judged", writeFile = false, _ = { toggles = { all = false } } }

---@param content string line to write to Debug.log
local function writeFile(content)
    local filePath = mq.luaDir .. package.config:sub(1,1) .. "Debug.log"
    local file = io.open(filePath, "a")
    assert(file ~= nil, "Unable to create file: " .. filePath)
    file:write(content, "\n")
    file:close()
end

---Print if Debug enabled
---@param toggleKey string
---@param str string
function Debug.Log(toggleKey, str)
    if Debug.GetToggle(toggleKey) or Debug.GetToggle("all") then
        if Debug.writeFile then
            writeFile(str)
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
