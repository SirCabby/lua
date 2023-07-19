---@type Mq
local mq = require("mq")

---@class Debug
local Debug = { author = "judged", writeFile = false, all = false, _toggles = { } }

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
    if Debug.GetToggle(toggleKey) or Debug.all then
        if Debug.writeFile then
            writeFile(str)
        else
            print(str)
        end
    end
end

function Debug.ExistsOrDefault(toggleKey)
    toggleKey = toggleKey:lower()
    if Debug._toggles[toggleKey] == nil then
        Debug._toggles[toggleKey] = false
    end
end

function Debug.GetToggle(toggleKey)
    Debug.ExistsOrDefault(toggleKey)
    return Debug._toggles[toggleKey:lower()]
end

function Debug.SetToggle(toggleKey, toggleValue)
    Debug._toggles[toggleKey:lower()] = toggleValue
end

function Debug.Toggle(toggleKey)
    Debug.SetToggle(toggleKey, not Debug.GetToggle(toggleKey))
end

return Debug
