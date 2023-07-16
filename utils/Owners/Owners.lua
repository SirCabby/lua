---@type Config
local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local StringUtils = require("utils.StringUtils.StringUtils")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Owners
local Owners = { author = "judged", key = "Owners" }

---@meta Owners
---Adds a new owner
---@param name string
function Owners:Add(name) end
---Removes a current owner
---@param name string
function Owners:Remove(name) end
---Returns true if name is listed as an owner
---@param name string
---@return boolean
function Owners:IsOwner(name) end

---@param configFilePath string
---@return Owners
function Owners:new(configFilePath)
    return Owners:new(Config:new(configFilePath))
end

---Mainly used for mocking
---@param config Config
---@return Owners
function Owners:new(config)
    local owners = {}

    ---@type Config
    if (config == nil) then error("config was nil") end
    Debug:new()

    ---@param str string
    local function DebugLog(str)
        Debug:Log(Owners.key, str)
    end

    function owners:Add(name)
        name = name:lower()
        local ownersConfig = config:GetConfig(Owners.key)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if not TableUtils.ArrayContains(ownersConfig, name) then
            ownersConfig[#ownersConfig + 1] = name
            print("Added [" .. name .. "] as Owner")
            config:SaveConfig(Owners.key, ownersConfig)
            return
        end
        DebugLog(name .. " was already an owner")
    end

    function owners:Remove(name)
        name = name:lower()
        local ownersConfig = config:GetConfig(Owners.key)
        if not TableUtils.IsArray(ownersConfig) then error("Owners config was not an array") end
        if TableUtils.ArrayContains(ownersConfig, name) then
            TableUtils.RemoveByValue(ownersConfig, name)
            print("Removed [" .. name .. "] as Owner")
            config:SaveConfig(Owners.key, ownersConfig)
            return
        end
        DebugLog(name .. " was not an owner")
    end

    function owners:IsOwner(name)
        local ownersConfig = config:GetConfig(Owners.key)
        return TableUtils.ArrayContains(ownersConfig, name:lower())
    end

    function owners:Print()
        local ownersConfig = config:GetConfig(Owners.key)
        print("My Owners: [" .. StringUtils.Join(ownersConfig, ", ") .. "]")
    end

    return owners
end

return Owners
