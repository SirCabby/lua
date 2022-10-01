local mq = require("mq")
---@type ArrayUtils
local ArrayUtils = require("utils.ArrayUtils.ArrayUtils")

mq.cmd("/mqclear")

local testArray1 = { 1, 2, "foo", true }
local testArray2 = {}
local notArray1 = { one = 1, two = 2}

assert(ArrayUtils.IsArray(testArray1))
assert(ArrayUtils.IsArray(testArray2))
assert(not ArrayUtils.IsArray(notArray1))

print("passed")
