local Debug = require("utils.Debug.Debug")

---@class TableUtils
local TableUtils = { author = "judged", key = "TableUtils" }

local function DebugLog(str)
    Debug.Log(TableUtils.key, str)
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

---@param array array
---@param obj any
---@return boolean
function TableUtils.ArrayContains(array, obj)
    DebugLog("Does array contain: " .. tostring(obj))
    if not TableUtils.IsArray(array) then error("Cannot call ArrayContains on a key-value table") end
    if type(obj) == "string" then obj = obj:lower() end

    for _, value in ipairs(array) do
        if type(value) == "string" then value = value:lower() end
        DebugLog("Does [" .. tostring(value) .. "] == [" .. tostring(obj) .. "]? " .. tostring(value == obj))
        if value == obj then return true end
    end

    DebugLog("Array did not contain: " .. tostring(obj))
    return false
end

---Removes all occurrences of obj (as a value) in tbl
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
    for key in pairs(tbl) do
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
    if TableUtils.IsArray(tbl) then
        DebugLog("tbl was an array, returning tbl")
        return tbl
    end
    local result = {}
    local count = 0
    for _, value in pairs(tbl) do
        count = count + 1
        result[count] = value
        DebugLog("Value [" .. tostring(value) .. "]")
    end
    return result
end

---@param tbl1 table
---@param tbl2 table
---@return boolean isEqual true if equal, false if not
function TableUtils.Compare(tbl1, tbl2)
    for k, v in pairs(tbl1) do
        DebugLog("Comparing table key: [" .. k .. "]")
        if type(v) == "boolean" or type(v) == "string" or type(v) == "number" or type(v) == "nil" then
            if v ~= tbl2[k] then
                DebugLog("Values were not equal: [" .. tostring(v) .. "] : [" .. tostring(tbl2[k]) .. "]")
                return false
            end
        elseif type(v) == "table" then
            if not TableUtils.Compare(v, tbl2[k]) then
                DebugLog("Tables were not equal for key: [" .. k .. "]")
                return false
            end
        end
    end
    for k, v in pairs(tbl2) do
        DebugLog("Comparing table key: [" .. k .. "]")
        if type(v) == "boolean" or type(v) == "string" or type(v) == "number" or type(v) == "nil" then
            if v ~= tbl1[k] then
                DebugLog("Values were not equal: [" .. tostring(v) .. "] : [" .. tostring(tbl1[k]) .. "]")
                return false
            end
        elseif type(v) == "table" then
            if not TableUtils.Compare(v, tbl1[k]) then
                DebugLog("Tables were not equal for key: [" .. k .. "]")
                return false
            end
        end
    end

    DebugLog("Tables were equal")
    return true
end

---@param tbl table original table to be cloned
---@return table | nil clone deep clone of original tbl or nil if input was not a table
function TableUtils.DeepClone(tbl)
    if type(tbl) ~= "table" then
        DebugLog("tbl was not a table [" .. tostring(tbl) .. "]")
        return nil
    end

    local result = {}
    for k, v in pairs(tbl) do
        if type(v) == "boolean" or type(v) == "string" or type(v) == "number" or type(v) == "nil" then
            result[k] = v
        elseif type(v) == "table" then
            result[k] = TableUtils.DeepClone(v)
        end
    end

    return result
end

---@param minuend array The array to subtract from
---@param subtrahend array The subtracted array
---@return array difference Difference from the subtraction
function TableUtils.ArraySubtract(minuend, subtrahend)
    local result = {}
    local matches = {}

    for k, v in pairs(minuend) do result[k] = v end

    for i = 1, #subtrahend do
        matches[subtrahend[i]] = true
    end
    for i = #minuend, 1, -1 do
        if matches[minuend[i]] then
            table.remove(result, i)
        end
    end

    return result
end

---@param arrayToAppendTo array
---@param valuesToAppend array
function TableUtils.ArrayAppend(arrayToAppendTo, valuesToAppend)
    for _, value in ipairs(valuesToAppend) do
        arrayToAppendTo[#arrayToAppendTo+1] = value
    end
end

---@param array array
---@param obj any
---@return integer index in array or -1 if not in the array
function TableUtils.ArrayIndexOf(array, obj)
    for index, value in ipairs(array) do
        if obj == value then
            return index
        end
    end

    return -1
end

return TableUtils
