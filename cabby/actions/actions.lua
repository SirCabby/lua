local StringUtils = require("utils.StringUtils.StringUtils")

local Skills = require("cabby.actions.skills")

local Actions = {}
Actions.ability = "ability"

---@param type string
---@param name string
---@return ActionType? action
Actions.Get = function(type, name)
    type = type:lower()
    if type == Actions.ability then
        local skillname = StringUtils.Join(StringUtils.Split(name:lower())) -- this removes spaces and lowercases it
        return Skills[skillname]
    end
end

return Actions
