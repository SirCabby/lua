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

---The half of `IsReady` that is about *them* rather than about us: could this land on that spawn
---from where we are standing, leaving aside cooldowns and resources. A caller that walks a list
---asks it to tell "wait a beat" apart from "they are not here" -- the first is worth holding the
---list for and the second is not.
---
---Answered `true` by default: anything with no range to speak of -- a skill, a discipline, a
---self-aimed cast -- reaches whoever it is for by definition, and only `CastAction` has a reason
---to say otherwise.
---@param targetId? number whoever it would be for; what is targeted now when left out
---@return boolean canReach
---@diagnostic disable-next-line: unused-local
function ActionType:CanReach(targetId)
    return true
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
