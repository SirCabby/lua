local mq = require("mq")

local Status = {}

Status.IsFacingTarget = function()
    if (mq.TLO.Target.ID() or 0) <= 0 then return false end

    local headingTo = mq.TLO.Target.HeadingTo.DegreesCCW()
    if headingTo == nil then return false end

    local calc = math.abs(headingTo - mq.TLO.Me.Heading.DegreesCCW())
    return calc < 50 or calc > 310 -- requires heading difference < 56, so plan for < 50, or > 310 for the wrap-around
end

return Status
