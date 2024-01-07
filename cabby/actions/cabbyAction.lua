---@class CabbyAction
---@field id string
---@field description string
---@field enabled boolean
---@field actionFunction function
local CabbyAction = {}

CabbyAction.__index = CabbyAction
setmetatable(CabbyAction, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

---@param id string
---@param enabled boolean
---@param actionFunction function
---@param description string
---@return CabbyAction
function CabbyAction.new(id, enabled, actionFunction, description)
    local self = setmetatable({}, CabbyAction)

    self.id = id
    self.enabled = enabled
    self.actionFunction = actionFunction
    self.description = description

    return self
end

return CabbyAction
