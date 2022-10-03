local mq = require("mq")
local FileSystem = require("utils.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
---@field store table
---@field filePath string
local Config = { author = "judged" }

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
    config.store = Json.Deserialize(configStr)

    ---Get config by name
    ---@param name string
    ---@return table
    function Config:GetConfig(name)
        return self.store[name] or {}
    end

    ---Save config by name
    ---@param name string
    ---@param obj table
    function Config:SaveConfig(name, obj)
        self.store[name] = obj
        FileSystem.WriteFile(self.filePath, Json.Serialize(self.store))
        print("Saved config [" .. name .. "]")
    end

    ---Prints the config
    ---@param name string
    function Config:Print(name)
        TableUtils.Print(self.store[name])
    end

    ---Return config names currently in use
    function Config:GetSavedNames()
        return TableUtils.GetKeys(self.store)
    end

    return config
end

return Config
