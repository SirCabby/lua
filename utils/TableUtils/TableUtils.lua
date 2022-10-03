---@class TableUtils
local TableUtils = { author = "judged" }

---@param obj any
---@return boolean
function TableUtils.IsArray(obj)
    local i = 1
    for _ in pairs(obj) do
        if obj[i] == nil then return false end
        i = i + 1
    end
    return true
end

---@param array table
---@param obj any
---@return boolean
function TableUtils.ArrayContains(array, obj)
    if not TableUtils.IsArray(array) then error("Cannot call ArrayContains on a key-value table") end

    for _, value in ipairs(array) do
        if value == obj then return true end
    end

    return false
end

---@param obj table
function TableUtils.Print(obj)
    local Json = require("utils.Json.Json")
    Json.Print(Json.Serialize(obj))
end

function TableUtils.GetKeys(obj)
    local result = {}
    local count = 0
    for key,_ in pairs(obj) do
        count = count + 1
        result[count] = key
    end
    table.sort(result)
    return result
end

return TableUtils
