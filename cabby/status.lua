local mq = require("mq")

local Status = {}

Status.IsFacingTarget = function()
    if mq.TLO.Target == nil then return false end

    local calc = math.abs(mq.TLO.Target.HeadingTo.DegreesCCW() - mq.TLO.Me.Heading.DegreesCCW())
    return calc < 50 or calc > 310 -- requires heading difference < 56, so plan for < 50, or > 310 for the wrap-around
end

return Status
