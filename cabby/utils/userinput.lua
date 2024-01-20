---@class UserInput
local UserInput = { author = "judged", key = "UserInput" }

---Return true for truthy inputs
---@param inputStr string
---@return boolean
UserInput.IsTrue = function(inputStr)
    inputStr = tostring(inputStr):lower()
    return inputStr == "on" or
        inputStr == "true" or
        inputStr == "enable" or
        inputStr == "yes" or
        inputStr == "1"
end

---Return false for falsy inputs
---@param inputStr string
---@return boolean
UserInput.IsFalse = function(inputStr)
    inputStr = tostring(inputStr):lower()
    return inputStr == "off" or
        inputStr == "false" or
        inputStr == "disable" or
        inputStr == "no" or
        inputStr == "0" or
        inputStr == "" or
        inputStr == "null" or
        inputStr == "nil"
end

return UserInput
