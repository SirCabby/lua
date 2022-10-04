---@class TableUtils
local TableUtils = { author = "judged", debug = false }

local function Debug(str)
    if TableUtils.debug then print(str) end
end

---@param tbl table
---@return boolean
function TableUtils.IsArray(tbl)
    Debug("Is array?")
    local i = 1
    for _ in pairs(tbl) do
        if tbl[i] == nil then
            Debug("Did not find index in table [" .. tostring(i) .. "], is not an array")
            return false
        end
        i = i + 1
    end
    Debug("this table is an array")
    return true
end

---@param array table
---@param obj any
---@return boolean
function TableUtils.ArrayContains(array, obj)
    Debug("Does array contain: " .. tostring(obj))
    if not TableUtils.IsArray(array) then error("Cannot call ArrayContains on a key-value table") end
    if type(obj) == "string" then obj = obj:lower() end

    for _, value in ipairs(array) do
        if type(value) == "string" then value = value:lower() end
        Debug("Does [" .. value .. "] == [" .. obj .. "]? " .. tostring(value == obj))
        if value == obj then return true end
    end

    Debug("Array did not contain: " .. tostring(obj))
    return false
end

---Removes all occurrences of obj in tbl
---@param tbl table Array or Table format
---@param obj any object to remove
function TableUtils.RemoveByValue(tbl, obj)
    Debug("Removing [" .. tostring(obj) .. "] from table")
    if type(obj) == "string" then obj = obj:lower() end
    if TableUtils.IsArray(tbl) then
        Debug("Table is an array, using array removal...")
        local indexesToRemove = {}
        -- find indexes of values to remove
        for index, value in ipairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            if value == obj then
                Debug("Value matched at index: " .. tostring(index))
                table.insert(indexesToRemove, index)
            end
        end
        -- remove in reverse order for iterator safety
        for i = #indexesToRemove, 1, -1 do
            table.remove(tbl, indexesToRemove[i])
            Debug("Removed index: " .. tostring(indexesToRemove[i]))
        end
    else
        Debug("Table is not an array, using table removal...")
        for key, value in pairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            Debug("Value matched")
            if value == obj then tbl[key] = nil end
        end
    end
    Debug("Finished removing from table")
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
    Debug("Getting keys from table")
    local result = {}
    local count = 0
    for key,_ in pairs(tbl) do
        count = count + 1
        result[count] = key
        Debug("Key [" .. tostring(key) .. "]")
    end
    table.sort(result)
    return result
end

return TableUtils
