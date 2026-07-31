---@class AvailableActions
---@field aas table
---@field abilities table
---@field cabilities table
---@field discs table
---@field items table
---@field spells table what this list is normally picked from -- for a state that narrows the book
---by category, the spells that suit the job
---@field allSpells table the wider set the same picker will offer behind a switch, if there is
---one worth offering. A category is a label in the game's data rather than a promise, so a state
---that narrows by it says here what it narrowed *from*.
local AvailableActions = {}

function AvailableActions.new()
    return {
        aas = {},
        abilities = {},
        cabilities = {},
        discs = {},
        items = {},
        spells = {},
        allSpells = {}
    }
end

return AvailableActions
