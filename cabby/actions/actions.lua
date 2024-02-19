local StringUtils = require("utils.StringUtils.StringUtils")

local ActionType = require('cabby.actions.actionType')
local Disciplines = require("cabby.actions.disciplines")
local Skills = require("cabby.actions.skills")

local Actions = {}

---@param type string
---@param name string
---@return ActionType? action
Actions.Get = function(type, name)
    type = type:lower()
    if type == ActionType.Ability then
        local skillname = StringUtils.Join(StringUtils.Split(name:lower())) -- this removes spaces and lowercases it
        return Skills[skillname]
    elseif type == ActionType.Discipline then
        return Disciplines.Get(name)
    end
end

return Actions
