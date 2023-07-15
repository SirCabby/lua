local mq = require("mq")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
local Config = { author = "judged", key = "Config", store = {}, _mocks = { FileSystem = nil } }

---@class ConfigInstance
local ConfigInstance = {}

---@meta ConfigInstance
---Get config by name
---@param name string
---@return table
function ConfigInstance:GetConfig(name) end
---Save config by name
---@param name string Config name to save content under
---@param obj table Saved content
function ConfigInstance:SaveConfig(name, obj) end
---Prints the config
---@param name string
function ConfigInstance:Print(name) end
---@return array configNames config names currently in use
function ConfigInstance:GetSavedNames() end

--[[
Config.store: { <-- Global / static config manager table
    "filepath1": { <-- Config:new() will be scoped to this
        "name1": { <-- each GetConfig returns this, but static reference so more copies share state and don't thrash
            ...
        }
    }
}
--]]

---@param filePath? string
---@return ConfigInstance
function Config:new(filePath)
    local config = {}
    setmetatable(config, self)
    self.__index = self

    Debug:new()
    if (Config._mocks.FileSystem ~= nil) then
        FileSystem = Config._mocks.FileSystem
    end
    if (FileSystem == nil) then error("FileSystem was nil") end

    config.filePath = filePath or FileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.json")

    function config:GetConfig(name)
        return Config.store[config.filePath][name] or {}
    end

    function config:SaveConfig(name, obj)
        Config.store[config.filePath][name] = obj
        FileSystem.WriteFile(config.filePath, Json.Serialize(Config.store[config.filePath]))
        Debug:Log(Config.key, "Saved config [" .. name .. "]")
    end

    function config:Print(name)
        TableUtils.Print(Config.store[config.filePath][name])
    end

    function config:GetSavedNames()
        return TableUtils.GetKeys(Config.store[config.filePath])
    end

    -- Create config file if DNE
    if not FileSystem.FileExists(config.filePath) then
        print("Creating config file: " .. config.filePath)
        FileSystem.WriteFile(config.filePath, { "{}" })
    end

    -- Load config if not already loaded
    local configStr = FileSystem.ReadFile(config.filePath)
    if Config.store[config.filePath] == nil then
        Config.store[config.filePath] = Json.Deserialize(configStr)
    end

    Debug:Log(Config.key, "Config loaded: " .. filePath)
    return config
end

return Config
