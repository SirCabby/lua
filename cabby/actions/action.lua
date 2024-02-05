---@class Action
local Action = {}

---@return string
function Action:Name()
    error("Action:Name() not implemented")
end

---@return string
function Action:ActionType()
    error("Action:ActionType() not implemented")
end

---@return boolean
function Action:HasAction()
    error("Action:HasAction() not implemented")
end

---@return boolean
function Action:IsReady()
    error("Action:IsReady() not implemented")
end

function Action:DoAction()
    error("Action:DoAction() not implemented")
end

return Action
