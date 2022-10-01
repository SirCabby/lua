local mq = require("mq")
---@type TableUtils
local TableUtils = require("utils.TableUtils.TableUtils")

mq.cmd("/mqclear")

local testArray1 = { 1, 2, "foo", true }
local testArray2 = {}
local notArray1 = { one = 1, two = 2}

assert(TableUtils.IsArray(testArray1))
assert(TableUtils.IsArray(testArray2))
assert(not TableUtils.IsArray(notArray1))

print("passed")
