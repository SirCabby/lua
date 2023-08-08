---@diagnostic disable: undefined-field
local mq = require("mq")

local Debug = require("utils.Debug.Debug")
local FileSystem = require("utils.FileSystem.FileSystem")
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
    self._.filePath = filePath or fileSystem.PathJoin(mq.configDir, mq.TLO.Me.Name() .. "-Config.lua")

    if Config.store[self._.filePath] == nil then
        local configData, err = loadfile(self._.filePath)
        if err then
            -- file dne
            print("Creating config file: " .. self._.filePath)
            Config.store[self._.filePath] = {}
        elseif configData then
            Config.store[self._.filePath] = configData()
        end
    end

    Debug.Log(Config.key, "Config loaded: " .. self._.filePath)
    return self
end

function Config:GetConfigRoot()
    return Config.store[self._.filePath] or {}
end

function Config:SaveConfig()
    mq.pickle(self._.filePath, Config.store[self._.filePath])
    Debug.Log(Config.key, "Saved config [" .. self._.filePath .. "]")
end

function Config:Print()
    TableUtils.Print(Config.store[self._.filePath])
end

return Config
