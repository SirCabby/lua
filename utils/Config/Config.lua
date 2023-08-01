local mq = require("mq")
local ConfigStore = require("utils.Config.ConfigStore")
local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
local Config = { author = "judged", key = "Config" }

---@meta Config
---Get config root storage table
---@return table
function Config:GetConfigRoot() end
---Save config
function Config:SaveConfig() end
---Prints the config
---@param name string
function Config:Print(name) end
---@return array sectionNames config section names currently in use
function Config:GetSectionNames() end

---@param filePath? string defaults to \config\CharName-Config.json
---@param fileSystem? FileSystem
---@return Config
function Config:new(filePath, fileSystem)
    local config = {}

    fileSystem = fileSystem or FileSystem
    config.filePath = filePath or fileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.json")

    function config:GetConfigRoot()
        return ConfigStore.get()[config.filePath] or {}
    end

    function config:SaveConfig()
        fileSystem.WriteFile(config.filePath, Json.Serialize(ConfigStore.get()[config.filePath]))
        Debug.Log(ConfigStore.key, "Saved config [" .. config.filePath .. "]")
    end

    function config:Print()
        TableUtils.Print(ConfigStore.get()[config.filePath])
    end

    function config:GetSectionNames()
        return TableUtils.GetKeys(ConfigStore.get()[config.filePath])
    end

    -- Create config file if DNE
    if not fileSystem.FileExists(config.filePath) then
        print("Creating config file: " .. config.filePath)
        fileSystem.WriteFile(config.filePath, { "{}" })
    end

    -- Load config if not already loaded
    local configStr = fileSystem.ReadFile(config.filePath)
    if ConfigStore.get()[config.filePath] == nil then
        ConfigStore.get()[config.filePath] = Json.Deserialize(configStr)
    end

    Debug.Log(ConfigStore.key, "Config loaded: " .. filePath)
    return config
end

return Config
