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

---Is this worth using right now? Cooldowns, resources, and whether the target it would be used
---on can actually be reached.
---@param request? table who it would be used on: `{ targetId }`. Skills and disciplines ignore
---it; a cast uses it to judge range and line of sight against a target it has not selected yet,
---which is how a heal is chosen for a group member before targeting them.
---@return boolean
function ActionType:IsReady(request)
    error("Action:IsReady() not implemented")
end

---Use it. Returns as soon as the action has been *started*, which for a cast means the request
---has been handed to the casting service and the cast itself is still seconds away.
---@param request? table who is asking: `{ owner, priority, targetId }`. Skills and disciplines
---ignore it -- they fire and are done. Casts need it, because the casting service arbitrates
---between behaviors by priority and holds back everything weaker while a cast runs. A caller
---that has a band should pass it; one that does not can only cast when nothing else is.
function ActionType:DoAction(request)
    error("Action:DoAction() not implemented")
end

return ActionType
