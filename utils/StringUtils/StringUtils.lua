local StringUtils = { author = "judged", debug = false }

local function Debug(str)
    if StringUtils.debug then print(str) end
end

---@param str string
---@param delimiter string|nil
---@return table - Array of split string
function StringUtils.Split(str, delimiter)
    delimiter = delimiter or " "
    Debug("Splitting string with delimiter [" .. delimiter .. "]: " .. str)
    
    local split = {}
    local index = 1
    while #str > 0 do
        local matchStart = string.find(str, delimiter, 1, true)
        if matchStart == nil then
            split[index] = str
            str = ""
            break
        elseif matchStart == 1 then
            str = str:sub(#delimiter)
        else
            split[index] = str:sub(1, matchStart - 1)
            str = str:sub(matchStart + #delimiter)
            index = index + 1
        end
    end
    
    return split
end

---@param array table Array of strings
---@param delimiter string|nil
---@return string
function StringUtils.Join(array, delimiter)
    delimiter = delimiter or ""
    Debug("Joining strings with delimiter [" .. delimiter .. "]")
    if array == nil or #array < 1 then
        Debug("array was empty, returning empty string")
        return ""
    end
    if #array < 2 then
        Debug ("Array was only 1 element, returning that element [" .. array[1] .. "]")
        return array[1]
    end

    local joined = array[1]
    for i = 2, #array, 1 do
        joined = joined..delimiter..array[i]
        Debug("String joined: " .. joined)
    end

    return joined
end

---@param str string
---@return table - char array
function StringUtils.ToCharArray(str)
    local charArray = {}
    Debug("Splitting str to char array: " .. str)
    for i = 1, #str do
        charArray[i] = str:sub(i, i)
        Debug(charArray[i])
    end
    return charArray
end

---Trims whitespace from front of string
---@param str string
---@return string
function StringUtils.TrimFront(str)
    local result = str:match'^%s*(.*)'
    Debug("Trimming Front string: [" .. str .. "]")
    Debug("Trimmed Front string: [" .. result .. "]")
    return result
end

---@param tabs number
---@param spacesPerTab number? default is 4
---@return string - a string of spaces up until propper line start amount
function StringUtils.TabsToSpaces(tabs, spacesPerTab)
    spacesPerTab = spacesPerTab or 4
    if tabs < 1 then return "" end

    local spaces = tabs * spacesPerTab
    local space = " "
    local result = ""
    for _ = 1, spaces do
        result = result .. space
    end

    return result
end

return StringUtils
