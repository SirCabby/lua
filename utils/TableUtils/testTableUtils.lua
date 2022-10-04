local mq = require("mq")
---@type TableUtils
local TableUtils = require("utils.TableUtils.TableUtils")

mq.cmd("/mqclear")

TableUtils.debug = true

local testArray1 = { 1, 2, "foo", true }
local testArray2 = {}
local notArray1 = { one = 1, two = 2}

assert(TableUtils.IsArray(testArray1))
assert(TableUtils.IsArray(testArray2))
assert(not TableUtils.IsArray(notArray1))


local arrayKeys1 = TableUtils.GetKeys(testArray1)
local arrayKeys2 = TableUtils.GetKeys(testArray2)
local notArrayKeys1 = TableUtils.GetKeys(notArray1)

TableUtils.Print(arrayKeys1)
TableUtils.Print(arrayKeys2)
TableUtils.Print(notArrayKeys1)

TableUtils.RemoveByValue(testArray1, 2)
TableUtils.Print(testArray1)
print()

TableUtils.RemoveByValue(notArray1, 2)
TableUtils.Print(notArray1)
