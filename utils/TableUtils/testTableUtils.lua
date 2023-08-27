local mq = require("mq")
local test = require("IntegrationTests.mqTest")

local Debug = require("utils.Debug.Debug")
---@type TableUtils
local TableUtils = require("utils.TableUtils.TableUtils")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

-- Arrange
local array = { "hi", { "bye" }, 3, false, 0, 3}
local fakeArray = { ["1"] = "foo", ["2"] = "bar", ["4"] = "baz" }
local emptyTable = {}
local notArrayTable = { hey = "foo", there = "bar", where = "baz" }

-- TESTS

test.TableUtils.IsArray_yes = function()
    test.is_true(TableUtils.IsArray(array))
end

test.TableUtils.IsArray_fake = function()
    test.is_false(TableUtils.IsArray(fakeArray))
end

test.TableUtils.IsArray_empty = function()
    test.is_true(TableUtils.IsArray(emptyTable))
end

test.TableUtils.IsArray_notArrayTable = function()
    test.is_false(TableUtils.IsArray(notArrayTable))
end

test.TableUtils.ArrayContains_notArrayErrors = function()
    test.error_raised(TableUtils.ArrayContains, "Cannot call ArrayContains on a key-value table", notArrayTable)
end

test.TableUtils.ArrayContains_yes = function()
    for i = 1, #array do
        test.is_true(TableUtils.ArrayContains(array, array[i]))
    end
end

test.TableUtils.ArrayContains_yesCaseInSensitive = function()
    test.is_true(TableUtils.ArrayContains(array, "HI"))
end

test.TableUtils.RemoveByValue_arrayCaseInsensitive = function()
    local array = { "hi", { "bye" }, 3, false, 0, 3}
    TableUtils.RemoveByValue(array, "HI")
    test.is_false(TableUtils.ArrayContains(array, "hi"))
    test.equal(#array, 5)
end

test.TableUtils.RemoveByValue_arrayMultipleEntries = function()
    local array = { "hi", { "bye" }, 3, false, 0, 3}
    TableUtils.RemoveByValue(array, 3)
    test.is_false(TableUtils.ArrayContains(array, 3))
    test.equal(#array, 4)
end

test.TableUtils.RemoveByValue_arrayNoRemoval = function()
    local array = { "hi", { "bye" }, 3, false, 0, 3}
    TableUtils.RemoveByValue(array, "dne")
    test.equal(#array, 6)
end

test.TableUtils.RemoveByValue_tableCaseInsensitive = function()
    local table = { foo = "bar", baz = 3, bizz = false }
    TableUtils.RemoveByValue(table, "BAR")
    test.equal(table["foo"], nil)
    test.equal(table["baz"], 3)
    test.equal(table["bizz"], false)
end

test.TableUtils.RemoveByValue_tableMultipleEntries = function()
    local table = { foo = "bar", baz = 3, bizz = false, barl = 3 }
    TableUtils.RemoveByValue(table, 3)
    test.equal(table["foo"], "bar")
    test.equal(table["baz"], nil)
    test.equal(table["bizz"], false)
    test.equal(table["barl"], nil)
end

test.TableUtils.RemoveByValue_tableNoRemoval = function()
    local table = { foo = "bar", baz = 3, bizz = false }
    TableUtils.RemoveByValue(table, "dne")
    test.equal(table["foo"], "bar")
    test.equal(table["baz"], 3)
    test.equal(table["bizz"], false)
end

test.TableUtils.GetKeys_arrayIsIndexes = function()
    local keys = TableUtils.GetKeys(array)
    for i = 1, #array do
        test.equal(keys[i], i)
    end
    test.equal(#keys, #array)
end

test.TableUtils.GetKeys_table = function()
    local keys = TableUtils.GetKeys(notArrayTable)
    test.assert(TableUtils.IsArray(keys))

    local count = 0
    for k,_ in pairs(notArrayTable) do
        test.assert(TableUtils.ArrayContains(keys, k))
        count = count + 1
    end
    test.equal(#keys, count)
end

test.TableUtils.GetKeys_emptyTable = function()
    local keys = TableUtils.GetKeys({})
    test.equal(#keys, 0)
end

test.TableUtils.GetValues_array = function()
    local values = TableUtils.GetValues(array)
    for i = 1, #array do
        test.equal(values[i], array[i])
    end
    test.equal(#values, #array)
end

test.TableUtils.GetValues_table = function()
    local values = TableUtils.GetValues(notArrayTable)
    test.assert(TableUtils.IsArray(values))

    local count = 0
    for _,v in pairs(notArrayTable) do
        test.assert(TableUtils.ArrayContains(values, v))
        count = count + 1
    end
    test.equal(#values, count)
end

test.TableUtils.GetValues_emptyTable = function()
    local values = TableUtils.GetValues({})
    test.equal(#values, 0)
end

test.TableUtils.Compare_matchingTables = function()
    local fooObj1 = {
        foo1 = "hi",
        foo2 = {
            "test1", 2, 3, false, 5
        },
        foo3 = {
            bar1 = {
                baz1 = "deep"
            }
        }
    }
    local fooObj2 = {
        foo1 = "hi",
        foo2 = {
            "test1", 2, 3, false, 5
        },
        foo3 = {
            bar1 = {
                baz1 = "deep"
            }
        }
    }
    test.is_true(TableUtils.Compare(fooObj1, fooObj2))
end

test.TableUtils.Compare_missmatchingTables = function()
    local fooObj1 = {
        foo1 = "hi",
        foo2 = {
            "test1", 2, 3, false, 5
        },
        foo3 = {
            bar1 = {
                baz1 = "deep"
            }
        }
    }
    local fooObj2 = {
        foo1 = "hi",
        foo2 = {
            "test1", 2, 3, false, 5
        },
        foo3 = {
            bar1 = {
                baz1 = "deep",
                baz2 = "deeper"
            }
        }
    }
    test.is_false(TableUtils.Compare(fooObj1, fooObj2))
end

test.TableUtils.Compare_matchingArrays = function()
    local array1 = { "hi", { "bye" }, 3, false, 0, 3 }
    local array2 = { "hi", { "bye" }, 3, false, 0, 3 }
    test.is_true(TableUtils.Compare(array1, array2))
end

test.TableUtils.Compare_missmatchingArrays = function()
    local array1 = { "hi", { "bye" }, 3, false, 0, 3 }
    local array2 = { "hi", { "bye", "barl" }, 3, false, 0, 3 }
    test.is_false(TableUtils.Compare(array1, array2))
end

test.TableUtils.Compare_emptyTables = function()
    local tbl1 = { }
    local tbl2 = { }
    test.is_true(TableUtils.Compare(tbl1, tbl2))
end

test.TableUtils.DeepClone_table = function()
    local fooObj = {
        foo1 = "hi",
        foo2 = {
            "test1", 2, 3, false, 5
        },
        foo3 = {
            bar1 = {
                baz1 = "deep"
            }
        }
    }
    local clone = TableUtils.DeepClone(fooObj) or {}
    test.assert(TableUtils.Compare(fooObj, clone))
end

test.TableUtils.DeepClone_array = function()
    local clone = TableUtils.DeepClone(array) or {}
    test.assert(TableUtils.Compare(array, clone))
end

test.TableUtils.DeepClone_emptyTable = function()
    local clone = TableUtils.DeepClone({})
---@diagnostic disable-next-line: param-type-mismatch
    test.assert(TableUtils.Compare({}, clone))
end

test.TableUtils.Subtract = function()
    local superset = { 1, 2, 3, 2, 2, 4, 5 }
    local subset = { 2, 3 }
    local result = TableUtils.ArraySubtract(superset, subset)
    test.equal(#result, 3)
end

-- RUN TESTS
test.summary()
