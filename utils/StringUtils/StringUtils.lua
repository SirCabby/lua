local StringUtils = { author = "judged" }

---@param str string
---@param delimiter string|nil
---@return table - Array of split string
function StringUtils.Split(str, delimiter)
    delimiter = delimiter or " "
    local split = {}
    for match in string.gmatch(str, "([^"..delimiter.."]+)") do
        table.insert(split, match)
    end
    return split
end

---@param array table Array of strings
---@param delimiter string|nil
---@return string
function StringUtils.Join(array, delimiter)
    if array == nil or #array < 1 then return "" end
    if #array < 2 then return array[1] end
    delimiter = delimiter or ""

    local joined = array[1]
    for i = 2, #array, 1 do
        joined = joined..delimiter..array[i]
    end

    return joined
end

---@param str string
---@return table - char array
function StringUtils.ToCharArray(str)
    local charArray = {}
    for i = 1, #str do
        charArray[i] = str:sub(i, i)
    end
    return charArray
end

---Trims whitespace from front of string
---@param str string
---@return string
function StringUtils.TrimFront(str)
    return str:match'^%s*(.*)'
end

return StringUtils
