---@class Debug
local Debug = { author = "judged", _toggles = { all = false } }

---@return Debug
function Debug:new()
    local debug = {}
    setmetatable(debug, self)
    self.__index = self

    ---Print if Debug enabled
    ---@param toggleKey string
    ---@param str string
    function Debug:Log(toggleKey, str)
        if Debug:GetToggle(toggleKey) or Debug._toggles.all then print(str) end
    end

    function Debug:ExistsOrDefault(toggleKey)
        toggleKey = toggleKey:lower()
        if Debug._toggles[toggleKey] == nil then
            Debug._toggles[toggleKey] = false
        end
    end

    function Debug:GetToggle(toggleKey)
        Debug:ExistsOrDefault(toggleKey)
        return Debug._toggles[toggleKey:lower()]
    end

    function Debug:SetToggle(toggleKey, toggleValue)
        Debug._toggles[toggleKey:lower()] = toggleValue
    end

    function Debug:Toggle(toggleKey)
        Debug:SetToggle(toggleKey, not Debug:GetToggle(toggleKey))
    end

    return debug
end

return Debug
