local Skills = require("cabby.actions.skills")

local Actions = {}

Actions.ability = "ability"

---@param type string
---@param name string
---@return Action? action
Actions.Get = function(type, name)
    if type:lower() == Actions.ability then
        return Skills[name:lower()]
    end
end

return Actions
