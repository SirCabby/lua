---@class TableUtils
local TableUtils = { author = "judged", debug = false }

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
    if type(obj) == "string" then obj = obj:lower() end

    for _, value in ipairs(array) do
        if type(value) == "string" then value = value:lower() end
        if value == obj then return true end
    end

    return false
end

---Removes all occurrences of obj in tbl
---@param tbl table Array or Table format
---@param obj any object to remove
function TableUtils.RemoveByValue(tbl, obj)
    if type(obj) == "string" then obj = obj:lower() end
    if TableUtils.IsArray(tbl) then
        local indexesToRemove = {}
        -- find indexes of values to remove
        for index, value in ipairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            if value == obj then
                table.insert(indexesToRemove, index)
            end
        end
        -- remove in reverse order for iterator safety
        for i = #indexesToRemove, 1, -1 do
            table.remove(tbl, indexesToRemove[i])
        end
    else
        for key, value in pairs(tbl) do
            if type(value) == "string" then value = value:lower() end
            if value == obj then tbl[key] = nil end
        end
    end
end

---@param obj table
function TableUtils.Print(obj)
    local Json = require("utils.Json.Json")
    Json.Print(Json.Serialize(obj))
end

---Returns all keys associated with obj
---@param tbl table
---@return table - containing array of keys
function TableUtils.GetKeys(tbl)
    local result = {}
    local count = 0
    for key,_ in pairs(tbl) do
        count = count + 1
        result[count] = key
    end
    table.sort(result)
    return result
end

return TableUtils
