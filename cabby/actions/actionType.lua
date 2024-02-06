---@class ActionType
local ActionType = {}

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

---@return boolean
function ActionType:IsReady()
    error("Action:IsReady() not implemented")
end

function ActionType:DoAction()
    error("Action:DoAction() not implemented")
end

return ActionType
