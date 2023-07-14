local Debug = require("utils.Debug.Debug")

---@class TableUtils
local TableUtils = { author = "judged", key = "TableUtils" }

Debug:new()

local function DebugLog(str)
    Debug:Log(TableUtils.key, str)
end

---@param tbl table
---@return boolean
function TableUtils.IsArray(tbl)
    DebugLog("Is array?")
    local i = 1
    for _ in pairs(tbl) do
        if tbl[i] == nil then
            DebugLog("Did not find index in table [" .. tostring(i) .. "], is not an array")
            return false
        end
        i = i + 1
    end
    DebugLog("this table is an array")
    return true
end

---@param array table
---@param obj any
---@return boolean
function TableUtils.ArrayContains(array, obj)
    DebugLog("Does array contain: " .. tostring(obj))
    if not TableUtils.IsArray(array) then error("Cannot call ArrayContains on a key-value table") end
    if type(obj) == "string" then obj = obj:lower() end

    for _, value in ipairs(array) do
        if type(value) == "string" then value = value:lower() end
        DebugLog("Does [" .. value .. "] == [" .. obj .. "]? " .. tostring(value == obj))
        if value == obj then return true end
    end

    DebugLog("Array did not contain: " .. tostring(obj))
    return false
end

---Removes all occurrences of obj in tbl
---@param tbl table Array or Table format
---@param obj any object to remove
function TableUtils.RemoveByValue(tbl, obj)
    DebugLog("Removing [" .. tostring(obj) .. "] from table")
    if type(obj) == "string" then obj = obj:lower() end
    if TableUtils.IsArray(tbl) then
        DebugLog("Table is an array, using array removal...")
        local indexesToRemove = {}
        -- find indexes of values to remove
        for index, value in ipairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            if value == obj then
                DebugLog("Value matched at index: " .. tostring(index))
                table.insert(indexesToRemove, index)
            end
        end
        -- remove in reverse order for iterator safety
        for i = #indexesToRemove, 1, -1 do
            table.remove(tbl, indexesToRemove[i])
            DebugLog("Removed index: " .. tostring(indexesToRemove[i]))
        end
    else
        DebugLog("Table is not an array, using table removal...")
        for key, value in pairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            DebugLog("Value matched")
            if value == obj then tbl[key] = nil end
        end
    end
    DebugLog("Finished removing from table")
end

---@param obj table
function TableUtils.Print(obj)
    local Json = require("utils.Json.Json")
    Json.Print(Json.Serialize(obj))
end

---Returns all keys associated with obj
---@param tbl table
---@return table - array of keys
function TableUtils.GetKeys(tbl)
    DebugLog("Getting keys from table")
    local result = {}
    local count = 0
    for key,_ in pairs(tbl) do
        count = count + 1
        result[count] = key
        DebugLog("Key [" .. tostring(key) .. "]")
    end
    table.sort(result)
    return result
end

---Returns all top-level values associated with obj
---@param tbl table
---@return table - array of top-level values
function TableUtils.GetValues(tbl)
    DebugLog("Getting top-level values from table")
    local result = {}
    local count = 0
    for _,value in pairs(tbl) do
        count = count + 1
        result[count] = value
        DebugLog("Value [" .. tostring(value) .. "]")
    end
    table.sort(result)
    return result
end

return TableUtils
