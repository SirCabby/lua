local mq = require("mq")

local Status = {}

---Is this character in travel mode -- following, and refusing every other job?
---
---This is the flee *switch* -- a persisted order, read out of config -- not the flee state's
---runtime, so a service consulting it (Combat refuses to open fights during a run) is reading an
---order, not another state. Read from the persisted section rather than off the module so that
---asking does not drag `states/fleeState.lua` in. Every class registers FleeState, so the section
---is always there; no section still reads as off, which is the safe answer.
---@return boolean isFleeing
Status.IsFleeing = function()
    local section = Global.configStore:GetConfigRoot()["FleeState"]
    return section ~= nil and section.enabled == true
end

---How healthy a spawn is, as a percentage, or nil when there is no spawn to ask about.
---
---Not `Spawn.PctHPs`, which is `HPCurrent * 100 / HPMax` with a divide-by-zero guard that hands
---back **0** when the maximum is zero -- and a real maximum is something the client is only told
---about *this* character. For everybody else the server sends a percentage, which the client keeps
---in `HPCurrent` while the maximum stays at nothing, so the obvious read turns every group member
---into somebody at death's door. MQ reads it exactly this way round itself: `Group.Injured` takes
---the ratio for our own slot and the raw value for everyone else's.
---
---Asking which of the two we are looking at, rather than assuming, is what makes this right on a
---client that does fill the maximum in as well as one that does not.
---@param spawn any mq spawn TLO
---@return number|nil pct
Status.HealthPct = function(spawn)
    if spawn == nil or spawn.ID() == nil then return nil end

    local max = tonumber(spawn.MaxHPs()) or 0
    if max > 0 then return tonumber(spawn.PctHPs()) end

    -- nothing to divide by, so what we were sent is already the percentage
    return tonumber(spawn.CurrentHPs())
end

Status.IsFacingTarget = function()
    if (mq.TLO.Target.ID() or 0) <= 0 then return false end

    local headingTo = mq.TLO.Target.HeadingTo.DegreesCCW()
    if headingTo == nil then return false end

    local calc = math.abs(headingTo - mq.TLO.Me.Heading.DegreesCCW())
    return calc < 50 or calc > 310 -- requires heading difference < 56, so plan for < 50, or > 310 for the wrap-around
end

return Status
