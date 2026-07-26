---Pure distance/heading math in EverQuest's coordinate conventions.
---
---Headings are degrees counter-clockwise from north, which is what
---`${Me.Heading.DegreesCCW}` and `${Spawn.Heading.DegreesCCW}` report. EQ's axes are
---y = northward-positive and x = westward-positive, so a heading of 90 points west.
---
---This module deliberately has no dependencies so it can be exercised off-client.
---@class Geometry
local Geometry = { author = "judged", key = "Geometry" }

-- LuaJIT (5.1) has math.atan2; 5.3+ folded it into math.atan
local atan2 = math.atan2 or math.atan

---@param y1 number
---@param x1 number
---@param y2 number
---@param x2 number
---@return number distance between two points, ignoring elevation
function Geometry.Distance2D(y1, x1, y2, x2)
    local dy = y2 - y1
    local dx = x2 - x1
    return math.sqrt(dy * dy + dx * dx)
end

---@param y1 number
---@param x1 number
---@param z1 number
---@param y2 number
---@param x2 number
---@param z2 number
---@return number distance between two points, including elevation
function Geometry.Distance3D(y1, x1, z1, y2, x2, z2)
    local dy = y2 - y1
    local dx = x2 - x1
    local dz = z2 - z1
    return math.sqrt(dy * dy + dx * dx + dz * dz)
end

---@param heading number
---@return number heading normalized into [0, 360)
function Geometry.Normalize(heading)
    heading = heading % 360
    if heading < 0 then heading = heading + 360 end
    return heading
end

---Heading that must be travelled to get from point 1 to point 2
---@param y1 number
---@param x1 number
---@param y2 number
---@param x2 number
---@return number heading degrees counter-clockwise
function Geometry.HeadingTo(y1, x1, y2, x2)
    return Geometry.Normalize(math.deg(atan2(x2 - x1, y2 - y1)))
end

---Shortest signed rotation from one heading to another. Negative is clockwise.
---@param fromHeading number
---@param toHeading number
---@return number degrees within (-180, 180]
function Geometry.HeadingDiff(fromHeading, toHeading)
    local diff = Geometry.Normalize(toHeading - fromHeading)
    if diff > 180 then diff = diff - 360 end
    return diff
end

---@param fromHeading number
---@param toHeading number
---@param arc number half-width of the arc, in degrees
---@return boolean isWithinArc
function Geometry.IsWithinArc(fromHeading, toHeading, arc)
    return math.abs(Geometry.HeadingDiff(fromHeading, toHeading)) <= arc
end

return Geometry
