local mq = require("mq")
---@type Config
local Config = require("utils.Config.Config")
local ConfigStore = require("utils.Config.ConfigStore")
local Debug = require("utils.Debug.Debug")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)
Debug:new()

-- Arrange
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
local fooStr = Json.Serialize(fooObj)
local foo2Obj = {
    foo4 = "new"
}
---@type Config
local config1
---@type Config
local config2
local file1 = "file1"
local file2 = "file2"

-- Setup Mocks
local FileExistsCalls = 0
local WriteFileCalls = 0
local ReadFileCalls = 0
local fileSystemMock = {}
function fileSystemMock.FileExists(...)
    FileExistsCalls = FileExistsCalls + 1
    return false
end
function fileSystemMock.WriteFile(...)
    WriteFileCalls = WriteFileCalls + 1
end
function fileSystemMock.ReadFile(...)
    ReadFileCalls = ReadFileCalls + 1
    return fooStr
end

-- TESTS
test.Config.new = function()
    config1 = Config:new(file1, fileSystemMock)
    config2 = Config:new(file2, fileSystemMock)

    --Debug:SetToggle(TableUtils.key, true)
    test.equal(FileExistsCalls, 2)
    test.equal(WriteFileCalls, 2)
    test.equal(ReadFileCalls, 2)
    test.assert(TableUtils.Compare(ConfigStore.store[file1], fooObj))
    test.assert(TableUtils.Compare(ConfigStore.store[file2], fooObj))
    --Debug:SetToggle(TableUtils.key, false)
end

test.Config.GetConfig = function()
    test.assert(config1:GetConfig("foo1") == "hi")
    test.assert(TableUtils.Compare(fooObj.foo2, config1:GetConfig("foo2")))
    test.assert(TableUtils.Compare(fooObj.foo3, config1:GetConfig("foo3")))
end

test.Config.GetSavedNames = function()
    local savedNames = config1:GetSavedNames()
    test.assert(TableUtils.ArrayContains(savedNames, "foo1"))
    test.assert(TableUtils.ArrayContains(savedNames, "foo2"))
    test.assert(TableUtils.ArrayContains(savedNames, "foo3"))
end

test.Config.SaveConfig = function()
    config1:SaveConfig("foo1", foo2Obj)
    test.assert(TableUtils.Compare(ConfigStore.store[file1]["foo1"], foo2Obj))
    test.assert(TableUtils.Compare(config1:GetConfig("foo1"), foo2Obj))
    test.assert(config2:GetConfig("foo1") == "hi")
    test.equal(WriteFileCalls, 3)
end

-- RUN TESTS
test.summary()
