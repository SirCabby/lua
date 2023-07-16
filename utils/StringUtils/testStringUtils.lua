local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)
Debug:new()

-- Arrange
local splitStrings = {
    "foo",
    "bar",
    "baz"
}
local joinedStrings = "foo, bar, baz"
local invalidStrings = {
    "foo", "bar", 1, "baz"
}

-- TESTS

test.StringUtils.Split_withDelimiter = function()
    local splitTest = StringUtils.Split(joinedStrings, ", ")
    for i = 1, #splitStrings do
        test.equal(splitTest[i], splitStrings[i])
    end
end

test.StringUtils.Split_defaultDelimiter = function()
    local splitTest = StringUtils.Split(joinedStrings)
    for i = 1, #splitStrings do
        if i < #splitStrings then
            test.equal(splitTest[i], splitStrings[i] .. ",")
        else
            test.equal(splitTest[i], splitStrings[i])
        end
    end
end

test.StringUtils.Join_emptyTable = function()
    test.equal(StringUtils.Join({}), "")
end

test.StringUtils.Join_nilTable = function()
---@diagnostic disable-next-line: param-type-mismatch
    test.equal(StringUtils.Join(nil), "")
end

test.StringUtils.Join_invalidStrings = function()
    test.equal(StringUtils.Join(invalidStrings), "")
end

test.StringUtils.Join_singleString = function()
    test.equal(StringUtils.Join({ splitStrings[1] }), splitStrings[1])
end

test.StringUtils.Join_defaultDelimiter = function()
    test.equal(StringUtils.Join(splitStrings), splitStrings[1] .. splitStrings[2] .. splitStrings[3])
end

test.StringUtils.Join_withDelimiter = function()
    test.equal(StringUtils.Join(splitStrings, ", "), joinedStrings)
end

test.StringUtils.ToCharArray_emptyString = function()
    test.assert(TableUtils.Compare(StringUtils.ToCharArray(""), {}))
end

test.StringUtils.ToCharArray_normalString = function()
    local compareTable = {}
    for i = 1, #joinedStrings do
        compareTable[i] = joinedStrings:sub(i, i)
    end
    test.assert(TableUtils.Compare(StringUtils.ToCharArray(joinedStrings), compareTable))
end

test.StringUtils.TrimFront_hasSpaces = function()
    local spacesString = " " .. joinedStrings
    test.equal(StringUtils.TrimFront(spacesString), joinedStrings)
end

test.StringUtils.TrimFront_noSpaces = function()
    test.equal(StringUtils.TrimFront(joinedStrings), joinedStrings)
end

test.StringUtils.TabsToSpaces_defaultTabSize = function()
    test.equal(StringUtils.TabsToSpaces(3), "            ")

end

test.StringUtils.TabsToSpaces_withTabSize = function()
    test.equal(StringUtils.TabsToSpaces(4, 2), "        ")
end

-- RUN TESTS
test.summary()
