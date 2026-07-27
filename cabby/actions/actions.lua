local StringUtils = require("utils.StringUtils.StringUtils")

local AAs = require("cabby.actions.aas")
local ActionType = require('cabby.actions.actionType')
local Disciplines = require("cabby.actions.disciplines")
local Items = require("cabby.actions.items")
local Skills = require("cabby.actions.skills")
local Spells = require("cabby.actions.spells")

---Turns the two strings a configured action slot stores -- a type and a name -- back into
---something that can be fired.
---
---Every type but Ability resolves through a registry of what this character actually has, so a
---slot naming a disc that was respecced away, a spell scribed over, or a clicky left in the
---bank comes back nil. Callers already skip a nil action; that is what keeps a stale config
---from being an error.
local Actions = {}

---@param type string
---@param name string
---@return ActionType? action
Actions.Get = function(type, name)
    if type == nil or name == nil then return nil end
    type = type:lower()

    if type == ActionType.Ability then
        local skillname = StringUtils.Join(StringUtils.Split(name:lower())) -- this removes spaces and lowercases it
        return Skills[skillname]
    elseif type == ActionType.Discipline then
        return Disciplines.Get(name)
    elseif type == ActionType.Spell then
        return Spells.Get(name)
    elseif type == ActionType.AA then
        return AAs.Get(name)
    elseif type == ActionType.Item then
        return Items.Get(name)
    end
end

return Actions
