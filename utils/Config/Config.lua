---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem.FileSystem")
local Json = require("utils.Json.Json")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class Config
local Config = { author = "judged", key = "Config", store = {} }

Config.__index = Config
setmetatable(Config, {
    __call = function (cls, ...)
        return cls.new(...)
    end
})

--[[
Config.store: { <-- Global / static config manager table
    "filepath1": { <-- Config:new() will be scoped to this
        "name1": { <-- each GetConfig returns this, but static reference so more copies share state and don't thrash
            ...
        }
    }
}
--]]

---@param filePath? string defaults to \config\CharName-Config.json
---@param fileSystem? FileSystem
---@return Config
function Config.new(filePath, fileSystem)
    local self = setmetatable({}, Config)

    self._ = {}
    self._.fileSystem = fileSystem or FileSystem
---@diagnostic disable-next-line: need-check-nil
    self._.filePath = filePath or fileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.json")

    -- Create config file if DNE
    if not self._.fileSystem.FileExists(self._.filePath) then
        print("Creating config file: " .. self._.filePath)
        self._.fileSystem.WriteFile(self._.filePath, { "{}" })
    end

    -- Load config if not already loaded
    local configStr = self._.fileSystem.ReadFile(self._.filePath)
    if Config.store[self._.filePath] == nil then
        Config.store[self._.filePath] = Json.Deserialize(configStr)
    end

    Debug.Log(Config.key, "Config loaded: " .. self._.filePath)
    return self
end

function Config:GetConfigRoot()
    return Config.store[self._.filePath] or {}
end

function Config:SaveConfig()
    self._.fileSystem.WriteFile(self._.filePath, Json.Serialize(Config.store[self._.filePath]))
    Debug.Log(Config.key, "Saved config [" .. self._.filePath .. "]")
end

function Config:Print()
    TableUtils.Print(Config.store[self._.filePath])
end

return Config
