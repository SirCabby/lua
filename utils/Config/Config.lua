local mq = require("mq")
local FileSystem = require("utils.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
local Config = { author = "judged", debug = false, store = {} }

-- Config.store: { <-- Global / static config manager table
--     "filepath1": { <-- Config:new() will be scoped to this
--         "name1": { <-- each GetConfig returns this, but static reference so more copies share state and don't thrash
--             ...
--         }
--     }
-- }

local function Debug(str)
    if Config.debug then print(str) end
end

---@param filePath? string
---@return Config
function Config:new(filePath)
    local config = {}
    setmetatable(config, self)
    self.__index = self
    config.filePath = filePath or FileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.json")
    if not FileSystem.FileExists(config.filePath) then
        print("Creating config file: " .. config.filePath)
        FileSystem.WriteFile(config.filePath, { "{}" })
    end
    local configStr = FileSystem.ReadFile(config.filePath)
    -- check if this file is already loaded
    if Config.store[config.filePath] == nil then
        Config.store[config.filePath] = Json.Deserialize(configStr)
    end

    ---Get config by name
    ---@param name string
    ---@return table
    function Config:GetConfig(name)
        return Config.store[config.filePath][name] or {}
    end

    ---Save config by name
    ---@param name string
    ---@param obj table
    function Config:SaveConfig(name, obj)
        Config.store[config.filePath][name] = obj
        FileSystem.WriteFile(config.filePath, Json.Serialize(Config.store[config.filePath]))
        if Config.debug then print("Saved config [" .. name .. "]") end
    end

    ---Prints the config
    ---@param name string
    function Config:Print(name)
        TableUtils.Print(Config.store[config.filePath][name])
    end

    ---Return config names currently in use
    function Config:GetSavedNames()
        return TableUtils.GetKeys(Config.store[config.filePath])
    end

    Debug("Config loaded: " .. filePath)
    return config
end

return Config
