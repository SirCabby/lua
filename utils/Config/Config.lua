local mq = require("mq")
local ConfigStore = require("utils.Config.ConfigStore")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
local Config = { author = "judged", key = "Config" }

---@meta Config
---Get config by name
---@param name string
---@return table
function Config:GetConfig(name) end
---Save config by name
---@param name string Config name to save content under
---@param obj table Saved content
function Config:SaveConfig(name, obj) end
---Prints the config
---@param name string
function Config:Print(name) end
---@return array configNames config names currently in use
function Config:GetSavedNames() end

---@param filePath? string
---@return Config
function Config:new(filePath)
    return Config:new(filePath, FileSystem)
end

---Overload mainly created for mocking
---@param filePath? string
---@param fileSystem FileSystem
---@return Config
function Config:new(filePath, fileSystem)
    local config = {}

    Debug:new()
    if (fileSystem == nil) then error("fileSystem was nil") end

    config.filePath = filePath or fileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.json")

    function config:GetConfig(name)
        return ConfigStore.store[config.filePath][name] or {}
    end

    function config:SaveConfig(name, obj)
        ConfigStore.store[config.filePath][name] = obj
        fileSystem.WriteFile(config.filePath, Json.Serialize(ConfigStore.store[config.filePath]))
        Debug:Log(ConfigStore.key, "Saved config [" .. name .. "]")
    end

    function config:Print(name)
        TableUtils.Print(ConfigStore.store[config.filePath][name])
    end

    function config:GetSavedNames()
        return TableUtils.GetKeys(ConfigStore.store[config.filePath])
    end

    -- Create config file if DNE
    if not fileSystem.FileExists(config.filePath) then
        print("Creating config file: " .. config.filePath)
        fileSystem.WriteFile(config.filePath, { "{}" })
    end

    -- Load config if not already loaded
    local configStr = fileSystem.ReadFile(config.filePath)
    if ConfigStore.store[config.filePath] == nil then
        ConfigStore.store[config.filePath] = Json.Deserialize(configStr)
    end

    Debug:Log(ConfigStore.key, "Config loaded: " .. filePath)
    return config
end

return Config
