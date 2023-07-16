local mq = require("mq")
local Debug = require("utils.Debug.Debug")
---@type Owners
local Owners = require("utils.Owners.Owners")
local TableUtils = require("utils.TableUtils.TableUtils")
local test = require("integration-tests.mqTest")

mq.cmd("/mqclear")
local args = { ... }
test.arguments(args)
Debug:new()

-- Arrange
local ownersConfig1 = { "name1", "name2" }
local ownersConfig2 = { "name3" }
local ownersConfig1_2 = { "name1", "name2", "namenew" }
local ownersConfig1_3 = { "name1", "namenew" }
local newOwner = "nameNew"
---@type Owners
local owners1
---@type Owners
local owners2

-- Setup Mocks
local configMock = {}
local GetConfig = 0
function configMock.GetConfig(...)
    GetConfig = GetConfig + 1
    if GetConfig == 1 or GetConfig == 2 or GetConfig == 4 or GetConfig == 7 or GetConfig == 9 then
        return ownersConfig1
    elseif GetConfig == 3 or GetConfig == 5 or GetConfig == 6 or GetConfig == 8 or GetConfig == 11 or GetConfig == 14 then
        return ownersConfig2
    elseif GetConfig == 10 or GetConfig == 12 then
        return ownersConfig1_2
    elseif GetConfig == 13 then
        return ownersConfig1_3
    end
    return "dne"
end
local SaveConfig = 0
local lastSavedConfig = {}
function configMock.SaveConfig(...)
    SaveConfig = SaveConfig + 1
    args = {...}
    lastSavedConfig = args[3]
end

-- TESTS
test.Owners.new = function()
    owners1 = Owners:new(configMock)
    owners2 = Owners:new(configMock)
    test.equal(GetConfig, 0)
end

test.Owners.IsOwner = function()
    test.is_true(owners1:IsOwner(ownersConfig1[1])) -- 1
    test.is_true(owners1:IsOwner(ownersConfig1[2])) -- 2
    test.is_true(owners2:IsOwner(ownersConfig2[1])) -- 3

    test.is_false(owners1:IsOwner(ownersConfig2[1])) -- 4
    test.is_false(owners2:IsOwner(ownersConfig1[1])) -- 5
    test.is_false(owners2:IsOwner(ownersConfig1[2])) -- 6
    test.is_false(owners1:IsOwner("dne")) -- 7
    test.is_false(owners2:IsOwner("dne")) -- 8
    test.equal(GetConfig, 8)
end

test.Owners.Add = function()
    owners1:Add(newOwner) -- 9
    test.is_true(owners1:IsOwner(newOwner)) -- 10
    test.is_false(owners2:IsOwner(newOwner)) -- 11
    test.equal(GetConfig, 11)
    test.equal(SaveConfig, 1)
    test.assert(TableUtils.Compare(lastSavedConfig, ownersConfig1_2))
end

test.Owners.Remove = function()
    owners1:Remove(ownersConfig1[2]) -- 12
    test.is_false(owners1:IsOwner(ownersConfig1[2])) -- 13
    test.is_false(owners2:IsOwner(ownersConfig1[2])) -- 14
    test.equal(GetConfig, 14)
    test.equal(SaveConfig, 2)
    test.assert(TableUtils.Compare(lastSavedConfig, ownersConfig1_3))
end

-- RUN TESTS
test.summary()
