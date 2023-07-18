---@type Config
local Config = require("utils.Config.Config")
local Debug = require("utils.Debug.Debug")
local TableUtils = require("utils.TableUtils.TableUtils")

---@class DebugConfig
local DebugConfig = {
    key = "DebugConfig"
}

---@param configFilePath string
---@return DebugConfig
function DebugConfig:new(configFilePath)
    local debugConfig = {}
    setmetatable(debugConfig, self)
    self.__index = self
    local config = Config:new(configFilePath)
    Debug:new()

    ---@param str string
    local function DebugLog(str)
        Debug:Log(DebugConfig.key, str)
    end

    ---@param key string
    ---@return boolean | nil
    function DebugConfig:GetDebugToggle(key)
        return Debug:GetToggle(key)
    end

    function DebugConfig:SetDebugToggle(key, value)
        DebugLog("Set debug toggle: [" .. key .. "] : [" .. tostring(value) .. "]")
        Debug:SetToggle(key, value)
        config:SaveConfig(DebugConfig.key, Debug._toggles)
    end

    function DebugConfig:FlipDebugToggle(key)
        Debug:Toggle(key)
        DebugLog("Flipped debug toggle: [" .. key .. "] : [" .. tostring(Debug:GetToggle(key)) .. "]")
        config:SaveConfig(DebugConfig.key, Debug._toggles)
    end

    function DebugConfig:Print()
        TableUtils.Print(Debug._toggles)
    end

    -- Sync Debug with DebugConfig on this ctor
    local debugConfig = config:GetConfig(DebugConfig.key)
    for k, v in pairs(debugConfig) do
        Debug:SetToggle(k, v)
    end
    config:SaveConfig(DebugConfig.key, Debug._toggles)

    return DebugConfig
end

return DebugConfig
