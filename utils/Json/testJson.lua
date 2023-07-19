local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local Json = require("utils.Json.Json")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

-- Arrange
local fooObj = {
    key = 1,
    key2 = {
        {
            foo = true,
            bar = 0
        },
        {
            boo = "hi"
        }
    }
}
local fooStr = '{    "key": 1,    "key2": [        {            "foo": true,            "bar": 0        },        {            "boo": "hi"        }    ]}'
---@type table
local serializedTable
---@type string
local serializedString

-- TESTS
test.Json.Serialize = function()
    serializedTable = Json.Serialize(fooObj)
    serializedString = StringUtils.Join(serializedTable)
    test.equal(serializedString, fooStr)
end

test.Json.DeserializeFromString = function()
    local deserialized = Json.Deserialize(serializedString)
    test.assert(TableUtils.Compare(deserialized, fooObj))
end

test.Json.DeserializeFromObject = function()
    local deserialized = Json.Deserialize(serializedTable)
    test.assert(TableUtils.Compare(deserialized, fooObj))
end

-- RUN TESTS
test.summary()
