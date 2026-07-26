local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local Geometry = require("utils.Movement.Geometry")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

-- Arrange
-- EQ axes are y = northward-positive and x = westward-positive, and headings run counter
-- clockwise from north, so north is 0, west is 90, south is 180 and east is 270.
local tolerance = 0.001

---@param actual number
---@param expected number
local function near(actual, expected)
    test.almost_equal(actual, expected, tolerance)
end

-- TESTS
test.Geometry.Distance2D = function()
    near(Geometry.Distance2D(0, 0, 3, 4), 5)
    near(Geometry.Distance2D(3, 4, 0, 0), 5)
    near(Geometry.Distance2D(10, -10, 10, -10), 0)
end

test.Geometry.Distance3D = function()
    near(Geometry.Distance3D(0, 0, 0, 3, 4, 12), 13)
    near(Geometry.Distance3D(0, 0, 0, 3, 4, 0), 5)
end

test.Geometry.Normalize = function()
    near(Geometry.Normalize(0), 0)
    near(Geometry.Normalize(359.5), 359.5)
    near(Geometry.Normalize(360), 0)
    near(Geometry.Normalize(730), 10)
    near(Geometry.Normalize(-10), 350)
    near(Geometry.Normalize(-730), 350)
end

test.Geometry.HeadingTo_cardinals = function()
    near(Geometry.HeadingTo(0, 0, 10, 0), 0)    -- north
    near(Geometry.HeadingTo(0, 0, 0, 10), 90)   -- west
    near(Geometry.HeadingTo(0, 0, -10, 0), 180) -- south
    near(Geometry.HeadingTo(0, 0, 0, -10), 270) -- east
end

test.Geometry.HeadingTo_diagonals = function()
    near(Geometry.HeadingTo(0, 0, 10, 10), 45)
    near(Geometry.HeadingTo(0, 0, -10, 10), 135)
    near(Geometry.HeadingTo(0, 0, -10, -10), 225)
    near(Geometry.HeadingTo(0, 0, 10, -10), 315)
end

test.Geometry.HeadingTo_isRelativeToTheStartingPoint = function()
    near(Geometry.HeadingTo(100, 100, 110, 100), 0)
    near(Geometry.HeadingTo(-50, -50, -50, -40), 90)
end

test.Geometry.HeadingDiff = function()
    near(Geometry.HeadingDiff(0, 30), 30)
    near(Geometry.HeadingDiff(30, 0), -30)
    near(Geometry.HeadingDiff(90, 90), 0)
    near(Geometry.HeadingDiff(0, 180), 180)
end

test.Geometry.HeadingDiff_takesTheShortWayAroundZero = function()
    near(Geometry.HeadingDiff(350, 10), 20)
    near(Geometry.HeadingDiff(10, 350), -20)
    near(Geometry.HeadingDiff(359, 1), 2)
end

test.Geometry.IsWithinArc = function()
    test.assert(Geometry.IsWithinArc(0, 30, 45))
    test.assert(Geometry.IsWithinArc(0, 330, 45))
    test.assert(not Geometry.IsWithinArc(0, 60, 45))
    test.assert(not Geometry.IsWithinArc(0, 300, 45))
end

-- RUN TESTS
test.summary()
