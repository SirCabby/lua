---@class Debug
local Debug = { author = "judged", toggles = { all = false } }

---@return Debug
function Debug:new()
    local debug = {}
    setmetatable(debug, self)
    self.__index = self

    ---Print if Debug enabled
    ---@param toggleKey string
    ---@param str string
    function Debug:Log(toggleKey, str)
        if Debug.toggles[toggleKey] == nil then
            Debug.toggles[toggleKey] = false
        end

        if Debug.toggles[toggleKey] or Debug.toggles.all then print(str) end
    end

    return debug
end

return Debug
