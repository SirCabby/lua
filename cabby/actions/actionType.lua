---@class ActionType
local ActionType = {}

ActionType.Edit = "none"
ActionType.AA = "aa"
ActionType.Ability = "ability"
ActionType.Discipline = "discipline"
ActionType.Item = "item"
ActionType.Spell = "spell"

---@return string
function ActionType:Name()
    error("Action:Name() not implemented")
end

---@return string
function ActionType:ActionType()
    error("Action:ActionType() not implemented")
end

---@return boolean
function ActionType:HasAction()
    error("Action:HasAction() not implemented")
end

---@return number
function ActionType:EndCost()
    error("ActionType:EndCost() not implemented")
end

---@return boolean
function ActionType:IsReady()
    error("Action:IsReady() not implemented")
end

function ActionType:DoAction()
    error("Action:DoAction() not implemented")
end

return ActionType
