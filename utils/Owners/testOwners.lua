local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem")
local Owners = require("utils.Owners.Owners")

mq.cmd("/mqclear")

Debug:new()
--Debug.toggles[FileSystem.key] = true
local filePath = FileSystem.PathJoin(mq.configDir, "test", "ownersTest.json")
local owners = Owners:new(filePath)

owners:Print()
owners:Add("Test Owner 1")
owners:Print()
owners:Add("Test Owner 1")
owners:Add("Test Owner 2")
owners:Print()
print("is foo an owner? " .. tostring(owners:IsOwner("foo")))
print("is [test owner 2] an owner? " .. tostring(owners:IsOwner("Test Owner 2")))
owners:Remove("Test Owner 2")
owners:Print()
print("is [Test Owner 2] an owner? " .. tostring(owners:IsOwner("Test Owner 2")))
