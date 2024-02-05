---@class AvailableActions
---@field aas table
---@field abilities table
---@field cabilities table
---@field discs table
---@field items table
---@field spells table
local AvailableActions = {}

function AvailableActions.new()
    return {
        aas = {},
        abilities = {},
        cabilities = {},
        discs = {},
        items = {},
        spells = {}
    }
end

return AvailableActions
