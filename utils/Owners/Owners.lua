local Config = require("utils.Config.Config")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Owners
local Owners = { author = "judged", debug = false, configKey = "Owners" }

---@param configFilePath string
---@return Owners
function Owners:new(configFilePath)
    local owners = {}
    setmetatable(owners, self)
    self.__index = self
    local config = Config:new(configFilePath)

    ---@param str string
    local function Debug(str)
        if Owners.debug then print(str) end
    end

    ---Adds a new owner
    ---@param name string
    function Owners:Add(name)
        local ownersConfig = config:GetConfig(Owners.configKey)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if not TableUtils.ArrayContains(ownersConfig, name) then
            ownersConfig[#ownersConfig + 1] = name
            print("Added [" .. name .. "] as Owner")
            Config:SaveConfig(Owners.configKey, ownersConfig)
            return
        end
        Debug(name .. " was already an owner")
    end

    ---Removes a current owner
    ---@param name string
    function Owners:Remove(name)
        local ownersConfig = config:GetConfig(Owners.configKey)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if TableUtils.ArrayContains(ownersConfig, name) then
            TableUtils.RemoveByValue(ownersConfig, name)
            print("Removed [" .. name .. "] as Owner")
            Config:SaveConfig(Owners.configKey, ownersConfig)
            return
        end
        Debug(name .. " was not an owner")
    end

    ---Returns true if name is listed as an owner
    ---@param name any
    ---@return boolean
    function Owners:IsOwner(name)
        local ownersConfig = config:GetConfig(Owners.configKey)
        return TableUtils.ArrayContains(ownersConfig, name)
    end

    function Owners:Print()
        local ownersConfig = config:GetConfig(Owners.configKey)
        TableUtils.PrintArray(ownersConfig)
    end

    return owners
end

return Owners
