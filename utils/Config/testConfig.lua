local mq = require("mq")
local Config = require("utils.Config.Config")
local FileSystem = require("utils.FileSystem")
local TableUtils = require("utils.TableUtils.TableUtils")

mq.cmd("/mqclear")

local filePath = FileSystem.PathJoin(mq.configDir, "test", mq.TLO.Me.Name() .. "-Config.json")
local filePath2 = FileSystem.PathJoin(mq.configDir, "test", "test-Config.json")
local config = Config:new(filePath)
local config2 = Config:new(filePath2)

local foo = config:GetConfig("foo")
config:Print("foo")

foo = {
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

config:SaveConfig("foo", foo)

foo = config:GetConfig("foo")
config:Print("foo")


print("Config store:")
---@diagnostic disable-next-line: undefined-field
TableUtils.Print(config.store)
print("Config2 store:")
---@diagnostic disable-next-line: undefined-field
TableUtils.Print(config2.store)

print("adding bar")
config:SaveConfig("bar", { bar = "1" })
---@diagnostic disable-next-line: undefined-field
TableUtils.Print(config.store)

print("adding baz")
config:SaveConfig("baz", { baz = "2" })
---@diagnostic disable-next-line: undefined-field
TableUtils.Print(config.store)
print("Names:")
local savedNames = config:GetSavedNames()
TableUtils.Print(savedNames)
