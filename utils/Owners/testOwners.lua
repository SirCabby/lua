local mq = require("mq")
local Debug = require("utils.Debug.Debug")
---@type Owners
local Owners = require("utils.Owners.Owners")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)

Debug.SetToggle(Owners.key, true)

-- Arrange
local ownersConfig1 = { owners = { "name1", "name2" } }
local ownersConfig2 = { owners = { "name3" } }
local ownersConfig3 = {
    foo = {
        bar = {
            baz = { owners = { "name4" } }
        }
    }
}
local ownersConfig1_2 = { "name1", "name2", "namenew" }
local ownersConfig1_3 = { "name1", "namenew" }
local newOwner = "nameNew"
---@type Owners
local owners1
---@type Owners
local owners2
---@type Owners
local owners3

-- Setup Mocks
local configMock = {}
local GetConfigRoot = 0
function configMock.GetConfigRoot()
    GetConfigRoot = GetConfigRoot + 1
    if GetConfigRoot == 1 or GetConfigRoot == 4 then
        return ownersConfig1
    elseif GetConfigRoot == 2 then
        return ownersConfig2
    elseif GetConfigRoot == 3 then
        return ownersConfig3
    else
        test.equal("Called GetConfigRoot more than expected", false)
    end
end
local SaveConfig = 0
function configMock.SaveConfig()
    SaveConfig = SaveConfig + 1
end

-- TESTS
test.Owners.new = function()
    owners1 = Owners:new(configMock, "")
    owners2 = Owners:new(configMock, "")
    owners3 = Owners:new(configMock, "foo.bar.baz")
    test.equal(GetConfigRoot, 3)
end

test.Owners.IsOwner = function()
    test.is_true(owners1:IsOwner(ownersConfig1.owners[1])) -- 1
    test.is_true(owners1:IsOwner(ownersConfig1.owners[2])) -- 2
    test.is_true(owners2:IsOwner(ownersConfig2.owners[1])) -- 3
    test.is_true(owners3:IsOwner(ownersConfig3.foo.bar.baz.owners[1])) -- 3

    test.is_false(owners1:IsOwner(ownersConfig2.owners[1])) -- 4
    test.is_false(owners2:IsOwner(ownersConfig1.owners[1])) -- 5
    test.is_false(owners2:IsOwner(ownersConfig1.owners[2])) -- 6
    test.is_false(owners1:IsOwner("dne")) -- 7
    test.is_false(owners2:IsOwner("dne")) -- 8
    test.equal(GetConfigRoot, 3)
end

test.Owners.Add = function()
    owners1:Add(newOwner) -- 9
    test.is_true(owners1:IsOwner(newOwner)) -- 10
    test.is_false(owners2:IsOwner(newOwner)) -- 11
    test.equal(GetConfigRoot, 3)
    test.equal(SaveConfig, 4)
    test.assert(TableUtils.Compare(ownersConfig1.owners, ownersConfig1_2))
end

test.Owners.Remove = function()
    local removeName = ownersConfig1.owners[2]
    owners1:Remove(removeName) -- 12
    test.is_false(owners1:IsOwner(removeName)) -- 13
    test.is_false(owners2:IsOwner(removeName)) -- 14
    test.equal(GetConfigRoot, 3)
    test.equal(SaveConfig, 5)
    test.assert(TableUtils.Compare(ownersConfig1.owners, ownersConfig1_3))
end

test.Owners.GetOwners = function()
    test.assert(TableUtils.Compare(owners1:GetOwners(), ownersConfig1_3))
end

-- RUN TESTS
test.summary()
