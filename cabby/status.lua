local mq = require("mq")

local Status = {}

---Is this character set to walk into melee?
---
---Read out of the melee state's persisted section rather than off the module, because a class that
---does not melee never loads `states/meleeState.lua` -- `classes/classes.lua` requires one class
---module and nothing else, so a wizard has no melee state at all -- and asking a question *about*
---melee should not be what drags it in.
---
---No section is the same answer as off: the class did not register the state, so nothing is going
---to walk this character into anything.
---@return boolean isEnabled
Status.IsMeleeEnabled = function()
    local section = Global.configStore:GetConfigRoot()["MeleeState"]
    return section ~= nil and section.enabled == true
end

---Is this character in travel mode -- following, and refusing every other job?
---
---Read out of the flee state's persisted section for the same reason melee is: asking a question
---*about* a state should not be what drags the module in. Every class registers FleeState, so the
---section is always there; no section still reads as off, which is the safe answer.
---@return boolean isFleeing
Status.IsFleeing = function()
    local section = Global.configStore:GetConfigRoot()["FleeState"]
    return section ~= nil and section.enabled == true
end

Status.IsFacingTarget = function()
    if (mq.TLO.Target.ID() or 0) <= 0 then return false end

    local headingTo = mq.TLO.Target.HeadingTo.DegreesCCW()
    if headingTo == nil then return false end

    local calc = math.abs(headingTo - mq.TLO.Me.Heading.DegreesCCW())
    return calc < 50 or calc > 310 -- requires heading difference < 56, so plan for < 50, or > 310 for the wrap-around
end

return Status
