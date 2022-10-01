local ArrayUtils = require("utils.ArrayUtils.ArrayUtils")
local StringUtils = require("utils.StringUtils.StringUtils")

---@class Json
local Json = { author = "judged" }

---@param obj any Any lua datatype to be serialized, `function` or `userdata` types will result in nulls
---@return table - json pretty-printed string array of each line
function Json.Serialize(obj)
    local switchType = {}

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

    local function SerializeTable(inputTable, output, indent)
        if #output < 1 then
            output[1] = "{"
        else
            output[#output] = output[#output] .. "{"
        end
        indent = indent + 1

        for key, value in pairs(inputTable) do
            output[#output + 1] =  GetPad(indent) .. "\"" .. key .. "\": "
            switchType[type(value)](value, output, indent)
            output[#output] = output[#output] .. ","
        end
        -- remove comma from last key
        output[#output] = output[#output]:sub(1, -2)

        indent = indent - 1
        output[#output + 1] = GetPad(indent) .. "}"
    end

    local function SerializeArray(inputArray, output, indent)
        if #output < 1 then
            output[1] = "["
        else
            output[#output] = output[#output] .. "["
        end
        indent = indent + 1

        for index, value in ipairs(inputArray) do
            output[#output + 1] = GetPad(indent)
            switchType[type(value)](value, output, indent)
            if index < #inputArray then
                output[#output] = output[#output] .. ","
            end
        end

        indent = indent - 1
        output[#output + 1] = GetPad(indent) .. "]"
    end

    local function SerializeTableOrArray(tableOrArray, output, indent)
        if ArrayUtils.IsArray(tableOrArray) then
            SerializeArray(tableOrArray, output, indent)
        else
            SerializeTable(tableOrArray, output, indent)
        end
    end

    local function SerializeString(input, output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. "\"" .. input .. "\"")
            table.insert(output, "]")
        else 
            output[#output] = output[#output] .. "\"" .. input .. "\""
        end
    end

    local function SerializeNumOrBool(input, output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. tostring(input))
            table.insert(output, "]")
        else
            output[#output] = output[#output] .. tostring(input)
        end
    end

    local function SerializeNull(output)
        if #output < 1 then
            table.insert(output, "[")
            table.insert(output, GetPad(1) .. "null")
            table.insert(output, "]")
        else
            output[#output] = output[#output] .. "null"
        end
    end

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
    if type(str) == "table" and ArrayUtils.IsArray(str) then str = StringUtils.Join(str) end
end

---@param strings table Array of string lines to print
function Json.Print(strings)
    for _,str in ipairs(strings) do
        print(str)
    end
end

return Json
