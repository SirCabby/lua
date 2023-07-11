local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Owners
local Owners = { author = "judged", key = "Owners" }

---@param configFilePath string
---@return Owners
function Owners:new(configFilePath)
    local owners = {}
    setmetatable(owners, self)
    self.__index = self
    local config = Config:new(configFilePath)
    local debug = Debug:new()

    ---@param str string
    local function DebugLog(str)
        Debug:Log(Owners.key, str)
    end

    ---Adds a new owner
    ---@param name string
    function Owners:Add(name)
        local ownersConfig = config:GetConfig(Owners.key)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if not TableUtils.ArrayContains(ownersConfig, name) then
            ownersConfig[#ownersConfig + 1] = name
            print("Added [" .. name .. "] as Owner")
            Config:SaveConfig(Owners.key, ownersConfig)
            return
        end
        DebugLog(name .. " was already an owner")
    end

    ---Removes a current owner
    ---@param name string
    function Owners:Remove(name)
        local ownersConfig = config:GetConfig(Owners.key)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if TableUtils.ArrayContains(ownersConfig, name) then
            TableUtils.RemoveByValue(ownersConfig, name)
            print("Removed [" .. name .. "] as Owner")
            Config:SaveConfig(Owners.key, ownersConfig)
            return
        end
        DebugLog(name .. " was not an owner")
    end

    ---Returns true if name is listed as an owner
    ---@param name any
    ---@return boolean
    function Owners:IsOwner(name)
        local ownersConfig = config:GetConfig(Owners.key)
        return TableUtils.ArrayContains(ownersConfig, name)
    end

    function Owners:Print()
        local ownersConfig = config:GetConfig(Owners.key)
        print("My Owners: " .. TableUtils.ArrayToString(ownersConfig))
    end

    return owners
end

return Owners
