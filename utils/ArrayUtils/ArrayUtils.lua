
---@class ArrayUtils
local ArrayUtils = { author = "judged" }

---@param obj any
---@return boolean
function ArrayUtils.IsArray(obj)
    local i = 1
    for _ in pairs(obj) do
        if obj[i] == nil then return false end
        i = i + 1
    end
    return true
end

return ArrayUtils
