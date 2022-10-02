local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Json
local Json = { 
    author = "judged",
    debug = false
}

---@param obj any Any lua datatype to be serialized, `function` or `userdata` types will result in nulls
---@return table - json pretty-printed string array of each line
function Json.Serialize(obj)
    local switchType = {}

    ---@param tabs number number of 4 space tabs to indent by
    ---@return string - a string of spaces up until propper line start amount
    local function GetPad(tabs)
        if tabs < 1 then return "" end

        local spaces = tabs * 4
        local space = " "
        local result = ""
        for _ = 1, spaces do
            result = result .. space
        end

        return result
    end

    ---Updates output string array with data from inputTable
    ---@param inputTable table actual table, not an array
    ---@param output table string array
    ---@param indent number current indentation amount
    local function SerializeTable(inputTable, output, indent)
        -- set opening table brace
        if #output < 1 then
            output[1] = "{"
        else
            output[#output] = output[#output] .. "{"
        end
        indent = indent + 1

        -- output each kvp
        for key, value in pairs(inputTable) do
            output[#output + 1] =  GetPad(indent) .. "\"" .. key .. "\": "
            switchType[type(value)](value, output, indent)
            output[#output] = output[#output] .. ","
        end
        -- remove comma from last key
        output[#output] = output[#output]:sub(1, -2)

        -- set closing table brace
        indent = indent - 1
        output[#output + 1] = GetPad(indent) .. "}"
    end

    ---@param inputArray table must be an array table
    ---@param output table string array
    ---@param indent number current indentation amount
    local function SerializeArray(inputArray, output, indent)
        -- set opening array bracket
        if #output < 1 then
            output[1] = "["
        else
            output[#output] = output[#output] .. "["
        end
        indent = indent + 1

        -- ouput each unknown value type
        for index, value in ipairs(inputArray) do
            output[#output + 1] = GetPad(indent)
            switchType[type(value)](value, output, indent)

            -- don't add comma for last item in array
            if index < #inputArray then
                output[#output] = output[#output] .. ","
            end
        end

        -- set closing array bracket
        indent = indent - 1
        output[#output + 1] = GetPad(indent) .. "]"
    end

    ---Determine if table is an array type or not and handle each appropriately
    ---@param tableOrArray table
    ---@param output table string array
    ---@param indent number current indentation amount
    local function SerializeTableOrArray(tableOrArray, output, indent)
        if TableUtils.IsArray(tableOrArray) then
            SerializeArray(tableOrArray, output, indent)
        else
            SerializeTable(tableOrArray, output, indent)
        end
    end

    ---Handle serializing a string with quote marks
    ---@param input string
    ---@param output table string array
    local function SerializeString(input, output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. "\"" .. input .. "\"")
            table.insert(output, "]")
        else 
            output[#output] = output[#output] .. "\"" .. input .. "\""
        end
    end

    ---@param input number|boolean
    ---@param output table string array
    local function SerializeNumOrBool(input, output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. tostring(input))
            table.insert(output, "]")
        else
            output[#output] = output[#output] .. tostring(input)
        end
    end

    ---@param output table string array
    local function SerializeNull(output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. "null")
            table.insert(output, "]")
        else
            output[#output] = output[#output] .. "null"
        end
    end

    ---Call appropriate serialization depending on the input type
    switchType = {
        ["string"] = function(input, output) return SerializeString(input, output) end,
        ["number"] = function(input, output) return SerializeNumOrBool(input, output) end,
        ["boolean"] = function(input, output) return SerializeNumOrBool(input, output) end,
        ["table"] = function(input, output, indent) return SerializeTableOrArray(input, output, indent) end,
        ["nil"] = function(_, output) return SerializeNull(output) end,
        ["function"] = function(_, output) return SerializeNull(output) end,
        ["userdata"] = function(_, output) return SerializeNull(output) end
    }

    local output = {}
    local indent = 0
    switchType[type(obj)](obj, output, indent)
    return output
end

---@param str string|table String or array of strings to join
---@return any
function Json.Deserialize(str)
    if type(str) == "table" and TableUtils.IsArray(str) then str = StringUtils.Join(str) end
    if type(str) ~= "string" then return {} end
    str = StringUtils.TrimFront(str)
    local indent = 0

    local _holder = {}

    ---@return string - a string of spaces up until propper line start amount
    local function GetPad()
        if indent < 1 then return "" end

        local spaces = indent * 4
        local space = " "
        local result = ""
        for _ = 1, spaces do
            result = result .. space
        end

        return result
    end

    ---@param str string
    local function Debug(str)
        if Json.debug then print(GetPad() .. str) end
    end

    ---Traverse char array up to a point, discarding elements until stopping
    ---@param charArray table
    ---@param stopperArray table char array of elements of importance
    ---@param stopAt boolean true to stop traversal when encountering an item in stopperArray, false to continue until not finding a match in stopperArray
    local function TraverseUntil(charArray, stopperArray, stopAt)
        if #charArray < 1 then return end

        --if Json.debug then print("start") end
        local nextChar = charArray[1]
        indent = indent + 1
        while TableUtils.ArrayContains(stopperArray, nextChar) == stopAt do
            local removed = table.remove(charArray, 1)
            --if Json.debug then print(removed) end
            nextChar = charArray[1]
        end
        indent = indent - 1
        Debug("Traverse stop - next: " .. charArray[1])
    end

    ---Traverse input char array until finding the end of the string via quotation mark
    ---@param charArray table
    ---@return string
    local function ReadString(charArray)
        if charArray[1] ~= "\"" then error("Tried to read a key but did not begin with a \"") end
        table.remove(charArray, 1)

        local keyResult = ""
        while #charArray > 0 do
            if charArray[1] == "\"" then
                table.remove(charArray, 1)
                break
            end
            keyResult = keyResult .. table.remove(charArray, 1)
        end

        Debug("Found string: " .. keyResult)
        return keyResult
    end

    ---Next value type is unknown, figure it out and decide which way to handle
    ---@param charArray table
    ---@return string|table|number|boolean
    local function ReadValue(charArray)
        TraverseUntil(charArray, { " " }, true)
        Debug("ReadValue start: " .. charArray[1])
        if #charArray < 1 then error("Reached end of input while looking for a value") end
        if charArray[1] == "\"" then return ReadString(charArray) end
        if charArray[1] == "{" then return _holder.DeserializeTable(charArray) end
        if charArray[1] == "[" then return _holder.DeserializeArray(charArray) end
        indent = indent + 1
        Debug("ReadValue primitive start: " .. charArray[1])
        -- read up the value string
        local valueResult = ""
        while #charArray > 0 do
            if charArray[1] == "," then
                table.remove(charArray, 1)
                break
            end
            if TableUtils.ArrayContains({ "}", "]", " " }, charArray[1]) then
                break
            end
            -- append character to the result string
            valueResult = valueResult .. table.remove(charArray, 1)
        end

        -- determine type
        local valueTypeFunction = loadstring("return " .. valueResult)
        if valueTypeFunction == nil then error("Failed to determine type of value: (" .. valueResult .. ")") end
        local valueType = type(valueTypeFunction())
        if valueType == "number" then
            Debug("Found number: " .. valueResult)
            indent = indent - 1
            local result = tonumber(valueResult)
            return result or 0
        elseif valueType == "boolean" then
            Debug("Found boolean: " .. valueResult)
            indent = indent - 1
            local result = false
            if string.lower(valueResult) == "true" then result = true end
            return result
        end

        error("Failed to convert string to value type: " .. valueType)
    end

    ---@param charArray table
    ---@return table
    function _holder.DeserializeArray(charArray)
        local output = {}
        indent = indent + 1
        Debug("Making Array...")

        table.remove(charArray, 1) -- remove the first [
        TraverseUntil(charArray, { " " }, true)

        while charArray[1] ~= "]" do
            table.insert(output, ReadValue(charArray))
            TraverseUntil(charArray, { " ", "," }, true)
        end

        table.remove(charArray, 1) -- remove the last ]

        Debug("Finished Array")
        indent = indent - 1
        return output
    end

    ---@param charArray table
    ---@return table
    function _holder.DeserializeTable(charArray)
        local output = {}
        indent = indent + 1
        Debug("Making table...")

        -- look for key or end of table
        TraverseUntil(charArray, { "\"", "}" }, false)

        -- *"key": unknownValueType
        while charArray[1] == "\"" do
            local thisKey = ReadString(charArray)
            -- "key"*: unknownValueType
            TraverseUntil(charArray, { ":" }, false)
            table.remove(charArray, 1)
            -- "key": *unknownValueType
            local thisValue = ReadValue(charArray)
            -- "key": unknownValueType*
            output[thisKey] = thisValue
            TraverseUntil(charArray, { "\"", "}" }, false)
        end

        if charArray[1] == "}" then table.remove(charArray, 1) end

        Debug("Finished table")
        indent = indent - 1
        return output
    end

    local charArray = StringUtils.ToCharArray(str)
    local result = {}

    if charArray[1] == "{" then
        result = _holder.DeserializeTable(charArray)
    elseif charArray[1] == "[" then
        result = _holder.DeserializeArray(charArray)
    end

    return result
end

---@param strings table Array of string lines to print
function Json.Print(strings)
    for _,str in ipairs(strings) do
        print(str)
    end
end

return Json
